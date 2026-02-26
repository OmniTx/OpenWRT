# OpenWrt Repository 🌐

Welcome to my OpenWrt repository! This project serves as a central hub for everything related to my OpenWrt router setups. Here you will find custom scripts, configurations, guides, applications, and backups to easily manage, replicate, or restore router configurations.

## 📁 Repository Structure

This repository is organized into the following sections:

- **[`my-configs/`](./my-configs/)**
  - Contains exported UCI states, custom shell scripts, and specific network setups (e.g., ProtonVPN WireGuard isolated LAN script).
  - *Note: Sensitive variables such as private keys and passwords have been redacted. Check for `.example` files (like `vpn-secrets.conf.example`) to see what information you need to provide to use these scripts.*
  
- **`apps/`**
  - OpenWrt packages, compiled binaries, or custom scripts for apps running on the router.

- **`guides/`** *(Coming Soon)*
  - Step-by-step markdown tutorials, troubleshooting notes, and explanations of complex setups (like VLANs, policy-based routing, or VPNs).

- **`backups/`** *(Coming Soon)*
  - Routine backups of my router's configuration. *(Note: Make sure not to upload hardware-specific or highly sensitive backup archives directly without sanitization!)*

## 🔒 A Note on Security

All sensitive credentials (passwords, private SSH/WireGuard keys, public IP addresses) are excluded from this repository using `.gitignore` or are masked with placeholder variables (e.g., `<YOUR_PRIVATE_KEY>`). 

If you decide to use any configuration found here, simply replace the placeholder strings with your actual values or provide the local `.conf` files as expected by the scripts.

## 🚀 Getting Started

1. **Clone the repository:**
   ```bash
   git clone https://github.com/OmniTx/OpenWRT.git
   cd OpenWRT
   ```

2. **Explore the configs:** Browse through `my-configs/` to find useful scripts. For instance, the `wireguard-setup-basic.sh` script automates creating an isolated VPN access point.

3. **Provide secrets:** Duplicate any `.example` files, remove the `.example` extension, and add your credentials.

---
*Built with ❤️ for the [OpenWrt](https://openwrt.org/) community.*
