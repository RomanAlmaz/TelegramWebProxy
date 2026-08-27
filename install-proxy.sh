#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

REUSE_MT=0
REUSE_RELAY=0
REUSE_CADDY=0
REUSE_EXISTING_HTTPS=0

on_error() {
    local code=$?
    trap - ERR
    show_failure
    exit "$code"
}
trap on_error ERR

clear 2>/dev/null || true

cat <<EOF
============================================================
   УСТАНОВЩИК TELEGRAM WEB PROXY v${VERSION}
============================================================

Репозиторий: ${PROJECT_REPO_URL}
Корень проекта: ${PROJECT_ROOT}
============================================================
EOF

require_root
require_x86_64
require_ubuntu
require_local_site

while true; do
    echo
    read -r -p "Домен (пример: proxy.example.com): " DOMAIN
    DOMAIN="$(trim "$DOMAIN")"
    DOMAIN="${DOMAIN,,}"
    valid_domain "$DOMAIN" && break
    echo "Некорректный домен. Пример: proxy.example.com"
done

while true; do
    echo
    read -r -p "Email для ACME/Let's Encrypt (пример: admin@example.com): " EMAIL
    EMAIL="$(trim "$EMAIL")"
    valid_email "$EMAIL" && break
    echo "Некорректный email. Пример: admin@example.com"
done

echo
read -r -p "Сгенерировать secret автоматически? [Y/n]: " MODE
MODE="$(trim "${MODE:-Y}")"

if [[ -z "$MODE" || "$MODE" =~ ^[Yy]$ ]]; then
    command -v openssl >/dev/null 2>&1 || {
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends openssl
    }
    SECRET="$(openssl rand -hex 16)"
else
    while true; do
        echo
        read -r -s -p "Secret Web Proxy (32 hex-символа, опционально dd + 32 hex): " SECRET
        echo
        valid_secret "$SECRET" && break
        echo "Некорректный secret."
    done
fi

valid_secret "$SECRET" || die "Некорректный secret."

echo
echo "[1/10] Проверка системы..."
echo "      Ubuntu ${VERSION_ID} / x86_64"

echo
echo "[2/10] Установка зависимостей..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates curl git openssl dnsutils nftables \
    build-essential libssl-dev util-linux zlib1g-dev
echo "      OK"

echo
echo "[+] Открытие портов firewall (Oracle Cloud)..."
bash "$SCRIPT_DIR/oracle-ports/open-ports.sh" 80 443

echo
echo "[3/10] Проверка портов..."
check_install_port 80 caddy
check_install_port 443 caddy
check_install_port 2398 mtproto-proxy
check_install_port 8080 tproxy-server
check_install_port 8081 tproxy-server

EXISTING_CADDY_CONF="/etc/systemd/system/caddy.service.d/tproxy.conf"
EXISTING_DOMAIN=""
EXISTING_EMAIL=""

if [[ -f "$EXISTING_CADDY_CONF" ]]; then
    EXISTING_DOMAIN="$(sed -n 's/^Environment=TPROXY_HOSTNAME=//p' "$EXISTING_CADDY_CONF" | head -n1)"
    EXISTING_EMAIL="$(sed -n 's/^Environment=ACME_EMAIL=//p' "$EXISTING_CADDY_CONF" | head -n1)"

    if [[ -n "$EXISTING_DOMAIN" && "$EXISTING_DOMAIN" != "$DOMAIN" ]]; then
        die "Уже установлен Web Proxy с доменом ${EXISTING_DOMAIN}. Используйте этот домен или сначала выполните uninstall-proxy.sh."
    fi

    if [[ -n "$EXISTING_DOMAIN" ]] &&
        curl -fsSI --max-time 10 "https://${EXISTING_DOMAIN}/" >/dev/null 2>&1; then
        REUSE_EXISTING_HTTPS=1
        REUSE_CADDY=1
        DOMAIN="$EXISTING_DOMAIN"
        [[ -n "$EXISTING_EMAIL" ]] && EMAIL="$EXISTING_EMAIL"
        echo "      HTTPS уже работает; сертификат и конфигурация будут переиспользованы."
    fi
fi

echo
echo "[4/10] Проверка DNS..."
if [[ "$REUSE_EXISTING_HTTPS" == "1" ]]; then
    DNS_IP="$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}')"
    [[ -n "$DNS_IP" ]] || die "HTTPS работает, но DNS-запрос для $DOMAIN не удался."
    echo "      HTTPS проверен: $DOMAIN -> $DNS_IP"
else
    DNS_IP="$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}')"
    [[ -n "$DNS_IP" ]] || die "Не найдена IPv4 A-запись для $DOMAIN."

    VPS_IP="$(curl -4fsS --max-time 10 https://api.ipify.org || true)"
    if [[ -n "$VPS_IP" && "$DNS_IP" != "$VPS_IP" ]]; then
        echo "      DNS: $DNS_IP"
        echo "      VPS: $VPS_IP"
        die "DNS не указывает на этот VPS."
    fi
    echo "      $DOMAIN -> $DNS_IP"
fi

echo
echo "[5/10] Подготовка исходников..."
ensure_tproxy_repo
rm -rf "$INSTALLED_REPO"
install -d -m 0755 "$INSTALLED_REPO"
cp -a "$TPROXY_REPO/." "$INSTALLED_REPO/"
echo "      Исходники скопированы в $INSTALLED_REPO"

echo
echo "[6/10] Установка компонентов Telegram Web Proxy..."

if [[ -x /opt/MTProxy/objs/bin/mtproto-proxy ]] &&
    systemctl list-unit-files mtproxy.service >/dev/null 2>&1 &&
    port_has_expected_process 2398 mtproto-proxy; then
    REUSE_MT=1
    echo "      Найден MTProxy; переиспользуем."
fi

if [[ -x /usr/local/bin/tproxy-server ]] &&
    systemctl list-unit-files tproxy-server.service >/dev/null 2>&1 &&
    port_has_expected_process 8080 tproxy-server &&
    port_has_expected_process 8081 tproxy-server; then
    REUSE_RELAY=1
    echo "      Найден tproxy-server; переиспользуем."
fi

if [[ -x /usr/local/bin/caddy ]] &&
    systemctl list-unit-files caddy.service >/dev/null 2>&1 &&
    port_has_expected_process 80 caddy &&
    port_has_expected_process 443 caddy; then
    REUSE_CADDY=1
    echo "      Найден Caddy; переиспользуем."
fi

if [[ "$REUSE_CADDY" == "1" ]]; then
    echo "      Caddy уже установлен; переиспользуем."
else
    echo "      Установка Caddy..."
    caddy_version="2.11.4"
    caddy_sha512="8220d1f013b6f27510247b2360c9e0ca9f018feebd82515f07635318b34ff9777ccc8fd0b6e6f2486ce3a33fe389fbb7db12d05baa474f4587509fb4f5ebf1c9"

    caddy_archive="$(mktemp /tmp/caddy-linux-amd64.XXXXXX.tar.gz)"
    caddy_directory="$(mktemp -d /tmp/caddy-linux-amd64.XXXXXX)"

    curl --fail --silent --show-error --location \
        --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --output "$caddy_archive" \
        "https://github.com/caddyserver/caddy/releases/download/v${caddy_version}/caddy_${caddy_version}_linux_amd64.tar.gz"

    test "$(sha512sum "$caddy_archive" | awk '{print $1}')" = "$caddy_sha512" ||
        die "Проверка контрольной суммы Caddy не прошла."

    tar -C "$caddy_directory" -xzf "$caddy_archive"
    install -m 0755 "$caddy_directory/caddy" /usr/local/bin/caddy
    rm -f "$caddy_archive"
    rm -rf "$caddy_directory"

    if ! id caddy >/dev/null 2>&1; then
        useradd --system --home /var/lib/caddy --shell /usr/sbin/nologin caddy
    fi
    install -d -o root -g caddy -m 0750 /etc/caddy
    install -d -o caddy -g caddy -m 0750 /var/lib/caddy
fi

echo "      Установка официального MTProxy..."
if [[ "$REUSE_MT" != "1" ]]; then
    "$INSTALLED_REPO/deploy/install-mtproxy.sh"
else
    echo "      Установка MTProxy пропущена; уже слушает :2398."
fi

if ! id tproxy >/dev/null 2>&1; then
    useradd --system --home /nonexistent --shell /usr/sbin/nologin tproxy
fi

echo "      Установка Go relay..."
go_version="1.26.5"
go_sha256="5c2c3b16caefa1d968a94c1daca04a7ca301a496d9b086e17ad77bb81393f053"

if [[ -x "/opt/go${go_version}/bin/go" ]]; then
    go_binary="/opt/go${go_version}/bin/go"
else
    go_archive="$(mktemp /tmp/go-linux-amd64.XXXXXX.tar.gz)"
    go_directory="$(mktemp -d /tmp/go-linux-amd64.XXXXXX)"

    curl --fail --silent --show-error --location \
        --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --output "$go_archive" \
        "https://go.dev/dl/go${go_version}.linux-amd64.tar.gz"

    test "$(sha256sum "$go_archive" | awk '{print $1}')" = "$go_sha256" ||
        die "Проверка контрольной суммы Go не прошла."

    tar -C "$go_directory" -xzf "$go_archive"
    mv "$go_directory/go" "/opt/go${go_version}"
    rm -f "$go_archive"
    rm -rf "$go_directory"
    go_binary="/opt/go${go_version}/bin/go"
fi

if [[ "$REUSE_RELAY" == "1" ]]; then
    echo "      tproxy-server уже активен; переиспользуем."
else
    echo "      Сборка relay..."
    (
        cd "$INSTALLED_REPO"
        "$go_binary" build -trimpath -ldflags='-s -w' \
            -o /usr/local/bin/tproxy-server ./cmd/tproxy-server
    )
    chown root:root /usr/local/bin/tproxy-server
    chmod 0755 /usr/local/bin/tproxy-server
fi

echo "      Деплой публичного сайта из ${SITE_SOURCE}..."
deploy_site_files "$SITE_SOURCE" "$SITE_TARGET"

echo "      Подготовка конфигурации..."
install -d -o root -g tproxy -m 0750 /etc/tproxy-server

cat > /etc/tproxy-server/config.json <<EOF
{
  "public_hostname": "$DOMAIN",
  "listen": "127.0.0.1:8080",
  "admin_listen": "127.0.0.1:8081",
  "public_dir": "/srv/tproxy-site",
  "profiles_file": "/run/credentials/tproxy-server.service/profiles.json"
}
EOF

cat > /etc/tproxy-server/profiles.json <<EOF
{"profiles":[{"name":"default","secret":"$SECRET","backend":"127.0.0.1:2398"}]}
EOF

chown root:tproxy /etc/tproxy-server/config.json /etc/tproxy-server/profiles.json
chmod 0640 /etc/tproxy-server/config.json
chmod 0400 /etc/tproxy-server/profiles.json

backend_secret="$SECRET"
if [[ "$backend_secret" == dd* ]] && [[ ${#backend_secret} -eq 34 ]]; then
    backend_secret="${backend_secret:2}"
fi

cat > /etc/mtproxy/mtproxy.env <<EOF
MTPROXY_SECRET=$backend_secret
MTPROXY_WORKERS=1
MTPROXY_MAX_CONNECTIONS=4096
EOF

chown root:mtproxy /etc/mtproxy/mtproxy.env
chmod 0640 /etc/mtproxy/mtproxy.env

echo "      Установка unit-файлов systemd..."
if [[ "$REUSE_CADDY" != "1" ]]; then
    install -m 0644 "$INSTALLED_REPO/deploy/Caddyfile" /etc/caddy/Caddyfile
    install -m 0644 "$INSTALLED_REPO/deploy/caddy.service" /etc/systemd/system/caddy.service
else
    echo "      Сохраняем существующие Caddyfile и сервис Caddy."
fi

install -d -m 0755 /etc/systemd/system/caddy.service.d
if [[ "$REUSE_EXISTING_HTTPS" == "1" ]]; then
    echo "      Сохраняем рабочую конфигурацию Caddy."
else
    cat > /etc/systemd/system/caddy.service.d/tproxy.conf <<EOF
[Service]
Environment=TPROXY_HOSTNAME=$DOMAIN
Environment=TPROXY_SITE_ROOT=/srv/tproxy-site
Environment=ACME_EMAIL=$EMAIL
ReadWritePaths=/etc/caddy
EOF
fi

install -d -o caddy -g caddy -m 0750 /etc/caddy/caddy

install -m 0644 "$INSTALLED_REPO/deploy/tproxy-server.service" /etc/systemd/system/tproxy-server.service
install -m 0644 "$INSTALLED_REPO/deploy/mtproxy.service" /etc/systemd/system/mtproxy.service
install -m 0644 "$INSTALLED_REPO/deploy/tproxy-firewall.service" /etc/systemd/system/tproxy-firewall.service
install -m 0644 "$INSTALLED_REPO/deploy/refresh-mtproxy-config.service" /etc/systemd/system/refresh-mtproxy-config.service
install -m 0644 "$INSTALLED_REPO/deploy/refresh-mtproxy-config.timer" /etc/systemd/system/refresh-mtproxy-config.timer
install -m 0644 "$INSTALLED_REPO/deploy/firewall.nft" /etc/tproxy-server/firewall.nft
install -m 0755 "$INSTALLED_REPO/deploy/refresh-mtproxy-config.sh" /usr/local/sbin/refresh-mtproxy-config

echo "      Предварительная проверка..."
fix_mtproxy_permissions
runuser -u tproxy -- test -r "$SITE_TARGET/index.html" ||
    die "Пользователь tproxy не может прочитать публичный сайт."

/usr/local/bin/tproxy-server \
    -config /etc/tproxy-server/config.json \
    -profiles-file /etc/tproxy-server/profiles.json \
    -check

TPROXY_HOSTNAME="$DOMAIN" \
TPROXY_SITE_ROOT=/srv/tproxy-site \
ACME_EMAIL="$EMAIL" \
/usr/local/bin/caddy validate \
    --config /etc/caddy/Caddyfile \
    --adapter caddyfile

systemctl daemon-reload

echo "      Запуск firewall..."
systemctl enable --now tproxy-firewall.service

echo "      Запуск MTProxy..."
fix_mtproxy_permissions
systemctl enable mtproxy.service
systemctl reset-failed mtproxy.service 2>/dev/null || true
systemctl restart mtproxy.service

MT_READY=0
for _ in $(seq 1 20); do
    if systemctl is-active --quiet mtproxy &&
        ss -lnt | grep -Eq ':(2398)\b'; then
        MT_READY=1
        break
    fi
    sleep 1
done
[[ "$MT_READY" == "1" ]] || die "MTProxy не запустился на порту 2398."
echo "      MTProxy :2398 OK"

echo "      Запуск relay..."
runuser -u tproxy -- test -r "$SITE_TARGET/index.html" ||
    die "Пользователь tproxy не может прочитать сайт перед запуском relay."

systemctl enable tproxy-server.service
systemctl reset-failed tproxy-server.service 2>/dev/null || true
systemctl restart tproxy-server.service

RELAY_READY=0
for _ in $(seq 1 30); do
    if systemctl is-active --quiet tproxy-server &&
        curl -fsS --max-time 2 http://127.0.0.1:8081/readyz >/dev/null 2>&1; then
        RELAY_READY=1
        break
    fi
    sleep 1
done

if [[ "$RELAY_READY" != "1" ]]; then
    echo "      Relay не готов; автоматическое восстановление..."
    fix_mtproxy_permissions
    chown -R root:tproxy "$SITE_TARGET"
    find "$SITE_TARGET" -type d -exec chmod 0750 {} +
    find "$SITE_TARGET" -type f -exec chmod 0640 {} +
    systemctl reset-failed mtproxy tproxy-server 2>/dev/null || true
    systemctl restart mtproxy.service
    sleep 2
    systemctl restart tproxy-server.service

    for _ in $(seq 1 20); do
        if systemctl is-active --quiet tproxy-server &&
            curl -fsS --max-time 2 http://127.0.0.1:8081/readyz >/dev/null 2>&1; then
            RELAY_READY=1
            break
        fi
        sleep 1
    done
fi

[[ "$RELAY_READY" == "1" ]] || die "tproxy-server не перешёл в состояние ready."
echo "      Relay /readyz OK"

echo "      Запуск таймера обновления MTProxy..."
systemctl enable --now refresh-mtproxy-config.timer

echo "      Запуск Caddy..."
systemctl enable caddy.service
systemctl restart caddy.service

echo
echo "[9/10] Проверка работоспособности..."
curl -fsS --max-time 5 http://127.0.0.1:8081/healthz >/dev/null ||
    die "Проверка healthz tproxy-server не прошла."

echo "      healthz OK"

HTTPS_READY=0

if [[ "$REUSE_EXISTING_HTTPS" == "1" ]]; then
    HTTPS_READY=1
    echo "      HTTPS-сертификат и конфигурация уже работают."
else
    for _ in $(seq 1 90); do
        if curl -fsSI --max-time 5 "https://${DOMAIN}/" >/dev/null 2>&1; then
            HTTPS_READY=1
            break
        fi
        sleep 2
    done
fi

if [[ "$HTTPS_READY" != "1" ]]; then
    echo "      Диагностика Caddy:"
    journalctl -u caddy -n 60 --no-pager 2>/dev/null || true
    die "HTTPS не стал доступен за 180 секунд. Проверьте Caddy/ACME/DNS."
fi

echo "      HTTPS OK"

echo
echo "[10/10] Проверка автозапуска и портов..."
for unit in mtproxy tproxy-server caddy; do
    systemctl is-active --quiet "$unit" || die "$unit не активен."
    systemctl is-enabled --quiet "$unit" || die "$unit не включён в автозапуск."
done

systemctl is-active --quiet tproxy-firewall || die "tproxy-firewall не активен."
systemctl is-enabled --quiet refresh-mtproxy-config.timer || die "таймер обновления не включён в автозапуск."

runuser -u mtproxy -- test -x /opt/MTProxy/objs/bin/mtproto-proxy ||
    die "Финальная проверка прав MTProxy не прошла."

runuser -u tproxy -- test -r /srv/tproxy-site/index.html ||
    die "Финальная проверка прав сайта не прошла."

for p in 2398 8080 8081 80 443; do
    ss -lnt | grep -Eq ":(${p})\b" || die "Ожидаемый порт ${p} не слушается."
done

write_manifest "$DOMAIN" "$EMAIL" "$REUSE_CADDY" "$REUSE_MT" "$REUSE_RELAY"

TELEGRAM_SECRET="${SECRET#dd}"

echo
echo "============================================================"
echo "          TELEGRAM WEB PROXY ГОТОВ К РАБОТЕ"
echo "============================================================"
echo
echo "Домен:"
echo "  https://${DOMAIN}/"
echo
echo "Secret:"
echo "  ${SECRET}"
echo
echo "Ссылка для Telegram:"
echo "  https://t.me/webproxy?server=${DOMAIN}&secret=${TELEGRAM_SECRET}"
echo
echo "Статус:"
echo "  HTTPS          OK"
echo "  MTProxy        ACTIVE"
echo "  Relay          READY"
echo "  Firewall       ACTIVE"
echo
echo "ВАЖНО: не передавайте secret третьим лицам."
echo "============================================================"
