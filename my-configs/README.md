# Bare-Metal 3-VLAN Setup

**Hardware:** Xiaomi Mi Router 4A Gigabit (MT7621, 16MB Flash, 128MB RAM)  
**Compatible with:** OpenWrt 23.05.5 · X-WRT (any fw4/nftables build)

Three completely isolated networks on one router. No userspace routing daemons. No `pbr`. No `mwan3`. Pure kernel-space nftables rules and a hotplug script that has no process to crash.

---

## Networks

| SSID | Subnet | Exit | IPv6 |
|---|---|---|---|
| *(your main SSID)* | 192.168.15.0/24 | PPPoE WAN | Enabled |
| `OpenWrt VPN` | 192.168.10.0/24 | ProtonVPN `wg0` | Blocked |
| `OpenWrt SOCKS5` | 192.168.20.0/24 | redsocks → BD Telegram proxy | Blocked |

Both VPN and SOCKS5 SSIDs broadcast on **2.4GHz and 5GHz simultaneously** with the same name and password. Clients pick the best band automatically.

---

## How It Works

### Hardware Offloading
Main LAN runs at full gigabit via MT7621 hardware flow offloading. VLAN10 and VLAN20 are self-excluded from offloading — not by disabling it, but by design:

- **VLAN10 → wg0:** WireGuard requires software encryption. The PPE cannot create a hardware shortcut through a tunnel interface. Every VLAN10 packet stays in the software path hitting nftables on every packet.
- **VLAN20 → redsocks:** The nftables `redirect` in `PREROUTING` sends packets to a local socket (`127.0.0.1:12345`). Locally terminated traffic takes the `LOCAL_IN` path — the `FORWARD` hook and PPE flowtable are never reached.

### VPN Killswitch
A blackhole route in routing table 200 is **always present** at metric 65535. When `wg0` is up, a VPN default route at metric 100 wins. When `wg0` goes down, the blackhole wins. VPN clients lose internet completely — no ISP fallback, no cleartext leak. The hotplug script manages this automatically on every `wg0` ifup/ifdown event.

### DNS
- **VLAN10 clients** receive `10.2.0.1` (ProtonVPN's internal resolver) via DHCP. DNS queries travel inside the WireGuard tunnel.
- **VLAN20 clients** receive the router's own IP (`192.168.20.1`) via DHCP. An nftables rule intercepts UDP port 53 in `PREROUTING` and redirects it to `dns2socks` on port 5300 before it reaches dnsmasq. `dns2socks` tunnels the query through the SOCKS5 proxy. Zero DNS leak.

---

## Prerequisites

Flash your firmware first. Either build works:

| Firmware | Build workflow |
|---|---|
| OpenWrt 23.05.5 | `openwrt-latest-build.yml` |
| X-WRT | `x-wrt-customize-build.yml` |

After flashing, configure your **PPPoE WAN** via LuCI and confirm main LAN internet works before running this script.

---

## Setup

**1. Create your secrets file on the router**

```sh
cat > /etc/vpn-secrets.conf << 'EOF'
WG_PRIVATE_KEY="your-wireguard-private-key"
WG_PUBLIC_KEY="protonvpn-server-public-key"
WG_ADDRESS="10.2.0.2/32"
WG_ENDPOINT="protonvpn-server-ip"
VPN_WIFI_KEY="your-vpn-wifi-password"
SOCKS5_WIFI_KEY="your-socks5-wifi-password"
SOCKS5_SERVER="your-proxy-ip"
SOCKS5_PORT="your-proxy-port"
SOCKS5_USER=""
SOCKS5_PASS=""
EOF
chmod 600 /etc/vpn-secrets.conf
```

> Get your WireGuard credentials from ProtonVPN → Downloads → WireGuard configuration. Use the server IP directly as `WG_ENDPOINT`, not the hostname — more stable on this hardware.

**2. Copy and run the setup script**

```sh
# Copy setup.sh to the router (from your machine)
scp my-configs/setup.sh root@192.168.15.1:/tmp/setup.sh

# On the router
sh /tmp/setup.sh
```

The script is safe to re-run. It removes existing peers and zones before re-adding them so running it twice produces the same result.

**3. Wait ~30 seconds** for the WiFi APs to appear.

---

## Verify

Run these on the router after setup completes:

```sh
# WireGuard tunnel status
wg show wg0

# Routing table 200 (VPN killswitch table)
ip route show table 200
# Expected output:
#   blackhole default metric 65535
#   10.2.0.1 dev wg0
#   default via 10.2.0.1 dev wg0 metric 100

# Policy routing rules
ip rule show
# Expected: rule from 192.168.10.0/24 lookup 200

# Full nftables ruleset (check ct_zones, ipv6_drop, socks_redirect, vpn_killswitch)
nft list ruleset

# redsocks listening on :12345
ss -tnlp | grep 12345

# dns2socks listening on :5300
ss -unlp | grep 5300
```

**From a VPN WiFi client:**
```sh
# Should show ProtonVPN exit IP, not your real IP
curl -s ifconfig.me

# Should show no IPv6
curl -6 --max-time 5 https://ipv6.google.com
```

**From a SOCKS5 WiFi client:**
```sh
# Should show proxy exit IP
curl -s ifconfig.me
```

---

## Killswitch Test

Do this before trusting the setup with real traffic:

```sh
# On the router — take the tunnel down
ip link set wg0 down

# On a VPN WiFi client — try to reach the internet
# Expected: complete silence, no response, no ISP fallback

# On the router — restore the tunnel
ip link set wg0 up
# hotplug fires automatically and restores table 200
# VPN clients regain internet within a few seconds
```

---

## ZeroTier Remote Access

ZeroTier gives you access to the router's LuCI from anywhere. After the script runs, join your ZeroTier network:

```sh
zerotier-cli join <your-network-id>
```

Then update the firewall zone with the actual interface name:

```sh
ZT=$(ip link show | awk -F': ' '/^[0-9]+: zt/{print $2}' | head -n1)
echo "ZeroTier interface: $ZT"
uci set firewall.zt.network="$ZT"
uci commit firewall
/etc/init.d/firewall restart
```

The ZeroTier zone is isolated — `forward=REJECT` means you can reach the router's admin interfaces but cannot cross into any LAN from ZeroTier.

---

## X-WRT natflow Note

X-WRT ships with `natflow` hardware acceleration which runs alongside fw4. If after flashing X-WRT you see VLAN10/20 traffic bypassing redsocks or the killswitch, disable natflow:

```sh
uci set natflow.misc.disabled='1'
uci commit natflow
/etc/init.d/natflow stop
/etc/init.d/natflow disable
```

Then re-run the killswitch test.

---

## Files Written by This Script

| Path | Purpose |
|---|---|
| `/etc/redsocks.conf` | redsocks SOCKS5 proxy config |
| `/etc/init.d/dns2socks` | dns2socks procd service |
| `/etc/nftables.d/10-custom-routing.nft` | Hard enforcement — proxy redirects + killswitch |
| `/etc/hotplug.d/iface/99-vpn-route` | Table 200 killswitch engine |
| `/etc/sysctl.d/10-conntrack.conf` | Conntrack tuning for 128MB RAM |

---

## Troubleshooting

**VPN WiFi gets IP but no internet**
The `iif lo lookup main priority 50` rule is missing. This keeps the router's own traffic (WireGuard handshake, dnsmasq) on the main table. Re-run the script.

```sh
ip rule show | grep "iif lo"
# Must exist — if missing:
ip rule add from all iif lo lookup main priority 50
```

**VPN WiFi connected but leaking to ISP**
Table 200 blackhole is missing. Check:

```sh
ip route show table 200
# Must contain: blackhole default metric 65535
```

If missing, trigger the hotplug manually:

```sh
INTERFACE=wg0 ACTION=ifup sh /etc/hotplug.d/iface/99-vpn-route
```

**SOCKS5 WiFi — DNS not working**
dns2socks is not running or not binding correctly:

```sh
ss -unlp | grep 5300
/etc/init.d/dns2socks restart
logread | grep dns2socks
```

**SOCKS5 WiFi — no internet but DNS works**
redsocks is not running or proxy credentials are wrong:

```sh
ss -tnlp | grep 12345
logread | grep redsocks
# Check proxy IP/port/credentials in /etc/vpn-secrets.conf
```

**IPv6 leaking on VPN/SOCKS5**
Check nftables and fw4 rules are loaded:

```sh
nft list table inet custom_routing
# Must show ipv6_drop chain with rules for br-tun_lan and br-prx_lan
```
