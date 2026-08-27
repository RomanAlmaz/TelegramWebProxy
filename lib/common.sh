#!/usr/bin/env bash
# Shared helpers for Telegram Web Proxy scripts.

set -Eeuo pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$_LIB_DIR/.." && pwd)"
TPROXY_REPO="$PROJECT_ROOT/tproxy-server"
SITE_SOURCE="$PROJECT_ROOT/site"
SITE_TARGET="/srv/tproxy-site"
MANIFEST="/etc/tproxy-webproxy-install.manifest"
INSTALLED_REPO="/opt/tproxy-server-source"
PROJECT_REPO_URL="https://github.com/RomanAlmaz/TelegramWebProxy.git"
PROJECT_REPO_NAME="TelegramWebProxy"
PROJECT_INSTALL_DIR="/root/${PROJECT_REPO_NAME}"
TPROXY_UPSTREAM_URL="https://github.com/telegramdesktop/tproxy-server.git"

VERSION="1.0"

clone_project_repo() {
    local target_dir="${1:-$PROJECT_INSTALL_DIR}"

    if [[ -d "$target_dir/.git" || -f "$target_dir/install-proxy.sh" ]]; then
        echo "      Project already exists at $target_dir"
        return 0
    fi

    command -v git >/dev/null 2>&1 || die "git is required to clone $PROJECT_REPO_URL"

    install -d -m 0755 "$(dirname "$target_dir")"
    git clone --depth 1 "$PROJECT_REPO_URL" "$target_dir"
}

die() {
    echo
    echo "ERROR: $*" >&2
    exit 1
}

info() {
    echo "$*"
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

valid_domain() {
    [[ "$1" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] &&
        [[ "$1" == *.* ]] &&
        [[ "$1" != *..* ]]
}

valid_email() {
    [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

valid_secret() {
    [[ "$1" =~ ^([0-9a-f]{32}|dd[0-9a-f]{32})$ ]]
}

require_root() {
    [[ $EUID -eq 0 ]] || die "Run this script as root."
}

require_ubuntu() {
    . /etc/os-release
    [[ "${ID:-}" == "ubuntu" ]] || die "Ubuntu is required."
    dpkg --compare-versions "${VERSION_ID:-0}" ge "22.04" ||
        die "Ubuntu 22.04 or newer is required."
}

require_x86_64() {
    [[ "$(uname -m)" == "x86_64" ]] || die "x86_64 is required."
}

require_local_repo() {
    [[ -d "$TPROXY_REPO" ]] || die "tproxy-server not found: $TPROXY_REPO"
    [[ -f "$TPROXY_REPO/cmd/tproxy-server/main.go" ]] ||
        die "Invalid tproxy-server source at $TPROXY_REPO"
}

ensure_tproxy_repo() {
    if [[ -f "$TPROXY_REPO/cmd/tproxy-server/main.go" ]]; then
        echo "      Using local tproxy-server source"
        return 0
    fi

    command -v git >/dev/null 2>&1 || die "git is required to download tproxy-server"

    echo "      Downloading official tproxy-server..."
    rm -rf "$TPROXY_REPO"
    git clone --depth 1 "$TPROXY_UPSTREAM_URL" "$TPROXY_REPO"

    [[ -f "$TPROXY_REPO/cmd/tproxy-server/main.go" ]] ||
        die "Failed to download tproxy-server from $TPROXY_UPSTREAM_URL"
}

require_local_site() {
    [[ -d "$SITE_SOURCE" ]] || die "site folder not found: $SITE_SOURCE"
    [[ -f "$SITE_SOURCE/index.html" ]] ||
        die "site/index.html not found."
}

port_is_listening() {
    local port="$1"
    ss -lnt | grep -Eq ":${port}\b"
}

port_has_expected_process() {
    local port="$1"
    local process="$2"
    ss -lntp 2>/dev/null |
        grep -Eq ":${port}\b.*users:\(\(\"${process}\""
}

check_install_port() {
    local port="$1"
    local process="$2"

    if ! port_is_listening "$port"; then
        echo "      :${port} free"
        return 0
    fi

    if port_has_expected_process "$port" "$process"; then
        echo "      :${port} already used by ${process}; continuing."
        return 0
    fi

    ss -lntp | grep -E ":${port}\b" || true
    die "Port ${port} is occupied by an unexpected process."
}

fix_mtproxy_permissions() {
    chmod 0755 /opt/MTProxy
    chmod 0755 /opt/MTProxy/objs
    chmod 0755 /opt/MTProxy/objs/bin
    chmod 0755 /opt/MTProxy/objs/bin/mtproto-proxy

    runuser -u mtproxy -- test -x /opt/MTProxy/objs/bin/mtproto-proxy ||
        die "mtproxy user cannot execute mtproto-proxy."
}

deploy_site_files() {
    local source_dir="${1:-$SITE_SOURCE}"
    local target_dir="${2:-$SITE_TARGET}"

    install -d -o root -g tproxy -m 0750 "$target_dir"
    rm -rf "${target_dir:?}/"*
    cp -a "$source_dir/." "$target_dir/"
    chown -R root:tproxy "$target_dir"
    find "$target_dir" -type d -exec chmod 0750 {} +
    find "$target_dir" -type f -exec chmod 0640 {} +

    runuser -u tproxy -- test -x "$target_dir" ||
        die "tproxy user cannot traverse public site."
    runuser -u tproxy -- test -r "$target_dir/index.html" ||
        die "tproxy user cannot read public site index.html."
}

read_manifest_value() {
    local key="$1"
    local default="${2:-}"
    local line

    if [[ ! -r "$MANIFEST" ]]; then
        printf '%s' "$default"
        return 0
    fi

    while IFS='=' read -r line; do
        [[ "$line" == "${key}="* ]] || continue
        printf '%s' "${line#*=}"
        return 0
    done < "$MANIFEST"

    printf '%s' "$default"
}

write_manifest() {
    local domain="$1"
    local email="$2"
    local reused_caddy="${3:-0}"
    local reused_mt="${4:-0}"
    local reused_relay="${5:-0}"

    cat > "$MANIFEST" <<EOF
installed_by=telegram-webproxy
version=$VERSION
project_root=$PROJECT_ROOT
domain=$domain
email=$email
reused_caddy=$reused_caddy
reused_mtproxy=$reused_mt
reused_relay=$reused_relay
EOF
    chmod 0600 "$MANIFEST"
}

stop_proxy_units() {
    for unit in \
        tproxy-firewall.service \
        refresh-mtproxy-config.timer \
        refresh-mtproxy-config.service \
        tproxy-server.service \
        mtproxy.service \
        caddy.service
    do
        systemctl stop "$unit" 2>/dev/null || true
    done
}

disable_proxy_units() {
    for unit in \
        tproxy-firewall.service \
        refresh-mtproxy-config.timer \
        refresh-mtproxy-config.service \
        tproxy-server.service \
        mtproxy.service \
        caddy.service
    do
        systemctl disable "$unit" 2>/dev/null || true
    done
}

remove_proxy_service_files() {
    rm -f \
        /etc/systemd/system/tproxy-firewall.service \
        /etc/systemd/system/refresh-mtproxy-config.service \
        /etc/systemd/system/refresh-mtproxy-config.timer \
        /etc/systemd/system/tproxy-server.service \
        /etc/systemd/system/mtproxy.service \
        /etc/systemd/system/caddy.service \
        /etc/systemd/system/caddy.service.d/tproxy.conf \
        /usr/local/sbin/refresh-mtproxy-config
}

remove_proxy_data() {
    rm -rf \
        "$INSTALLED_REPO" \
        /opt/tproxy-site \
        /srv/tproxy-site \
        /etc/tproxy-server \
        /etc/caddy/caddy \
        /usr/local/bin/tproxy-server \
        /opt/MTProxy \
        /etc/mtproxy

    rm -rf /opt/go1.26.5 /opt/go1.26.4 /opt/go1.26.3 2>/dev/null || true
}

remove_proxy_users() {
    for user in tproxy mtproxy caddy; do
        if id "$user" >/dev/null 2>&1; then
            userdel "$user" 2>/dev/null || true
        fi
    done
}

remove_proxy_firewall() {
    nft delete table inet tproxy_backend 2>/dev/null || true
}

get_domain_from_config() {
    if [[ -r /etc/systemd/system/caddy.service.d/tproxy.conf ]]; then
        sed -n 's/^Environment=TPROXY_HOSTNAME=//p' \
            /etc/systemd/system/caddy.service.d/tproxy.conf | head -n1
        return 0
    fi

    if [[ -r /etc/tproxy-server/config.json ]]; then
        sed -n 's/.*"public_hostname"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
            /etc/tproxy-server/config.json | head -n1
        return 0
    fi

    read_manifest_value domain
}

get_secret_from_profiles() {
    if [[ ! -r /etc/tproxy-server/profiles.json ]]; then
        return 1
    fi

    sed -n 's/.*"secret"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        /etc/tproxy-server/profiles.json | head -n1
}

mask_secret() {
    local secret="$1"
    local len="${#secret}"

    if (( len <= 8 )); then
        printf '%s' "********"
        return 0
    fi

    printf '%s...%s' "${secret:0:4}" "${secret: -4}"
}

show_failure() {
    echo
    echo "============================================================"
    echo "                    INSTALLATION FAILED"
    echo "============================================================"
    echo
    echo "--- services ---"
    systemctl --no-pager --full status mtproxy tproxy-server caddy tproxy-firewall 2>/dev/null || true
    echo
    echo "--- MTProxy log ---"
    journalctl -u mtproxy -n 40 --no-pager 2>/dev/null || true
    echo
    echo "--- relay log ---"
    journalctl -u tproxy-server -n 40 --no-pager 2>/dev/null || true
    echo
    echo "--- site permissions ---"
    namei -l "$SITE_TARGET/index.html" 2>/dev/null || true
    echo
    echo "--- MTProxy permissions ---"
    namei -l /opt/MTProxy/objs/bin/mtproto-proxy 2>/dev/null || true
}
