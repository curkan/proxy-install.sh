# proxy-install.sh

Интерактивный установщик прокси-сервера на Ubuntu/Debian.
Ставит **Telemt** (MTProxy с Fake-TLS) и/или **3proxy** (SOCKS5), настраивает firewall и готовит конфиг для proxy-agent.

> **Рекомендуется запускать на чистом сервере.** На существующей системе учитывай следующее:
>
> - **Firewall** — скрипт включает `ufw` с политикой `deny incoming` и открывает только нужные порты (22, 443, 1080, 8080). Если у тебя были свои правила — они сохранятся, но политика по умолчанию изменится на запрет входящих.
> - **Порт 443** — Telemt по умолчанию занимает порт 443. Если на нём уже работает nginx, Apache или другой веб-сервер — будет конфликт. Укажи другой порт при установке.
> - **Порт 1080** — аналогично для 3proxy. Убедись, что порт свободен.
> - **Существующий 3proxy** — если 3proxy уже установлен, скрипт перезапишет `/etc/3proxy/3proxy.cfg`. Сделай бэкап конфига перед запуском.
> - **sysctl / limits** — скрипт создаёт drop-in файлы в `/etc/sysctl.d/` и `/etc/security/limits.d/`. Повторный запуск безопасно перезаписывает их.

## Быстрый старт

```bash
wget -qO proxy-install.sh https://raw.githubusercontent.com/curkan/proxy-install.sh/master/proxy-install.sh && bash proxy-install.sh
```

или через `curl`:

```bash
curl -sLO https://raw.githubusercontent.com/curkan/proxy-install.sh/master/proxy-install.sh && bash proxy-install.sh
```

Скрипт задаст несколько вопросов и всё настроит сам.

## CLI-режим (без промптов)

```bash
bash proxy-install.sh \
  --host mt-bel-1.closed.ru \
  --tls-domain closed.ru \
  --bot-ip 10.0.0.1
```

Все параметры:

| Флаг | Описание | По умолчанию |
|---|---|---|
| `--host HOST` | Домен или IP сервера | обязательный |
| `--tls-domain DOMAIN` | Домен для TLS-маскировки | обязательный |
| `--bot-ip IP` | IP сервера бота (для firewall) | обязательный |
| `--telemt-port PORT` | Порт Telemt | 443 |
| `--socks5-port PORT` | Порт SOCKS5 | 1080 |
| `--agent-port PORT` | Порт proxy-agent | 8080 |
| `--3proxy-version VER` | Версия 3proxy | 0.9.5 |
| `--no-telemt` | Не устанавливать Telemt | — |
| `--no-socks5` | Не устанавливать 3proxy | — |

Только SOCKS5 без Telemt:

```bash
bash proxy-install.sh \
  --host 141.98.233.68 \
  --tls-domain closed.ru \
  --bot-ip 10.0.0.1 \
  --no-telemt
```

## Удаление

```bash
bash proxy-install.sh --uninstall
```

Удалит все компоненты, systemd-сервисы, конфиги и системного пользователя. Правила ufw нужно проверить вручную.

## Требования

- Ubuntu 22.04 / 24.04 или Debian 11+
- Архитектура x86_64
- Root-доступ

## Что устанавливается

| Компонент | Описание | Порт по умолчанию |
|---|---|---|
| Telemt | MTProxy с Fake-TLS маскировкой | 443 |
| 3proxy | SOCKS5 с логином/паролем | 1080 |
| [proxy-agent](https://github.com/curkan/proxy-agent) | HTTP API для управления прокси | 8080 |

Можно поставить оба прокси или только один — скрипт спросит.

## После установки

Скрипт выведет токен агента — сохрани его. Все компоненты уже запущены и работают, включая proxy-agent (бинарник скачивается автоматически из [GitHub Releases](https://github.com/curkan/proxy-agent/releases)).

## Структура файлов

```
/usr/local/bin/telemt                  # бинарник Telemt
/etc/telemt/telemt.toml                # конфиг Telemt (chmod 640)
/var/lib/telemt/                       # рабочая директория Telemt

/etc/3proxy/3proxy.cfg                 # конфиг 3proxy
/etc/3proxy/passwd                     # логины/пароли (hot-reload)

/opt/proxy-agent/proxy-agent           # Go-бинарник агента (скачивается из GitHub)
/opt/proxy-agent/env                   # переменные окружения (chmod 600)

/etc/sysctl.d/99-proxy-install.conf    # sysctl-параметры
/etc/security/limits.d/99-proxy-install.conf  # лимиты
```

## Управление

```bash
# Статус
systemctl status telemt
systemctl status 3proxy
systemctl status proxy-agent

# Логи
journalctl -u telemt -n 50
journalctl -u 3proxy -n 50
journalctl -u proxy-agent -n 50

# Telemt: ссылки для подключения
journalctl -u telemt | grep 'EE-TLS\|DD:'

# Telemt: пользователи через API
curl http://127.0.0.1:9091/v1/users

# 3proxy: пользователи
cat /etc/3proxy/passwd
```

## Повторный запуск

Скрипт идемпотентен — можно запустить повторно для переконфигурации. Drop-in конфиги перезаписываются, ufw-правила не дублируются.

## Development

### Тестирование в Docker (systemd)

Для локальной разработки и отладки скрипт можно запустить в Docker-контейнере с systemd. ufw замокан — iptables хоста не затрагиваются.

```bash
make test-cli      # установка в CLI-режиме
make test-smoke    # установка + автоматические проверки
make test-uninstall # установка → проверка → удаление → проверка
make exec          # зайти в контейнер для отладки
make down          # остановить контейнер
make clean         # удалить контейнер и образ
```

> Требует Docker. Контейнер запускается с `--privileged` для systemd.
> Не заменяет тестирование на реальной VM перед релизом.

## Лицензия

MIT
