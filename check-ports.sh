#!/usr/bin/env bash
# Diagnose why ports 80/443 are closed on Oracle VPS.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
fail() { echo -e "${RED}[!!]${NC} $*"; }
warn() { echo -e "${YELLOW}[?]${NC} $*"; }

if [[ "$#" -gt 0 ]]; then
    PORTS=("$@")
else
    PORTS=(80 443)
fi

RULES_V4="/etc/iptables/rules.v4"

check_port_listening() {
    local port="$1"

    echo "--- Port ${port} listener ---"
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        ss -tlnp | grep ":${port} "
        if ss -tlnp | grep ":${port} " | grep -q "127.0.0.1:${port}"; then
            fail "Service listens only on 127.0.0.1 - not reachable from outside"
        else
            ok "Port ${port} is listening"
        fi
    else
        fail "Nothing listens on port ${port}"
    fi
    echo ""
}

check_port_iptables() {
    local port="$1"

    echo "--- iptables for port ${port} ---"
    if iptables -C INPUT -p tcp -m state --state NEW -m tcp --dport "$port" -j ACCEPT 2>/dev/null; then
        ok "Live iptables: ACCEPT for port ${port}"
    elif iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
        ok "Live iptables: ACCEPT for port ${port} (no state match)"
    else
        fail "Live iptables: NO rule for port ${port}"
        echo "       Fix: sudo bash open-ports.sh ${port}"
    fi

    if [[ -f "$RULES_V4" ]]; then
        if grep -qE "^-A INPUT -p tcp .*--dport ${port}\b" "$RULES_V4"; then
            ok "rules.v4 contains INPUT ACCEPT for port ${port}"
        else
            fail "rules.v4 has NO rule for port ${port}"
            echo "       Fix: sudo bash open-ports.sh ${port}"
        fi
    else
        warn "File ${RULES_V4} not found (not Oracle Ubuntu image?)"
    fi
    echo ""
}

echo ""
echo "=== Port diagnostics: ${PORTS[*]} ==="
echo ""

for port in "${PORTS[@]}"; do
    check_port_listening "$port"
    check_port_iptables "$port"
done

echo "--- UFW ---"
if command -v ufw >/dev/null 2>&1; then
    ufw status 2>/dev/null | head -3
    if ufw status 2>/dev/null | grep -qiE '^Status:\s*active'; then
        fail "UFW is active - often blocks ports on Oracle. Run: sudo ufw disable"
    else
        ok "UFW is not active"
    fi
else
    ok "UFW is not installed"
fi
echo ""

echo "--- Proxy services ---"
for unit in caddy tproxy-server mtproxy; do
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
        ok "${unit}.service active"
    else
        fail "${unit}.service is not running"
    fi
done
echo ""

echo "--- Public IP ---"
PUB="$(curl -4 -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || echo "")"
[[ -n "$PUB" ]] && ok "Public IP: ${PUB}" || warn "Could not detect public IP"
echo ""

echo "=== Oracle Console (manual check) ==="
echo "- Security List -> Ingress: TCP ${PORTS[*]} from 0.0.0.0/0"
echo "- If VNIC has NSG - add rules there too"
echo "- Test: nmap -Pn ${PUB:-YOUR_IP} -p ${PORTS[0]}"
echo ""
