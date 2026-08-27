#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root

echo "============================================================"
echo "          УДАЛЕНИЕ TELEGRAM WEB PROXY"
echo "============================================================"
echo
echo "Будут удалены компоненты, установленные установщиком Web Proxy."
echo "Компоненты, которые уже были на сервере до установки, сохраняются."
echo
echo "Введите REMOVE для продолжения:"
read -r CONFIRM
[[ "$CONFIRM" == "REMOVE" ]] || { echo "Отменено."; exit 0; }

REUSED_CADDY=0
REUSED_MT=0
REUSED_RELAY=0

if [[ -r "$MANIFEST" ]]; then
    REUSED_CADDY="$(read_manifest_value reused_caddy 0)"
    REUSED_MT="$(read_manifest_value reused_mtproxy 0)"
    REUSED_RELAY="$(read_manifest_value reused_relay 0)"
else
    echo
    echo "ВНИМАНИЕ: manifest установки не найден."
    echo "Включён консервативный режим: MTProxy, relay и Caddy сохраняются."
    REUSED_CADDY=1
    REUSED_MT=1
    REUSED_RELAY=1
fi

echo
echo "[1/7] Остановка сервисов установщика..."

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

echo "[2/7] Отключение сервисов установщика..."

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

echo "[3/7] Удаление unit-файлов установщика..."

rm -f \
    /etc/systemd/system/tproxy-firewall.service \
    /etc/systemd/system/refresh-mtproxy-config.service \
    /etc/systemd/system/refresh-mtproxy-config.timer \
    /usr/local/sbin/refresh-mtproxy-config

[[ "$REUSED_RELAY" == "1" ]] || rm -f /etc/systemd/system/tproxy-server.service
[[ "$REUSED_MT" == "1" ]] || rm -f /etc/systemd/system/mtproxy.service
[[ "$REUSED_CADDY" == "1" ]] || rm -f /etc/systemd/system/caddy.service

rm -f /etc/systemd/system/caddy.service.d/tproxy.conf

echo "[4/7] Удаление файлов прокси..."

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

echo "[5/7] Удаление пользователей установщика..."

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

echo "[6/7] Очистка firewall и runtime-состояния..."
remove_proxy_firewall
rm -f "$MANIFEST"

systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true

echo "[7/7] Финальная проверка..."

echo
echo "Оставшиеся связанные unit-ы:"
systemctl list-unit-files 2>/dev/null | grep -E '^(mtproxy|tproxy-server|tproxy-firewall|refresh-mtproxy-config)\.' || true

echo
echo "============================================================"
echo "          TELEGRAM WEB PROXY УДАЛЁН"
echo "============================================================"
echo
echo "Компоненты прокси, установленные установщиком, удалены."
echo "Общие системные пакеты намеренно не удалялись."
echo "Ранее существовавшие Caddy/MTProxy/relay сохранены, если были обнаружены."
echo
echo "Перезагрузка обычно не требуется."
echo "============================================================"
