#!/usr/bin/env bash
# Oracle Cloud / Ubuntu: open inbound TCP ports in iptables.
# Security List in Oracle Console is not enough on many Ubuntu images.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

require_root

if [[ "$#" -gt 0 ]]; then
    PORTS=("$@")
elif [[ -n "${PORTS:-}" ]]; then
    read -ra PORTS <<< "$PORTS"
else
    PORTS=(80 443)
fi

RULES_V4="/etc/iptables/rules.v4"
IPTABLES_CHAIN="INPUT"

port_rule_exists_in_file() {
    local port="$1"
    [[ -f "$RULES_V4" ]] && grep -qE "^-A INPUT -p tcp .*--dport ${port}\b" "$RULES_V4"
}

port_rule_exists_live() {
    local port="$1"
    iptables -C "$IPTABLES_CHAIN" -p tcp -m state --state NEW -m tcp --dport "$port" -j ACCEPT 2>/dev/null
}

add_rule_to_rules_v4() {
    local port="$1"
    [[ -f "$RULES_V4" ]] || return 1

    if port_rule_exists_in_file "$port"; then
        info "rules.v4: port ${port} already open"
        return 0
    fi

    local new_rule="-A INPUT -p tcp -m state --state NEW -m tcp --dport ${port} -j ACCEPT"
    local tmp
    tmp="$(mktemp)"

    awk -v rule="$new_rule" '
        /^-A INPUT -j REJECT/ && !done {
            print rule
            done=1
        }
        { print }
    ' "$RULES_V4" > "$tmp"

    if ! grep -q "dport ${port}" "$tmp"; then
        awk -v rule="$new_rule" '
            /^COMMIT/ && !done {
                print rule
                done=1
            }
            { print }
        ' "$RULES_V4" > "$tmp"
    fi

    cp "$RULES_V4" "${RULES_V4}.bak.$(date +%Y%m%d%H%M%S)"
    mv "$tmp" "$RULES_V4"
    info "rules.v4: added rule for port ${port}"
}

add_rule_live() {
    local port="$1"

    if port_rule_exists_live "$port"; then
        info "iptables (live): port ${port} already open"
        return 0
    fi

    if iptables -I "$IPTABLES_CHAIN" 6 -p tcp -m state --state NEW -m tcp --dport "$port" -j ACCEPT 2>/dev/null; then
        info "iptables (live): port ${port} opened (INSERT pos 6)"
    else
        iptables -I "$IPTABLES_CHAIN" -p tcp --dport "$port" -j ACCEPT
        info "iptables (live): port ${port} opened (INSERT head)"
    fi
}

apply_and_persist() {
    if [[ -f "$RULES_V4" ]]; then
        info "Applying rules.v4..."
        iptables-restore < "$RULES_V4" || warn "iptables-restore failed - check ${RULES_V4}"
    fi

    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 && info "Saved via netfilter-persistent"
    elif [[ -f "$RULES_V4" ]]; then
        cp "$RULES_V4" /etc/iptables/rules.v4 2>/dev/null || true
        info "rules.v4 updated (netfilter-persistent not installed)"
    fi
}

install_persistent_if_missing() {
    if command -v netfilter-persistent >/dev/null 2>&1; then
        return 0
    fi
    if [[ -f /etc/debian_version ]]; then
        info "Installing iptables-persistent..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq iptables-persistent
    fi
}

disable_ufw_if_active() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "active"; then
        warn "UFW is active - disabling on Oracle Ubuntu..."
        ufw disable || true
    fi
}

show_oracle_checklist() {
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  Also check Oracle Cloud Console${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""
    echo "1. Instance -> Subnet -> Security Lists -> Ingress Rules"
    echo "   TCP, ports: ${PORTS[*]}, Source: 0.0.0.0/0"
    echo ""
    echo "2. Instance -> Attached VNIC -> Network Security Groups"
    echo "   If NSG is attached, add the same rule there too"
    echo ""
    echo "3. Test from outside: nmap -Pn YOUR_IP -p ${PORTS[0]}"
    echo ""
    echo "4. On server: ss -tlnp | grep -E '${PORTS[*]// /|}'"
    echo "   Should show 0.0.0.0:PORT, not 127.0.0.1"
    echo ""
}

main() {
    echo ""
    info "Opening iptables ports: ${PORTS[*]}"
    echo ""

    command -v iptables >/dev/null 2>&1 || error "iptables not found"

    disable_ufw_if_active
    install_persistent_if_missing

    for port in "${PORTS[@]}"; do
        [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || error "Invalid port: $port"
        add_rule_to_rules_v4 "$port"
        add_rule_live "$port"
    done

    apply_and_persist

    echo ""
    info "Current INPUT rules:"
    iptables -L "$IPTABLES_CHAIN" -n --line-numbers | head -20
    echo ""

    if [[ -f "$RULES_V4" ]]; then
        info "Fragment of ${RULES_V4}:"
        grep -E "dport (22|${PORTS[*]// /|})|REJECT" "$RULES_V4" || true
    fi

    show_oracle_checklist
    info "Done. Test the site in 1-2 minutes."
}

main "$@"
