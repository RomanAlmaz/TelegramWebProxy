#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root
require_local_site

SOURCE_DIR="$SITE_SOURCE"
if [[ $# -gt 0 ]]; then
    SOURCE_DIR="$1"
fi

[[ -d "$SOURCE_DIR" ]] || die "Каталог сайта не найден: $SOURCE_DIR"
[[ -f "$SOURCE_DIR/index.html" ]] || die "index.html не найден в $SOURCE_DIR"

if [[ ! -f /etc/tproxy-server/config.json ]]; then
    die "Прокси не установлен. Сначала запустите install-proxy.sh."
fi

if ! id tproxy >/dev/null 2>&1; then
    die "Пользователь tproxy не найден. Сначала запустите install-proxy.sh."
fi

echo "============================================================"
echo "          ДЕПЛОЙ ПУБЛИЧНОГО САЙТА"
echo "============================================================"
echo
echo "Источник: $SOURCE_DIR"
echo "Цель:     $SITE_TARGET"
echo

deploy_site_files "$SOURCE_DIR" "$SITE_TARGET"

if [[ -x /usr/local/bin/tproxy-server ]]; then
    echo "Проверка конфигурации relay..."
    /usr/local/bin/tproxy-server \
        -config /etc/tproxy-server/config.json \
        -profiles-file /etc/tproxy-server/profiles.json \
        -check
fi

if systemctl list-unit-files tproxy-server.service >/dev/null 2>&1; then
    echo "Перезапуск tproxy-server..."
    systemctl restart tproxy-server.service

    READY=0
    for _ in $(seq 1 20); do
        if curl -fsS --max-time 2 http://127.0.0.1:8081/readyz >/dev/null 2>&1; then
            READY=1
            break
        fi
        sleep 1
    done

    if [[ "$READY" == "1" ]]; then
        echo "      Relay /readyz OK"
    else
        echo "ВНИМАНИЕ: relay не перешёл в ready после перезапуска."
        echo "Проверьте: journalctl -u tproxy-server -n 50 --no-pager"
    fi
else
    echo "Сервис tproxy-server не найден; файлы только скопированы."
fi

DOMAIN="$(get_domain_from_config)"
file_count="$(find "$SITE_TARGET" -type f | wc -l | tr -d ' ')"

echo
echo "============================================================"
echo "          САЙТ РАЗВЁРНУТ"
echo "============================================================"
echo
echo "Файлов развёрнуто: $file_count"
echo "Путь к сайту:      $SITE_TARGET"
if [[ -n "$DOMAIN" ]]; then
    echo "Публичный URL:     https://${DOMAIN}/"
fi
echo
echo "Перезапуск Caddy не требуется."
echo "============================================================"
