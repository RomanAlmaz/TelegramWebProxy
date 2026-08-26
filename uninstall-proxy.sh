#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root

echo "============================================================"
echo "          TELEGRAM WEB PROXY UNINSTALLER"
echo "============================================================"
echo
echo "This removes components installed by the Web Proxy installer."
echo "Existing components that were detected as pre-existing are kept."
echo
echo "Type REMOVE to continue:"
read -r CONFIRM
[[ "$CONFIRM" == "REMOVE" ]] || { echo "Cancelled."; exit 0; }

REUSED_CADDY=0
REUSED_MT=0
REUSED_RELAY=0

if [[ -r "$MANIFEST" ]]; then
    REUSED_CADDY="$(read_manifest_value reused_caddy 0)"
    REUSED_MT="$(read_manifest_value reused_mtproxy 0)"
    REUSED_RELAY="$(read_manifest_value reused_relay 0)"
else
    echo
    echo "WARNING: ownership manifest not found."
    echo "Conservative mode is enabled: pre-existing MTProxy, relay and Caddy are preserved."
    REUSED_CADDY=1
    REUSED_MT=1
    REUSED_RELAY=1
fi

echo
echo "[1/7] Stopping installer services..."

for unit in \
    tproxy-firewall.service \
    refresh-mtproxy-config.timer \
    refresh-mtproxy-config.service
do
    systemctl stop "$unit" 2>/dev/null || true
done

[[ "$REUSED_RELAY" == "1" ]] || systemctl stop tproxy-server.service 2>/dev/null || true
[[ "$REUSED_MT" == "1" ]] || systemctl stop mtproxy.service 2>/dev/null || true
[[ "$REUSED_CADDY" == "1" ]] || systemctl stop caddy.service 2>/dev/null || true

echo "[2/7] Disabling installer services..."

for unit in \
    tproxy-firewall.service \
    refresh-mtproxy-config.timer \
    refresh-mtproxy-config.service
do
    systemctl disable "$unit" 2>/dev/null || true
done

[[ "$REUSED_RELAY" == "1" ]] || systemctl disable tproxy-server.service 2>/dev/null || true
[[ "$REUSED_MT" == "1" ]] || systemctl disable mtproxy.service 2>/dev/null || true
[[ "$REUSED_CADDY" == "1" ]] || systemctl disable caddy.service 2>/dev/null || true

echo "[3/7] Removing installer service files..."

rm -f \
    /etc/systemd/system/tproxy-firewall.service \
    /etc/systemd/system/refresh-mtproxy-config.service \
    /etc/systemd/system/refresh-mtproxy-config.timer \
    /usr/local/sbin/refresh-mtproxy-config

[[ "$REUSED_RELAY" == "1" ]] || rm -f /etc/systemd/system/tproxy-server.service
[[ "$REUSED_MT" == "1" ]] || rm -f /etc/systemd/system/mtproxy.service
[[ "$REUSED_CADDY" == "1" ]] || rm -f /etc/systemd/system/caddy.service

rm -f /etc/systemd/system/caddy.service.d/tproxy.conf

echo "[4/7] Removing proxy files..."

rm -rf \
    "$INSTALLED_REPO" \
    /opt/tproxy-site \
    /srv/tproxy-site \
    /etc/tproxy-server \
    /etc/caddy/caddy

if [[ "$REUSED_RELAY" != "1" ]]; then
    rm -f /usr/local/bin/tproxy-server
    rm -rf /opt/go1.26.5
fi

if [[ "$REUSED_MT" != "1" ]]; then
    rm -rf /opt/MTProxy
    rm -rf /etc/mtproxy
fi

echo "[5/7] Removing installer users..."

if [[ "$REUSED_RELAY" != "1" ]] && id tproxy >/dev/null 2>&1; then
    home="$(getent passwd tproxy | cut -d: -f6 || true)"
    shell="$(getent passwd tproxy | cut -d: -f7 || true)"
    if [[ "$home" == "/nonexistent" && "$shell" == "/usr/sbin/nologin" ]]; then
        userdel tproxy 2>/dev/null || true
    fi
fi

if [[ "$REUSED_MT" != "1" ]] && id mtproxy >/dev/null 2>&1; then
    home="$(getent passwd mtproxy | cut -d: -f6 || true)"
    shell="$(getent passwd mtproxy | cut -d: -f7 || true)"
    if [[ "$home" == "/nonexistent" && "$shell" == "/usr/sbin/nologin" ]]; then
        userdel mtproxy 2>/dev/null || true
    fi
fi

echo "[6/7] Cleaning firewall and runtime state..."
remove_proxy_firewall
rm -f "$MANIFEST"

systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true

echo "[7/7] Final verification..."

echo
echo "Remaining related units:"
systemctl list-unit-files 2>/dev/null | grep -E '^(mtproxy|tproxy-server|tproxy-firewall|refresh-mtproxy-config)\.' || true

echo
echo "============================================================"
echo "             TELEGRAM WEB PROXY REMOVED"
echo "============================================================"
echo
echo "The installer-owned proxy components have been removed."
echo "Shared OS packages were intentionally NOT removed."
echo "A pre-existing Caddy/MTProxy/relay was preserved if detected."
echo
echo "Reboot is normally not required."
echo "============================================================"
