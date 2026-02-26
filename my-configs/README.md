# My OpenWrt Configurations

This directory contains my exported router states, scripts, and network configuration files.

## 📄 Contents

- **`wireguard-setup-basic.sh`**: A shell script to configure a robust WireGuard VPN on an OpenWrt router (specifically targeted at X-WRT 26.04). It handles creating an isolated VPN LAN, a dedicated 5 GHz Wi-Fi access point, strict firewall rules (kill switch), and a PC-specific toggle command (`pc-vpn-toggle`).
- **`uci export.txt`**: A snapshot of the UCI (Unified Configuration Interface) state for my router's network, wireless, firewall, and dhcp configurations.
- **`vpn-secrets.conf.example`**: A template file containing dummy variables for sensitive information. 

## 🔒 Secrets Management

For security, my actual keys, passwords, and IPs are **not** stored in this repository.

To use the `wireguard-setup-basic.sh` script:

1. Copy the example secrets file:
   ```bash
   cp vpn-secrets.conf.example vpn-secrets.conf
   ```
2. Edit `vpn-secrets.conf` and fill in your actual ProtonVPN or WireGuard credentials, as well as your desired Wi-Fi password.
3. The `.gitignore` at the repository root guarantees that your raw `vpn-secrets.conf` will never be accidentally pushed to GitHub.

## 🛠 Usage

You can safely run the setup script on a freshly reset OpenWrt installation (after configuring your primary WAN/Wi-Fi):
```bash
chmod +x wireguard-setup-basic.sh
./wireguard-setup-basic.sh
```
