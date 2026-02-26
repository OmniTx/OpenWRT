#!/bin/sh
# ------------------------------------------------------------------
# X-WRT ZeroTier Remote Management Setup
# Target : X-WRT 26.04 (fw4 / nftables), MT7621
# Goal   : Install ZeroTier, join network, allow remote LuCI/SSH access,
#          and strictly block LAN forwarding (management only).
# ------------------------------------------------------------------

ZT_NETWORK="<YOUR_ZT_NETWORK_ID>"

echo "=== X-WRT ZeroTier Setup ==="
echo ""

# ------------------------------------------------------------------
# STEP 1: Install Package
# ------------------------------------------------------------------
echo "[1/4] Installing ZeroTier..."
apk update
apk add zerotier

# ------------------------------------------------------------------
# STEP 2: Configure ZeroTier Daemon
# Overwriting directly prevents UCI syntax/parsing corruption.
# ------------------------------------------------------------------
echo "[2/4] Configuring ZeroTier daemon..."

cat > /etc/config/zerotier << EOF
config zerotier 'zerotier'
	option enabled '1'
	list join '${ZT_NETWORK}'
	option secret 'generate'
EOF

# ------------------------------------------------------------------
# STEP 3: Network Interface
# ------------------------------------------------------------------
echo "[3/4] Creating network interface..."

uci set network.zerotier=interface
uci set network.zerotier.proto='none'
uci set network.zerotier.device='zt+'

# ------------------------------------------------------------------
# STEP 4: Firewall Rules (fw4)
# Allows INPUT (admin access) but REJECTS FORWARD (no LAN bridging).
# ------------------------------------------------------------------
echo "[4/4] Configuring firewall..."

uci set firewall.zt_zone=zone
uci set firewall.zt_zone.name='zerotier'
uci set firewall.zt_zone.input='ACCEPT'
uci set firewall.zt_zone.output='ACCEPT'
uci set firewall.zt_zone.forward='REJECT'

# Clear existing list to remain idempotent, then assign network
uci del firewall.zt_zone.network 2>/dev/null || true
uci add_list firewall.zt_zone.network='zerotier'

# ------------------------------------------------------------------
# STEP 5: Apply & Restart
# ------------------------------------------------------------------
echo "[Applying Configuration]..."

uci commit network
uci commit firewall

/etc/init.d/zerotier enable
/etc/init.d/network reload
/etc/init.d/firewall restart

# The crucial delayed restart to ensure netifd binds the zt+ interface
echo "Restarting ZeroTier service to bind interface..."
sleep 3
/etc/init.d/zerotier restart

echo ""
echo "============================================="
echo "  ZeroTier Setup Complete"
echo "============================================="
echo "  Network ID : $ZT_NETWORK"
echo "  Access     : Router Admin (LuCI / SSH) ONLY"
echo ""
echo "  Check Status: zerotier-cli info"
echo "  Check IP    : ifconfig | grep -A 2 zt"
echo "============================================="