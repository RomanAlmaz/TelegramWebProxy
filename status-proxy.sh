#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root

print_unit() {
    local unit="$1"
    local state enabled

    if ! systemctl list-unit-files "${unit}" >/dev/null 2>&1; then
        printf "  %-28s не установлен\n" "$unit"
        return 0
    fi

    state="$(systemctl is-active "$unit" 2>/dev/null || true)"
    enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
    printf "  %-28s active=%-10s enabled=%s\n" "$unit" "$state" "$enabled"
}

print_port() {
    local port="$1"
    local process="${2:-any}"

    if port_is_listening "$port"; then
        if [[ "$process" != "any" ]] && port_has_expected_process "$port" "$process"; then
            printf "  :%-5s слушается (%s)\n" "$port" "$process"
        else
            local line
            line="$(ss -lntp 2>/dev/null | grep -E ":${port}\b" | head -n1 || true)"
            printf "  :%-5s слушается %s\n" "$port" "${line:-}"
        fi
    else
        printf "  :%-5s не слушается\n" "$port"
    fi
}

check_http() {
    local url="$1"
    local label="$2"

    if curl -fsS --max-time 5 "$url" >/dev/null 2>&1; then
        printf "  %-18s OK\n" "$label"
    else
        printf "  %-18s FAIL\n" "$label"
    fi
}

DOMAIN="$(get_domain_from_config)"
SECRET="$(get_secret_from_profiles || true)"

echo "============================================================"
echo "          СТАТУС TELEGRAM WEB PROXY"
echo "============================================================"
echo

if [[ ! -f /usr/local/bin/tproxy-server && ! -f /etc/tproxy-server/config.json ]]; then
    echo "Прокси на этом VPS не установлен."
    echo
    echo "Установка:"
    echo "  git clone ${PROJECT_REPO_URL}"
    echo "  cd ${PROJECT_REPO_NAME} && chmod +x *.sh && sudo bash install-proxy.sh"
    exit 0
fi

echo "--- сервисы ---"
print_unit mtproxy.service
print_unit tproxy-server.service
print_unit caddy.service
print_unit tproxy-firewall.service
print_unit refresh-mtproxy-config.timer

echo
echo "--- порты ---"
print_port 80 caddy
print_port 443 caddy
print_port 2398 mtproto-proxy
print_port 8080 tproxy-server
print_port 8081 tproxy-server

echo
echo "--- health ---"
check_http "http://127.0.0.1:8081/healthz" "healthz"
check_http "http://127.0.0.1:8081/readyz" "readyz"

if [[ -n "$DOMAIN" ]]; then
    if curl -fsSI --max-time 10 "https://${DOMAIN}/" >/dev/null 2>&1; then
        printf "  %-18s OK (https://${DOMAIN}/)\n" "HTTPS"
    else
        printf "  %-18s FAIL (https://${DOMAIN}/)\n" "HTTPS"
    fi
else
    printf "  %-18s домен не настроен\n" "HTTPS"
fi

echo
echo "--- конфигурация ---"
if [[ -n "$DOMAIN" ]]; then
    echo "  Домен:   https://${DOMAIN}/"
else
    echo "  Домен:   не настроен"
fi

if [[ -n "$SECRET" ]]; then
    echo "  Secret:  $(mask_secret "$SECRET")"
    TELEGRAM_SECRET="${SECRET#dd}"
    echo "  Ссылка для Telegram:"
    echo "    https://t.me/webproxy?server=${DOMAIN}&secret=${TELEGRAM_SECRET}"
else
    echo "  Secret:  не найден"
fi

if [[ -r "$MANIFEST" ]]; then
    echo
    echo "--- manifest установки ---"
    echo "  Manifest: $MANIFEST"
    echo "  Установлен: $(read_manifest_value installed_by unknown)"
    echo "  Версия:     $(read_manifest_value version unknown)"
    echo "  Проект:     $(read_manifest_value project_root unknown)"
fi

echo
echo "--- сайт ---"
if [[ -f "$SITE_TARGET/index.html" ]]; then
    file_count="$(find "$SITE_TARGET" -type f | wc -l | tr -d ' ')"
    site_size="$(du -sh "$SITE_TARGET" 2>/dev/null | awk '{print $1}')"
    echo "  Путь:    $SITE_TARGET"
    echo "  Файлов:  $file_count"
    echo "  Размер:  ${site_size:-неизвестно}"
else
    echo "  Сайт не развёрнут в $SITE_TARGET"
fi

echo
echo "--- последние логи (5 строк) ---"
for unit in mtproxy tproxy-server caddy; do
    if systemctl list-units --all --type=service 2>/dev/null | grep -q "${unit}.service"; then
        echo "  [$unit]"
        journalctl -u "$unit" -n 5 --no-pager 2>/dev/null | sed 's/^/    /' || true
    fi
done

echo
echo "============================================================"
