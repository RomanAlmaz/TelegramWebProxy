# Telegram Web Proxy - установка на VPS

Скрипты для развёртывания [официального tproxy-server](https://github.com/telegramdesktop/tproxy-server) на Ubuntu VPS с HTTPS, MTProxy и публичным сайтом.

## Что это

Telegram Web Proxy - тип прокси, при котором Telegram отправляет MTProxy-трафик через WebView по HTTPS. На сервере работают:

- **Caddy** - HTTPS на портах 80/443, автоматический сертификат Let's Encrypt
- **tproxy-server** - relay, принимает WebView-сессии и разводит потоки на MTProxy
- **MTProxy** - официальный backend на `127.0.0.1:2398`
- **Публичный сайт** - обычный HTTPS-сайт на том же домене (папка `site/`)

Схема:

```text
Internet :80/:443
    -> Caddy
    -> 127.0.0.1:8080 tproxy-server
         -> публичный сайт (/srv/tproxy-site)
         -> 127.0.0.1:2398 MTProxy
```

Оригинальный репозиторий: https://github.com/telegramdesktop/tproxy-server

## Структура проекта

```text
TelegramWebProxy/
├── install-proxy.sh      # установка прокси
├── uninstall-proxy.sh    # удаление прокси
├── clean-all.sh          # полный сброс VPS
├── status-proxy.sh       # статус и health-check
├── deploy-site.sh        # деплой сайта из site/
├── lib/common.sh         # общие функции
├── tproxy-server/        # исходники официального relay
└── site/                 # статический публичный сайт
```

## Требования

- Ubuntu 22.04 или новее
- Архитектура x86_64
- root-доступ
- Свободные порты 80 и 443
- Домен с A-записью на IP VPS

Пример DNS:

```text
proxy.example.com -> IP вашего VPS
```

## Быстрый старт

Репозиторий: https://github.com/RomanAlmaz/TelegramWebProxy

На VPS:

```bash
git clone https://github.com/RomanAlmaz/TelegramWebProxy.git
cd TelegramWebProxy
chmod +x *.sh

# Установка
sudo bash install-proxy.sh

# Проверка
sudo bash status-proxy.sh
```

Одной командой:

```bash
git clone https://github.com/RomanAlmaz/TelegramWebProxy.git && cd TelegramWebProxy && chmod +x *.sh && sudo bash install-proxy.sh
```

Установщик спросит:

```text
Домен (пример: proxy.example.com):
Email для ACME/Let's Encrypt (пример: admin@example.com):
Сгенерировать secret автоматически? [Y/n]:
```

После установки вы получите:

- URL: `https://ваш-домен/`
- Secret для подключения
- Ссылку: `https://t.me/webproxy?server=...&secret=...`

Secret никому не передавайте.

## Скрипты

### install-proxy.sh

Полная установка:

1. Проверка системы, DNS и портов
2. Загрузка или использование локального `tproxy-server`
3. Установка зависимостей
4. Сборка MTProxy и tproxy-server
5. Установка Caddy
6. Деплой сайта из `site/` в `/srv/tproxy-site`
7. Настройка systemd, firewall, HTTPS
8. Health-check всех компонентов

### status-proxy.sh

Показывает:

- статус сервисов (mtproxy, tproxy-server, caddy, firewall)
- порты 80, 443, 2398, 8080, 8081
- healthz / readyz / HTTPS
- домен, secret (маскированный), ссылку t.me
- информацию о сайте и последние строки логов

### deploy-site.sh

Обновляет публичный сайт из папки `site/`:

```bash
sudo bash deploy-site.sh
```

Можно указать другую папку:

```bash
sudo bash deploy-site.sh /path/to/custom-site
```

После деплоя перезапускается только `tproxy-server`. Caddy перезапускать не нужно.

### uninstall-proxy.sh

Удаляет компоненты, установленные через `install-proxy.sh`. Подтверждение: `REMOVE`.

Если на сервере уже были MTProxy, relay или Caddy до установки, они сохраняются (консервативный режим через manifest).

### clean-all.sh

**Полный сброс VPS (factory reset)** - делает сервер максимально чистым, как после первой установки Ubuntu.

**Удаляет:**

- Telegram Web Proxy и **весь** другой установленный софт
- docker, nginx, apache, node, базы данных и т.д.
- все apt-пакеты, установленные вручную (кроме SSH и базовой системы)
- все custom systemd-сервисы
- всех пользователей кроме root и **текущего пользователя** (через которого запущен скрипт)
- все файлы в `/root` (кроме `.ssh`), домашние папки других пользователей, `/opt`, `/srv`, `/var/www`
- все бинарники в `/usr/local`
- firewall, cron, логи, temp, snap-пакеты, файлы проекта

**Сохраняет:**

- Ubuntu, SSH, сеть, cloud-init
- текущего пользователя и его `/home` (включая `.ssh` - SSH-ключи не удаляются)

Подтверждение: введите **hostname сервера**, затем `FACTORY-RESET`.

Разница с `uninstall-proxy.sh`: `uninstall-proxy.sh` снимает только прокси, `clean-all.sh` полностью обнуляет VPS.

## Публичный сайт

Сайт лежит в `site/` и копируется в `/srv/tproxy-site` при установке.

Требования к сайту для tproxy-server описаны в `tproxy-server/PUBLIC_SITE.md`. Relay загружает статику в память при старте - после изменения файлов нужен `deploy-site.sh` или перезапуск `tproxy-server`.

## Полезные команды

```bash
# Логи
journalctl -u tproxy-server -f
journalctl -u mtproxy -f
journalctl -u caddy -f

# Ручной health-check
curl http://127.0.0.1:8081/healthz
curl http://127.0.0.1:8081/readyz

# Перезапуск relay
systemctl restart tproxy-server
```

## Обновление relay

Исходники в `tproxy-server/` можно обновить из upstream:

```bash
cd tproxy-server
git pull
cd ..
sudo bash install-proxy.sh   # или tproxy-server/deploy/update-relay.sh на уже установленном сервере
```

## Репозиторий

- Этот проект: https://github.com/RomanAlmaz/TelegramWebProxy
- Upstream relay: https://github.com/telegramdesktop/tproxy-server

Скрипты в корне - обёртка для удобной установки на VPS поверх официального [tproxy-server](https://github.com/telegramdesktop/tproxy-server).
