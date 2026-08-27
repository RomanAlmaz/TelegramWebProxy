#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root

KEEP_LOGIN_USERS=(root)

add_keep_login_user() {
    local user="$1"
    local existing

    [[ -n "$user" ]] || return 0
    [[ "$user" == "root" ]] && return 0

    for existing in "${KEEP_LOGIN_USERS[@]}"; do
        [[ "$existing" == "$user" ]] && return 0
    done

    KEEP_LOGIN_USERS+=("$user")
}

is_kept_login_user() {
    local user="$1"
    local kept

    for kept in "${KEEP_LOGIN_USERS[@]}"; do
        [[ "$kept" == "$user" ]] && return 0
    done

    return 1
}

init_keep_login_users() {
    add_keep_login_user "${SUDO_USER:-}"
    add_keep_login_user "$(logname 2>/dev/null || true)"
    add_keep_login_user "$(who am i 2>/dev/null | awk '{print $1}' || true)"
}

KEEP_PACKAGES=(
    openssh-server
    openssh-client
    openssh-sftp-server
    cloud-init
    cloud-guest-utils
    cloud-initramfs-copymods
    cloud-initramfs-dyn-netconf
    cloud-initramfs-growroot
    ubuntu-minimal
    ubuntu-standard
    systemd
    systemd-sysv
    sudo
    bash
    apt
    dpkg
    ca-certificates
    curl
    wget
    nano
    vim
    vim-tiny
    netplan.io
    iproute2
    netbase
    rsyslog
    cron
    dbus
    login
    passwd
    util-linux
    grep
    sed
    gzip
    tar
    mount
    hostname
    procps
    kmod
    initramfs-tools
    grub-pc
    grub-common
    grub2-common
    locales
    tzdata
    console-setup
    keyboard-configuration
    udev
    ufw
    unattended-upgrades
    needrestart
)

stop_and_disable() {
    local unit="$1"
    systemctl stop "$unit" 2>/dev/null || true
    systemctl disable "$unit" 2>/dev/null || true
}

is_keep_package() {
    local pkg="$1"
    local keep

    for keep in "${KEEP_PACKAGES[@]}"; do
        [[ "$pkg" == "$keep" ]] && return 0
    done

    [[ "$pkg" == linux-image-* ]] && return 0
    [[ "$pkg" == linux-headers-* ]] && return 0
    [[ "$pkg" == linux-modules-* ]] && return 0
    [[ "$pkg" == linux-modules-extra-* ]] && return 0
    [[ "$pkg" == linux-generic* ]] && return 0
    [[ "$pkg" == linux-image-virtual ]] && return 0
    [[ "$pkg" == linux-virtual ]] && return 0

    return 1
}

remove_custom_systemd_units() {
    local path base

    find /etc/systemd/system -maxdepth 1 -type f \
        \( -name '*.service' -o -name '*.timer' -o -name '*.socket' -o -name '*.target' \) \
        -print0 | while IFS= read -r -d '' path; do
            base="$(basename "$path")"
            systemctl stop "$base" 2>/dev/null || true
            systemctl disable "$base" 2>/dev/null || true
            rm -f "$path"
        done

    find /etc/systemd/system -mindepth 1 -maxdepth 1 -type d -print0 | while IFS= read -r -d '' path; do
        rm -rf "$path"
    done
}

remove_extra_users() {
    local user uid home shell

    while IFS=: read -r user _ uid _ _ home shell; do
        [[ "$uid" -ge 1000 ]] || continue
        [[ "$user" == "nobody" ]] && continue
        is_kept_login_user "$user" && {
            echo "      сохраняем пользователя $user"
            continue
        }

        echo "      удаляем пользователя $user"
        userdel -r -f "$user" 2>/dev/null || userdel -f "$user" 2>/dev/null || true
        rm -rf "$home" 2>/dev/null || true
    done < /etc/passwd

    for user in tproxy mtproxy caddy www-data nginx; do
        id "$user" >/dev/null 2>&1 || continue
        userdel -f "$user" 2>/dev/null || true
    done
}

clean_home_directories() {
    local entry owner

    for entry in /home/* /home/.[!.]* /home/..?*; do
        [[ -e "$entry" ]] || continue
        owner="$(stat -c '%U' "$entry" 2>/dev/null || true)"
        if [[ -n "$owner" ]] && is_kept_login_user "$owner"; then
            echo "      сохраняем домашний каталог $entry"
            continue
        fi
        rm -rf "$entry" 2>/dev/null || true
    done

    mkdir -p /home
    chmod 755 /home
}

reset_package_state() {
    local pkg

    echo "      помечаем необязательные пакеты как auto-installed..."
    while read -r pkg; do
        [[ -n "$pkg" ]] || continue
        is_keep_package "$pkg" && continue
        apt-mark auto "$pkg" 2>/dev/null || true
    done < <(dpkg-query -W -f='${Package}\n' 2>/dev/null || true)

    echo "      сохраняем essential-пакеты как manual..."
    for pkg in "${KEEP_PACKAGES[@]}"; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
            apt-mark manual "$pkg" 2>/dev/null || true
        fi
    done

    while read -r pkg; do
        apt-mark manual "$pkg" 2>/dev/null || true
    done < <(dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -E '^linux-(image|headers|modules)' || true)

    echo "      удаляем auto-installed пакеты..."
    apt-get autoremove --purge -y || true
    apt-get autoclean -y || true
    apt-get clean -y || true
}

echo "============================================================"
echo "          ПОЛНЫЙ СБРОС VPS (FACTORY RESET)"
echo "============================================================"
echo
echo "ВНИМАНИЕ: этот скрипт полностью очищает VPS."
echo "После завершения сервер будет максимально близок к чистой Ubuntu."
echo
echo "Будет УДАЛЕНО:"
echo "  - Telegram Web Proxy и весь другой установленный софт"
echo "  - docker, nginx, apache, node, python, базы данных и т.д."
echo "  - все apt-пакеты, установленные вручную (кроме SSH и базовой системы)"
echo "  - все custom systemd-сервисы"
echo "  - все пользователи кроме root и текущего пользователя входа"
echo "  - все файлы в /root (кроме .ssh), другие /home, /opt, /srv, /var/www"
echo "  - все бинарники в /usr/local"
echo "  - правила firewall, cron, логи, temp, файлы проекта"
echo "  - snap-пакеты"
echo
echo "Будет СОХРАНЕНО:"
echo "  - базовая система Ubuntu"
echo "  - SSH и сетевые настройки"
echo "  - cloud-init (для облачных VPS)"
echo "  - текущий пользователь и его домашний каталог (включая .ssh)"
echo
echo "Введите hostname сервера для подтверждения:"
read -r CONFIRM_HOST
CURRENT_HOST="$(hostname)"
[[ "$CONFIRM_HOST" == "$CURRENT_HOST" ]] || { echo "Отменено."; exit 0; }
echo
echo "Введите FACTORY-RESET для продолжения:"
read -r CONFIRM
[[ "$CONFIRM" == "FACTORY-RESET" ]] || { echo "Отменено."; exit 0; }

init_keep_login_users
echo
echo "Сохраняем пользователей: ${KEEP_LOGIN_USERS[*]}"

PROJECT_TO_REMOVE="$PROJECT_ROOT"
if [[ -r "$MANIFEST" ]]; then
    saved_root="$(read_manifest_value project_root "")"
    [[ -n "$saved_root" && -d "$saved_root" ]] && PROJECT_TO_REMOVE="$saved_root"
fi

export DEBIAN_FRONTEND=noninteractive

echo
echo "[1/18] Остановка сервисов прокси..."
stop_proxy_units

echo "[2/18] Остановка типовых сервисов..."
for unit in \
    nginx.service apache2.service httpd.service \
    docker.service docker.socket containerd.service \
    fail2ban.service ufw.service \
    snapd.service snapd.socket
do
    stop_and_disable "$unit"
done

echo "[3/18] Остановка docker-контейнеров..."
if command -v docker >/dev/null 2>&1; then
    docker ps -aq 2>/dev/null | xargs -r docker stop 2>/dev/null || true
    docker ps -aq 2>/dev/null | xargs -r docker rm -f 2>/dev/null || true
    docker system prune -af --volumes 2>/dev/null || true
fi

echo "[4/18] Удаление custom systemd unit-ов..."
remove_custom_systemd_units
disable_proxy_units
remove_proxy_service_files

echo "[5/18] Удаление данных и бинарников прокси..."
remove_proxy_data
rm -f \
    /usr/local/bin/caddy \
    /usr/local/bin/tproxy-server \
    /usr/local/bin/tproxy-server.previous \
    /usr/local/bin/tproxy-server.next \
    /usr/local/sbin/refresh-mtproxy-config

echo "[6/18] Очистка /usr/local..."
find /usr/local -mindepth 1 -maxdepth 1 ! -name 'share' -exec rm -rf {} + 2>/dev/null || true
rm -rf /usr/local/go /usr/local/bin/* /usr/local/sbin/* 2>/dev/null || true

echo "[7/18] Удаление web, app и data каталогов..."
rm -rf \
    /etc/caddy \
    /etc/nginx \
    /etc/apache2 \
    /etc/mtproxy \
    /etc/tproxy-server \
    /var/lib/caddy \
    /var/lib/docker \
    /var/lib/containerd \
    /var/www \
    /srv \
    /opt/go* \
    /opt/MTProxy* \
    /opt/tproxy-site \
    /opt/tproxy-server-source \
    /opt/containerd \
    /root/tproxy-server \
    /root/install-webproxy.sh \
    "$PROJECT_INSTALL_DIR" \
    "$MANIFEST" \
    /run/lock/tproxy-server-update.lock

echo "[8/18] Удаление лишних пользователей..."
remove_extra_users

echo "[9/18] Очистка /root и /home..."
find /root -mindepth 1 -maxdepth 1 ! -name '.ssh' -exec rm -rf {} + 2>/dev/null || true
clean_home_directories

echo "[10/18] Сброс firewall..."
remove_proxy_firewall
nft flush ruleset 2>/dev/null || true
iptables -F 2>/dev/null || true
iptables -X 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -t nat -X 2>/dev/null || true
iptables -t mangle -F 2>/dev/null || true
iptables -t mangle -X 2>/dev/null || true
ip6tables -F 2>/dev/null || true
ip6tables -X 2>/dev/null || true
ufw --force reset 2>/dev/null || true

echo "[11/18] Удаление cron-задач..."
rm -f /etc/cron.d/* /var/spool/cron/crontabs/* 2>/dev/null || true
find /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly -mindepth 1 -delete 2>/dev/null || true

echo "[12/18] Удаление snap-пакетов..."
if command -v snap >/dev/null 2>&1; then
    snap list 2>/dev/null | awk 'NR>1 {print $1}' | while read -r snap_pkg; do
        [[ -n "$snap_pkg" ]] || continue
        snap remove --purge "$snap_pkg" 2>/dev/null || true
    done
fi

echo "[13/18] Сброс состояния apt-пакетов..."
apt-get update || true
reset_package_state

echo "[14/18] Очистка temp и cache..."
rm -rf \
    /tmp/* \
    /var/tmp/* \
    /var/cache/apt/archives/*.deb \
    /root/.cache/* 2>/dev/null || true

echo "[15/18] Очистка логов..."
journalctl --rotate 2>/dev/null || true
journalctl --vacuum-time=1s 2>/dev/null || true
find /var/log -type f -name '*.log' -exec truncate -s 0 {} + 2>/dev/null || true
find /var/log -type f -name '*.gz' -delete 2>/dev/null || true
find /var/log -type f -name '*.1' -delete 2>/dev/null || true
: > /root/.bash_history 2>/dev/null || true
history -c 2>/dev/null || true

echo "[16/18] Перезагрузка systemd..."
systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true

echo "[17/18] Удаление файлов проекта..."
if [[ -d "$PROJECT_TO_REMOVE" ]]; then
    echo "      Удаляем $PROJECT_TO_REMOVE"
    rm -rf "$PROJECT_TO_REMOVE"
fi

echo "[18/18] Финальная проверка..."
echo
echo "Активные слушатели:"
ss -lntp 2>/dev/null | grep -v '127.0.0.1:22' || echo "  только SSH (ожидаемо)"

echo
echo "Оставшиеся custom systemd unit-ы:"
find /etc/systemd/system -maxdepth 1 -type f 2>/dev/null | head -n 20 || echo "  нет"

echo
echo "Использование диска:"
df -h / /var /home 2>/dev/null || true

echo
echo "============================================================"
echo "          СБРОС VPS ЗАВЕРШЁН"
echo "============================================================"
echo
echo "Сервер очищен и готов к новой установке."
echo "Снова клонируйте проект и запустите install-proxy.sh:"
echo "  git clone ${PROJECT_REPO_URL}"
echo "  cd ${PROJECT_REPO_NAME} && chmod +x *.sh && sudo bash install-proxy.sh"
echo
echo "Настоятельно рекомендуется перезагрузка:"
echo "  reboot"
echo "============================================================"
