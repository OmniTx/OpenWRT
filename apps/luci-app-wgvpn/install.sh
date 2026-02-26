#!/bin/sh
# install.sh — luci-app-wgvpn installer
# Run on the router over SSH: sh install.sh

set -e

REPO="https://raw.githubusercontent.com/OmniTx/luci-app-wgvpn/refs/heads/master/src"

echo ""
echo "╔══════════════════════════════════════╗"
echo "║   luci-app-wgvpn Installer           ║"
echo "╚══════════════════════════════════════╝"
echo ""

[ -f /etc/openwrt_release ] || { echo "❌ Not an OpenWrt system."; exit 1; }

FREE=$(df /overlay 2>/dev/null | awk 'NR==2{print $4}')
[ -n "$FREE" ] && [ "$FREE" -lt 100 ] && { echo "❌ Not enough free space (${FREE}KB)."; exit 1; }

get() {
    local src="$1" dst="$2" mode="${3:-644}"
    mkdir -p "$(dirname "$dst")"
    wget -qO "$dst" --no-check-certificate "${REPO}/${src}" || {
        echo "  ❌ Failed to download $src"
        return 1
    }
    chmod "$mode" "$dst"
    echo "  → $dst"
}

echo "📦 Installing files..."
get "usr/libexec/rpcd/luci.wgvpn"               "/usr/libexec/rpcd/luci.wgvpn"               755
get "usr/share/rpcd/acl.d/luci-app-wgvpn.json"  "/usr/share/rpcd/acl.d/luci-app-wgvpn.json"  644
get "usr/share/luci/menu.d/luci-app-wgvpn.json" "/usr/share/luci/menu.d/luci-app-wgvpn.json" 644
get "www/luci-static/resources/view/wgvpn.js"   "/www/luci-static/resources/view/wgvpn.js"   644

# Strip Windows CR characters from shell scripts — harmless if already LF-only
sed -i 's/\r//' /usr/libexec/rpcd/luci.wgvpn

if [ ! -f /etc/config/wgvpn ]; then
    get "etc/config/wgvpn" "/etc/config/wgvpn" 644
    echo "  ✅ Default config created"
else
    echo "  ℹ️  /etc/config/wgvpn already exists — not overwritten"
fi

echo ""
echo "🔄 Restarting services..."
/etc/init.d/rpcd restart   && echo "  ✅ rpcd"
/etc/init.d/uhttpd restart && echo "  ✅ uhttpd"

echo ""
echo "╔══════════════════════════════════════╗"
echo "║  ✅ Done! Open LuCI → Services →    ║"
echo "║            WireGuard VPN            ║"
echo "╚══════════════════════════════════════╝"
echo ""
