#!/usr/bin/env bash
#
# proxy-install.sh — установщик Telemt + 3proxy + proxy-agent
# Использование: bash proxy-install.sh
#

set -euo pipefail

# ─── Цвета ────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Вспомогательные функции ──────────────────────────────────────────────────

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }
header()  { echo -e "\n${BOLD}${BLUE}━━━ $* ━━━${NC}\n"; }

# ─── Версии ───────────────────────────────────────────────────────────────────

TELEMT_VERSION="latest"
PROXY_3PROXY_VERSION="0.9.5"
AGENT_PORT_DEFAULT="8080"
TELEMT_PORT_DEFAULT="443"
SOCKS5_PORT_DEFAULT="1080"

# ─── Проверки ─────────────────────────────────────────────────────────────────

check_root() {
	if [[ $EUID -ne 0 ]]; then
		die "Скрипт должен запускаться от root. Используй: sudo bash $0"
	fi
}

check_os() {
	if [[ ! -f /etc/os-release ]]; then
		die "Не удалось определить ОС"
	fi
	source /etc/os-release
	if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
		die "Поддерживается только Ubuntu и Debian. Текущая ОС: $ID"
	fi
	info "ОС: $PRETTY_NAME"
}

check_arch() {
	ARCH=$(uname -m)
	if [[ "$ARCH" != "x86_64" ]]; then
		die "Поддерживается только x86_64. Текущая архитектура: $ARCH"
	fi
}

# ─── Получение публичного IP ──────────────────────────────────────────────────

get_public_ip() {
	PUBLIC_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
	            curl -s --max-time 5 https://ifconfig.me 2>/dev/null || \
	            echo "")
	echo "$PUBLIC_IP"
}

# ─── Интерактивный ввод ───────────────────────────────────────────────────────

prompt() {
	local var_name="$1"
	local prompt_text="$2"
	local default="${3:-}"
	local value

	if [[ -n "$default" ]]; then
		read -r -p "$(echo -e "${BOLD}${prompt_text}${NC} [${default}]: ")" value
		value="${value:-$default}"
	else
		while [[ -z "${value:-}" ]]; do
			read -r -p "$(echo -e "${BOLD}${prompt_text}${NC}: ")" value
			[[ -z "$value" ]] && warn "Значение обязательно"
		done
	fi

	printf -v "$var_name" '%s' "$value"
}

prompt_yes_no() {
	local var_name="$1"
	local prompt_text="$2"
	local default="${3:-y}"
	local value

	while true; do
		read -r -p "$(echo -e "${BOLD}${prompt_text}${NC} [y/n, default: ${default}]: ")" value
		value="${value:-$default}"
		case "${value,,}" in
			y|yes) printf -v "$var_name" 'true';  return ;;
			n|no)  printf -v "$var_name" 'false'; return ;;
			*) warn "Введи y или n" ;;
		esac
	done
}

# ─── Сбор конфигурации ────────────────────────────────────────────────────────

collect_config() {
	header "Конфигурация"

	local detected_ip
	detected_ip=$(get_public_ip)

	echo -e "Публичный IP сервера: ${CYAN}${detected_ip:-не определён}${NC}\n"

	prompt PUBLIC_HOST      "Домен сервера (DNS → IP этого сервера)" "${detected_ip}"
	prompt TLS_DOMAIN       "Домен для TLS-маскировки (уникальный, не google.com)" ""
	prompt BOT_SERVER_IP    "IP сервера бота (для firewall)" ""

	echo ""
	prompt TELEMT_PORT   "Порт Telemt (MTProxy)" "$TELEMT_PORT_DEFAULT"
	prompt SOCKS5_PORT   "Порт SOCKS5 (3proxy)"  "$SOCKS5_PORT_DEFAULT"
	prompt AGENT_PORT    "Порт proxy-agent"       "$AGENT_PORT_DEFAULT"

	echo ""
	prompt_yes_no INSTALL_TELEMT "Установить Telemt (MTProxy)?" "y"
	prompt_yes_no INSTALL_SOCKS5 "Установить 3proxy (SOCKS5)?"  "y"

	echo ""
	info "Генерирую токен агента..."
	AGENT_TOKEN=$(openssl rand -hex 32)

	echo ""
	echo -e "${BOLD}Конфигурация:${NC}"
	echo -e "  Домен сервера:       ${CYAN}${PUBLIC_HOST}${NC}"
	echo -e "  TLS маскировка:      ${CYAN}${TLS_DOMAIN}${NC}"
	echo -e "  IP бота:             ${CYAN}${BOT_SERVER_IP}${NC}"
	echo -e "  Порт Telemt:         ${CYAN}${TELEMT_PORT}${NC}"
	echo -e "  Порт SOCKS5:         ${CYAN}${SOCKS5_PORT}${NC}"
	echo -e "  Порт агента:         ${CYAN}${AGENT_PORT}${NC}"
	echo -e "  Установить Telemt:   ${CYAN}${INSTALL_TELEMT}${NC}"
	echo -e "  Установить SOCKS5:   ${CYAN}${INSTALL_SOCKS5}${NC}"
	echo ""

	local confirm
	prompt_yes_no confirm "Продолжить установку?" "y"
	[[ "$confirm" == "false" ]] && { info "Установка отменена"; exit 0; }
}

# ─── Системные настройки ──────────────────────────────────────────────────────

setup_system() {
	header "Системные настройки"

	info "Обновляем пакеты..."
	apt-get update -qq

	info "Устанавливаем зависимости..."
	apt-get install -y -qq curl wget xxd openssl ufw

	info "Настраиваем лимиты файловых дескрипторов..."
	if ! grep -q '# proxy-install' /etc/security/limits.conf 2>/dev/null; then
		cat >> /etc/security/limits.conf << 'EOF'
# proxy-install
nobody  soft  nofile  65536
nobody  hard  nofile  65536
*       soft  nofile  65536
*       hard  nofile  65536
EOF
	fi

	if ! grep -q '# proxy-install' /etc/sysctl.conf 2>/dev/null; then
		cat >> /etc/sysctl.conf << 'EOF'
# proxy-install
fs.file-max = 1000000
net.ipv4.tcp_tw_reuse = 1
net.core.somaxconn = 65535
EOF
	fi
	sysctl -p -q

	success "Системные настройки применены"
}

# ─── Установка Telemt ─────────────────────────────────────────────────────────

install_telemt() {
	header "Установка Telemt (MTProxy)"

	info "Скачиваем бинарник Telemt..."
	local libc_type
	libc_type=$(ldd --version 2>&1 | grep -iq musl && echo musl || echo gnu)
	local arch
	arch=$(uname -m)

	wget -qO /tmp/telemt.tar.gz \
		"https://github.com/telemt/telemt/releases/latest/download/telemt-${arch}-linux-${libc_type}.tar.gz"
	tar -xzf /tmp/telemt.tar.gz -C /tmp
	mv /tmp/telemt /bin/telemt
	chmod +x /bin/telemt
	rm -f /tmp/telemt.tar.gz
	success "Telemt установлен: $(/bin/telemt --version 2>/dev/null || echo 'ok')"

	info "Создаём конфигурацию..."
	mkdir -p /etc/telemt /var/lib/telemt

	# Первый пользователь-заглушка, бот заменит через API
	local first_key
	first_key=$(openssl rand -hex 16)
	local first_user="u_${first_key:0:8}"

	cat > /etc/telemt/telemt.toml << EOF
[general]
use_middle_proxy = false
log_level = "normal"
fast_mode = false

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = "*"
public_host = "${PUBLIC_HOST}"
public_port = ${TELEMT_PORT}

[server]
port = ${TELEMT_PORT}

[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32"]

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
tls_domain = "${TLS_DOMAIN}"
mask = true

[access.users]
${first_user} = "${first_key}"
EOF

	chown nobody:nogroup /etc/telemt
	chown nobody:nogroup /etc/telemt/telemt.toml
	chmod 664 /etc/telemt/telemt.toml
	chown nobody:nogroup /var/lib/telemt

	info "Создаём systemd-сервис..."
	cat > /etc/systemd/system/telemt.service << 'EOF'
[Unit]
Description=Telemt MTProxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
WorkingDirectory=/var/lib/telemt
ExecStart=/bin/telemt /etc/telemt/telemt.toml
Restart=on-failure
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

	systemctl daemon-reload
	systemctl enable telemt
	systemctl start telemt

	if systemctl is-active --quiet telemt; then
		success "Telemt запущен"
	else
		error "Telemt не запустился. Проверь: journalctl -u telemt -n 20"
	fi
}

# ─── Установка 3proxy ─────────────────────────────────────────────────────────

install_3proxy() {
	header "Установка 3proxy (SOCKS5)"

	info "Скачиваем 3proxy ${PROXY_3PROXY_VERSION}..."
	wget -qO /tmp/3proxy.deb \
		"https://github.com/3proxy/3proxy/releases/download/${PROXY_3PROXY_VERSION}/3proxy-${PROXY_3PROXY_VERSION}.x86_64.deb"
	dpkg -i /tmp/3proxy.deb > /dev/null 2>&1 || true
	rm -f /tmp/3proxy.deb
	success "3proxy установлен"

	info "Создаём конфигурацию..."
	mkdir -p /etc/3proxy
	touch /etc/3proxy/passwd

	cat > /etc/3proxy/3proxy.cfg << EOF
nscache 65536
nserver 8.8.8.8
nserver 8.8.4.4

pidfile /var/run/3proxy.pid

log /usr/local/3proxy/logs/3proxy-%y%m%d.log D
rotate 60
counter /usr/local/3proxy/count/3proxy.3cf

users \$/etc/3proxy/passwd
monitor /etc/3proxy/passwd

auth strong
deny * * 127.0.0.1
allow *

socks -p${SOCKS5_PORT}
flush
EOF

	systemctl start 3proxy
	systemctl enable 3proxy

	if systemctl is-active --quiet 3proxy; then
		success "3proxy запущен на порту ${SOCKS5_PORT}"
	else
		error "3proxy не запустился. Проверь: journalctl -u 3proxy -n 20"
	fi
}

# ─── Подготовка proxy-agent ───────────────────────────────────────────────────

setup_agent() {
	header "Подготовка proxy-agent"

	mkdir -p /opt/proxy-agent

	cat > /opt/proxy-agent/env << EOF
AGENT_TOKEN=${AGENT_TOKEN}
AGENT_PORT=${AGENT_PORT}
EOF

	# Включаем бэкенды по выбору (можно оба)
	if [[ "$INSTALL_TELEMT" == "true" ]]; then
		cat >> /opt/proxy-agent/env << EOF
TELEMT_API_URL=http://127.0.0.1:9091
EOF
	fi

	if [[ "$INSTALL_SOCKS5" == "true" ]]; then
		cat >> /opt/proxy-agent/env << EOF
SOCKS5_PASSWD_FILE=/etc/3proxy/passwd
SOCKS5_PID_FILE=/var/run/3proxy.pid
EOF
	fi

	chmod 600 /opt/proxy-agent/env
	chown root:root /opt/proxy-agent/env

	cat > /etc/systemd/system/proxy-agent.service << EOF
[Unit]
Description=Proxy Agent
After=network.target telemt.service 3proxy.service

[Service]
User=root
WorkingDirectory=/opt/proxy-agent
EnvironmentFile=/opt/proxy-agent/env
ExecStart=/opt/proxy-agent/proxy-agent
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

	systemctl daemon-reload

	info "Бинарник агента (/opt/proxy-agent/proxy-agent) нужно скопировать отдельно:"
	echo -e "  ${CYAN}scp proxy-agent root@${PUBLIC_HOST}:/opt/proxy-agent/proxy-agent${NC}"
	echo -e "  ${CYAN}ssh root@${PUBLIC_HOST} 'chmod +x /opt/proxy-agent/proxy-agent && systemctl enable proxy-agent && systemctl start proxy-agent'${NC}"
	success "Конфигурация агента готова"
}

# ─── Настройка firewall ───────────────────────────────────────────────────────

setup_firewall() {
	header "Настройка firewall (ufw)"

	ufw default deny incoming > /dev/null
	ufw default allow outgoing > /dev/null

	ufw allow 22/tcp comment "SSH"

	if [[ "$INSTALL_TELEMT" == "true" ]]; then
		ufw allow "${TELEMT_PORT}/tcp" comment "Telemt MTProxy"
	fi

	if [[ "$INSTALL_SOCKS5" == "true" ]]; then
		if [[ -n "$BOT_SERVER_IP" ]]; then
			ufw allow from "$BOT_SERVER_IP" to any port "$SOCKS5_PORT" comment "SOCKS5 from bot"
		else
			ufw allow "${SOCKS5_PORT}/tcp" comment "SOCKS5"
			warn "SOCKS5 открыт для всех IP. Рекомендуется ограничить по IP бота"
		fi
	fi

	if [[ -n "$BOT_SERVER_IP" ]]; then
		ufw allow from "$BOT_SERVER_IP" to any port "$AGENT_PORT" comment "proxy-agent from bot"
	fi

	# Telemt API — только localhost
	ufw deny 9091 comment "Telemt API — только localhost" > /dev/null

	ufw --force enable > /dev/null
	success "Firewall настроен"
}

# ─── Итоговый вывод ───────────────────────────────────────────────────────────

print_summary() {
	header "Установка завершена"

	echo -e "${BOLD}Параметры подключения:${NC}"
	echo ""

	if [[ "$INSTALL_TELEMT" == "true" ]]; then
		echo -e "${BOLD}Telemt (MTProxy):${NC}"
		echo -e "  Сервер: ${CYAN}${PUBLIC_HOST}${NC}"
		echo -e "  Порт:   ${CYAN}${TELEMT_PORT}${NC}"
		echo -e "  Ссылки выводятся в логах: ${CYAN}journalctl -u telemt | grep 'EE-TLS\|DD:'${NC}"
		echo ""
	fi

	if [[ "$INSTALL_SOCKS5" == "true" ]]; then
		echo -e "${BOLD}3proxy (SOCKS5):${NC}"
		echo -e "  Сервер: ${CYAN}${PUBLIC_HOST}${NC}"
		echo -e "  Порт:   ${CYAN}${SOCKS5_PORT}${NC}"
		echo -e "  Логин/пароль: ${CYAN}из /etc/3proxy/passwd${NC}"
		echo ""
	fi

	echo -e "${BOLD}proxy-agent:${NC}"
	echo -e "  Порт:      ${CYAN}${AGENT_PORT}${NC}"
	echo -e "  Токен:     ${CYAN}${AGENT_TOKEN}${NC}"
	local backends=""
	[[ "$INSTALL_TELEMT" == "true" ]] && backends+="telemt"
	[[ "$INSTALL_SOCKS5" == "true" ]] && backends+="${backends:+, }socks5"
	echo -e "  Бэкенды:  ${CYAN}${backends}${NC}"
	echo ""

	echo -e "${BOLD}Конфиги сохранены в:${NC}"
	[[ "$INSTALL_TELEMT" == "true" ]] && echo -e "  ${CYAN}/etc/telemt/telemt.toml${NC}"
	[[ "$INSTALL_SOCKS5" == "true" ]] && echo -e "  ${CYAN}/etc/3proxy/3proxy.cfg${NC}"
	echo -e "  ${CYAN}/opt/proxy-agent/env${NC}"
	echo ""

	warn "Сохрани токен агента в надёжном месте!"
	echo ""

	echo -e "${BOLD}Следующий шаг — деплой бинарника агента:${NC}"
	echo -e "  ${CYAN}scp proxy-agent root@${PUBLIC_HOST}:/opt/proxy-agent/proxy-agent${NC}"
	echo -e "  ${CYAN}ssh root@${PUBLIC_HOST} 'chmod +x /opt/proxy-agent/proxy-agent && systemctl enable proxy-agent && systemctl start proxy-agent'${NC}"
}

# ─── Главная функция ──────────────────────────────────────────────────────────

main() {
	echo -e "${BOLD}${BLUE}"
	echo "  ┌─────────────────────────────────────┐"
	echo "  │       proxy-install v1.0.0          │"
	echo "  │  Telemt + 3proxy + proxy-agent       │"
	echo "  └─────────────────────────────────────┘"
	echo -e "${NC}"

	check_root
	check_os
	check_arch
	collect_config
	setup_system

	[[ "$INSTALL_TELEMT" == "true" ]] && install_telemt
	[[ "$INSTALL_SOCKS5" == "true" ]] && install_3proxy

	setup_agent
	setup_firewall
	print_summary
}

main "$@"
