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

[[ -d "$SOURCE_DIR" ]] || die "Site directory not found: $SOURCE_DIR"
[[ -f "$SOURCE_DIR/index.html" ]] || die "index.html not found in $SOURCE_DIR"

if [[ ! -f /etc/tproxy-server/config.json ]]; then
    die "Proxy is not installed. Run install-proxy.sh first."
fi

if ! id tproxy >/dev/null 2>&1; then
    die "User tproxy not found. Run install-proxy.sh first."
fi

echo "============================================================"
echo "          DEPLOY PUBLIC SITE"
echo "============================================================"
echo
echo "Source:  $SOURCE_DIR"
echo "Target:  $SITE_TARGET"
echo

deploy_site_files "$SOURCE_DIR" "$SITE_TARGET"

if [[ -x /usr/local/bin/tproxy-server ]]; then
    echo "Validating relay configuration..."
    /usr/local/bin/tproxy-server \
        -config /etc/tproxy-server/config.json \
        -profiles-file /etc/tproxy-server/profiles.json \
        -check
fi

if systemctl list-unit-files tproxy-server.service >/dev/null 2>&1; then
    echo "Restarting tproxy-server..."
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
        echo "WARNING: relay did not become ready after restart."
        echo "Check: journalctl -u tproxy-server -n 50 --no-pager"
    fi
else
    echo "tproxy-server service not found; files deployed only."
fi

DOMAIN="$(get_domain_from_config)"
file_count="$(find "$SITE_TARGET" -type f | wc -l | tr -d ' ')"

echo
echo "============================================================"
echo "             SITE DEPLOYED"
echo "============================================================"
echo
echo "Files deployed: $file_count"
echo "Site path:      $SITE_TARGET"
if [[ -n "$DOMAIN" ]]; then
    echo "Public URL:     https://${DOMAIN}/"
fi
echo
echo "Caddy restart is not required."
echo "============================================================"
