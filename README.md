# proxy-install.sh

Интерактивный установщик прокси-сервера на Ubuntu/Debian.
Ставит **Telemt** (MTProxy с Fake-TLS) и/или **3proxy** (SOCKS5), настраивает firewall и готовит конфиг для proxy-agent.

> **Рекомендуется запускать на чистом сервере.** На существующей системе учитывай следующее:
>
> - **Firewall** — скрипт включает `ufw` с политикой `deny incoming` и открывает только нужные порты (22, 443, 1080, 8080). Если у тебя были свои правила — они сохранятся, но политика по умолчанию изменится на запрет входящих.
> - **Порт 443** — Telemt по умолчанию занимает порт 443. Если на нём уже работает nginx, Apache или другой веб-сервер — будет конфликт. Укажи другой порт при установке.
> - **Порт 1080** — аналогично для 3proxy. Убедись, что порт свободен.
> - **Существующий 3proxy** — если 3proxy уже установлен, скрипт перезапишет `/etc/3proxy/3proxy.cfg`. Сделай бэкап конфига перед запуском.
> - **sysctl / limits** — скрипт дописывает параметры в `/etc/sysctl.conf` и `/etc/security/limits.conf`. Повторный запуск дубликатов не создаёт, но значения могут конфликтовать с существующими настройками.

## Быстрый старт

```bash
wget -qO- https://raw.githubusercontent.com/curkan/proxy-install.sh/main/proxy-install.sh | bash
```

или через `curl`:

```bash
curl -sL https://raw.githubusercontent.com/curkan/proxy-install.sh/main/proxy-install.sh | bash
```

Скрипт задаст несколько вопросов и всё настроит сам.

## Требования

- Ubuntu 22.04 / 24.04 или Debian 11+
- Архитектура x86_64
- Root-доступ

## Что устанавливается

| Компонент | Описание | Порт по умолчанию |
|---|---|---|
| Telemt | MTProxy с Fake-TLS маскировкой | 443 |
| 3proxy | SOCKS5 с логином/паролем | 1080 |
| proxy-agent | Конфиг и systemd-сервис (бинарник деплоится отдельно) | 8080 |

Можно поставить оба прокси или только один — скрипт спросит.

## Что спросит скрипт

```
Домен сервера (DNS → IP этого сервера) [автоопределение IP]:
Домен для TLS-маскировки (уникальный, не google.com):
IP сервера бота (для firewall):
Порт Telemt (MTProxy) [443]:
Порт SOCKS5 (3proxy) [1080]:
Порт proxy-agent [8080]:
Установить Telemt (MTProxy)? [y/n, default: y]:
Установить 3proxy (SOCKS5)? [y/n, default: y]:
```

## После установки

Скрипт выведет токен агента и инструкции для деплоя бинарника:

```bash
scp proxy-agent root@<IP>:/opt/proxy-agent/proxy-agent
ssh root@<IP> 'chmod +x /opt/proxy-agent/proxy-agent && systemctl enable proxy-agent && systemctl start proxy-agent'
```

## Структура файлов

```
/bin/telemt                       # бинарник Telemt
/etc/telemt/telemt.toml           # конфиг Telemt
/var/lib/telemt/                  # рабочая директория Telemt

/etc/3proxy/3proxy.cfg            # конфиг 3proxy
/etc/3proxy/passwd                # логины/пароли (hot-reload)

/opt/proxy-agent/proxy-agent      # Go-бинарник агента (деплоится отдельно)
/opt/proxy-agent/env              # переменные окружения (chmod 600)
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

Скрипт идемпотентен — можно запустить повторно для переконфигурации. Системные лимиты и sysctl не дублируются.

## Лицензия

MIT
