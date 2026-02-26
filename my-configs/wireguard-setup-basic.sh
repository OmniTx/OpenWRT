#!/bin/sh
# X-WRT VPN Setup — ProtonVPN WireGuard + Isolated VPN LAN
# Target : X-WRT 26.04 (fw4 / nftables), MT7621, 128 MB RAM
# Run    : After factory reset + backup restore (PPPoE + main Wi-Fi working)
#
# Layout:
#   Main LAN : 192.168.15.0/24  — ISP routing, unchanged
#   VPN  LAN : 192.168.50.0/24  — ProtonVPN tunnel, isolated 5 GHz Wi-Fi
#   Kill sw  : Blackhole in table 200; VPN clients lose internet if wg drops
#   MTU      : 1360 (proven on this hardware/ISP)

echo "=== X-WRT VPN Setup (fw4 / nftables) ==="
echo ""

# Load sensitive configuration
SECRETS_FILE="$(dirname "$0")/vpn-secrets.conf"
if [ -f "$SECRETS_FILE" ]; then
    . "$SECRETS_FILE"
elif [ -f "/etc/vpn-secrets.conf" ]; then
    . "/etc/vpn-secrets.conf"
else
    echo "ERROR: Secrets file not found!"
    echo "Please create vpn-secrets.conf with WG_PRIVATE_KEY, WG_PUBLIC_KEY, WG_ADDRESS, WG_ENDPOINT, VPN_WIFI_KEY"
    exit 1
fi

# ------------------------------------------------------------------
# STEP 0: Wait for network to stabilize after boot
# ------------------------------------------------------------------
echo "[0/8] Waiting for network..."
sleep 3

# ------------------------------------------------------------------
# STEP 1: WireGuard Interface (wg_vpn)
# Named UCI section → idempotent on re-runs.
# route_allowed_ips=0: we manage routes manually via table 200.
# No listen_port: kernel picks a random ephemeral port (client-only).
# MTU set here so netifd applies it on every ifup automatically.
# ------------------------------------------------------------------
echo "[1/8] Configuring WireGuard interface..."

uci set network.wg_vpn=interface
uci set network.wg_vpn.proto='wireguard'
uci set network.wg_vpn.private_key="$WG_PRIVATE_KEY"
uci set network.wg_vpn.mtu='1360'
uci del network.wg_vpn.addresses 2>/dev/null || true
uci add_list network.wg_vpn.addresses="$WG_ADDRESS"

# Remove ALL existing peers before re-adding (idempotent)
while uci -q get network.@wireguard_wg_vpn[0] > /dev/null 2>&1; do
    uci del network.@wireguard_wg_vpn[0]
done

uci add network wireguard_wg_vpn
uci set network.@wireguard_wg_vpn[-1].public_key="$WG_PUBLIC_KEY"
uci add_list network.@wireguard_wg_vpn[-1].allowed_ips='0.0.0.0/0'
uci set network.@wireguard_wg_vpn[-1].route_allowed_ips='0'
uci set network.@wireguard_wg_vpn[-1].endpoint_host="$WG_ENDPOINT"
uci set network.@wireguard_wg_vpn[-1].endpoint_port='51820'
uci set network.@wireguard_wg_vpn[-1].persistent_keepalive='25'

# ------------------------------------------------------------------
# STEP 2: VPN LAN Bridge  (vpn_lan → br-vpn_lan)
# Named UCI section → idempotent.
# DNS: push ProtonVPN's internal resolver (10.2.0.1) to all clients.
# IPv6 RA/DHCPv6 disabled → no IPv6 leak path.
# MTU: clamp bridge to 1360 to match the tunnel.
# ------------------------------------------------------------------
echo "[2/8] Configuring VPN LAN..."

uci set network.vpn_lan=interface
uci set network.vpn_lan.type='bridge'
uci set network.vpn_lan.proto='static'
uci set network.vpn_lan.ipaddr='192.168.50.1'
uci set network.vpn_lan.netmask='255.255.255.0'
uci set network.vpn_lan.mtu='1360'

uci set dhcp.vpn_lan=dhcp
uci set dhcp.vpn_lan.interface='vpn_lan'
uci set dhcp.vpn_lan.start='100'
uci set dhcp.vpn_lan.limit='150'
uci set dhcp.vpn_lan.leasetime='12h'
# Clear any existing dhcp_option list before re-adding (idempotent)
uci del dhcp.vpn_lan.dhcp_option 2>/dev/null || true
uci add_list dhcp.vpn_lan.dhcp_option='6,10.2.0.1'
uci set dhcp.vpn_lan.ra='disabled'
uci set dhcp.vpn_lan.dhcpv6='disabled'

# ------------------------------------------------------------------
# STEP 3: VPN Wi-Fi AP  (5 GHz, radio1)
# Named UCI section → idempotent.
# ------------------------------------------------------------------
echo "[3/8] Configuring VPN Wi-Fi..."

uci set wireless.vpn_wifi=wifi-iface
uci set wireless.vpn_wifi.device='radio1'
uci set wireless.vpn_wifi.mode='ap'
uci set wireless.vpn_wifi.ssid='OpenWrt VPN'
uci set wireless.vpn_wifi.encryption='sae-mixed'
uci set wireless.vpn_wifi.key="$VPN_WIFI_KEY"
uci set wireless.vpn_wifi.network='vpn_lan'
uci set wireless.vpn_wifi.disabled='0'

# ------------------------------------------------------------------
# STEP 4: Firewall Zones & Rules  (fw4 / nftables)
# ALL sections are named → idempotent on re-runs.
#
# vpn_wan  : tunnel exit zone; masq=1 → fw4 auto-generates MASQUERADE
#            for oifname "wg_vpn"; mtu_fix=1 → fw4 clamps TCP MSS.
# vpn_local: client zone; forward=REJECT blocks all cross-zone fwd
#            except the explicit vpn_local→vpn_wan forwarding below.
#
# ISOLATION design:
#   vpn_local → vpn_wan   : ALLOWED (VPN internet)
#   vpn_local → lan       : BLOCKED (vpn_local.forward=REJECT + no fwd rule)
#   lan       → vpn_local : BLOCKED (no forwarding rule)
#   lan       → vpn_wan   : ALLOWED in firewall (actual routing only
#                           happens for PCs with an ip rule via toggle)
#
# Admin access (SSH/HTTP/HTTPS to the router itself):
#   This is an INPUT rule, not a FORWARD rule. The router's own IP
#   (192.168.50.1 or 192.168.15.1) is local — traffic never crosses
#   zones. vpn_local.input=ACCEPT already covers this; the explicit
#   rule documents intent and survives if input policy ever tightens.
# ------------------------------------------------------------------
echo "[4/8] Configuring firewall..."

# VPN WAN zone (wg_vpn — tunnel exit)
uci set firewall.vpn_wan=zone
uci set firewall.vpn_wan.name='vpn_wan'
uci set firewall.vpn_wan.input='REJECT'
uci set firewall.vpn_wan.output='ACCEPT'
uci set firewall.vpn_wan.forward='REJECT'
uci set firewall.vpn_wan.masq='1'
uci set firewall.vpn_wan.mtu_fix='1'
uci del firewall.vpn_wan.network 2>/dev/null || true
uci add_list firewall.vpn_wan.network='wg_vpn'

# VPN LAN zone (br-vpn_lan — client subnet)
uci set firewall.vpn_local=zone
uci set firewall.vpn_local.name='vpn_local'
uci set firewall.vpn_local.input='ACCEPT'
uci set firewall.vpn_local.output='ACCEPT'
uci set firewall.vpn_local.forward='REJECT'
uci del firewall.vpn_local.network 2>/dev/null || true
uci add_list firewall.vpn_local.network='vpn_lan'

# Forwarding: VPN LAN → VPN WAN (the only allowed exit)
uci set firewall.vpn_fwd=forwarding
uci set firewall.vpn_fwd.src='vpn_local'
uci set firewall.vpn_fwd.dest='vpn_wan'

# Forwarding: main LAN → VPN WAN (firewall-level allow for pc-vpn-toggle)
# Routing only happens for IPs that have an ip rule pointing at table 200.
# Clients without a rule continue using the main table (ISP) as normal.
uci set firewall.lan_vpn_fwd=forwarding
uci set firewall.lan_vpn_fwd.src='lan'
uci set firewall.lan_vpn_fwd.dest='vpn_wan'

# INPUT rule: allow VPN clients to reach router admin services
# (No dest= → this is an INPUT rule, not a FORWARD rule)
uci set firewall.vpn_admin=rule
uci set firewall.vpn_admin.name='Allow-VPN-Admin'
uci set firewall.vpn_admin.src='vpn_local'
uci del firewall.vpn_admin.proto 2>/dev/null || true
uci add_list firewall.vpn_admin.proto='tcp'
uci del firewall.vpn_admin.dest_port 2>/dev/null || true
uci add_list firewall.vpn_admin.dest_port='22'
uci add_list firewall.vpn_admin.dest_port='80'
uci add_list firewall.vpn_admin.dest_port='443'
uci set firewall.vpn_admin.target='ACCEPT'

# Belt-and-suspenders: drop IPv6 from VPN clients (no IPv6 tunnel = leak)
uci set firewall.vpn_block_ipv6=rule
uci set firewall.vpn_block_ipv6.name='Block-VPN-IPv6'
uci set firewall.vpn_block_ipv6.src='vpn_local'
uci set firewall.vpn_block_ipv6.family='ipv6'
uci set firewall.vpn_block_ipv6.target='REJECT'

# ------------------------------------------------------------------
# STEP 5: Disable mwan3
# mwan3 deletes manually-added ip rules and overrides table 200.
# ------------------------------------------------------------------
echo "[5/8] Disabling mwan3..."

if [ -f /etc/init.d/mwan3 ]; then
    /etc/init.d/mwan3 stop    2>/dev/null || true
    /etc/init.d/mwan3 disable 2>/dev/null || true
    logger "vpn-setup: mwan3 disabled"
else
    echo "  mwan3 not installed — skipping"
fi

# ------------------------------------------------------------------
# STEP 6: Hotplug Script  (/etc/hotplug.d/iface/99-vpn-route)
#
# Fires on every wg_vpn ifup / ifdown event.
# fw4 handles NAT (masq=1) and FORWARD rules via UCI — this script
# only manages ip rules and routing table 200.
#
# Kill-switch design:
#   table 200 always has a blackhole default at metric 65535.
#   When VPN is UP  → lower-metric VPN route (100) wins.
#   When VPN is DOWN → blackhole wins. No ISP fallback.
#   The ip rule is NEVER removed; clients always hit table 200.
# ------------------------------------------------------------------
echo "[6/8] Installing hotplug script..."

mkdir -p /etc/hotplug.d/iface

cat > /etc/hotplug.d/iface/99-vpn-route << 'HOTPLUG'
#!/bin/sh
# VPN Policy Routing Hotplug
# Manages routing table 200 and kill switch for wg_vpn.

[ "$INTERFACE" = "wg_vpn" ] || exit 0

VPN_IF="wg_vpn"
VPN_GW="10.2.0.1"
VPN_LAN="192.168.50.0/24"
TABLE=200
PRIO_LO=50      # router's own traffic → main table (keeps dnsmasq/SSH on ISP)
PRIO_VPN=1000   # VPN subnet → table 200

if [ "$ACTION" = "ifup" ]; then
    logger "vpn-hotplug: wg_vpn UP — configuring policy routing"

    # 1. Router's own outbound traffic always uses main table.
    #    Prevents dnsmasq upstream queries and SSH from going into tunnel.
    ip rule del priority $PRIO_LO 2>/dev/null || true
    ip rule add from all iif lo lookup main priority $PRIO_LO

    # 2. Host route to VPN gateway — allows WireGuard handshake + DNS.
    ip route add "${VPN_GW}/32" dev $VPN_IF 2>/dev/null || true

    # 3. Build table 200.
    #    Blackhole at metric 65535 = kill-switch floor (always present).
    #    VPN default at metric 100 wins when tunnel is up.
    ip route flush table $TABLE
    ip route add blackhole default table $TABLE metric 65535
    ip route add "${VPN_GW}/32" dev $VPN_IF table $TABLE 2>/dev/null || true
    ip route add default via $VPN_GW dev $VPN_IF onlink table $TABLE metric 100

    # 4. Policy rule: VPN LAN packets → table 200.
    ip rule del from $VPN_LAN lookup $TABLE 2>/dev/null || true
    ip rule add from $VPN_LAN lookup $TABLE priority $PRIO_VPN

    ip route flush cache
    logger "vpn-hotplug: routing active. Table $TABLE → $VPN_GW via $VPN_IF"

elif [ "$ACTION" = "ifdown" ]; then
    logger "vpn-hotplug: wg_vpn DOWN — activating kill switch"

    # Kill switch: flush VPN routes, leave only the blackhole.
    # The ip rule stays → VPN LAN still hits table 200 → blackhole → DROP.
    # No ISP fallback whatsoever.
    ip route flush table $TABLE
    ip route add blackhole default table $TABLE metric 65535

    ip route flush cache
    logger "vpn-hotplug: kill switch active. VPN clients offline."
fi
HOTPLUG

chmod +x /etc/hotplug.d/iface/99-vpn-route

# ------------------------------------------------------------------
# STEP 7: PC VPN Toggle  (/usr/bin/pc-vpn-toggle)
# Usage: pc-vpn-toggle [on|off|status]
#
# Routes 192.168.15.100 through ProtonVPN on demand by adding a
# priority-100 ip rule pointing that source IP at table 200.
# NAT is handled by fw4 (vpn_wan masq=1); firewall forwarding is
# covered by the lan→vpn_wan forwarding rule added in STEP 4.
# ------------------------------------------------------------------
echo "[7/8] Installing pc-vpn-toggle..."

cat > /usr/bin/pc-vpn-toggle << 'TOGGLE'
#!/bin/sh
# pc-vpn-toggle — Route 192.168.15.100 through ProtonVPN and block IPv6 leaks

PC_IP="192.168.15.100"
TABLE=200
WG_IF="wg_vpn"
PRIO=100

log() { logger -t "pc-vpn" "$1"; echo "$1"; }

get_mac() {
    ping -c 1 -W 1 "$PC_IP" >/dev/null 2>&1
    ip neigh show "$PC_IP" | grep -v FAILED | awk '{print $5}' | head -n1
}

clean_v6_rules() {
    for chain in forward input; do
        nft -a list chain inet fw4 $chain 2>/dev/null | awk '/pc-vpn-v6/{print $NF}' | while read h; do
            nft delete rule inet fw4 $chain handle "$h" 2>/dev/null || true
        done
    done
}

case "$1" in
    on)
        if ! ip link show "$WG_IF" up > /dev/null 2>&1; then
            log "ERROR: $WG_IF is down. VPN tunnel not running."
            exit 1
        fi
        
        ip rule del from "$PC_IP" lookup $TABLE 2>/dev/null || true
        ip rule add from "$PC_IP" lookup $TABLE priority $PRIO
        ip route flush cache
        
        # Block IPv6 to prevent dual-stack leaks
        clean_v6_rules
        PC_MAC=$(get_mac)
        if [ -n "$PC_MAC" ]; then
            nft insert rule inet fw4 forward ether saddr "$PC_MAC" meta nfproto ipv6 drop comment "pc-vpn-v6"
            nft insert rule inet fw4 input ether saddr "$PC_MAC" meta nfproto ipv6 drop comment "pc-vpn-v6"
            log "Blocked IPv6 for MAC $PC_MAC to prevent leaks"
        else
            log "WARNING: Could not resolve MAC for $PC_IP. IPv6 limit not applied!"
        fi
        
        log "VPN ON for $PC_IP — routing via $WG_IF"
        log "Test (run on PC): curl -s ifconfig.me"
        ;;
    off)
        ip rule del from "$PC_IP" lookup $TABLE 2>/dev/null || true
        ip route flush cache
        clean_v6_rules
        log "VPN OFF for $PC_IP — normal ISP routing restored"
        ;;
    status)
        if ip rule show | grep -q "from $PC_IP lookup $TABLE"; then
            echo "Status : VPN ON (priority $PRIO → table $TABLE)"
            PC_MAC=$(get_mac)
            if [ -n "$PC_MAC" ] && nft list chain inet fw4 forward 2>/dev/null | grep -q -i "$PC_MAC".*"pc-vpn-v6"; then
                echo "IPv6   : BLOCK ACTIVE for MAC $PC_MAC"
            else
                echo "IPv6   : WARNING - LEAKING (No block rule found)"
            fi
            echo "Route  :"
            ip route get 8.8.8.8 from "$PC_IP" 2>/dev/null || echo "  (no route)"
        else
            echo "Status : VPN OFF (normal ISP routing)"
        fi
        echo ""
        echo "WireGuard tunnel:"
        wg show "$WG_IF" 2>/dev/null || echo "  ($WG_IF is down)"
        echo ""
        echo "Table $TABLE:"
        ip route show table $TABLE 2>/dev/null || echo "  (empty)"
        ;;
    *)
        echo "Usage: pc-vpn-toggle [on|off|status]"
        exit 1
        ;;
esac
TOGGLE

chmod +x /usr/bin/pc-vpn-toggle

# ------------------------------------------------------------------
# STEP 8: Apply — commit, restart services, apply routing rules
#
# Scoped commits: only touch modified subsystems.
# Why re-apply rules after restart:
#   network restart triggers hotplug(ifup), but by the time it
#   finishes restarting all interfaces, the netifd flush clears
#   any routing state the hotplug installed during the restart.
#   We re-apply directly here so the VPN works immediately.
# ------------------------------------------------------------------
echo "[8/8] Applying configuration..."
echo ""

uci commit network
uci commit dhcp
uci commit wireless
uci commit firewall

/etc/init.d/network  restart
/etc/init.d/firewall restart
/etc/init.d/dnsmasq  restart

# Wait for wg_vpn to come up (poll instead of blind sleep)
echo "Waiting for wg_vpn..."
TRIES=0
while true; do
    TRIES=$((TRIES + 1))
    if ip link show wg_vpn up > /dev/null 2>&1; then
        echo "wg_vpn is up after ${TRIES}s"
        break
    fi
    if [ $TRIES -ge 30 ]; then
        echo "WARNING: wg_vpn not detected after 30 s — applying rules anyway."
        echo "Hotplug will complete setup on the next ifup event."
        break
    fi
    sleep 1
done

# Re-apply routing rules (mirrors what the hotplug does)
VPN_GW="10.2.0.1"
VPN_IF="wg_vpn"
VPN_LAN="192.168.50.0/24"
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

# ------------------------------------------------------------------
# Done
# ------------------------------------------------------------------
echo ""
echo "============================================="
echo "  X-WRT VPN Setup Complete"
echo "============================================="
echo ""
echo "  VPN Wi-Fi  : OpenWrt VPN (5 GHz)"
echo "  Password   : $VPN_WIFI_KEY"
echo "  Subnet     : 192.168.50.0/24"
echo "  DNS        : 10.2.0.1 (ProtonVPN)"
echo "  Kill switch: ON (blackhole in table $TABLE)"
echo ""
echo "  PC toggle  : pc-vpn-toggle [on|off|status]"
echo ""
echo "  Verify     : wg show wg_vpn"
echo "  Routes     : ip route show table $TABLE"
echo "  Rules      : ip rule show"
echo "  Firewall   : nft list ruleset | grep -E 'wg_vpn|vpn'"
echo ""
echo "  Wait ~30 s for Wi-Fi AP to appear."
echo "============================================="