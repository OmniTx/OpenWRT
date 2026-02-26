# luci-app-wgvpn

> A lightweight LuCI application for managing WireGuard VPN routing on OpenWrt routers.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![OpenWrt](https://img.shields.io/badge/OpenWrt-22.03%2B-blueviolet)](https://openwrt.org)
[![Firewall](https://img.shields.io/badge/Firewall-nftables%20%2F%20fw4-orange)](https://openwrt.org/docs/guide-user/firewall/fw4)

---

## Overview

`luci-app-wgvpn` gives you a clean web UI inside LuCI to control which devices on your LAN route through a WireGuard VPN tunnel — without touching the command line after the initial setup. It supports both **selective routing** (per-device or per-subnet) and **full-tunnel** mode, with live status monitoring, IPv6 leak protection, and automatic rule persistence across reboots.

---

## Features

| | |
|---|---|
| 📊 **Live status card** | Shows endpoint, last handshake, data transfer, and active rule count — refreshes every 5 seconds |
| 🎯 **Selective routing** | Per-device or per-subnet rules; only listed hosts use the VPN |
| 🌐 **Full-tunnel mode** | Routes all RFC-1918 LAN traffic through the VPN with one toggle |
| 🛡️ **IPv6 leak protection** | Drops outbound global IPv6 from `br-lan` so native IPv6 cannot bypass the tunnel |
| � **Input validation** | Interface names, IPs, and subnets are all validated before anything is sent to the backend |
| ♻️ **Persistent rules** | Writes a hotplug script so routing rules survive interface restarts and reboots |
| 🧹 **Clean uninstall** | Removes all files, routing rules, nftables chains, and the hotplug script |

---

## Requirements

- **OpenWrt 22.03 or newer** (or a compatible fork such as **X-WRT**) — uses `nftables` / `fw4`
- **WireGuard already configured** as a network interface (e.g. `wg_vpn`) under *Network → Interfaces*
- **`wireguard-tools`** installed (`wg` binary must be present for status reporting)

> **Note:** This app manages *routing and firewall rules* for an existing WireGuard interface. It does not create or manage WireGuard peers, keys, or tunnel configuration itself.

---

## Installation

### Quick install (recommended)

Run this on your router over SSH:

```sh
wget --no-check-certificate -O /tmp/install.sh https://raw.githubusercontent.com/OmniTx/luci-app-wgvpn/refs/heads/master/install.sh
sh /tmp/install.sh
```

The installer checks for free space, downloads all required files, and restarts `rpcd` and `uhttpd` automatically.

### Manual install (SCP)

If your router has no internet access, copy the files from your machine:

```sh
# From your computer, inside the repo directory:
scp -r src/* root@192.168.1.1:/

# Then on the router:
ssh root@192.168.1.1
chmod +x /usr/libexec/rpcd/luci.wgvpn
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```

### Installed files

```
/usr/libexec/rpcd/luci.wgvpn                  ← backend RPC handler (shell)
/usr/share/rpcd/acl.d/luci-app-wgvpn.json     ← rpcd ACL definition
/usr/share/luci/menu.d/luci-app-wgvpn.json    ← LuCI menu entry
/www/luci-static/resources/view/wgvpn.js      ← frontend view
/etc/config/wgvpn                              ← UCI configuration
```

A hotplug script at `/etc/hotplug.d/iface/99-wgvpn` is written the first time you click **Save & Apply** in the UI.

---

## Configuration

After installation, open LuCI and navigate to **Services → WireGuard VPN**.

### Routing Settings

| Option | Default | Description |
|--------|---------|-------------|
| **WireGuard Interface** | `wg_vpn` | System name of your WireGuard interface. Must match the name shown under *Network → Interfaces*. |
| **Routing Table ID** | `100` | Numeric ID of the custom routing table used for VPN traffic. Only change this if it conflicts with another service. |
| **VPN Mode** | `selective` | `selective` — only listed rules use the VPN. `all` — all RFC-1918 LAN traffic goes through the VPN. |
| **Block IPv6 Leaks** | off | Drops outbound global-scope IPv6 (`2000::/3`) from `br-lan` to prevent address leaks. |
| **VPN DNS Server** | *(empty)* | An optional DNS server reachable through the tunnel (e.g. `10.2.0.1` for Proton VPN). Leave blank to keep the system default. |

### Routing Rules (Selective mode only)

Each rule targets a specific IP address or subnet. Only enabled rules are applied.

| Field | Example | Description |
|-------|---------|-------------|
| **Label** | `My Laptop` | A human-friendly name for your own reference |
| **IP / Subnet** | `10.10.1.50` or `192.168.1.0/24` | The source IP or CIDR subnet to match |
| **Active** | ✓ | If unchecked, the rule is saved but not applied |

Click **Save & Apply** after making any changes. Rules take effect immediately without a reboot.

### UCI configuration reference

The underlying config file is `/etc/config/wgvpn`:

```uci
config global 'global'
    option interface  'wg_vpn'   # WireGuard interface name
    option table      '100'      # Routing table ID
    option mode       'selective' # 'selective' or 'all'
    option block_ipv6 '0'        # '1' to enable IPv6 leak block
    option vpn_dns    '10.2.0.1' # VPN DNS server (optional)

config rule 'my_laptop'
    option name    'My Laptop'
    option subnet  '10.10.1.50'
    option enabled '1'
```

---

## Uninstall

```sh
wget --no-check-certificate -O /tmp/uninstall.sh https://raw.githubusercontent.com/OmniTx/luci-app-wgvpn/refs/heads/master/uninstall.sh
sh /tmp/uninstall.sh
```

The uninstaller removes all installed files, clears the routing table and ip rules, removes the nftables chains and masquerade rule, and reloads the affected services. It will optionally remove `/etc/config/wgvpn` when prompted.

---

## How it works

When you click **Save & Apply**, the frontend saves the UCI config and calls the `luci.wgvpn apply` RPC method. The backend shell script then:

1. Removes any existing ip rules pointing at the VPN routing table
2. Rebuilds the routing table with a default route and (optionally) a DNS host route through the WireGuard interface
3. Adds `ip rule` entries to direct traffic from the matching sources into that table
4. Ensures the `input_wg_vpn` nftables chain exists, is clean, and is hooked into the `fw4 input` chain
5. Adds a masquerade rule so the VPN provider sees the tunnel address rather than the LAN address
6. Optionally blocks outbound IPv6
7. Writes or overwrites `/etc/hotplug.d/iface/99-wgvpn` so everything is automatically re-applied the next time the WireGuard interface comes up

---

## Tested on

| Device | SoC | Firmware | Kernel |
|--------|-----|----------|--------|
| Xiaomi Mi Router 4A Gigabit Edition | MediaTek MT7621 | X-WRT 26.04 Resolute (`b202602160201`) | 6.12.71 |

---

## Troubleshooting

**The status card always shows DISCONNECTED**
- Confirm WireGuard is running: `wg show` — if it returns nothing, the interface is not up
- Check that the interface name in *Routing Settings* matches exactly what `ip link show` reports

**No internet on VPN clients after applying rules**
- Verify the WireGuard peer's `AllowedIPs` includes `0.0.0.0/0` if using full-tunnel mode
- Check that the masquerade rule was added: `nft list chain inet fw4 srcnat`

**Rules disappear after reboot**
- Make sure the hotplug script exists: `cat /etc/hotplug.d/iface/99-wgvpn`
- If it's missing, click **Save & Apply** once while the interface is up

**IPv6 still leaks with block enabled**
- The block targets `br-lan`. If your LAN bridge has a different name, the rule won't match — check with `ip link show type bridge`

---

## License

[MIT](LICENSE) © 2026 OmniTx
