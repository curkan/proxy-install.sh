#!/usr/bin/env bash
#
# proxy-install.sh — установщик Telemt + 3proxy + proxy-agent
#
# Интерактивный режим:
#   wget -qO proxy-install.sh URL && bash proxy-install.sh
#
# CLI режим (без промптов):
#   bash proxy-install.sh \
#     --host mt-bel-1.closed.ru \
#     --tls-domain closed.ru \
#     --bot-ip 10.0.0.1 \
#     --telemt \
#     --socks5
#
# Удаление:
#   bash proxy-install.sh --uninstall
#

set -euo pipefail

# ─── Цвета ────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ─── Вспомогательные функции ──────────────────────────────────────────────────

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }
header()  { echo -e "\n${BOLD}${BLUE}━━━ $* ━━━${NC}\n"; }

# ─── Step runner ─────────────────────────────────────────────────────────────

STEP_CURRENT=0
STEP_TOTAL=0
STEP_LOG=""

step_init() {
	STEP_TOTAL="$1"
	STEP_CURRENT=0
	STEP_LOG=$(mktemp /tmp/proxy-install-log.XXXXXX)
	CLEANUP_FILES+=("$STEP_LOG")
}

run_step() {
	local description="$1"
	local func="$2"
	STEP_CURRENT=$((STEP_CURRENT + 1))

	local prefix
	prefix=$(printf "[%d/%d] %s " "$STEP_CURRENT" "$STEP_TOTAL" "$description")
	local dots_len=$(( 50 - ${#prefix} ))
	if [[ $dots_len -lt 3 ]]; then
		dots_len=3
	fi
	local dots
	dots=$(printf '%*s' "$dots_len" '' | tr ' ' '.')

	local line="${BOLD}${prefix}${NC}${DIM}${dots}${NC}"

	# Запускаем функцию в фоне
	"$func" >> "$STEP_LOG" 2>&1 &
	local pid=$!

	# Спиннер
	local spinner=('◰' '◳' '◲' '◱')
	local i=0
	while kill -0 "$pid" 2>/dev/null; do
		echo -ne "\r${line} ${CYAN}${spinner[$i]}${NC}"
		i=$(( (i + 1) % ${#spinner[@]} ))
		sleep 0.15
	done

	# Получаем код выхода
	local exit_code=0
	wait "$pid" || exit_code=$?

	if [[ $exit_code -eq 0 ]]; then
		echo -e "\r${line} ${GREEN}✔${NC}"
	else
		echo -e "\r${line} ${RED}✘${NC}"
		echo ""
		echo -e "${RED}  Вывод:${NC}"
		tail -20 "$STEP_LOG" | sed 's/^/    /'
		echo ""
		die "Шаг '$description' завершился с ошибкой (код $exit_code)"
	fi

	: > "$STEP_LOG"
}

# ─── Cleanup при ошибке ─────────────────────────────────────────────────────

CLEANUP_FILES=()

cleanup() {
	local exit_code=$?
	for f in "${CLEANUP_FILES[@]}"; do
		rm -f "$f" 2>/dev/null
	done
	if [[ $exit_code -ne 0 && $exit_code -ne 130 ]]; then
		echo ""
		error "Скрипт завершился с ошибкой (код $exit_code)"
		error "Проверь вывод выше для диагностики"
	fi
}

trap cleanup EXIT

# ─── Версии ───────────────────────────────────────────────────────────────────

TELEMT_VERSION="latest"
PROXY_3PROXY_VERSION="0.9.5"
AGENT_PORT_DEFAULT="8080"
TELEMT_PORT_DEFAULT="443"
SOCKS5_PORT_DEFAULT="1080"

# ─── Валидация ввода ─────────────────────────────────────────────────────────

validate_domain() {
	local val="$1"
	if [[ ! "$val" =~ ^[a-zA-Z0-9._-]+$ ]]; then
		die "Некорректный домен/хост: '$val'. Допустимы буквы, цифры, точки, дефисы"
	fi
}

validate_ip() {
	local val="$1"
	if [[ ! "$val" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		die "Некорректный IP-адрес: '$val'. Формат: x.x.x.x"
	fi
}

validate_port() {
	local val="$1"
	if [[ ! "$val" =~ ^[0-9]+$ ]] || [[ "$val" -lt 1 ]] || [[ "$val" -gt 65535 ]]; then
		die "Некорректный порт: '$val'. Допустимый диапазон: 1-65535"
	fi
}

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
	local ip
	ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || \
	     curl -s --max-time 5 https://ifconfig.me 2>/dev/null || \
	     echo "")
	if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		echo "$ip"
	else
		echo ""
	fi
}

# ─── Определение libc ───────────────────────────────────────────────────────

detect_libc() {
	if ls /lib/ld-musl-*.so.1 >/dev/null 2>&1; then
		echo "musl"
	else
		echo "gnu"
	fi
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
			if [[ -z "$value" ]]; then
				warn "Значение обязательно"
			fi
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

# ─── Парсинг CLI-аргументов ──────────────────────────────────────────────────

CLI_MODE="false"
UNINSTALL_MODE="false"

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--host)
				[[ $# -ge 2 ]] || die "Аргумент $1 требует значения"
				PUBLIC_HOST="$2"; shift 2 ;;
			--tls-domain)
				[[ $# -ge 2 ]] || die "Аргумент $1 требует значения"
				TLS_DOMAIN="$2"; shift 2 ;;
			--bot-ip)
				[[ $# -ge 2 ]] || die "Аргумент $1 требует значения"
				BOT_SERVER_IP="$2"; shift 2 ;;
			--telemt-port)
				[[ $# -ge 2 ]] || die "Аргумент $1 требует значения"
				TELEMT_PORT="$2"; shift 2 ;;
			--socks5-port)
				[[ $# -ge 2 ]] || die "Аргумент $1 требует значения"
				SOCKS5_PORT="$2"; shift 2 ;;
			--agent-port)
				[[ $# -ge 2 ]] || die "Аргумент $1 требует значения"
				AGENT_PORT="$2"; shift 2 ;;
			--3proxy-version)
				[[ $# -ge 2 ]] || die "Аргумент $1 требует значения"
				PROXY_3PROXY_VERSION="$2"; shift 2 ;;
			--telemt)        INSTALL_TELEMT="true";  shift ;;
			--socks5)        INSTALL_SOCKS5="true";  shift ;;
			--no-telemt)     INSTALL_TELEMT="false"; shift ;;
			--no-socks5)     INSTALL_SOCKS5="false"; shift ;;
			--uninstall)     UNINSTALL_MODE="true";  shift ;;
			-h|--help)       usage; exit 0 ;;
			*) die "Неизвестный аргумент: $1" ;;
		esac
	done

	if [[ -n "${PUBLIC_HOST:-}" ]]; then
		CLI_MODE="true"
	fi
}

usage() {
	cat << 'EOF'
Использование: bash proxy-install.sh [ОПЦИИ]

Без аргументов — интерактивный режим.

Опции:
  --host HOST            Домен или IP сервера (обязательно для CLI)
  --tls-domain DOMAIN    Домен для TLS-маскировки (обязательно для CLI)
  --bot-ip IP            IP сервера бота для firewall (обязательно для CLI)
  --telemt-port PORT     Порт Telemt (по умолчанию: 443)
  --socks5-port PORT     Порт SOCKS5 (по умолчанию: 1080)
  --agent-port PORT      Порт proxy-agent (по умолчанию: 8080)
  --3proxy-version VER   Версия 3proxy (по умолчанию: 0.9.5)
  --telemt               Установить Telemt (по умолчанию: да)
  --socks5               Установить 3proxy (по умолчанию: да)
  --no-telemt            Не устанавливать Telemt
  --no-socks5            Не устанавливать 3proxy
  --uninstall            Удалить все компоненты
  -h, --help             Показать справку

Пример:
  bash proxy-install.sh \
    --host mt-bel-1.closed.ru \
    --tls-domain closed.ru \
    --bot-ip 10.0.0.1
EOF
}

# ─── Сбор конфигурации ────────────────────────────────────────────────────────

collect_config_interactive() {
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

	validate_all_inputs

	echo ""
	info "Генерирую токен агента..."
	AGENT_TOKEN=$(openssl rand -hex 32)

	echo ""
	print_config
	print_cli_command

	local confirm
	prompt_yes_no confirm "Продолжить установку?" "y"
	if [[ "$confirm" == "false" ]]; then
		info "Установка отменена"
		exit 0
	fi
}

collect_config_cli() {
	TELEMT_PORT="${TELEMT_PORT:-$TELEMT_PORT_DEFAULT}"
	SOCKS5_PORT="${SOCKS5_PORT:-$SOCKS5_PORT_DEFAULT}"
	AGENT_PORT="${AGENT_PORT:-$AGENT_PORT_DEFAULT}"
	INSTALL_TELEMT="${INSTALL_TELEMT:-true}"
	INSTALL_SOCKS5="${INSTALL_SOCKS5:-true}"

	[[ -z "${PUBLIC_HOST:-}" ]]   && die "Не указан --host"
	[[ -z "${TLS_DOMAIN:-}" ]]    && die "Не указан --tls-domain"
	[[ -z "${BOT_SERVER_IP:-}" ]] && die "Не указан --bot-ip"

	validate_all_inputs

	AGENT_TOKEN=$(openssl rand -hex 32)

	header "Конфигурация (CLI)"
	print_config
}

validate_all_inputs() {
	validate_domain "$PUBLIC_HOST"
	validate_domain "$TLS_DOMAIN"
	validate_ip "$BOT_SERVER_IP"
	validate_port "$TELEMT_PORT"
	validate_port "$SOCKS5_PORT"
	validate_port "$AGENT_PORT"
}

print_config() {
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
}

print_cli_command() {
	local cmd="bash proxy-install.sh --host ${PUBLIC_HOST} --tls-domain ${TLS_DOMAIN} --bot-ip ${BOT_SERVER_IP}"

	if [[ "$TELEMT_PORT" != "$TELEMT_PORT_DEFAULT" ]]; then
		cmd+=" --telemt-port ${TELEMT_PORT}"
	fi
	if [[ "$SOCKS5_PORT" != "$SOCKS5_PORT_DEFAULT" ]]; then
		cmd+=" --socks5-port ${SOCKS5_PORT}"
	fi
	if [[ "$AGENT_PORT" != "$AGENT_PORT_DEFAULT" ]]; then
		cmd+=" --agent-port ${AGENT_PORT}"
	fi
	if [[ "$INSTALL_TELEMT" == "false" ]]; then
		cmd+=" --no-telemt"
	fi
	if [[ "$INSTALL_SOCKS5" == "false" ]]; then
		cmd+=" --no-socks5"
	fi

	echo -e "${BOLD}Команда для повторного запуска:${NC}"
	echo -e "  ${CYAN}${cmd}${NC}"
	echo ""
}

# ─── Шаги установки ─────────────────────────────────────────────────────────

step_system() {
	# Починить dpkg если был прерван
	dpkg --configure -a 2>/dev/null || true

	apt-get update -qq
	apt-get install -y -qq curl wget xxd openssl ufw

	cat > /etc/security/limits.d/99-proxy-install.conf << 'EOF'
nobody  soft  nofile  65536
nobody  hard  nofile  65536
*       soft  nofile  65536
*       hard  nofile  65536
EOF

	cat > /etc/sysctl.d/99-proxy-install.conf << 'EOF'
fs.file-max = 1000000
net.ipv4.tcp_tw_reuse = 1
net.core.somaxconn = 65535
EOF
	sysctl --system -q
}

step_telemt() {
	local libc_type
	libc_type=$(detect_libc)
	local arch
	arch=$(uname -m)

	local tmp_archive="/tmp/telemt.tar.gz"
	CLEANUP_FILES+=("$tmp_archive")

	wget -qO "$tmp_archive" \
		"https://github.com/telemt/telemt/releases/latest/download/telemt-${arch}-linux-${libc_type}.tar.gz"
	tar -xzf "$tmp_archive" -C /tmp
	mv /tmp/telemt /usr/local/bin/telemt
	chmod +x /usr/local/bin/telemt
	rm -f "$tmp_archive"

	mkdir -p /etc/telemt /var/lib/telemt

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
	chmod 640 /etc/telemt/telemt.toml
	chown nobody:nogroup /var/lib/telemt

	cat > /etc/systemd/system/telemt.service << 'EOF'
[Unit]
Description=Telemt MTProxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
WorkingDirectory=/var/lib/telemt
ExecStart=/usr/local/bin/telemt /etc/telemt/telemt.toml
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
}

step_3proxy() {
	local tmp_deb="/tmp/3proxy.deb"
	CLEANUP_FILES+=("$tmp_deb")

	wget -qO "$tmp_deb" \
		"https://github.com/3proxy/3proxy/releases/download/${PROXY_3PROXY_VERSION}/3proxy-${PROXY_3PROXY_VERSION}.x86_64.deb"

	dpkg -i "$tmp_deb" > /dev/null 2>&1 || apt-get install -f -y -qq
	rm -f "$tmp_deb"

	if ! dpkg -s 3proxy &>/dev/null; then
		echo "3proxy package not found after install" >&2
		return 1
	fi

	mkdir -p /etc/3proxy /usr/local/3proxy/logs /usr/local/3proxy/count
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

	systemctl enable 3proxy
	systemctl start 3proxy
}

step_agent() {
	mkdir -p /opt/proxy-agent

	if ! id proxy-agent &>/dev/null; then
		useradd --system --no-create-home --shell /usr/sbin/nologin proxy-agent
	fi

	cat > /opt/proxy-agent/env << EOF
AGENT_TOKEN=${AGENT_TOKEN}
AGENT_PORT=${AGENT_PORT}
EOF

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
		chown root:proxy-agent /etc/3proxy/passwd
		chmod 660 /etc/3proxy/passwd
	fi

	chmod 600 /opt/proxy-agent/env
	chown proxy-agent:proxy-agent /opt/proxy-agent/env
	chown proxy-agent:proxy-agent /opt/proxy-agent

	cat > /etc/systemd/system/proxy-agent.service << 'EOF'
[Unit]
Description=Proxy Agent
After=network.target telemt.service 3proxy.service

[Service]
User=proxy-agent
WorkingDirectory=/opt/proxy-agent
EnvironmentFile=/opt/proxy-agent/env
ExecStart=/opt/proxy-agent/proxy-agent
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

	systemctl daemon-reload
}

step_firewall() {
	ufw default deny incoming > /dev/null
	ufw default allow outgoing > /dev/null

	ufw allow 22/tcp > /dev/null 2>&1 || true

	if [[ "$INSTALL_TELEMT" == "true" ]]; then
		ufw allow "${TELEMT_PORT}/tcp" > /dev/null 2>&1 || true
	fi

	if [[ "$INSTALL_SOCKS5" == "true" ]]; then
		if [[ -n "$BOT_SERVER_IP" ]]; then
			ufw allow from "$BOT_SERVER_IP" to any port "$SOCKS5_PORT" > /dev/null 2>&1 || true
		else
			ufw allow "${SOCKS5_PORT}/tcp" > /dev/null 2>&1 || true
		fi
	fi

	if [[ -n "$BOT_SERVER_IP" ]]; then
		ufw allow from "$BOT_SERVER_IP" to any port "$AGENT_PORT" > /dev/null 2>&1 || true
	fi

	ufw --force enable > /dev/null
}

# ─── Итоговый вывод ───────────────────────────────────────────────────────────

print_summary() {
	echo ""
	echo -e "${BOLD}Параметры подключения:${NC}"
	echo ""

	if [[ "$INSTALL_TELEMT" == "true" ]]; then
		echo -e "  ${BOLD}Telemt (MTProxy):${NC}"
		echo -e "    Сервер:  ${CYAN}${PUBLIC_HOST}${NC}"
		echo -e "    Порт:    ${CYAN}${TELEMT_PORT}${NC}"
		echo -e "    Ссылки:  ${CYAN}journalctl -u telemt | grep 'EE-TLS\|DD:'${NC}"
		echo ""
	fi

	if [[ "$INSTALL_SOCKS5" == "true" ]]; then
		echo -e "  ${BOLD}3proxy (SOCKS5):${NC}"
		echo -e "    Сервер:  ${CYAN}${PUBLIC_HOST}${NC}"
		echo -e "    Порт:    ${CYAN}${SOCKS5_PORT}${NC}"
		echo -e "    Пароли:  ${CYAN}/etc/3proxy/passwd${NC}"
		echo ""
	fi

	echo -e "  ${BOLD}proxy-agent:${NC}"
	echo -e "    Порт:     ${CYAN}${AGENT_PORT}${NC}"
	echo -e "    Токен:    ${CYAN}${AGENT_TOKEN}${NC}"
	local backends=""
	if [[ "$INSTALL_TELEMT" == "true" ]]; then
		backends+="telemt"
	fi
	if [[ "$INSTALL_SOCKS5" == "true" ]]; then
		backends+="${backends:+, }socks5"
	fi
	echo -e "    Бэкенды: ${CYAN}${backends}${NC}"
	echo ""

	echo -e "  ${BOLD}Конфиги:${NC}"
	if [[ "$INSTALL_TELEMT" == "true" ]]; then
		echo -e "    ${CYAN}/etc/telemt/telemt.toml${NC}"
	fi
	if [[ "$INSTALL_SOCKS5" == "true" ]]; then
		echo -e "    ${CYAN}/etc/3proxy/3proxy.cfg${NC}"
	fi
	echo -e "    ${CYAN}/opt/proxy-agent/env${NC}"
	echo ""

	warn "Сохрани токен агента в надёжном месте!"
	echo ""

	echo -e "${BOLD}Следующий шаг — деплой бинарника агента:${NC}"
	echo -e "  ${CYAN}scp proxy-agent root@${PUBLIC_HOST}:/opt/proxy-agent/proxy-agent${NC}"
	echo -e "  ${CYAN}ssh root@${PUBLIC_HOST} 'chmod +x /opt/proxy-agent/proxy-agent && systemctl enable proxy-agent && systemctl start proxy-agent'${NC}"
}

# ─── Удаление ────────────────────────────────────────────────────────────────

uninstall() {
	header "Удаление proxy-install"

	if systemctl is-active --quiet telemt 2>/dev/null; then
		info "Останавливаю Telemt..."
		systemctl stop telemt
	fi
	if [[ -f /etc/systemd/system/telemt.service ]]; then
		systemctl disable telemt 2>/dev/null || true
		rm -f /etc/systemd/system/telemt.service
	fi
	rm -f /usr/local/bin/telemt
	rm -rf /etc/telemt /var/lib/telemt

	if systemctl is-active --quiet 3proxy 2>/dev/null; then
		info "Останавливаю 3proxy..."
		systemctl stop 3proxy
	fi
	if dpkg -s 3proxy &>/dev/null; then
		dpkg -r 3proxy 2>/dev/null || true
	fi
	rm -rf /etc/3proxy

	if systemctl is-active --quiet proxy-agent 2>/dev/null; then
		info "Останавливаю proxy-agent..."
		systemctl stop proxy-agent
	fi
	if [[ -f /etc/systemd/system/proxy-agent.service ]]; then
		systemctl disable proxy-agent 2>/dev/null || true
		rm -f /etc/systemd/system/proxy-agent.service
	fi
	rm -rf /opt/proxy-agent

	if id proxy-agent &>/dev/null; then
		userdel proxy-agent 2>/dev/null || true
	fi

	rm -f /etc/sysctl.d/99-proxy-install.conf
	rm -f /etc/security/limits.d/99-proxy-install.conf

	systemctl daemon-reload
	sysctl --system -q 2>/dev/null || true

	success "Все компоненты удалены"
	info "Правила ufw не удалены — проверь вручную: ufw status numbered"
}

# ─── Главная функция ──────────────────────────────────────────────────────────

main() {
	echo -e "${BOLD}${BLUE}"
	echo "  ┌──────────────────────────────────────┐"
	echo "  │        proxy-install v1.0.0          │"
	echo "  │  Telemt + 3proxy + proxy-agent       │"
	echo "  └──────────────────────────────────────┘"
	echo -e "${NC}"

	parse_args "$@"

	check_root
	check_os
	check_arch

	if [[ "$UNINSTALL_MODE" == "true" ]]; then
		uninstall
		return
	fi

	if [[ "$CLI_MODE" == "true" ]]; then
		collect_config_cli
	else
		collect_config_interactive
	fi

	# Считаем шаги
	local total=3  # system + agent + firewall
	if [[ "$INSTALL_TELEMT" == "true" ]]; then
		total=$((total + 1))
	fi
	if [[ "$INSTALL_SOCKS5" == "true" ]]; then
		total=$((total + 1))
	fi

	step_init "$total"

	echo -e "${BOLD}Установка:${NC}"
	echo ""

	run_step "Системные настройки"   step_system

	if [[ "$INSTALL_TELEMT" == "true" ]]; then
		run_step "Установка Telemt"   step_telemt
	fi
	if [[ "$INSTALL_SOCKS5" == "true" ]]; then
		run_step "Установка 3proxy"   step_3proxy
	fi

	run_step "Подготовка proxy-agent" step_agent
	run_step "Настройка firewall"     step_firewall

	echo ""
	echo -e "${GREEN}${BOLD}Установка завершена успешно!${NC}"

	print_summary
}

main "$@"
