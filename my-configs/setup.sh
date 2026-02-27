#!/bin/sh
# =============================================================================
# OpenWrt / X-WRT Bare-Metal 3-VLAN Setup
# Hardware : Xiaomi Mi Router 4A Gigabit (MT7621, 16MB Flash, 128MB RAM)
# Base OS  : OpenWrt 23.05.5 or X-WRT (fw4 / nftables)
#
# Networks:
#   Main  LAN : 192.168.15.0/24  br-lan       → PPPoE WAN (HW offloaded)
#   VPN   LAN : 192.168.10.0/24  br-tun_lan   → ProtonVPN wg0
#   SOCKS5 LAN: 192.168.20.0/24  br-prx_lan   → redsocks (SOCKS5 proxy)
#
# Killswitch : blackhole table 200 — VPN clients drop if wg0 goes down
# HW Offload : ENABLED for Main only — VLAN10/20 self-excluded by design
# IPv6       : BLOCKED on VLAN10 + VLAN20
#
# Run AFTER  : sysupgrade + first boot + PPPoE working on main LAN
# =============================================================================

echo "=== Bare-Metal 3-VLAN Setup (fw4 / nftables) ==="

# =============================================================================
# Load secrets
# /etc/vpn-secrets.conf must define:
#   WG_PRIVATE_KEY   — WireGuard private key
#   WG_PUBLIC_KEY    — ProtonVPN server public key
#   WG_ADDRESS       — Your ProtonVPN assigned tunnel IP e.g. 10.2.0.2/32
#   WG_ENDPOINT      — ProtonVPN server IP (use IP not hostname for stability)
#   VPN_WIFI_KEY     — VPN SSID password
#   SOCKS5_WIFI_KEY  — SOCKS5 SSID password
#   SOCKS5_SERVER    — Your SOCKS5 proxy IP
#   SOCKS5_PORT      — Proxy port
#   SOCKS5_USER      — Proxy username (leave empty if none)
#   SOCKS5_PASS      — Proxy password (leave empty if none)
# =============================================================================
SECRETS_FILE="/etc/vpn-secrets.conf"
if [ ! -f "$SECRETS_FILE" ]; then
    echo "ERROR: $SECRETS_FILE not found"
    echo "Create it with: WG_PRIVATE_KEY, WG_PUBLIC_KEY, WG_ADDRESS,"
    echo "WG_ENDPOINT, VPN_WIFI_KEY, SOCKS5_WIFI_KEY, SOCKS5_SERVER,"
    echo "SOCKS5_PORT, SOCKS5_USER, SOCKS5_PASS"
    exit 1
fi
. "$SECRETS_FILE"

echo "[0/9] Waiting for network to stabilize..."
sleep 3

# =============================================================================
# STEP 1: WIREGUARD INTERFACE (wg0)
# =============================================================================
# route_allowed_ips=0 — we manage routes manually via table 200 in the
# hotplug script. If we let OpenWrt auto-install routes from allowed_ips,
# it installs a default route in the main table which breaks the main LAN.
#
# No listen_port — client-only mode, kernel picks ephemeral port.
# MTU 1360 — proven on this hardware/ISP from working xwrt script.
# persistent_keepalive=25 — keeps NAT mapping alive through ISP NAT.
# =============================================================================
echo "[1/9] Configuring WireGuard interface..."

uci set network.wg0=interface
uci set network.wg0.proto='wireguard'
uci set network.wg0.private_key="$WG_PRIVATE_KEY"
uci set network.wg0.mtu='1360'
uci del network.wg0.addresses 2>/dev/null || true
uci add_list network.wg0.addresses="$WG_ADDRESS"

# Remove all existing peers first — makes script safe to re-run
while uci -q get network.@wireguard_wg0[0] > /dev/null 2>&1; do
    uci del network.@wireguard_wg0[0]
done

uci add network wireguard_wg0
uci set network.@wireguard_wg0[-1].public_key="$WG_PUBLIC_KEY"
uci add_list network.@wireguard_wg0[-1].allowed_ips='0.0.0.0/0'
uci set network.@wireguard_wg0[-1].route_allowed_ips='0'
uci set network.@wireguard_wg0[-1].endpoint_host="$WG_ENDPOINT"
uci set network.@wireguard_wg0[-1].endpoint_port='51820'
uci set network.@wireguard_wg0[-1].persistent_keepalive='25'

# =============================================================================
# STEP 2: VPN LAN — tun_lan (VLAN10, br-tun_lan)
# =============================================================================
# DNS option 6 = 10.2.0.1 (ProtonVPN internal resolver).
# Clients must not use ISP DNS — pushing 10.2.0.1 explicitly prevents
# any fallback to dnsmasq or the ISP resolver on VLAN10.
# MTU 1360 matches tunnel — prevents fragmentation inside WireGuard.
# delegate=0 — disables IPv6 prefix delegation, closes IPv6 leak path.
# ra/dhcpv6 disabled — belt-and-suspenders IPv6 kill at DHCP level.
# =============================================================================
echo "[2/9] Configuring VPN LAN (tun_lan)..."

uci set network.tun_lan=interface
uci set network.tun_lan.type='bridge'
uci set network.tun_lan.proto='static'
uci set network.tun_lan.ipaddr='192.168.10.1'
uci set network.tun_lan.netmask='255.255.255.0'
uci set network.tun_lan.mtu='1360'
uci set network.tun_lan.delegate='0'

uci set dhcp.tun_lan=dhcp
uci set dhcp.tun_lan.interface='tun_lan'
uci set dhcp.tun_lan.start='100'
uci set dhcp.tun_lan.limit='150'
uci set dhcp.tun_lan.leasetime='12h'
uci del dhcp.tun_lan.dhcp_option 2>/dev/null || true
uci add_list dhcp.tun_lan.dhcp_option='6,10.2.0.1'
uci set dhcp.tun_lan.ra='disabled'
uci set dhcp.tun_lan.dhcpv6='disabled'

# =============================================================================
# STEP 3: SOCKS5 LAN — prx_lan (VLAN20, br-prx_lan)
# =============================================================================
# DNS pushed to clients = router itself (192.168.20.1).
# Clients query 192.168.20.1 → nftables PREROUTING redirects UDP/53
# to dns2socks on port 5300 BEFORE it reaches dnsmasq.
# dns2socks tunnels the query through the SOCKS5 proxy → zero DNS leak.
# delegate=0 + ra/dhcpv6 disabled — same IPv6 kill as VLAN10.
# =============================================================================
echo "[3/9] Configuring SOCKS5 LAN (prx_lan)..."

uci set network.prx_lan=interface
uci set network.prx_lan.type='bridge'
uci set network.prx_lan.proto='static'
uci set network.prx_lan.ipaddr='192.168.20.1'
uci set network.prx_lan.netmask='255.255.255.0'
uci set network.prx_lan.delegate='0'

uci set dhcp.prx_lan=dhcp
uci set dhcp.prx_lan.interface='prx_lan'
uci set dhcp.prx_lan.start='100'
uci set dhcp.prx_lan.limit='150'
uci set dhcp.prx_lan.leasetime='12h'
uci del dhcp.prx_lan.dhcp_option 2>/dev/null || true
uci add_list dhcp.prx_lan.dhcp_option='6,192.168.20.1'
uci set dhcp.prx_lan.ra='disabled'
uci set dhcp.prx_lan.dhcpv6='disabled'

# =============================================================================
# STEP 4: WIFI — Dual-band SSIDs (2.4GHz + 5GHz per VLAN)
# =============================================================================
# MT7603 (radio0) = 2.4GHz, MT7612 (radio1) = 5GHz.
# Same SSID + password on both radios = client picks best band.
# This is the standard band-steering substitute on hardware that does
# not support 802.11k/v/r (which the 4A Gigabit does not).
# Main WiFi is already configured — we do not touch it.
# sae-mixed = WPA2/WPA3 mixed — same as your working xwrt script.
# =============================================================================
echo "[4/9] Configuring WiFi SSIDs..."

# VPN WiFi 2.4GHz
uci set wireless.vpn_wifi_2g=wifi-iface
uci set wireless.vpn_wifi_2g.device='radio0'
uci set wireless.vpn_wifi_2g.mode='ap'
uci set wireless.vpn_wifi_2g.ssid='OpenWrt VPN'
uci set wireless.vpn_wifi_2g.encryption='sae-mixed'
uci set wireless.vpn_wifi_2g.key="$VPN_WIFI_KEY"
uci set wireless.vpn_wifi_2g.network='tun_lan'
uci set wireless.vpn_wifi_2g.disabled='0'

# VPN WiFi 5GHz
uci set wireless.vpn_wifi_5g=wifi-iface
uci set wireless.vpn_wifi_5g.device='radio1'
uci set wireless.vpn_wifi_5g.mode='ap'
uci set wireless.vpn_wifi_5g.ssid='OpenWrt VPN'
uci set wireless.vpn_wifi_5g.encryption='sae-mixed'
uci set wireless.vpn_wifi_5g.key="$VPN_WIFI_KEY"
uci set wireless.vpn_wifi_5g.network='tun_lan'
uci set wireless.vpn_wifi_5g.disabled='0'

# SOCKS5 WiFi 2.4GHz
uci set wireless.socks_wifi_2g=wifi-iface
uci set wireless.socks_wifi_2g.device='radio0'
uci set wireless.socks_wifi_2g.mode='ap'
uci set wireless.socks_wifi_2g.ssid='OpenWrt SOCKS5'
uci set wireless.socks_wifi_2g.encryption='sae-mixed'
uci set wireless.socks_wifi_2g.key="$SOCKS5_WIFI_KEY"
uci set wireless.socks_wifi_2g.network='prx_lan'
uci set wireless.socks_wifi_2g.disabled='0'

# SOCKS5 WiFi 5GHz
uci set wireless.socks_wifi_5g=wifi-iface
uci set wireless.socks_wifi_5g.device='radio1'
uci set wireless.socks_wifi_5g.mode='ap'
uci set wireless.socks_wifi_5g.ssid='OpenWrt SOCKS5'
uci set wireless.socks_wifi_5g.encryption='sae-mixed'
uci set wireless.socks_wifi_5g.key="$SOCKS5_WIFI_KEY"
uci set wireless.socks_wifi_5g.network='prx_lan'
uci set wireless.socks_wifi_5g.disabled='0'

# =============================================================================
# STEP 5: FIREWALL ZONES (fw4 UCI)
# =============================================================================
# Hardware offloading ON globally.
# VLAN10 is self-excluded: wg0 is a tunnel — PPE cannot create a hardware
# shortcut through it (no L2 nexthop). Every VLAN10 packet stays in
# the software path hitting nftables on every packet.
# VLAN20 is self-excluded: redsocks redirect in PREROUTING sends packets
# to a local socket (LOCAL_IN path). The FORWARD hook and PPE flowtable
# are never reached for redirected packets.
#
# Zone design:
#   wg_exit  (wg0)        — tunnel exit, masq=1 for NAT, mtu_fix=1 for MSS
#   tun      (br-tun_lan) — VPN clients, input=ACCEPT for LuCI/SSH
#   prx      (br-prx_lan) — SOCKS5 clients, input=ACCEPT for LuCI/SSH
#   zt       (ztXXXX)     — ZeroTier remote admin, forward=REJECT isolation
#
# ZeroTier auto-detection: if ZT has already joined before this script
# runs, we detect the interface name. If not, we print the two commands
# needed to update the zone after joining.
# =============================================================================
echo "[5/9] Configuring firewall..."

# Hardware offloading
uci set firewall.@defaults[0].flow_offloading='1'
uci set firewall.@defaults[0].flow_offloading_hw='1'

# --- WireGuard tunnel exit zone ---
# masq=1  : fw4 auto-generates MASQUERADE for oifname "wg0"
# mtu_fix : fw4 clamps TCP MSS to prevent fragmentation in tunnel
uci set firewall.wg_exit=zone
uci set firewall.wg_exit.name='wg_exit'
uci set firewall.wg_exit.input='REJECT'
uci set firewall.wg_exit.output='ACCEPT'
uci set firewall.wg_exit.forward='REJECT'
uci set firewall.wg_exit.masq='1'
uci set firewall.wg_exit.mtu_fix='1'
uci del firewall.wg_exit.network 2>/dev/null || true
uci add_list firewall.wg_exit.network='wg0'

# --- VPN client zone ---
# forward=REJECT: cannot reach any other zone directly
# Only allowed exit is via tun_fwd → wg_exit below
uci set firewall.tun=zone
uci set firewall.tun.name='tun'
uci set firewall.tun.input='ACCEPT'
uci set firewall.tun.output='ACCEPT'
uci set firewall.tun.forward='REJECT'
uci del firewall.tun.network 2>/dev/null || true
uci add_list firewall.tun.network='tun_lan'

# VPN clients → WireGuard exit (the only allowed forward path for VLAN10)
uci set firewall.tun_fwd=forwarding
uci set firewall.tun_fwd.src='tun'
uci set firewall.tun_fwd.dest='wg_exit'

# --- SOCKS5 client zone ---
# forward=REJECT: no zone crossing at all
# redsocks handles proxying as a local process — traffic never forwards
uci set firewall.prx=zone
uci set firewall.prx.name='prx'
uci set firewall.prx.input='ACCEPT'
uci set firewall.prx.output='ACCEPT'
uci set firewall.prx.forward='REJECT'
uci del firewall.prx.network 2>/dev/null || true
uci add_list firewall.prx.network='prx_lan'

# --- ZeroTier zone ---
# input=ACCEPT: you can reach LuCI from ZeroTier network
# forward=REJECT: ZeroTier cannot reach LAN/VPN/SOCKS5 zones
ZT_IFACE=$(ip link show 2>/dev/null | awk -F': ' '/^[0-9]+: zt/{print $2}' | head -n1)
if [ -z "$ZT_IFACE" ]; then
    echo "  WARNING: ZeroTier interface not detected yet"
    echo "  After 'zerotier-cli join <network_id>' run:"
    echo "    ZT=\$(ip link show | awk -F': ' '/^[0-9]+: zt/{print \$2}' | head -n1)"
    echo "    uci set firewall.zt.network=\"\$ZT\""
    echo "    uci commit firewall && /etc/init.d/firewall restart"
    ZT_IFACE='ztplaceholder'
fi
uci set firewall.zt=zone
uci set firewall.zt.name='zt'
uci set firewall.zt.input='ACCEPT'
uci set firewall.zt.output='ACCEPT'
uci set firewall.zt.forward='REJECT'
uci del firewall.zt.network 2>/dev/null || true
uci add_list firewall.zt.network="$ZT_IFACE"
echo "  ZeroTier zone: $ZT_IFACE"

# --- Block IPv6 on VPN zone ---
# Belt-and-suspenders alongside nftables drop below.
# fw4 REJECT here prevents any IPv6 from VLAN10 reaching the router.
uci set firewall.tun_block_v6=rule
uci set firewall.tun_block_v6.name='Block-VPN-IPv6'
uci set firewall.tun_block_v6.src='tun'
uci set firewall.tun_block_v6.family='ipv6'
uci set firewall.tun_block_v6.target='REJECT'

# --- Block IPv6 on SOCKS5 zone ---
uci set firewall.prx_block_v6=rule
uci set firewall.prx_block_v6.name='Block-SOCKS5-IPv6'
uci set firewall.prx_block_v6.src='prx'
uci set firewall.prx_block_v6.family='ipv6'
uci set firewall.prx_block_v6.target='REJECT'

# --- Allow VPN clients to reach router admin ---
# INPUT rule — traffic stays local, never crosses zones.
# Covers LuCI (80/443) and SSH (22).
uci set firewall.tun_admin=rule
uci set firewall.tun_admin.name='Allow-VPN-Admin'
uci set firewall.tun_admin.src='tun'
uci del firewall.tun_admin.proto 2>/dev/null || true
uci add_list firewall.tun_admin.proto='tcp'
uci del firewall.tun_admin.dest_port 2>/dev/null || true
uci add_list firewall.tun_admin.dest_port='22'
uci add_list firewall.tun_admin.dest_port='80'
uci add_list firewall.tun_admin.dest_port='443'
uci set firewall.tun_admin.target='ACCEPT'

# --- Allow SOCKS5 clients to reach router admin ---
uci set firewall.prx_admin=rule
uci set firewall.prx_admin.name='Allow-SOCKS5-Admin'
uci set firewall.prx_admin.src='prx'
uci del firewall.prx_admin.proto 2>/dev/null || true
uci add_list firewall.prx_admin.proto='tcp'
uci del firewall.prx_admin.dest_port 2>/dev/null || true
uci add_list firewall.prx_admin.dest_port='22'
uci add_list firewall.prx_admin.dest_port='80'
uci add_list firewall.prx_admin.dest_port='443'
uci set firewall.prx_admin.target='ACCEPT'

# =============================================================================
# STEP 6: NFTABLES — Hard enforcement layer
# =============================================================================
# fw4 zones above are the first line. This file is the line that cannot
# be bypassed regardless of UCI state — it is loaded directly by fw4
# from /etc/nftables.d/ on every boot and firewall restart.
#
# Hook execution order (lower number fires first):
#   prerouting -150 : ct_zones, ipv6_drop, antispoof (before conntrack at -100)
#   prerouting -100 : socks_redirect (nat prerouting standard priority)
#   forward      0  : vpn_killswitch (filter forward standard priority)
#
# Why PREROUTING for redsocks redirect:
#   After redirect to :12345, destination = 127.0.0.1:12345 (local socket).
#   Packet takes LOCAL_IN path — FORWARD hook and PPE flowtable never see it.
#   This is structural, not config-dependent.
#
# Why FORWARD for killswitch:
#   PPE cannot offload wg0-bound flows (tunnel, no hardware L2 nexthop).
#   The explicit drop here catches: wg0 down (no route resolves to wg0),
#   or any misconfiguration that would send VLAN10 out via WAN.
#   'drop' not 'reject' — no ICMP back to client, no information leak.
# =============================================================================
echo "[6/9] Installing nftables rules..."

mkdir -p /etc/nftables.d

cat > /etc/nftables.d/10-custom-routing.nft << 'NFT'
# /etc/nftables.d/10-custom-routing.nft
# Loaded automatically by fw4 on boot and firewall restart.
# This is the hard enforcement layer — do not remove.

table inet custom_routing {

    # -------------------------------------------------------------------------
    # Conntrack zone isolation — fires before conntrack at priority -150
    # Prevents VLAN1 conntrack entries matching VLAN10/20 traffic.
    # Critical if any device moves between VLANs (same MAC, new DHCP lease).
    # Without this, a stale VLAN1 PPE shortcut can briefly route VLAN10
    # traffic to WAN before the entry expires.
    # -------------------------------------------------------------------------
    chain ct_zones {
        type filter hook prerouting priority -150;
        iifname "br-lan"     ct zone set 1
        iifname "br-tun_lan" ct zone set 10
        iifname "br-prx_lan" ct zone set 20
    }

    # -------------------------------------------------------------------------
    # IPv6 drop — priority -150 (before conntrack)
    # Fires before conntrack so IPv6 packets never create conntrack entries.
    # Belt-and-suspenders alongside fw4 zone REJECT rules.
    # -------------------------------------------------------------------------
    chain ipv6_drop {
        type filter hook prerouting priority -150;
        iifname "br-tun_lan" meta nfproto ipv6 drop
        iifname "br-prx_lan" meta nfproto ipv6 drop
    }

    # -------------------------------------------------------------------------
    # Anti-spoof — priority -120
    # Clients must source from their own subnet only.
    # Prevents a rogue VLAN20 client spoofing a VLAN1 IP to bypass redsocks,
    # or a VLAN10 client spoofing VLAN20 to avoid the VPN killswitch.
    # -------------------------------------------------------------------------
    chain antispoof {
        type filter hook prerouting priority -120;
        iifname "br-tun_lan" ip saddr != 192.168.10.0/24 drop
        iifname "br-prx_lan" ip saddr != 192.168.20.0/24 drop
    }

    # -------------------------------------------------------------------------
    # SOCKS5 proxy redirects — nat prerouting priority -100
    #
    # TCP → redsocks on :12345
    # UDP/53 → dns2socks on :5300
    #   (NOT 5353 — that conflicts with mDNS/dnsmasq multicast DNS)
    #
    # 'ip daddr 192.168.20.1 return' — do NOT redirect traffic destined
    # for the router itself. Without this, SSH and LuCI from VLAN20 clients
    # gets redirected into redsocks and fails silently.
    #
    # After redirect: destination becomes 127.0.0.1:12345 (local socket).
    # Packet takes LOCAL_IN path — FORWARD hook and PPE flowtable never
    # see it. The MT7621 PPE bug cannot affect locally terminated traffic.
    # -------------------------------------------------------------------------
    chain socks_redirect {
        type nat hook prerouting priority -100;
        iifname != "br-prx_lan" return
        ip daddr 192.168.20.1 return
        ip protocol tcp redirect to :12345
        udp dport 53 redirect to :5300
    }

    # -------------------------------------------------------------------------
    # WireGuard killswitch — filter forward priority 0
    #
    # Any packet from VLAN10 NOT exiting via wg0 is silently dropped.
    # Two failure scenarios this covers:
    #   a) wg0 is down — routing fails to resolve a nexthop via wg0,
    #      no rule matches, explicit drop fires
    #   b) Misconfiguration — a route incorrectly sends VLAN10 to WAN,
    #      oifname check catches it and drops
    #
    # 'drop' not 'reject': no ICMP unreachable sent to client.
    # Client sees a dead connection, not a "network unreachable" message.
    # This is correct killswitch semantics — no information leakage.
    #
    # PPE note: the PPE cannot offload wg0-bound flows because wg0 is a
    # software tunnel with no hardware L2 nexthop. Every VLAN10 packet
    # reaches this hook on every packet — no race condition possible.
    # -------------------------------------------------------------------------
    chain vpn_killswitch {
        type filter hook forward priority 0;
        iifname != "br-tun_lan" return
        oifname "wg0" accept
        drop
    }
}
NFT

echo "  ✓ /etc/nftables.d/10-custom-routing.nft written"

# =============================================================================
# STEP 7: REDSOCKS
# =============================================================================
# local_ip=0.0.0.0 — accept redirected connections from any source.
#   Must be 0.0.0.0, not 127.0.0.1. After nftables redirect, the packet
#   still carries the original client source IP. The local socket lookup
#   needs 0.0.0.0 binding to accept it.
#
# on_proxy_fail=close — if the SOCKS5 proxy is unreachable, redsocks
#   CLOSES the connection. Without this redsocks may pass traffic directly
#   to WAN (fail-open), defeating the proxy entirely for VLAN20 clients.
#   This is the fail-closed guarantee for VLAN20.
# =============================================================================
echo "[7/9] Configuring redsocks..."

cat > /etc/redsocks.conf << REDSOCKS
base {
    log_debug = off;
    log_info  = on;
    log       = syslog:daemon;
    daemon    = on;
    redirector = iptables;
}

redsocks {
    local_ip   = 0.0.0.0;
    local_port = 12345;
    ip         = $SOCKS5_SERVER;
    port       = $SOCKS5_PORT;
    type       = socks5;
    login      = "$SOCKS5_USER";
    password   = "$SOCKS5_PASS";
}
REDSOCKS

/etc/init.d/redsocks enable
echo "  ✓ /etc/redsocks.conf written"

# =============================================================================
# STEP 7b: DNS2SOCKS
# =============================================================================
# Listens on 0.0.0.0:5300 — matches nftables UDP/53 redirect.
# Must bind 0.0.0.0 for the same reason as redsocks above.
# Upstream DNS: 1.1.1.1 — queries arrive at Cloudflare via SOCKS5 proxy.
# procd respawn: automatically restarts dns2socks if it crashes.
# =============================================================================
cat > /etc/init.d/dns2socks << 'DNS2SOCKS'
#!/bin/sh /etc/rc.common
START=95
STOP=10
USE_PROCD=1

start_service() {
    . /etc/vpn-secrets.conf 2>/dev/null || true
    procd_open_instance
    procd_set_param command /usr/bin/dns2socks \
        "${SOCKS5_SERVER}:${SOCKS5_PORT}" \
        "1.1.1.1:53" \
        "0.0.0.0:5300"
    procd_set_param respawn 3600 5 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
DNS2SOCKS
chmod +x /etc/init.d/dns2socks
/etc/init.d/dns2socks enable
echo "  ✓ /etc/init.d/dns2socks written"

# =============================================================================
# STEP 8: HOTPLUG — Table 200 killswitch engine
# =============================================================================
# This is the VPN killswitch engine. It must exist as a hotplug script
# and NOT be replaced with UCI network.rule/route because:
#   UCI route/rule has no blackhole — when wg0 goes down the ip rule
#   still points VLAN10 at table 200, which is now empty, so the kernel
#   falls through to the main table and VLAN10 traffic exits via PPPoE
#   WAN in cleartext. This is a silent VPN leak.
#
# Kill-switch design (proven in your working xwrt script):
#   table 200 ALWAYS has a blackhole default at metric 65535
#   wg0 UP   → VPN default route metric 100 wins → traffic flows
#   wg0 DOWN → blackhole metric 65535 wins → traffic dropped, no fallback
#   ip rule from 192.168.10.0/24 → table 200 is PERMANENT (never removed)
#
# iif lo lookup main priority 50:
#   Router's own traffic (WireGuard handshake packets, dnsmasq upstream
#   DNS queries, SSH sessions) must stay on the main table.
#   Without this the router tries to route its own DNS through the tunnel
#   before the tunnel is established → tunnel never comes up → clients
#   get an IP from DHCP but have no internet.
#   This was one of your original "connected but no internet" bugs.
# =============================================================================
echo "[8/9] Installing hotplug script..."

mkdir -p /etc/hotplug.d/iface

cat > /etc/hotplug.d/iface/99-vpn-route << 'HOTPLUG'
#!/bin/sh
# VPN killswitch hotplug — fires on wg0 ifup/ifdown only

[ "$INTERFACE" = "wg0" ] || exit 0

VPN_IF="wg0"
VPN_GW="10.2.0.1"
VPN_LAN="192.168.10.0/24"
TABLE=200
PRIO_LO=50
PRIO_VPN=1000

if [ "$ACTION" = "ifup" ]; then
    logger "vpn-hotplug: wg0 UP — configuring table $TABLE"

    # Keep router's own traffic on main table (fixes WG handshake + dnsmasq)
    ip rule del priority $PRIO_LO 2>/dev/null || true
    ip rule add from all iif lo lookup main priority $PRIO_LO

    # Host route to VPN gateway so WireGuard can reach the endpoint
    ip route add "${VPN_GW}/32" dev $VPN_IF 2>/dev/null || true

    # Build table 200
    # Flush first to remove any stale routes from previous ifup
    ip route flush table $TABLE
    # Blackhole floor — ALWAYS present, metric 65535 loses to VPN route
    ip route add blackhole default table $TABLE metric 65535
    # Host route to gateway inside table 200
    ip route add "${VPN_GW}/32" dev $VPN_IF table $TABLE 2>/dev/null || true
    # VPN default route — metric 100 wins over blackhole while tunnel is up
    ip route add default via $VPN_GW dev $VPN_IF onlink table $TABLE metric 100

    # Policy rule: all traffic from VPN LAN → table 200
    # PERMANENT — never removed, even when wg0 goes down
    ip rule del from $VPN_LAN lookup $TABLE 2>/dev/null || true
    ip rule add from $VPN_LAN lookup $TABLE priority $PRIO_VPN

    ip route flush cache
    logger "vpn-hotplug: table $TABLE active — VPN clients online"

elif [ "$ACTION" = "ifdown" ]; then
    logger "vpn-hotplug: wg0 DOWN — killswitch active"

    # Remove VPN routes, keep ONLY the blackhole
    # The ip rule stays → VLAN10 still hits table 200 → blackhole → DROP
    # No ISP fallback. No cleartext leak.
    ip route flush table $TABLE
    ip route add blackhole default table $TABLE metric 65535

    ip route flush cache
    logger "vpn-hotplug: killswitch active — VPN clients offline"
fi
HOTPLUG

chmod +x /etc/hotplug.d/iface/99-vpn-route
echo "  ✓ /etc/hotplug.d/iface/99-vpn-route written"

# =============================================================================
# STEP 8b: SYSCTL — Conntrack tuning
# =============================================================================
# 32768 max entries: right-sized for 10 clients on 128MB RAM.
#   At ~300 bytes/entry: 32768 entries = ~9.8MB max conntrack table.
#   Default is often 65536 which wastes RAM on this hardware.
# TCP established timeout 3600: 1 hour — standard for long-lived TCP.
# UDP timeout 30: most UDP is DNS (one query, one answer, done fast).
#   Short timeout reclaims entries quickly, reduces table pressure.
# UDP stream 120: for UDP "connections" like QUIC/WireGuard handshakes.
# Generic timeout 120: for non-TCP/UDP protocols.
# =============================================================================
cat > /etc/sysctl.d/10-conntrack.conf << 'SYSCTL'
net.netfilter.nf_conntrack_max=32768
net.netfilter.nf_conntrack_tcp_timeout_established=3600
net.netfilter.nf_conntrack_udp_timeout=30
net.netfilter.nf_conntrack_udp_timeout_stream=120
net.netfilter.nf_conntrack_generic_timeout=120
SYSCTL

sysctl -p /etc/sysctl.d/10-conntrack.conf 2>/dev/null || true
echo "  ✓ /etc/sysctl.d/10-conntrack.conf written"

# =============================================================================
# STEP 9: COMMIT AND APPLY
# =============================================================================
# Commit order: network first, then dependent subsystems.
#
# The netifd flush problem:
#   When /etc/init.d/network restart runs, netifd rebuilds all interfaces.
#   During this rebuild it flushes routing state. Any ip rules/routes
#   installed by hotplug during the restart get wiped by the time netifd
#   finishes. This is why we re-apply table 200 manually at the end of
#   this script — same pattern as your working xwrt script, same reason.
# =============================================================================
echo "[9/9] Committing and applying configuration..."

uci commit network
uci commit dhcp
uci commit wireless
uci commit firewall

/etc/init.d/network restart
/etc/init.d/firewall restart
/etc/init.d/dnsmasq restart

# Wait for wg0 to come up
echo "  Waiting for wg0..."
TRIES=0
while true; do
    TRIES=$((TRIES + 1))
    if ip link show wg0 up > /dev/null 2>&1; then
        echo "  ✓ wg0 is up after ${TRIES}s"
        break
    fi
    if [ $TRIES -ge 30 ]; then
        echo "  WARNING: wg0 not up after 30s"
        echo "  Hotplug will complete table 200 setup on next ifup event"
        break
    fi
    sleep 1
done

# Re-apply table 200 routing rules (fixes the netifd flush race)
VPN_GW="10.2.0.1"
VPN_IF="wg0"
VPN_LAN="192.168.10.0/24"
TABLE=200

ip rule del priority 50 2>/dev/null || true
ip rule add from all iif lo lookup main priority 50

ip route add "${VPN_GW}/32" dev $VPN_IF 2>/dev/null || true

ip route flush table $TABLE
ip route add blackhole default table $TABLE metric 65535
ip route add "${VPN_GW}/32" dev $VPN_IF table $TABLE 2>/dev/null || true
ip route add default via $VPN_GW dev $VPN_IF onlink table $TABLE metric 100 2>/dev/null || true

ip rule del from $VPN_LAN lookup $TABLE 2>/dev/null || true
ip rule add from $VPN_LAN lookup $TABLE priority 1000

ip route flush cache

# Start proxy services
/etc/init.d/redsocks restart
/etc/init.d/dns2socks restart

# =============================================================================
# Done
# =============================================================================
echo ""
echo "============================================="
echo "  Setup Complete"
echo "============================================="
echo ""
echo "  Main  WiFi : existing SSID  → 192.168.15.0/24 → PPPoE (HW offloaded)"
echo "  VPN   WiFi : OpenWrt VPN    → 192.168.10.0/24 → wg0 (ProtonVPN)"
echo "  SOCKS5 WiFi: OpenWrt SOCKS5 → 192.168.20.0/24 → redsocks"
echo ""
echo "  Killswitch : ON  (table 200 blackhole)"
echo "  IPv6 leak  : OFF (blocked on tun_lan + prx_lan)"
echo "  HW Offload : ON  (Main only — VLAN10/20 self-excluded)"
echo ""
echo "  ZeroTier   : $([ "$ZT_IFACE" = "ztplaceholder" ] && echo "PENDING — see WARNING above" || echo "$ZT_IFACE ✓")"
echo ""
echo "  ── Verify ─────────────────────────────────"
echo "  wg show wg0"
echo "  ip route show table 200"
echo "  ip rule show"
echo "  nft list ruleset"
echo "  ss -tnlp | grep 12345    (redsocks)"
echo "  ss -unlp | grep 5300     (dns2socks)"
echo ""
echo "  ── Killswitch test ─────────────────────────"
echo "  ip link set wg0 down"
echo "  (VPN WiFi clients lose internet — no ISP fallback)"
echo "  ip link set wg0 up"
echo "  (hotplug restores routing automatically)"
echo ""
echo "  Wait ~30s for WiFi APs to appear."
echo "============================================="
