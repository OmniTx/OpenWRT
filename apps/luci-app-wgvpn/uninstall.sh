#!/bin/sh
# uninstall.sh — luci-app-wgvpn uninstaller
# Run on the router over SSH: sh uninstall.sh

echo ""
echo "╔══════════════════════════════════════╗"
echo "║   luci-app-wgvpn Uninstaller         ║"
echo "╚══════════════════════════════════════╝"
echo ""

[ -f /etc/openwrt_release ] || { echo "❌ Not an OpenWrt system."; exit 1; }

# ── Remove installed files ────────────────────────────────────────────────────
echo "🗑️  Removing files..."
rm -f /usr/libexec/rpcd/luci.wgvpn
rm -f /usr/share/rpcd/acl.d/luci-app-wgvpn.json
rm -f /usr/share/luci/menu.d/luci-app-wgvpn.json
rm -f /www/luci-static/resources/view/wgvpn.js
rm -f /etc/hotplug.d/iface/99-wgvpn

if [ -f /etc/config/wgvpn ]; then
    printf "❓ Remove /etc/config/wgvpn as well? [y/N] "
    read ANS
    [ "$ANS" = "y" ] && rm -f /etc/config/wgvpn && echo "  ✅ Config removed"
fi

# ── Read settings before config may be gone ──────────────────────────────────
TABLE="100"
IFACE=""
if [ -f /etc/config/wgvpn ]; then
    . /lib/functions.sh
    config_load wgvpn
    config_get TABLE global table     '100'
    config_get IFACE global interface ''
fi

# ── Clean up routing rules ────────────────────────────────────────────────────
echo "🔧 Cleaning up routing..."
ip rule del prio 50 2>/dev/null
ip rule list 2>/dev/null | grep "lookup $TABLE" | awk -F: '{print $1}' | while read p; do
    ip rule del prio "$p" 2>/dev/null
done
ip route flush table "$TABLE" 2>/dev/null

# ── Clean up nftables ─────────────────────────────────────────────────────────
echo "🔧 Cleaning up firewall..."

H=$(nft -a list chain inet fw4 input 2>/dev/null | awk '/jump input_wg_vpn/{print $NF}')
[ -n "$H" ] && nft delete rule inet fw4 input handle "$H" 2>/dev/null
nft flush  chain inet fw4 input_wg_vpn 2>/dev/null
nft delete chain inet fw4 input_wg_vpn 2>/dev/null

if [ -n "$IFACE" ]; then
    H=$(nft -a list chain inet fw4 srcnat 2>/dev/null | awk "/oifname \"$IFACE\" masquerade/{print \$NF}")
    [ -n "$H" ] && nft delete rule inet fw4 srcnat handle "$H" 2>/dev/null

    H=$(nft -a list chain inet fw4 forward 2>/dev/null | grep "oifname \"$IFACE\" accept" | awk '{print $NF}' | head -1)
    [ -n "$H" ] && nft delete rule inet fw4 forward handle "$H" 2>/dev/null
fi

nft -a list chain inet fw4 forward 2>/dev/null | awk '/ipv6-leak/{print $NF}' | while read h; do
    nft delete rule inet fw4 forward handle "$h" 2>/dev/null
done

# ── Restart services ──────────────────────────────────────────────────────────
echo "🔄 Restarting services..."
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart

echo ""
echo "✅ Uninstallation complete!"
echo ""