#!/bin/bash
# https://github.com/Bud668/VPS-Proxy-Suite
# ==============================================================================
# Server & Proxy Manager (统一版)
# System Guardian v10.1.0 + Proxy Manager v13.2
# ==============================================================================

set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
export DEBIAN_FRONTEND=noninteractive

# ── 手动配置区（升级时只改这里）──────────────────────────────────
readonly SNELL_VERSION_OVERRIDE="v5.0.1"


# ==============================================================================
# SECTION 1: 全局常量
# ==============================================================================

readonly SCRIPT_VERSION="13.2"
readonly WORK_DIR="/opt/proxy-manager"
readonly CACHE_FILE="$WORK_DIR/server_info.cache"
readonly CACHE_TTL=86400
readonly LOCK_FILE="/run/server-manager.lock"
readonly UPDATE_CHECK_CACHE="$WORK_DIR/update_check.cache"
readonly UPDATE_CHECK_INTERVAL=86400
readonly RAND_PORT_MIN=10000
readonly RAND_PORT_MAX=65535
readonly DATA_MAX_LINES=86400
readonly ULIMIT_NOFILE=51200

# 变量初始化
SERVER_IP="127.0.0.1"
SERVER_COUNTRY_CODE="UN"
SERVER_COUNTRY_NAME="Unknown"
SERVER_CITY="Unknown"
_G_BBR_VER=""
_TMPFILES=()


# Snell/SS/Realm/SOCKS5 服务路径
readonly SNELL_USER="snellproxy"
readonly SNELL_BIN="/usr/local/bin/snell-server"
readonly SNELL_CONFIG_DIR="/etc/snell"
readonly SNELL_LEGACY_CONFIG="${SNELL_CONFIG_DIR}/snell-server.conf"
readonly SNELL_SERVICE_FILE="/etc/systemd/system/snell@.service"

# Shadowsocks-Rust 相关
readonly SS_USER="ssproxy"
readonly SS_BIN="/usr/local/bin/ssserver"
readonly SS_CONFIG_DIR="/etc/shadowsocks-rust"
readonly SS_CONFIG_FILE="${SS_CONFIG_DIR}/config.json"
readonly SS_ACL_FILE="${SS_CONFIG_DIR}/block.acl"
readonly SS_SERVICE_FILE="/etc/systemd/system/shadowsocks-rust.service"

# Realm 相关
readonly REALM_USER="realmproxy"
readonly REALM_BIN="/usr/local/bin/realm"
readonly REALM_CONFIG_DIR="/etc/realm"
readonly REALM_CONFIG_FILE="${REALM_CONFIG_DIR}/config.json"
readonly REALM_META_FILE="${REALM_CONFIG_DIR}/metadata.json"
readonly REALM_SERVICE_FILE="/etc/systemd/system/realm.service"

# SOCKS5 代理相关（专供 vps_monitor 使用）
readonly SOCKS5_USER="socks5proxy"
readonly SOCKS5_CONFIG_DIR="/etc/socks5-monitor"
readonly SOCKS5_CONFIG_FILE="${SOCKS5_CONFIG_DIR}/danted.conf"
readonly SOCKS5_META_FILE="${SOCKS5_CONFIG_DIR}/metadata.conf"
readonly SOCKS5_SERVICE_FILE="/etc/systemd/system/socks5-monitor.service"
readonly SOCKS5_LOG_FILE="/var/log/socks5-monitor.log"


TCPING_SERVICE_NAME="tcping-monitor"
TCPING_CONFIG_FILE="/etc/tcping-monitor.conf"

SSH_TG_SERVICE="ssh-tg-monitor"
SSH_TG_CONF="/etc/ssh-tg-monitor.conf"
SSH_TG_SCRIPT="/usr/local/bin/ssh-tg-monitor.sh"
F2B_WHITELIST="/etc/fail2ban/f2b-whitelist.conf"


# ==============================================================================
# SECTION 2: 颜色变量（统一 C_* 命名 + iptables 模块兼容别名）
# ==============================================================================

readonly C_RESET='\033[0m'
readonly C_RED='\033[1;31m'
readonly C_GREEN='\033[1;32m'
readonly C_YELLOW='\033[1;33m'
readonly C_BLUE='\033[1;34m'
readonly C_PURPLE='\033[1;35m'
readonly C_CYAN='\033[1;36m'
readonly C_WHITE='\033[1;37m'
readonly C_DIM='\033[2m'

# 兼容 iptables 模块中大量使用的旧名字（不影响功能）
RED=$C_RED; GREEN=$C_GREEN; YELLOW=$C_YELLOW; BLUE=$C_BLUE
PURPLE=$C_PURPLE; CYAN=$C_CYAN; WHITE=$C_WHITE; NC=$C_RESET
L_RED=$C_RED; L_GREEN=$C_GREEN; L_YELLOW=$C_YELLOW; L_BLUE=$C_BLUE
L_PURPLE=$C_PURPLE; L_CYAN=$C_CYAN; C_TEXT=$C_WHITE


# ==============================================================================
# SECTION 3: 日志与核心工具函数
# ==============================================================================

readonly LOG_FILE="/var/log/proxy-manager.log"
readonly LOG_LEVEL="${LOG_LEVEL:-INFO}"

log_message() {
    local level=$1
    shift
    local message="$*"
    local timestamp
    timestamp=$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')
    case "$LOG_LEVEL" in
        DEBUG) ;;
        INFO) [[ "$level" == "DEBUG" ]] && return ;;
        WARN) [[ "$level" == "DEBUG" || "$level" == "INFO" ]] && return ;;
        ERROR) [[ "$level" != "ERROR" ]] && return ;;
    esac
    if [[ ! -f "$LOG_FILE" ]]; then
        install -m 600 /dev/null "$LOG_FILE" 2>/dev/null || true
    fi
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

# 基础 msg 只做输出，不自己写日志 (避免包装函数重复写入)
msg() { printf '%b\n' "$@"; }
msg_info()    { msg "${C_GREEN}[信息]${C_RESET} $1"; log_message "INFO"  "$1"; }
msg_warn()    { msg "${C_YELLOW}[警告]${C_RESET} $1"; log_message "WARN"  "$1"; }
msg_error()   { msg "${C_RED}[错误]${C_RESET} $1" >&2; log_message "ERROR" "$1"; }
msg_step()    { msg "${C_BLUE}[步骤]${C_RESET} $1"; log_message "INFO"  "$1"; }
msg_success() { msg "${C_GREEN}[成功]${C_RESET} $1"; log_message "INFO"  "$1"; }
cleanup() {
    rm -f "$LOCK_FILE" 2>/dev/null || true
}
trap cleanup EXIT

die() {
    msg_error "$1"
    exit 1
}

acquire_lock() {
    local _pid
    _pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    exec 9>"$LOCK_FILE"
    if ! flock -n 9 2>/dev/null; then
        if [[ "$_pid" =~ ^[0-9]+$ ]] && kill -0 "$_pid" >/dev/null 2>&1; then
            echo -e "${C_RED}错误: 脚本已在运行 (PID: ${_pid})。${C_RESET}" >&2
        else
            echo -e "${C_RED}错误: 无法获取锁文件 ${LOCK_FILE}。${C_RESET}" >&2
        fi
        exit 1
    fi
    : > "$LOCK_FILE"
    echo $$ >&9
    chmod 600 "$LOCK_FILE" 2>/dev/null || true
}

get_flag_emoji() {
    local country_code=$1
    case "$country_code" in
        "US") printf "🇺🇸" ;; "CN") printf "🇨🇳" ;; "JP") printf "🇯🇵" ;;
        "KR") printf "🇰🇷" ;; "SG") printf "🇸🇬" ;; "HK") printf "🇭🇰" ;;
        "TW") printf "🇹🇼" ;; "GB") printf "🇬🇧" ;; "DE") printf "🇩🇪" ;;
        "FR") printf "🇫🇷" ;; "CA") printf "🇨🇦" ;; "AU") printf "🇦🇺" ;;
        "RU") printf "🇷🇺" ;; "IN") printf "🇮🇳" ;; "BR") printf "🇧🇷" ;;
        "NL") printf "🇳🇱" ;; "IT") printf "🇮🇹" ;; "ES") printf "🇪🇸" ;;
        *) printf "🌐" ;;
    esac
}

get_latest_github_release() {
    local repo_url=$1
    local fallback_version="${2:-}"
    local latest_tag

    # 尝试获取，如果失败则静默
    latest_tag=$(curl -s --max-time 10 --retry 2 "https://api.github.com/repos/${repo_url}/releases/latest" | jq -r '.tag_name' 2>/dev/null)

    if [[ -z "$latest_tag" || "$latest_tag" == "null" ]]; then
        if [[ -n "$fallback_version" ]]; then
            msg_warn "无法连接 Github API (可能触发限流)，将使用保底版本: ${fallback_version}"
            echo "$fallback_version"
        else
            msg_warn "无法连接 Github API，且无保底版本，请检查网络后重试。"
            return 1
        fi
        return 0
    fi
    echo "$latest_tag"
}


# ------------------------------------------------------------------------------
# 系统与环境检查
# ------------------------------------------------------------------------------

check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "此脚本需要root权限运行。请使用: sudo $0"
    fi
    return 0
}

# ==============================================================================
# SECTION 4: 系统工具函数（共享）
# ==============================================================================

detect_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) echo "amd64" ;;
        aarch64 | arm64) echo "aarch64" ;;
        armv7l) echo "armv7l" ;;
        *) echo "unsupported" ;;
    esac
}

SNELL_ARCH=$(detect_arch)
SS_ARCH=$SNELL_ARCH

get_public_ip() {
    local ip url
    for url in "https://api.ipify.org" "https://ip.sb" "https://ifconfig.me" "https://ipv4.icanhazip.com"; do
        ip=$(curl -4 -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            printf '%s' "$ip"; return 0
        fi
    done
    echo "<获取失败，请手动填写>"
}


show_spinner() {
    local pid=$1
    local message=$2
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0

    tput civis 2>/dev/null
    while kill -0 "$pid" 2>/dev/null; do
        i=$(((i + 1) % ${#spin}))
        printf "\r${YELLOW}%s %s${NC}" "$message" "${spin:$i:1}"
        sleep 0.1
    done
    tput cnorm 2>/dev/null
    printf "\r%s\r" "$(tput el)"
}

check_package_manager_lock() {
    local lock_files=(
        "/var/lib/dpkg/lock-frontend"
        "/var/lib/dpkg/lock"
        "/var/lib/apt/lists/lock"
    )
    for lock_file in "${lock_files[@]}"; do
        if fuser "$lock_file" >/dev/null 2>&1; then
            echo -e "${RED}错误: 包管理器被占用 ($lock_file)。${NC}"
            return 1
        fi
    done
    return 0
}

pause() {
    echo
    printf "${C_BLUE}按任意键返回主菜单...${C_RESET}\n"
    read -rsn1
}

open_firewall_port() {
    local port=$1
    msg_step "配置防火墙开放端口 ${port}..."
    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        ufw allow "$port" >/dev/null
    elif systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="${port}/tcp" &>/dev/null
        firewall-cmd --permanent --add-port="${port}/udp" &>/dev/null
        firewall-cmd --reload &>/dev/null
    elif command -v iptables &>/dev/null; then
        iptables -C INPUT -p tcp --dport "$port" -j ACCEPT &>/dev/null || iptables -I INPUT 1 -p tcp --dport "$port" -j ACCEPT
        iptables -C INPUT -p udp --dport "$port" -j ACCEPT &>/dev/null || iptables -I INPUT 1 -p udp --dport "$port" -j ACCEPT
        
        # 优先使用 netfilter-persistent 保存
        if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save >/dev/null 2>&1
        else
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null
        fi
    fi
}

close_firewall_port() {
    local port=$1

    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        ufw delete allow "$port" >/dev/null
    elif systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --remove-port="${port}/tcp" &>/dev/null
        firewall-cmd --permanent --remove-port="${port}/udp" &>/dev/null
        firewall-cmd --reload &>/dev/null
    elif command -v iptables &>/dev/null; then
        iptables -D INPUT -p tcp --dport "$port" -j ACCEPT &>/dev/null || true
        iptables -D INPUT -p udp --dport "$port" -j ACCEPT &>/dev/null || true
        
        if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save >/dev/null
        else
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null
        fi
    fi
    printf "${C_GREEN}已尝试删除防火墙规则 (Port: %s)${C_RESET}\n" "$port"
}


# ==============================================================================
# SECTION 5: 统一 Telegram 基础设施
# ==============================================================================

readonly TG_CONF="/etc/ssh-tg-monitor.conf"

# 写入 SSH TG 配置（TG_CONF only，各监控独立管理自己的 Token）
_write_tg_conf() {
    local _tok="$1" _chat="$2" _srv="$3" _mon="$4" _quota="$5"
    {
        printf 'TG_BOT_TOKEN=%s\n' "$_tok"
        printf 'TG_CHAT_ID=%s\n'   "$_chat"
        [[ -n "$_srv"   ]] && printf 'SERVER_NAME="%s"\n'   "$_srv"
        [[ -n "$_mon"   ]] && printf 'TG_CHAT_MONITOR=%s\n' "$_mon"
        [[ -n "$_quota" ]] && printf 'TG_CHAT_QUOTA=%s\n'   "$_quota"
    } > "$TG_CONF"
    chmod 600 "$TG_CONF"
}

# 写入 Relay 监控配置
_write_monitor_conf() {
    local _tok="$1" _chat="$2"
    local _mon_dir="/opt/proxy-manager/monitor"
    mkdir -p "$_mon_dir"
    printf "TG_BOT_TOKEN='%s'\nTG_CHAT_ID='%s'\n" "$_tok" "$_chat" > "${_mon_dir}/config.conf"
    chmod 600 "${_mon_dir}/config.conf"
}

# 写入配额 TG 配置
_write_quota_tg_conf() {
    local _tok="$1" _chat="$2"
    local _quota_dir="/opt/proxy-manager/quota"
    [[ -d "$_quota_dir" ]] || mkdir -p "$_quota_dir"
    printf "TG_BOT_TOKEN='%s'\nTG_CHAT_ID='%s'\n" "$_tok" "$_chat" > "${_quota_dir}/tg.conf"
    chmod 600 "${_quota_dir}/tg.conf"
}

# 读取并保存 TG Token/Chat ID；成功返回 0，失败返回 1
# $1 = SERVER_NAME（可为空）
_tg_input_tokens() {
    local _srv="${1:-}"
    printf "  粘贴配置，支持 # 注释行和空行，自动跳过:\n"
    printf "  顺序: SSH Token/Chat ID → Realm Token/Chat ID → 配额 Token/Chat ID\n>>> "
    local _vals=() _vline
    while [[ ${#_vals[@]} -lt 6 ]]; do
        read -r _vline < /dev/tty
        _vline="${_vline#"${_vline%%[![:space:]]*}"}"
        _vline="${_vline%"${_vline##*[![:space:]]}"}"
        [[ "$_vline" =~ ^# ]] && continue
        [[ -z "$_vline" ]] && continue
        _vals+=("$_vline")
    done
    local _new_tok="${_vals[0]}" _new_chat="${_vals[1]}"
    local _rm_tok2="${_vals[2]}"  _rm_chat2="${_vals[3]}"
    local _qt_tok2="${_vals[4]}"  _qt_chat2="${_vals[5]}"
    if [[ -z "$_new_tok" || -z "$_new_chat" ]]; then
        printf "  ${C_RED}SSH Token 或 Chat ID 不能为空${C_RESET}\n"; return 1
    fi
    printf "  正在验证 Bot..."
    local _resp; _resp=$(curl -s --max-time 8 "https://api.telegram.org/bot${_new_tok}/getMe" 2>/dev/null || true)
    if ! echo "$_resp" | grep -q '"ok":true'; then
        printf " ${C_RED}✗ 连接失败${C_RESET}\n"; return 1
    fi
    local _bot; _bot=$(echo "$_resp" | grep -oP '"username":"\K[^"]+' || echo "?")
    printf " ${C_GREEN}✓ @%s${C_RESET}\n" "$_bot"
    if [[ -z "$_srv" ]]; then
        local _gf; _gf=$(get_flag_emoji "${SERVER_COUNTRY_CODE:-UN}")
        _srv="${_gf} ${SERVER_COUNTRY_NAME:-Unknown}, ${SERVER_CITY:-Unknown}"
    fi
    _write_tg_conf "$_new_tok" "$_new_chat" "$_srv" "" ""
    [[ -n "$_rm_tok2" && -n "$_rm_chat2" ]] && _write_monitor_conf  "$_rm_tok2"  "$_rm_chat2"
    [[ -n "$_qt_tok2" && -n "$_qt_chat2" ]] && _write_quota_tg_conf "$_qt_tok2"  "$_qt_chat2"
    local _d_rm _d_qt
    _d_rm="${_rm_tok2:+${_rm_tok2:0:20}...}"; _d_rm="${_d_rm:-未设置}"
    _d_qt="${_qt_tok2:+${_qt_tok2:0:20}...}"; _d_qt="${_d_qt:-未设置}"
    printf "  SSH   : %s  %s\n  Realm : %s  %s\n  配额  : %s  %s\n" \
        "${_new_tok:0:20}..." "$_new_chat" \
        "$_d_rm" "${_rm_chat2:-未设置}" \
        "$_d_qt" "${_qt_chat2:-未设置}"
    printf "  ${C_GREEN}✓ 已保存${C_RESET}\n"
    printf "  ${C_CYAN}正在启动各监控服务...${C_RESET}\n"
    _setup_ssh_tg_monitor || true
    [[ -n "$_rm_tok2" && -n "$_rm_chat2" ]] && [[ -f "$REALM_BIN" ]] && { setup_config || true; }
    [[ -n "$_qt_tok2" && -n "$_qt_chat2" ]] && grep -q '^[0-9]' "$QUOTA_CONFIG" 2>/dev/null && { install_quota_services || true; }
    return 0
}

# 中央 TG 推送配置菜单
_do_tg_config() {
    while true; do
        clear
        printf "${C_CYAN}:: TG 推送配置 ::${C_RESET}\n\n"

        local _tok="" _chat="" _srv="" _mon="" _quota=""
        if [[ -f "$TG_CONF" ]]; then
            _tok=$(grep   "^TG_BOT_TOKEN="    "$TG_CONF" 2>/dev/null | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" || true)
            _chat=$(grep  "^TG_CHAT_ID="      "$TG_CONF" 2>/dev/null | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" || true)
            _srv=$(grep   "^SERVER_NAME="     "$TG_CONF" 2>/dev/null | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" || true)
            _mon=$(grep   "^TG_CHAT_MONITOR=" "$TG_CONF" 2>/dev/null | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" || true)
            _quota=$(grep "^TG_CHAT_QUOTA="   "$TG_CONF" 2>/dev/null | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" || true)
        fi

        # 读取各监控实际 Token 和 Chat ID
        local _rm_tok="" _rm_chat="" _qt_tok="" _qt_chat=""
        if [[ -f "$MONITOR_CONFIG" ]]; then
            _rm_tok=$(grep  "^TG_BOT_TOKEN=" "$MONITOR_CONFIG" 2>/dev/null | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" || true)
            _rm_chat=$(grep "^TG_CHAT_ID="   "$MONITOR_CONFIG" 2>/dev/null | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" || true)
        fi
        if [[ -f "$QUOTA_TG_CONFIG" ]]; then
            _qt_tok=$(grep  "^TG_BOT_TOKEN=" "$QUOTA_TG_CONFIG" 2>/dev/null | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" || true)
            _qt_chat=$(grep "^TG_CHAT_ID="   "$QUOTA_TG_CONFIG" 2>/dev/null | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" || true)
        fi
        local _ssh_tg_st _relay_st
        systemctl is-active --quiet "$SSH_TG_SERVICE" 2>/dev/null \
            && _ssh_tg_st="${C_GREEN}运行中${C_RESET}" || _ssh_tg_st="[-]"
        systemctl is-active --quiet relay-monitor 2>/dev/null \
            && _relay_st="${C_GREEN}运行中${C_RESET}" || _relay_st="[-]"

        local _d
        printf "  ${C_BLUE}[ SSH ]${C_RESET}   %b\n" "$_ssh_tg_st"
        _d="${_tok:+${_tok:0:20}...}"; printf "    Token  : %s\n" "${_d:-未设置}"
        printf "    Chat   : %s\n" "${_chat:-未设置}"
        printf "  ${C_BLUE}[ Realm ]${C_RESET} %b\n" "$_relay_st"
        _d="${_rm_tok:+${_rm_tok:0:20}...}"; printf "    Token  : %s\n" "${_d:-未设置}"
        printf "    Chat   : %s\n" "${_rm_chat:-未配置}"
        local _quota_st
        systemctl is-active --quiet quota-check.timer 2>/dev/null \
            && _quota_st="${C_GREEN}运行中${C_RESET}" || _quota_st="[-]"
        printf "  ${C_BLUE}[ 配额 ]${C_RESET}   %b\n" "$_quota_st"
        _d="${_qt_tok:+${_qt_tok:0:20}...}"; printf "    Token  : %s\n" "${_d:-未设置}"
        printf "    Chat   : %s\n" "${_qt_chat:-未配置}"

        printf "\n  ${C_GREEN}1.${C_RESET} 设置 Token & Chat ID\n"
        printf "  ${C_GREEN}2.${C_RESET} SSH 监控\n"
        printf "  ${C_GREEN}3.${C_RESET} Realm 监控\n"
        printf "  ${C_GREEN}4.${C_RESET} 配额 监控\n"
        printf "  ${C_GREEN}5.${C_RESET} 测试推送\n"
        printf "  ${C_GREEN}0.${C_RESET} 返回\n"
        printf "\n${C_CYAN}请选择 [0-5]: ${C_RESET}"
        local _tg_ch; read -r _tg_ch < /dev/tty

        case "$_tg_ch" in
            1)  printf "\n"; _tg_input_tokens "$_srv" || true; pause ;;
            2)  # SSH 监控 sub-menu
                while true; do
                    clear
                    printf "${C_CYAN}:: SSH 监控 ::${C_RESET}\n\n"
                    local _ss_st
                    systemctl is-active --quiet "$SSH_TG_SERVICE" 2>/dev/null \
                        && _ss_st="${C_GREEN}运行中${C_RESET}" || _ss_st="${C_RED}未运行${C_RESET}"
                    printf "  状态    : %b\n" "$_ss_st"
                    { [[ -n "$_chat" ]] && printf "  推送频道: ${C_CYAN}%s${C_RESET}\n" "$_chat" || printf "  推送频道: ${C_YELLOW}未设置${C_RESET}\n"; }
                    printf "\n  ${C_GREEN}1.${C_RESET} 设置 Token & Chat ID\n"
                    printf "  ${C_GREEN}2.${C_RESET} 配置并启动服务\n"
                    printf "  ${C_GREEN}3.${C_RESET} 查看日志\n"
                    printf "  ${C_GREEN}4.${C_RESET} 停止并卸载\n"
                    printf "  ${C_GREEN}0.${C_RESET} 返回\n"
                    printf "\n${C_CYAN}请选择 [0-4]: ${C_RESET}"
                    local _ssh_sub; read -r _ssh_sub < /dev/tty; printf "\n"
                    case $_ssh_sub in
                        1)  printf "  粘贴2行 (Token / Chat ID，回车跳过保持不变):\n>>> "
                            local _nt _nc; read -r _nt < /dev/tty; read -r _nc < /dev/tty
                            _nt=$(echo "$_nt" | tr -d '[:space:]'); _nc=$(echo "$_nc" | tr -d '[:space:]')
                            [[ -n "$_nt" ]] && _tok="$_nt"
                            [[ -n "$_nc" ]] && _chat="$_nc"
                            _write_tg_conf "$_tok" "$_chat" "$_srv" "$_mon" "$_quota"
                            printf "  ${C_CYAN}正在启动 SSH 推送服务...${C_RESET}\n"
                            _setup_ssh_tg_monitor || true
                            pause ;;
                        2)  _setup_ssh_tg_monitor; pause ;;
                        3)  clear
                            printf "${C_YELLOW}--- SSH 推送最近日志 (50条) ---${C_RESET}\n"
                            journalctl -u "$SSH_TG_SERVICE" --no-pager -n 50 2>/dev/null \
                                || printf "${C_YELLOW}暂无日志${C_RESET}\n"
                            pause ;;
                        4)  systemctl stop    "$SSH_TG_SERVICE" 2>/dev/null || true
                            systemctl disable "$SSH_TG_SERVICE" 2>/dev/null || true
                            rm -f "/etc/systemd/system/${SSH_TG_SERVICE}.service" \
                                  "$SSH_TG_SCRIPT" "$SSH_TG_CONF"
                            systemctl daemon-reload 2>/dev/null || true
                            printf "${C_GREEN}✓ SSH 推送服务已停止并移除${C_RESET}\n"
                            pause; break ;;
                        0|"") break ;;
                        *) msg_warn "无效选项"; printf "\n${C_GREEN}按任意键返回...${C_RESET}"; read -rsn1 ;;
                    esac
                done ;;
            3)  # Realm 监控
                while true; do
                    clear
                    printf "${C_CYAN}:: Realm 监控 ::${C_RESET}\n\n"
                    local _rm_st
                    [[ -f "$MONITOR_CONFIG" ]] \
                        && _rm_st="${C_GREEN}已配置${C_RESET}" || _rm_st="${C_RED}未配置${C_RESET}"
                    printf "  状态    : %b\n" "$_rm_st"
                    { [[ -n "$_rm_chat" ]] && printf "  推送频道: ${C_CYAN}%s${C_RESET}\n" "$_rm_chat" || printf "  推送频道: ${C_YELLOW}未配置${C_RESET}\n"; }
                    printf "\n  ${C_GREEN}1.${C_RESET} 设置 Token & Chat ID\n"
                    printf "  ${C_GREEN}2.${C_RESET} 配置并启动服务\n"
                    printf "  ${C_GREEN}3.${C_RESET} 推送稳定性排名\n"
                    printf "  ${C_GREEN}4.${C_RESET} 查看实时统计\n"
                    printf "  ${C_GREEN}5.${C_RESET} 查看探测日志\n"
                    printf "  ${C_GREEN}6.${C_RESET} 卸载服务\n"
                    printf "  ${C_GREEN}0.${C_RESET} 返回\n"
                    printf "\n${C_CYAN}请选择 [0-6]: ${C_RESET}"
                    local _rm_sub; read -r _rm_sub < /dev/tty; printf "\n"
                    case $_rm_sub in
                        1)  printf "  粘贴2行 (Token / Chat ID，回车跳过保持不变):\n>>> "
                            local _rmt _rmc; read -r _rmt < /dev/tty; read -r _rmc < /dev/tty
                            _rmt=$(echo "$_rmt" | tr -d '[:space:]'); _rmc=$(echo "$_rmc" | tr -d '[:space:]')
                            [[ -n "$_rmt" ]] && _rm_tok="$_rmt"
                            [[ -n "$_rmc" ]] && _rm_chat="$_rmc"
                            _write_monitor_conf "$_rm_tok" "$_rm_chat"
                            if [[ -f "$REALM_BIN" ]]; then
                                printf "  ${C_CYAN}正在启动 Realm 监控服务...${C_RESET}\n"
                                setup_config || true
                            else
                                printf "  ${C_YELLOW}Realm 未安装，跳过启动${C_RESET}\n"
                            fi
                            pause ;;
                        2)  setup_config || true; pause ;;
                        3)  load_config; send_daily_report || true
                            printf "\n${C_GREEN}按任意键返回...${C_RESET}"; read -rsn1 ;;
                        4)  show_relay_status ;;
                        5)  journalctl -u relay-monitor.service -f -o cat &
                            local _rmpid=$!
                            read -n 1 -s -r -p "按任意键返回..."
                            kill "$_rmpid" 2>/dev/null || true
                            wait "$_rmpid" 2>/dev/null || true ;;
                        6)  uninstall_relay_services || true; break ;;
                        0|"") break ;;
                        *) msg_warn "无效选项"; printf "\n${C_GREEN}按任意键返回...${C_RESET}"; read -rsn1 ;;
                    esac
                done ;;
            4)  # 配额 监控
                while true; do
                    clear
                    printf "${C_CYAN}:: 配额 监控 ::${C_RESET}\n\n"
                    { [[ -n "$_qt_chat" ]] && printf "  配额频道: ${C_CYAN}%s${C_RESET}\n" "$_qt_chat" || printf "  配额频道: ${C_YELLOW}未配置${C_RESET}\n"; }
                    printf "\n  ${C_GREEN}1.${C_RESET} 设置 Token & Chat ID\n"
                    printf "  ${C_GREEN}2.${C_RESET} 立即推送配额日报\n"
                    printf "  ${C_GREEN}0.${C_RESET} 返回\n"
                    printf "\n${C_CYAN}请选择 [0-2]: ${C_RESET}"
                    local _quota_sub; read -r _quota_sub < /dev/tty; printf "\n"
                    case $_quota_sub in
                        1)  printf "  粘贴2行 (Token / Chat ID，回车跳过保持不变):\n>>> "
                            local _qtt _qtc; read -r _qtt < /dev/tty; read -r _qtc < /dev/tty
                            _qtt=$(echo "$_qtt" | tr -d '[:space:]'); _qtc=$(echo "$_qtc" | tr -d '[:space:]')
                            [[ -n "$_qtt" ]] && _qt_tok="$_qtt"
                            [[ -n "$_qtc" ]] && _qt_chat="$_qtc"
                            _write_quota_tg_conf "$_qt_tok" "$_qt_chat"
                            printf "  ${C_GREEN}✓ 已保存${C_RESET}\n"
                            if grep -q '^[0-9]' "$QUOTA_CONFIG" 2>/dev/null; then
                                printf "  ${C_CYAN}正在启动配额监控服务...${C_RESET}\n"
                                install_quota_services || true
                            else
                                printf "  ${C_YELLOW}未配置流量配额，跳过启动${C_RESET}\n"
                            fi
                            pause ;;
                        2)  load_config; quota_daily_report || true; pause ;;
                        0|"") break ;;
                        *) msg_warn "无效选项"; printf "\n${C_GREEN}按任意键返回...${C_RESET}"; read -rsn1 ;;
                    esac
                done ;;
            5)  # 测试推送（分别测3个频道）
                local _ts; _ts=$(date '+%H:%M:%S')
                local _tr
                printf "  SSH   : "
                if [[ -n "$_tok" && -n "$_chat" ]]; then
                    _tr=$(curl -s --max-time 8 "https://api.telegram.org/bot${_tok}/sendMessage" \
                        -d "chat_id=${_chat}&text=🔔+SSH+测试推送+${_ts}" 2>/dev/null || true)
                    echo "$_tr" | grep -q '"ok":true' \
                        && printf "${C_GREEN}✓ 成功${C_RESET}\n" || printf "${C_RED}✗ 失败${C_RESET}\n"
                else
                    printf "${C_YELLOW}未配置${C_RESET}\n"
                fi
                printf "  Realm : "
                if [[ -n "$_rm_tok" && -n "$_rm_chat" ]]; then
                    _tr=$(curl -s --max-time 8 "https://api.telegram.org/bot${_rm_tok}/sendMessage" \
                        -d "chat_id=${_rm_chat}&text=🔔+Realm+测试推送+${_ts}" 2>/dev/null || true)
                    echo "$_tr" | grep -q '"ok":true' \
                        && printf "${C_GREEN}✓ 成功${C_RESET}\n" || printf "${C_RED}✗ 失败${C_RESET}\n"
                else
                    printf "${C_YELLOW}未配置${C_RESET}\n"
                fi
                printf "  配额  : "
                if [[ -n "$_qt_tok" && -n "$_qt_chat" ]]; then
                    _tr=$(curl -s --max-time 8 "https://api.telegram.org/bot${_qt_tok}/sendMessage" \
                        -d "chat_id=${_qt_chat}&text=🔔+配额+测试推送+${_ts}" 2>/dev/null || true)
                    echo "$_tr" | grep -q '"ok":true' \
                        && printf "${C_GREEN}✓ 成功${C_RESET}\n" || printf "${C_RED}✗ 失败${C_RESET}\n"
                else
                    printf "${C_YELLOW}未配置${C_RESET}\n"
                fi
                pause ;;
            0|"") return ;;
            *) continue ;;
        esac
    done
}

_TG_LAST_MSG_ID=""

_tg_send_chunk() {
    local text="$1"
    _TG_LAST_MSG_ID=""
    local _cfg _old_umask
    _old_umask=$(umask)
    umask 177
    _cfg=$(mktemp)
    umask "$_old_umask"
    trap "rm -f '$_cfg'" RETURN
    printf 'max-time = 15\nurl = "https://api.telegram.org/bot%s/sendMessage"\ndata = "chat_id=%s"\ndata = "parse_mode=HTML"\n' \
        "$TG_BOT_TOKEN" "$TG_CHAT_ID" > "$_cfg"

    local attempt resp
    for attempt in 1 2 3; do
        resp=$(printf '%s' "$text" | curl -K "$_cfg" --data-urlencode "text@-" -s 2>/dev/null)
        if printf '%s' "$resp" | grep -q '"ok":true'; then
            _TG_LAST_MSG_ID=$(printf '%s' "$resp" | grep -o '"message_id":[0-9]*' | grep -o '[0-9]*')
            rm -f "$_cfg"
            return 0
        fi
        [[ $attempt -lt 3 ]] && sleep 5
    done
    rm -f "$_cfg"
    msg_warn "Telegram 推送失败（已重试 3 次），请检查网络或 Bot 配置"
    return 1
}

_tg_edit_keyboard() {
    local msg_id="$1" keyboard_json="$2"
    curl -s -m 10 \
        "https://api.telegram.org/bot${TG_BOT_TOKEN}/editMessageReplyMarkup" \
        -H 'Content-Type: application/json' \
        -d "{\"chat_id\":\"${TG_CHAT_ID}\",\"message_id\":${msg_id},\"reply_markup\":{\"inline_keyboard\":${keyboard_json}}}" \
        >/dev/null 2>&1 || true
}

send_telegram() {
    local text="$1"
    local server_label="${2:-}"
    [[ -z "${TG_BOT_TOKEN:-}" || -z "${TG_CHAT_ID:-}" ]] && return 0

    # 消息不超限直接发送
    if [[ ${#text} -le 4050 ]]; then
        _tg_send_chunk "$text"
        return
    fi

    # 超限时在 ╌ 分隔符处分段，每段同时限制字符数(≤3800)和条目数(≤8)
    # 8条/页确保 <u><b> 双标签不超 Telegram 100 entities/msg 限制
    local limit=3800 entry_limit=14 chunk="" line sep_count=0
    local -a chunks=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^╌ && -n "$chunk" ]] && \
           [[ ${#chunk} -gt $limit || $sep_count -ge $entry_limit ]]; then
            chunks+=("$chunk")
            chunk="$line"
            sep_count=1
        else
            chunk="${chunk:+${chunk}$'\n'}${line}"
            [[ "$line" =~ ^╌ ]] && sep_count=$((sep_count + 1))
        fi
    done <<< "$text"
    [[ -n "$chunk" ]] && chunks+=("$chunk")

    local total=${#chunks[@]}
    # 只有一段（无可用切割点）直接发送
    if [[ $total -eq 1 ]]; then
        _tg_send_chunk "${chunks[0]}"
        return
    fi

    # 多段：每段首行加「标题 (N/total)」，第二行若是时间行(🕐)也重复
    local title_line1 title_line2
    title_line1=$(printf '%s' "$text" | head -1)
    title_line2=$(printf '%s' "$text" | sed -n '2p')
    [[ "$title_line2" != 🕐* ]] && title_line2=""

    local -a msg_ids=()
    local i
    for (( i=0; i<total; i++ )); do
        local part="${chunks[$i]}"
        local label="$((i+1))/${total}"
        if [[ $i -eq 0 ]]; then
            if [[ -n "$title_line2" ]]; then
                local _rest="${part#*$'\n'}"
                local _body="${_rest#*$'\n'}"
                part="${title_line1}"$'\n'"${title_line2} (${label})"$'\n'"${_body}"
            else
                part="${title_line1} (${label})"$'\n'"${part#*$'\n'}"
            fi
        else
            if [[ -n "$title_line2" ]]; then
                part="${title_line1}"$'\n'"${title_line2} (${label})"$'\n'"${part}"
            else
                part="${title_line1} (${label})"$'\n'"${part}"
            fi
        fi
        _tg_send_chunk "$part" || return 1
        msg_ids+=("$_TG_LAST_MSG_ID")
    done

    # 添加翻页按钮（仅限频道，且成功获取到 message_id 时）
    if [[ -n "${msg_ids[0]:-}" && "${TG_CHAT_ID}" == -100* ]]; then
        local channel_num="${TG_CHAT_ID#-100}"
        local last=$((total - 1))
        local base_url="https://t.me/c/${channel_num}"
        local prefix="${server_label:+${server_label} · }"
        for (( i=0; i<total; i++ )); do
            [[ -z "${msg_ids[$i]:-}" ]] && continue
            local kb="[" row="" col=0
            for (( j=0; j<total; j++ )); do
                local btn_label
                [[ $j -eq $i ]] \
                    && btn_label="${prefix}▶ $((j+1))/${total}" \
                    || btn_label="${prefix}$((j+1))/${total}"
                [[ $col -gt 0 ]] && row+=","
                row+="{\"text\":\"${btn_label}\",\"url\":\"${base_url}/${msg_ids[$j]}\"}"
                col=$(( col + 1 ))
                if [[ $col -eq 2 ]]; then
                    [[ "$kb" != "[" ]] && kb+=","
                    kb+="[${row}]"
                    row=""; col=0
                fi
            done
            [[ -n "$row" ]] && { [[ "$kb" != "[" ]] && kb+=","; kb+="[${row}]"; }
            kb+="]"
            _tg_edit_keyboard "${msg_ids[$i]}" "$kb"
        done
    fi
    return 0
}


# 设置/修改服务器名称（统一入口，写入 TG_CONF）
_set_server_name() {
    local _cur_name=""
    [[ -f "$TG_CONF" ]] && _cur_name=$(grep "^SERVER_NAME=" "$TG_CONF" 2>/dev/null | cut -d= -f2- || true)
    echo -e "  当前名称: ${C_YELLOW}${_cur_name:-（未设置）}${C_RESET}"
    echo -ne "  输入服务器名称 (格式如 🇭🇰SR_HK_Std，回车跳过): "
    local _new_name
    read -r _new_name < /dev/tty
    [[ -z "$_new_name" ]] && return 0
    if [[ -f "$TG_CONF" ]]; then
        if grep -q "^SERVER_NAME=" "$TG_CONF" 2>/dev/null; then
            sed -i "s|^SERVER_NAME=.*|SERVER_NAME=${_new_name}|" "$TG_CONF"
        else
            echo "SERVER_NAME=${_new_name}" >> "$TG_CONF"
        fi
    else
        printf 'SERVER_NAME=%s\n' "$_new_name" > "$TG_CONF"
        chmod 600 "$TG_CONF"
    fi
    echo -e "  ${C_GREEN}✓ 服务器名称已设为: ${_new_name}${C_RESET}"
    if systemctl is-active --quiet "$SSH_TG_SERVICE" 2>/dev/null; then
        systemctl restart "$SSH_TG_SERVICE" 2>/dev/null || true
        echo -e "  ${C_GREEN}✓ SSH TG 服务已重启${C_RESET}"
    fi
}


# ==============================================================================
# SECTION 6: 系统管理模块（来自 iptables+rely.sh）
# ==============================================================================

_safe_iptables_remove_rule() {
    local pattern="$1"
    local grep_flag="${2:--F}"
    local _tmp _bak
    if ! _tmp=$(mktemp /root/.iptfw-XXXXXX 2>/dev/null); then
        echo -e "${RED}错误: mktemp 失败，跳过防火墙规则操作${NC}" >&2
        return 1
    fi
    if ! _bak=$(mktemp /root/.iptfw-bak-XXXXXX 2>/dev/null); then
        rm -f "$_tmp"
        echo -e "${RED}错误: mktemp 失败，跳过防火墙规则操作${NC}" >&2
        return 1
    fi
    chmod 600 "$_tmp" "$_bak"
    local _orig _filtered orig_lines filtered_lines
    _orig=$(iptables-save 2>/dev/null) || { rm -f "$_tmp" "$_bak"; return 1; }
    # 先将当前规则保存到备份，供 restore 失败时回滚
    echo "$_orig" > "$_bak"
    _filtered=$(echo "$_orig" | grep -v "$grep_flag" "$pattern" || true)
    orig_lines=$(echo "$_orig" | wc -l)
    filtered_lines=$(echo "$_filtered" | wc -l)
    if [ "$orig_lines" -gt 20 ] && [ "$filtered_lines" -lt $(( orig_lines * 50 / 100 )) ]; then
        echo -e "${RED}错误: 规则过滤结果异常 (${filtered_lines}/${orig_lines} 行)，已中止还原${NC}" >&2
        rm -f "$_tmp" "$_bak"
        return 1
    fi
    echo "$_filtered" > "$_tmp"
    if ! iptables-restore < "$_tmp"; then
        echo -e "${RED}错误: iptables-restore 失败，正在回滚...${NC}" >&2
        iptables-restore < "$_bak" 2>/dev/null || true
        rm -f "$_tmp" "$_bak"
        return 1
    fi
    rm -f "$_tmp" "$_bak"
    return 0
}

# iptables 规则持久化：写入对应发行版的文件路径并调用持久化工具
# 支持 Debian/Ubuntu（/etc/iptables/rules.v4 + netfilter-persistent）
# 和 RHEL/CentOS（/etc/sysconfig/iptables + service iptables save）
_persist_iptables() {
    local _save_file="/etc/iptables/rules.v4"
    [ -f /etc/redhat-release ] && _save_file="/etc/sysconfig/iptables"
    mkdir -p "$(dirname "$_save_file")"
    iptables-save > "$_save_file" || { echo -e "${RED}错误: iptables-save 写入失败${NC}" >&2; return 1; }
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null 2>&1 || true
    elif command -v service &>/dev/null && [ -f /etc/redhat-release ]; then
        service iptables save >/dev/null 2>&1 || true
    fi
}


# ==============================================================================
# 共享工具函数 (供多个核心功能复用)
# ==============================================================================

# 写入 IPv6 禁用配置并同步清理 /etc/sysctl.conf 残留条目
_write_disable_ipv6_conf() {
    cat > /etc/sysctl.d/99-disable-ipv6.conf <<'IPVCEOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
IPVCEOF
    if [ -f "/etc/sysctl.conf" ]; then
        sed -i '/net.ipv6.conf.all.disable_ipv6/d' /etc/sysctl.conf
        sed -i '/net.ipv6.conf.default.disable_ipv6/d' /etc/sysctl.conf
        sed -i '/net.ipv6.conf.lo.disable_ipv6/d' /etc/sysctl.conf
    fi
    sysctl --system >/dev/null 2>&1 || true
}

# Swap 检测与自动创建（未启用时按磁盘剩余空间动态分配）
_ensure_swap() {
    local _free_kb _free_mb _size_mb=1024
    # 若存在临时 Swap 标志（XanMod 安装前创建的），先拆除再按实际磁盘重建
    if [ -f /tmp/.swap_is_temp ]; then
        echo -e "  ${YELLOW}检测到临时 Swap，按当前磁盘重新计算...${NC}"
        swapoff /swapfile 2>/dev/null || true
        rm -f /swapfile /tmp/.swap_is_temp
        sed -i '/\/swapfile/d' /etc/fstab 2>/dev/null || true
    fi
    local _swap_kb _swap_mb
    _swap_kb=$(grep SwapTotal /proc/meminfo | awk '{print $2}' || echo 0)
    _swap_mb=$(( ${_swap_kb:-0} / 1024 ))
    if [ "$_swap_mb" -gt 0 ]; then
        echo -e "  Swap 状态: ${GREEN}已启用 (${_swap_mb} MB)${NC}"
        return
    fi
    _free_kb=$(df -k / | awk 'NR==2 {print $4}' || echo 0)
    _free_mb=$(( ${_free_kb:-0} / 1024 ))
    [ "$_free_mb" -ge 20480 ] && _size_mb=2048
    [ "$_free_mb" -lt 2048  ] && _size_mb=512
    echo -e "  ${YELLOW}未启用 Swap，磁盘剩余 ${_free_mb}MB → 创建 ${_size_mb}MB...${NC}"
    if [ ! -f /swapfile ]; then
        fallocate -l "${_size_mb}M" /swapfile 2>/dev/null || \
            dd if=/dev/zero of=/swapfile bs=1M count="$_size_mb" status=none
    fi
    chmod 600 /swapfile
    if ! swapon --show 2>/dev/null | grep -q '/swapfile'; then
        mkswap /swapfile >/dev/null 2>&1 || { echo -e "  ${RED}✗ mkswap 失败${NC}"; return; }
        swapon /swapfile >/dev/null 2>&1 || { echo -e "  ${RED}✗ swapon 失败${NC}"; return; }
    fi
    grep -q '/swapfile' /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
    echo -e "  ${GREEN}✓ /swapfile (${_size_mb}MB) 已创建并挂载${NC}"
}

# 8 线程并发测速 → Cloudflare，结果写入全局 _BW_MBPS
# 调用前先 printf "测速中..." 提示，本函数用 \r 覆盖同一行打印结果
_measure_bandwidth() {
    local _default=${1:-1000}
    _BW_MBPS=$_default
    local _tmpdir _threads=8 _i _pid _pids=()
    _tmpdir=$(mktemp -d) || { _BW_MBPS=$_default; return 0; }
    for _i in $(seq 1 $_threads); do
        curl -4 -o /dev/null -s --max-time 15 \
            -w "%{speed_download}" \
            "https://speed.cloudflare.com/__down?bytes=10485760" \
            > "${_tmpdir}/spd_${_i}" 2>/dev/null &
        _pids+=($!)
    done
    # 注册信号处理：Ctrl+C 时杀掉全部 curl 子进程，避免孤儿进程继续占用带宽
    trap 'kill "${_pids[@]}" 2>/dev/null; rm -rf "$_tmpdir"; trap - INT TERM' INT TERM
    for _pid in "${_pids[@]}"; do wait "$_pid" 2>/dev/null || true; done
    trap - INT TERM
    local _total_bytes=0 _v
    for _i in $(seq 1 $_threads); do
        _v=$(cat "${_tmpdir}/spd_${_i}" 2>/dev/null)
        _v=${_v%%.*}
        [[ "${_v:-0}" =~ ^[0-9]+$ ]] && _total_bytes=$(( _total_bytes + _v ))
    done
    rm -rf "$_tmpdir"
    if [[ $(( _total_bytes / 1048576 )) -gt 0 ]]; then
        _BW_MBPS=$(( _total_bytes * 8 / 1000000 ))
        [ "$_BW_MBPS" -lt 1 ] && _BW_MBPS=1
        echo -e "\r  实测下行: ${GREEN}${_BW_MBPS} Mbps${NC}                              "
    else
        echo -e "\r  ${YELLOW}⚠ 测速失败，使用默认值 ${_default} Mbps${NC}              "
    fi
}

# 根据物理内存和带宽计算 sysctl 动态参数，结果写入全局 _P_* 变量
_calc_sysctl_params() {
    local _pmem=$1 _bw=$2
    local _rmem_ram_cap=$(( _pmem * 1048576 / 10 ))  # 10% RAM 上限
    # rmem_max = BDP @ 200ms RTT (代理中继最远链路基准)
    # 旧值 bw*50000 = BDP@400ms, BBR 探测窗口是实际 BDP 的 4× → 拥塞路径(HK-SEA/Chicago)重传爆表
    # cap=64MB: 覆盖高带宽落地(HKT 2.5Gbps × 129ms BDP=25.8MB，adv_win_scale=1时需socket≥51MB)
    _P_RMEM_MAX=$(( _bw * 25000 ))
    [ "$_P_RMEM_MAX" -lt 8388608  ] && _P_RMEM_MAX=8388608    # min 8MB
    [ "$_P_RMEM_MAX" -gt 67108864 ] && _P_RMEM_MAX=67108864   # max 64MB
    [ "$_P_RMEM_MAX" -gt "$_rmem_ram_cap" ] && _P_RMEM_MAX=$_rmem_ram_cap
    [ "$_P_RMEM_MAX" -lt 8388608  ] && _P_RMEM_MAX=8388608
    # tcp_rmem middle / rmem_default = BDP @ 20ms RTT (国内/日韩典型延迟)
    # TCP 自动调优会从此值按需增长到 rmem_max，无需把 default 设得很大
    # 封顶 8MB：避免大量连接时虚拟内存过度占用，高延迟路径由自动调优覆盖
    _P_TCP_RMEM_MID=4194304    # 固定 4MB：BDP@10ms@3Gbps=3.75MB，覆盖亚洲路径无需爬坡，自动调优按需涨到 rmem_max
    _P_CONNTRACK_MAX=$(( _pmem * 256 ))
    [ "$_P_CONNTRACK_MAX" -gt 4194304 ] && _P_CONNTRACK_MAX=4194304
    [ "$_P_CONNTRACK_MAX" -lt 131072  ] && _P_CONNTRACK_MAX=131072
    _P_SOMAXCONN=$(( _pmem * 16 ))
    [ "$_P_SOMAXCONN" -gt 65535 ] && _P_SOMAXCONN=65535
    [ "$_P_SOMAXCONN" -lt 1024  ] && _P_SOMAXCONN=1024
    _P_TW_BUCKETS=$(( _pmem * 128 ))
    [ "$_P_TW_BUCKETS" -lt 131072 ] && _P_TW_BUCKETS=131072
    _P_NETDEV_BACKLOG=$(( _pmem * 8 ))
    [ "$_P_NETDEV_BACKLOG" -gt 32768 ] && _P_NETDEV_BACKLOG=32768
    [ "$_P_NETDEV_BACKLOG" -lt 1000  ] && _P_NETDEV_BACKLOG=1000
    # 带宽 ≥ 1Gbps 时下限提升至 16384，避免 3G/5G 高速端口 softirq 丢包
    [ "$_bw" -ge 1000 ] && [ "$_P_NETDEV_BACKLOG" -lt 16384 ] && _P_NETDEV_BACKLOG=16384
    _P_FS_FILE_MAX=$(( _pmem * 256 ))
    [ "$_P_FS_FILE_MAX" -lt 1000000 ] && _P_FS_FILE_MAX=1000000
    # net.ipv4.udp_mem 单位是内存页数 (4KB/页)，需先换算: MB → 字节 → 页数
    _P_UDP_MEM_MAX=$(( _pmem * 1024 * 1024 / 4096 / 4 ))
    _P_UDP_MEM_PRESSURE=$(( _P_UDP_MEM_MAX * 3 / 4 ))
    [ "$_P_UDP_MEM_MAX"      -lt 32768 ] && _P_UDP_MEM_MAX=32768
    [ "$_P_UDP_MEM_PRESSURE" -lt 8192  ] && _P_UDP_MEM_PRESSURE=8192
    [ "$_P_UDP_MEM_PRESSURE" -gt "$_P_UDP_MEM_MAX" ] && _P_UDP_MEM_PRESSURE=$_P_UDP_MEM_MAX
    return 0
}

# nf_conntrack 模块就绪后逐条强制写入（sysctl --system 不保证模块已初始化）
_apply_conntrack_sysctl() {
    local _ctmax=${1:-131072}
    # 确保模块开机提前加载（在 sysctl --system 之前），防止参数写入失败
    echo "nf_conntrack" > /etc/modules-load.d/nf_conntrack.conf 2>/dev/null || true
    modprobe nf_conntrack 2>/dev/null || true
    sysctl -w net.netfilter.nf_conntrack_max="$_ctmax"               >/dev/null 2>&1 || true
    sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=3600 >/dev/null 2>&1 || true
    sysctl -w net.netfilter.nf_conntrack_tcp_timeout_time_wait=30     >/dev/null 2>&1 || true
    sysctl -w net.netfilter.nf_conntrack_tcp_timeout_fin_wait=30      >/dev/null 2>&1 || true
    sysctl -w net.netfilter.nf_conntrack_tcp_timeout_close_wait=15    >/dev/null 2>&1 || true
}

# 设置 /etc/security/limits.conf nofile 上限为 512000
_apply_nofile_limits() {
    # limits.conf: '*' does NOT match root, so we set both wildcard and root explicitly
    local _lc=/etc/security/limits.conf
    for _u in "*" "root"; do
        # '*' is a regex metachar; use [*] in patterns to match the literal asterisk
        local _pat; [ "$_u" = "*" ] && _pat='[*]' || _pat="$_u"
        if grep -q "^${_pat} soft nofile" "$_lc" 2>/dev/null; then
            sed -i "s|^${_pat} soft nofile.*|${_u} soft nofile 512000|" "$_lc"
        else
            echo "${_u} soft nofile 512000" >> "$_lc"
        fi
        if grep -q "^${_pat} hard nofile" "$_lc" 2>/dev/null; then
            sed -i "s|^${_pat} hard nofile.*|${_u} hard nofile 512000|" "$_lc"
        else
            echo "${_u} hard nofile 512000" >> "$_lc"
        fi
    done
    # systemd: DefaultLimitNOFILE covers system services (including sshd)
    mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d
    printf '[Manager]\nDefaultLimitNOFILE=512000\n' > /etc/systemd/system.conf.d/nofile-limits.conf
    printf '[Manager]\nDefaultLimitNOFILE=512000\n' > /etc/systemd/user.conf.d/nofile-limits.conf
    systemctl daemon-reload 2>/dev/null || true
    # profile.d fallback: catches any shell not covered by PAM/systemd
    printf 'ulimit -n 512000 2>/dev/null || true\n' > /etc/profile.d/nofile-limits.sh
    chmod 644 /etc/profile.d/nofile-limits.sh
}

# 写入 sysctl 配置文件（唯一入口，避免双份不一致）
# 调用前必须已运行 _calc_sysctl_params，_P_* 全局变量已就绪
# 用法: _write_sysctl_conf <bw_mbps> <phys_mem_mb> <cc>
_write_sysctl_conf() {
    local bw_mbps="$1" phys_mem_mb="$2" cc="$3"
    # H-01 断言：确保在调用前已运行 _calc_sysctl_params，避免关键参数为 0 导致写入无效配置
    if [[ "${_P_SOMAXCONN:-0}" -eq 0 || "${_P_RMEM_MAX:-0}" -eq 0 ]]; then
        echo -e "${RED}BUG: _write_sysctl_conf 被调用前未初始化 _P_* 参数，已中止${NC}" >&2
        return 1
    fi
    local _sw_val=10
    [ "$phys_mem_mb" -ge 400 ] && _sw_val=5
    local _min_free_kb=$(( phys_mem_mb * 1024 * 6 / 100 ))
    [ "$_min_free_kb" -lt 32768  ] && _min_free_kb=32768   # 下限 32MB
    [ "$_min_free_kb" -gt 131072 ] && _min_free_kb=131072  # 上限 128MB
    cat > /etc/sysctl.d/99-custom-tuning.conf <<EOF
# ============================================================
# 动态调优 | 带宽: ${bw_mbps}Mbps | RAM: ${phys_mem_mb}MB | RTT基准: 200ms
# 生成时间: $(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')
# ============================================================

# --- 拥塞控制 & 队列调度 ---
# default_qdisc=fq: 内核级 sysctl 对新建接口生效；
# 已有接口须由 do_quick_init 末尾的 tc 命令显式更新
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = ${cc}

# --- 基础协议标志 ---
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 2
net.ipv4.tcp_sack = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.ip_forward = 1
net.ipv4.conf.all.route_localnet = 1

# --- 重传 & 乱序优化 (实测调优，适合代理中转场景) ---
# frto=2: F-RTO 检测伪超时重传，对 HK→LA(143ms)/JP→LA(97ms) 等长RTT路径有效
# ecn=2:  仅在对端支持时启用 ECN，通过拥塞信号替代丢包，减少不必要重传
# mtu_probing=1: 防 MTU 黑洞（LA节点 MTU=1350），避免静默超时
# reordering=6: 乱序容忍度提高，减少 Fast-Retransmit 误触发
# notsent_lowat=16384: 更早唤醒发送端补充数据，降低代理实时延迟
net.ipv4.tcp_frto = 2
net.ipv4.tcp_ecn = 2
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_reordering = 6
net.ipv4.tcp_notsent_lowat = 16384

# --- 超时 & 故障检测 ---
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_keepalive_time = 500
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.ip_local_port_range = 10000 65000
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_retries2 = 6
net.ipv4.tcp_orphan_retries = 1

# --- Conntrack 超时 ---
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait   = 30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait    = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait  = 15

# --- 系统调度 & 内存管理 ---
kernel.sched_autogroup_enabled = 0
vm.swappiness = ${_sw_val}
vm.min_free_kbytes = ${_min_free_kb}
vm.vfs_cache_pressure = 50

# --- 容量类 动态计算 (RAM: ${phys_mem_mb}MB) ---
fs.file-max = ${_P_FS_FILE_MAX}
net.core.somaxconn = ${_P_SOMAXCONN}
net.ipv4.tcp_max_syn_backlog = $(( _P_SOMAXCONN * 4 ))
net.ipv4.tcp_max_tw_buckets = ${_P_TW_BUCKETS}
net.core.netdev_max_backlog = ${_P_NETDEV_BACKLOG}
net.netfilter.nf_conntrack_max = ${_P_CONNTRACK_MAX}

# --- Buffer 类 动态计算 (${bw_mbps}Mbps | rmem_max=BDP@200ms | default=固定4MB) ---
net.core.rmem_max = ${_P_RMEM_MAX}
net.core.wmem_max = ${_P_RMEM_MAX}
net.ipv4.tcp_rmem = 4096 ${_P_TCP_RMEM_MID} ${_P_RMEM_MAX}
net.ipv4.tcp_wmem = 4096 ${_P_TCP_RMEM_MID} ${_P_RMEM_MAX}
net.core.rmem_default = ${_P_TCP_RMEM_MID}
net.core.wmem_default = ${_P_TCP_RMEM_MID}

# --- UDP 动态计算 (单位: 内存页 4KB) ---
net.ipv4.udp_mem = 8192 ${_P_UDP_MEM_PRESSURE} ${_P_UDP_MEM_MAX}
EOF
}


# ==============================================================================
# 核心功能 1: 端口/IP 验证工具 (validate_ip_cidr / get_current_ssh_port)
# 核心功能 2: 防火墙初始化
# ==============================================================================

validate_ip_cidr() {
    local input="$1"
    [[ "$input" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(/([0-9]{1,2}))?$ ]] || return 1
    local o1=${BASH_REMATCH[1]} o2=${BASH_REMATCH[2]} o3=${BASH_REMATCH[3]} o4=${BASH_REMATCH[4]} prefix=${BASH_REMATCH[6]}
    [[ $o1 -le 255 && $o2 -le 255 && $o3 -le 255 && $o4 -le 255 ]] || return 1
    [[ -z "$prefix" || ( $prefix -ge 0 && $prefix -le 32 ) ]] || return 1
    return 0
}

get_current_ssh_port() {
    local port=""
    # 主配置文件
    [ -r /etc/ssh/sshd_config ] && port=$(grep -iE '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config | awk '{print $2}' | tail -n 1 || true)
    # drop-in 目录优先级更高，无条件覆盖主配置的值
    if [ -d /etc/ssh/sshd_config.d ]; then
        local _dropin
        _dropin=$(grep -rhiE '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config.d/ 2>/dev/null | awk '{print $2}' | tail -n 1 || true)
        [ -n "$_dropin" ] && port="$_dropin"
    fi
    # 兜底：从实际监听端口读取
    [ -z "$port" ] && command -v ss >/dev/null && port=$(ss -tlnp 2>/dev/null | grep -iE 'sshd|ssh' | sed -n 's/.*:\([0-9]\{1,5\}\).*/\1/p' | head -n 1 || true)
    echo "${port:-22}"
}

confirm_ssh_port() {
    local p=$1
    # 检测 /dev/tty 可用性，避免在非交互环境（管道/CI/SSH heredoc）中 read < /dev/tty 死锁
    if [ -t 0 ] && [ -e /dev/tty ]; then
        echo -e "\n${YELLOW}检测到 SSH 端口: ${GREEN}${p}${NC}" > /dev/tty
        echo -ne "${BLUE}确认使用此端口? (回车确认, 或输入其他): ${NC}" > /dev/tty
        local c
        read -r c < /dev/tty
        c=$(echo "$c" | tr -d '[:space:]')
        [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le 65535 ] && echo "$c" || echo "$p"
    else
        # 非交互环境直接沿用检测值，避免死锁
        echo "$p"
    fi
}

_harden_sshd() {
    local _cfg=/etc/ssh/sshd_config
    if [ ! -f "$_cfg" ]; then
        echo -e "  ${YELLOW}⚠ sshd_config 未找到，跳过 SSH 加固${NC}"
        return 0
    fi
    # 备份原始配置
    cp -f "$_cfg" "${_cfg}.bak.$(TZ=Asia/Shanghai date +%Y%m%d%H%M%S)" 2>/dev/null || true
    # 幂等写入：先删除所有相关行（含注释行），再追加
    _sshd_set() {
        sed -i -E "/^[[:space:]]*#?[[:space:]]*${1}[[:space:]]/d" "$_cfg"
        echo "${1} ${2}" >> "$_cfg"
    }
    _sshd_set MaxAuthTries 3
    _sshd_set LoginGraceTime 30
    # 验证语法后才重载，失败则从备份恢复
    if sshd -t 2>/dev/null; then
        systemctl reload sshd 2>/dev/null || systemctl restart sshd 2>/dev/null || true
        echo -e "  ${GREEN}✓ SSH 加固: MaxAuthTries=3  LoginGraceTime=30${NC}"
    else
        echo -e "  ${RED}✗ sshd 配置语法错误，正在从备份恢复...${NC}"
        local _bak
        _bak=$(ls -t "${_cfg}.bak."* 2>/dev/null | head -1 || true)
        [ -n "$_bak" ] && cp -f "$_bak" "$_cfg" && \
            systemctl reload sshd 2>/dev/null || true
    fi
}

do_init_firewall() {
    local _auto=0; [[ "${1:-}" == "--auto" ]] && _auto=1

    echo -e "${GREEN}================================================${NC}"
    echo -e "${L_CYAN}       防火墙安全策略初始化${NC}"
    echo -e "${GREEN}================================================${NC}"

    if ! command -v iptables >/dev/null 2>&1 || ! command -v iptables-save >/dev/null 2>&1 || \
       ! command -v iptables-restore >/dev/null 2>&1 || ! command -v at >/dev/null 2>&1; then
        echo -e "${RED}错误: 缺少依赖 (iptables/iptables-save/iptables-restore/at)，请先执行 [1] 安装依赖。${NC}"
        return
    fi

    # 这里的逻辑是确保只有 iptables 在运行，避免 ufw/firewalld 干扰
    echo -e "${CYAN}正在检查并关闭冲突的防火墙服务 (ufw/firewalld)...${NC}"
    systemctl stop ufw >/dev/null 2>&1 || true
    systemctl disable ufw >/dev/null 2>&1 || true
    systemctl stop firewalld >/dev/null 2>&1 || true
    systemctl disable firewalld >/dev/null 2>&1 || true

    local mode_choice
    if [[ $_auto -eq 1 ]]; then
        mode_choice=1
    else
        echo -e "\n请选择防火墙模式:"
        echo -e " 1. ${GREEN}[推荐] 安全模式${NC} (仅开放 SSH/Web 端口，默认拒绝)"
        echo -e " 2. ${RED}[危险] 开放模式${NC} (关闭防火墙，放行所有流量)"
        echo -ne "${BLUE}请选择 [1-2] (1): ${NC}"
        read -r mode_choice
        mode_choice=${mode_choice:-1}
    fi

    if [ "$mode_choice" = "2" ]; then
        # --- 开放模式 (Disable Firewall) ---
        echo -e "\n${RED}>>> 正在执行: 关闭防火墙 (全放行)${NC}"
        
        iptables -P INPUT ACCEPT
        iptables -P FORWARD ACCEPT
        iptables -P OUTPUT ACCEPT
        iptables -F
        iptables -X
        
        echo -e "策略状态: ${RED}ACCEPT (All Allowed)${NC}"
        
        if _persist_iptables; then
            echo -e "${GREEN}✓ 防火墙已关闭，策略已保存。${NC}"
        else
            echo -e "${RED}保存失败!${NC}"
        fi
        return
    fi

    # --- 安全模式 (标准逻辑) ---
    local ssh_port
    ssh_port=$(get_current_ssh_port)
    if [[ $_auto -eq 0 ]]; then
        ssh_port=$(confirm_ssh_port "$ssh_port")
    else
        echo -e "\n${YELLOW}检测到 SSH 端口: ${GREEN}${ssh_port}${NC}"
    fi
    
    echo -e "\n${YELLOW}正在设置安全网 (2分钟后自动恢复)...${NC}"
    
    local revert_script
    revert_script=$(mktemp /root/.iptfw-revert-XXXXXX)
    chmod 700 "$revert_script"
    # 使用局引号 '\''EOF'\'' 阻止 shell 变量展开（防止 $0 注入）
    cat > "$revert_script" <<'REVERT_EOF'
#!/bin/bash
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
iptables -F
iptables -X
# N-01 修复: 支持 RHEL/CentOS 路径 (/etc/sysconfig/iptables)
_f=/etc/iptables/rules.v4
[ -f /etc/redhat-release ] && _f=/etc/sysconfig/iptables
mkdir -p "$(dirname "$_f")"
iptables-save > "$_f"
REVERT_EOF
    # 单独写入自删除逻辑，避免在 heredoc 内展开 $revert_script 变量
    echo "rm -f \"${revert_script}\"" >> "$revert_script"

    # 清理上次遗留的安全网作业，防止重复执行时多个 at 作业同时触发
    atq 2>/dev/null | awk '{print $1}' | while read -r _jid; do
        at -c "$_jid" 2>/dev/null | grep -q "iptfw-revert" && atrm "$_jid" 2>/dev/null || true
    done

    local job_id _at_out
    # S-01 修复：分离 at 与 grep，独立检测 at 的退出码
    # 若用管道 at | grep，set -e 下 grep 失败会掩盖 at 失败，导致安全网未建立但 DROP 策略已收紧
    if ! _at_out=$(at now + 2 minutes < "$revert_script" 2>&1); then
        echo -e "${RED}错误: at 命令执行失败（exit $?），无法创建安全网。${NC}" >&2
        rm -f "$revert_script"
        return
    fi
    job_id=$(echo "$_at_out" | grep -oP 'job \K[0-9]+' || echo "")

    if [ -z "$job_id" ]; then
        echo -e "${RED}错误: 无法解析 at job ID（atd 是否运行？）${NC}" >&2
        rm -f "$revert_script"
        return
    fi

    echo -e "${CYAN}正在应用防火墙策略 (Secure Mode)...${NC}"
    # 先清空规则（此时策略仍为 ACCEPT，不会断联）
    iptables -F
    iptables -X

    # 先添加所有 ACCEPT 规则，再收紧策略，消除断联窗口
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

    # SSH 速率限制：60s 内同 IP 超 4 次新连接先 LOG 再 DROP
    iptables -A INPUT -p tcp --dport "$ssh_port" -m conntrack --ctstate NEW \
        -m recent --name SSH_RATE --set
    iptables -A INPUT -p tcp --dport "$ssh_port" -m conntrack --ctstate NEW \
        -m recent --name SSH_RATE --rcheck --seconds 60 --hitcount 5 \
        -j LOG --log-prefix "SSH-BRUTE: " --log-level 4
    iptables -A INPUT -p tcp --dport "$ssh_port" -m conntrack --ctstate NEW \
        -m recent --name SSH_RATE --rcheck --seconds 60 --hitcount 5 \
        -j DROP
    iptables -A INPUT -p tcp --dport "$ssh_port" -j ACCEPT
    iptables -A INPUT -p tcp --dport 80 -j ACCEPT
    iptables -A INPUT -p tcp --dport 443 -j ACCEPT
    iptables -A INPUT -p icmp --icmp-type 8 -m limit --limit 1/s --limit-burst 3 -j ACCEPT
    # PMTUD: Destination Unreachable (type 3) 和 TTL Exceeded (type 11) 必须放行，
    # 否则 conntrack RELATED 无法覆盖所有 ICMP 错误，导致 MTU 黑洞
    iptables -A INPUT -p icmp --icmp-type 3 -j ACCEPT
    iptables -A INPUT -p icmp --icmp-type 11 -j ACCEPT

    iptables -P OUTPUT ACCEPT
    # ip_forward=1 已在 sysctl 中开启，放行已建立连接的转发流量（Realm/中继场景）
    iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    # 记录被拦截流量，供选项 12 日志查看使用（限速 5/min 防止日志洪泛）
    iptables -A INPUT -m limit --limit 5/min --limit-burst 10 \
        -j LOG --log-prefix "IPT-DROP: " --log-level 4
    # 最后收紧默认策略（ACCEPT 规则已就位，不会断联）
    # 注意: iperf3 端口 (5201) 不在此处自动开放，如需测速请在菜单 [5] 手动开放
    iptables -P INPUT DROP
    iptables -P FORWARD DROP

    if _persist_iptables; then
        echo -e "${GREEN}✓ 策略应用成功并已保存。${NC}"
        echo -e "${GREEN}✓ 正在移除安全网...${NC}"
        atrm "$job_id" 2>/dev/null || true
        rm -f "$revert_script"
        _harden_sshd
    else
        echo -e "${RED}保存失败! 可能是权限或路径问题。${NC}"
        echo -e "${YELLOW}安全网将在 2 分钟后自动回滚，请勿重启机器。${NC}"
    fi
}


# ==============================================================================
# UI 显示 (仪表盘)
# ==============================================================================

# policy 和 ir 由 show_menu 在调用前设置
_port_dot() {
    local port="$1" label="$2"
    if [ "$policy" == "ACCEPT" ]; then
        echo "$ir" | grep -qE -- "-p tcp.*--dport ${port}[^0-9].*-j DROP" \
            && echo -ne "   ${RED}○ ${label}:${port}${NC}" \
            || echo -ne "   ${L_GREEN}● ${label}:${port}${NC}"
    else
        echo "$ir" | grep -qE -- "-p tcp.*--dport ${port}[^0-9].*-j ACCEPT" \
            && echo -ne "   ${L_GREEN}● ${label}:${port}${NC}" \
            || echo -ne "   ${RED}○ ${label}:${port}${NC}"
    fi
}


toggle_ipv6() {
    clear
    echo -e "${L_BLUE}:: IPv6 管理 ::${NC}"
    
    local is_disabled=0
    if [ -f "/etc/sysctl.d/99-disable-ipv6.conf" ]; then
        is_disabled=1
    fi
    
    if [ "$is_disabled" -eq 1 ]; then
        echo -e "当前状态: ${RED}已禁用${NC}"
        echo -e "${GREEN}正在开启 IPv6...${NC}"
        
        # 1. 删除禁用配置
        rm -f /etc/sysctl.d/99-disable-ipv6.conf
        if [ -f "/etc/sysctl.conf" ]; then
            sed -i '/net.ipv6.conf.all.disable_ipv6/d' /etc/sysctl.conf
            sed -i '/net.ipv6.conf.default.disable_ipv6/d' /etc/sysctl.conf
            sed -i '/net.ipv6.conf.lo.disable_ipv6/d' /etc/sysctl.conf
        fi
        
        # 2. 内核层面应用 (sysctl)
        sysctl --system >/dev/null 2>&1 || true
        
        # 3. 暴力强制开启 (即使 sysctl 没立即生效)
        # 直接修改运行时的 procfs 参数，无需重启
        echo -e "${CYAN}正在激活网卡 IPv6 协议栈...${NC}"
        for i in /proc/sys/net/ipv6/conf/*/disable_ipv6; do 
            echo 0 > "$i" 2>/dev/null
        done
        
        # 4. 尝试获取地址：优先静态配置，fallback DHCPv6
        local ifaces
        ifaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo" || true)

        local _v6_applied=0
        for iface in $ifaces; do
            # 从 /etc/network/interfaces 读取静态 IPv6 配置
            local _v6_addr _v6_gw _v6_dns
            _v6_addr=$(awk "/iface ${iface} inet6 static/{f=1} f && /^[[:space:]]*address/{print \$2; exit}" \
                       /etc/network/interfaces 2>/dev/null || true)
            _v6_gw=$(awk  "/iface ${iface} inet6 static/{f=1} f && /^[[:space:]]*gateway/{print \$2; exit}" \
                       /etc/network/interfaces 2>/dev/null || true)
            if [ -n "$_v6_addr" ]; then
                echo -e "${CYAN}正在应用静态 IPv6 配置 ($iface)...${NC}"
                ip -6 addr add "$_v6_addr" dev "$iface" 2>/dev/null || true
                [ -n "$_v6_gw" ] && ip -6 route add default via "$_v6_gw" dev "$iface" 2>/dev/null || true
                _v6_applied=1
            fi
        done

        # 无静态配置时 fallback DHCPv6
        if [ "$_v6_applied" -eq 0 ]; then
            echo -e "${CYAN}未检测到静态 IPv6 配置，尝试 DHCPv6...${NC}"
            if command -v dhclient >/dev/null 2>&1; then
                for iface in $ifaces; do
                    timeout 8 dhclient -6 -1 -nw "$iface" >/dev/null 2>&1 || true
                done
            else
                echo -e "${YELLOW}! dhclient 未安装，跳过 DHCPv6 请求${NC}"
            fi
        fi

        # 5. 最终检测（轮询，最多等 5s）
        for _i6w in {1..5}; do ip -6 addr | grep -q "global" && break; sleep 1; done
        if ip -6 addr | grep -q "global"; then
            echo -e "${GREEN}✓ IPv6 已成功开启并获取到公网地址！${NC}"
            ip -6 addr | grep "global" | awk '{print "   IP: " $2}'
        elif ip -6 addr | grep -q "inet6"; then
            echo -e "${YELLOW}✓ IPv6 协议栈已开启 (仅本地链路)。${NC}"
            echo -e "注意: 未获取到公网 IP，可能需要您的网络环境支持 DHCPv6 或重启生效。"
        else
            echo -e "${RED}! IPv6 开启失败。可能需要重启服务器。${NC}"
        fi
        
    else
        echo -e "当前状态: ${GREEN}已开启${NC}"
        echo -ne "${YELLOW}确认禁用 IPv6？默认禁用 [Y/n]: ${NC}"
        read -r _ipv6_confirm
        _ipv6_confirm="${_ipv6_confirm:-Y}"
        if [[ "${_ipv6_confirm,,}" != "y" ]]; then
            echo -e "${CYAN}已取消，IPv6 保持开启状态。${NC}"
            return
        fi
        echo -e "${YELLOW}正在禁用 IPv6...${NC}"
        _write_disable_ipv6_conf

        # 暴力强制禁用
        for i in /proc/sys/net/ipv6/conf/*/disable_ipv6; do 
            echo 1 > "$i" 2>/dev/null
        done
        
        echo -e "${RED}✓ IPv6 已禁用${NC}"
    fi
}


# ==============================================================================
# TCPing 监控端口管理
# ==============================================================================

TCPING_SERVICE_NAME="tcping-monitor"
TCPING_CONFIG_FILE="/etc/tcping-monitor.conf"

SSH_TG_SERVICE="ssh-tg-monitor"
SSH_TG_CONF="/etc/ssh-tg-monitor.conf"
SSH_TG_SCRIPT="/usr/local/bin/ssh-tg-monitor.sh"
F2B_WHITELIST="/etc/fail2ban/f2b-whitelist.conf"

# 获取本机公网 IPv4，依次尝试多个源，校验格式后返回


# 查找从 start_port 开始的第一个未占用端口
# 仅依据 ss 实际监听状态判断，不受防火墙规则影响
find_available_port() {
    local start_port=${1:-9999}
    local port=$start_port
    while [ "$port" -le 65535 ]; do
        if ! ss -tuln 2>/dev/null | grep -qE ":${port}[^0-9]"; then
            echo "$port"
            return 0
        fi
        port=$((port + 1))
    done
    echo "0"
    return 1
}

# 静默启用 TCPing 监控（用于一键初始化，不询问用户）
_tcping_setup_silent() {
    if systemctl is-active --quiet "$TCPING_SERVICE_NAME" 2>/dev/null; then
        local _p; _p=$(grep "^PORT=" "$TCPING_CONFIG_FILE" 2>/dev/null | cut -d= -f2 || echo "?")
        echo -e "  TCPing: ${C_GREEN}已运行 [端口 ${_p}]（跳过）${C_RESET}"
        return 0
    fi

    if ! command -v socat &>/dev/null; then
        apt-get install -y -qq socat 2>/dev/null || { echo -e "  TCPing: ${C_RED}socat 安装失败，跳过${C_RESET}"; return 1; }
    fi

    if ! id tcping &>/dev/null; then
        useradd --system --no-create-home --shell /usr/sbin/nologin tcping 2>/dev/null || true
    fi

    local monitor_port
    monitor_port=$(find_available_port 9999)
    if [[ "$monitor_port" == "0" ]]; then
        echo -e "  TCPing: ${C_RED}找不到可用端口，跳过${C_RESET}"; return 1
    fi

    if [[ -f "$TCPING_CONFIG_FILE" ]]; then
        local _old_port; _old_port=$(grep "^PORT=" "$TCPING_CONFIG_FILE" 2>/dev/null | cut -d= -f2 || true)
        [[ -n "$_old_port" ]] && _safe_iptables_remove_rule "tcping-monitor" 2>/dev/null || true
    fi

    printf '# TCPing Monitor Configuration\nPORT=%s\n' "$monitor_port" > "$TCPING_CONFIG_FILE"

    cat > "/etc/systemd/system/${TCPING_SERVICE_NAME}.service" <<EOF
[Unit]
Description=TCPing Monitor Port for Nezha Probe
After=network.target

[Service]
Type=simple
User=tcping
NoNewPrivileges=true
ExecStart=/usr/bin/socat TCP4-LISTEN:${monitor_port},reuseaddr,fork,max-children=100 EXEC:/bin/true
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now "$TCPING_SERVICE_NAME" 2>/dev/null || { echo -e "  TCPing: ${C_RED}服务启动失败${C_RESET}"; return 1; }

    iptables -I INPUT 1 -p tcp --dport "$monitor_port" \
        -m connlimit --connlimit-upto 3 --connlimit-mask 32 \
        -m comment --comment "tcping-monitor-${monitor_port}" -j ACCEPT 2>/dev/null || true
    _persist_iptables 2>/dev/null || true

    echo -e "  TCPing: ${C_GREEN}已启动 [端口 ${monitor_port}]${C_RESET}"
}

do_tcping_monitor() {
    clear
    echo -e "${L_BLUE}:: TCPing 监控端口管理 ::${NC}"
    echo -e "${CYAN}用于哪吒探针等监控系统的 TCPing 延迟检测${NC}\n"
    
    # 检测当前状态
    local current_status="${RED}未运行${NC}"
    local current_port="-"
    
    if systemctl is-active --quiet "$TCPING_SERVICE_NAME" 2>/dev/null; then
        current_status="${GREEN}运行中${NC}"
        if [ -f "$TCPING_CONFIG_FILE" ]; then
            current_port=$(grep "^PORT=" "$TCPING_CONFIG_FILE" 2>/dev/null | cut -d= -f2)
        fi
    fi
    
    echo -e "${L_BLUE}[ 当前状态 ]${NC}"
    echo -e "   服务: $current_status"
    if [ "$current_port" != "-" ]; then
        echo -e "   端口: ${GREEN}$current_port${NC}"
        # 获取公网 IPv4 地址
        local public_ip
        public_ip=$(get_public_ip)
        echo -e "   目标: ${GREEN}${public_ip}:${current_port}${NC}  ${CYAN}← 复制到哪吒 Dashboard${NC}"
    fi
    
    echo -e "\n${L_BLUE}[ 操作选项 ]${NC}"
    echo -e "  ${L_GREEN}1.${NC} 创建/重新配置 TCPing 监控端口"
    echo -e "  ${L_GREEN}2.${NC} 停止并移除 TCPing 监控"
    echo -e "  ${L_GREEN}3.${NC} 查看服务状态"
    echo -e "  ${L_GREEN}0.${NC} 返回主菜单"
    
    echo -ne "\n${L_PURPLE}请选择 [1]: ${NC}"
    read -r tcping_choice
    tcping_choice="${tcping_choice:-1}"

    case "$tcping_choice" in
        1)
            # 检查 socat 是否安装
            if ! command -v socat &>/dev/null; then
                echo -e "\n${YELLOW}正在安装 socat...${NC}"
                apt-get update -qq && apt-get install -y -qq socat
                if ! command -v socat &>/dev/null; then
                    echo -e "${RED}安装 socat 失败，请手动安装: apt install socat${NC}"
                    return
                fi
                echo -e "${GREEN}✓ socat 已安装${NC}"
            fi

            # 确保专用隔离用户存在（无 shell、无 home、不可登录）
            if ! id tcping &>/dev/null; then
                useradd --system --no-create-home --shell /usr/sbin/nologin tcping
                echo -e "${GREEN}✓ 专用用户 tcping 已创建${NC}"
            fi
            
            local monitor_port
            monitor_port=$(find_available_port 9999)
            if [ "$monitor_port" = "0" ]; then
                echo -e "${RED}错误: 无法找到可用端口 (9999-65535)${NC}"; return
            fi
            echo -e "  ${CYAN}自动选定端口: ${GREEN}${monitor_port}${NC}"
            
            echo -e "\n${CYAN}正在配置 TCPing 监控端口...${NC}"
            
            # 停止旧服务并清理孤儿进程
            systemctl stop "$TCPING_SERVICE_NAME" 2>/dev/null || true
            systemctl disable "$TCPING_SERVICE_NAME" 2>/dev/null || true
            pkill -9 -f "socat.*${monitor_port}" 2>/dev/null || true
            
            # 清理旧的防火墙规则
            if [ -f "$TCPING_CONFIG_FILE" ]; then
                local old_port
                old_port=$(grep "^PORT=" "$TCPING_CONFIG_FILE" 2>/dev/null | cut -d= -f2 || true)
                if [ -n "$old_port" ]; then
                    _safe_iptables_remove_rule "tcping-monitor"
                fi
            fi

            # 保存配置
            cat > "$TCPING_CONFIG_FILE" <<EOF
# TCPing Monitor Configuration
PORT=$monitor_port
EOF
            
            # 创建 systemd 服务
            cat > "/etc/systemd/system/${TCPING_SERVICE_NAME}.service" <<EOF
[Unit]
Description=TCPing Monitor Port for Nezha Probe
After=network.target

[Service]
Type=simple
User=tcping
NoNewPrivileges=true
ExecStart=/usr/bin/socat TCP4-LISTEN:${monitor_port},reuseaddr,fork,max-children=100 EXEC:/bin/true
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
            
            systemctl daemon-reload 2>/dev/null || true
            if ! systemctl enable --now "$TCPING_SERVICE_NAME" 2>/dev/null; then
                echo -e "${RED}✗ 服务启动失败，防火墙规则未写入，请检查: journalctl -u $TCPING_SERVICE_NAME${NC}"
                return
            fi

            # 每源 IP 最多 3 个并发连接，防单 IP 连接洪水；不影响多节点监控（各 IP 独立计数）
            iptables -I INPUT 1 -p tcp --dport "$monitor_port" \
                -m connlimit --connlimit-upto 3 --connlimit-mask 32 \
                -m comment --comment "tcping-monitor-$monitor_port" -j ACCEPT

            _persist_iptables
            
            # 验证服务状态
            sleep 1
            if systemctl is-active --quiet "$TCPING_SERVICE_NAME"; then
                echo -e "${GREEN}✓ TCPing 监控服务已启动${NC}"
                echo -e "\n${L_BLUE}[ 配置完成 ]${NC}"
                echo -e "   端口: ${GREEN}$monitor_port${NC}"
                echo -e "   状态: ${GREEN}运行中${NC}"
                echo -e "\n${CYAN}在哪吒 Dashboard 添加 TCPing 监控:${NC}"
                # 获取本机公网 IPv4 地址
                local public_ip
                public_ip=$(get_public_ip)
                echo -e "   目标: ${GREEN}${public_ip}:${monitor_port}${NC}"
                echo -e "\n${YELLOW}提示: 此端口仅用于 TCPing 连通性检测，无安全风险${NC}"
            else
                echo -e "${RED}✗ 服务启动失败，请检查日志: journalctl -u $TCPING_SERVICE_NAME${NC}"
            fi
            ;;
        
        2)
            echo -e "\n${YELLOW}正在停止并移除 TCPing 监控...${NC}"
            
            # 停止服务
            systemctl stop "$TCPING_SERVICE_NAME" 2>/dev/null || true
            systemctl disable "$TCPING_SERVICE_NAME" 2>/dev/null || true
            rm -f "/etc/systemd/system/${TCPING_SERVICE_NAME}.service"
            systemctl daemon-reload 2>/dev/null || true
            
            # 清理防火墙规则（按注释 pattern 匹配，不依赖端口号）
            if _safe_iptables_remove_rule "tcping-monitor"; then
                _persist_iptables
                echo -e "${GREEN}✓ 防火墙规则已清理${NC}"
            fi
            
            rm -f "$TCPING_CONFIG_FILE"
            echo -e "${GREEN}✓ TCPing 监控已完全移除${NC}"
            ;;
        
        3)
            echo -e "\n${L_BLUE}[ 服务状态 ]${NC}"
            systemctl status "$TCPING_SERVICE_NAME" --no-pager 2>/dev/null || echo -e "${YELLOW}服务未安装${NC}"
            
            echo -e "\n${L_BLUE}[ 相关防火墙规则 ]${NC}"
            local _tcping_rules
            _tcping_rules=$(iptables -L INPUT -nv --line-numbers 2>/dev/null | grep -E "tcping-monitor" || true)
            if [[ -n "$_tcping_rules" ]]; then
                iptables -L INPUT -nv --line-numbers 2>/dev/null | head -2
                echo "$_tcping_rules"
            else
                echo -e "${YELLOW}无相关规则${NC}"
            fi
            ;;
        
        0)
            return
            ;;
        *)
            echo -e "${RED}无效选项${NC}"; sleep 1
            ;;
    esac
}


# ==============================================================================
# 一键参数检测
# ==============================================================================

do_check_all() {
    clear
    echo -e "${L_PURPLE}================================================${NC}"
    echo -e "${L_CYAN}         一键参数检测${NC}"
    echo -e "${L_PURPLE}================================================${NC}"

    local _ok=0 _warn=0 _fail=0

    _ck_pass() { echo -e "   ${GREEN}✓${NC}  $1"; _ok=$((_ok + 1)); }
    _ck_warn() { echo -e "   ${YELLOW}!${NC}  $1"; _warn=$((_warn + 1)); }
    _ck_fail() { echo -e "   ${RED}✗${NC}  $1"; _fail=$((_fail + 1)); }

    _ck_sysctl() {
        local key=$1 expect=$2 op=${3:-eq} label=${4:-$1}
        local val
        val=$(sysctl -n "$key" 2>/dev/null)
        if [ -z "$val" ]; then
            _ck_warn "${label}  →  无法读取（模块未加载?）"
            return
        fi
        local hit=0
        case $op in
            eq) [ "$val"  =  "$expect" ] && hit=1 ;;
            ge) [ "$val" -ge "$expect" ] && hit=1 ;;
            le) [ "$val" -le "$expect" ] && hit=1 ;;
        esac
        if [ $hit -eq 1 ]; then
            _ck_pass "${label}  =  ${val}"
        else
            _ck_fail "${label}  =  ${val}  （期望 ${op} ${expect}）"
        fi
    }

    # ── 1-5. sysctl 参数（依赖配置文件）────────────────────
    local _sysctl_conf="/etc/sysctl.d/99-custom-tuning.conf"
    if [ ! -f "$_sysctl_conf" ]; then
        echo -e "\n${L_BLUE}[ sysctl 配置 ]${NC}"
        _ck_fail "99-custom-tuning.conf 不存在，TCP/缓冲区/Conntrack 参数均未配置（请运行选项 1）"
    else
        _ck_pass_file() {
            # 同时验证配置文件内容 + 内核实际值，两者都对才算通过
            local key=$1 expect=$2 op=${3:-eq} label=${4:-$1}
            local live file_val hit_live=0 hit_file=0
            live=$(sysctl -n "$key" 2>/dev/null)
            file_val=$(awk -F'=' "/^[[:space:]]*${key//./\\.}[[:space:]]*=/{gsub(/ /,\"\",\$2); print \$2; exit}" "$_sysctl_conf" 2>/dev/null)

            # 检查配置文件中是否有此项
            if [ -z "$file_val" ]; then
                _ck_warn "${label}  →  配置文件中无此项（使用内核默认值 ${live:-?}）"
                return
            fi
            # 检查实际生效值
            if [ -z "$live" ]; then
                _ck_warn "${label}  →  无法读取内核值（模块未加载?）"
                return
            fi
            case $op in
                eq) [ "$live" = "$expect"  ] && hit_live=1; [ "$file_val" = "$expect"  ] && hit_file=1 ;;
                ge) [ "$live" -ge "$expect" ] && hit_live=1; [ "$file_val" -ge "$expect" ] && hit_file=1 ;;
                le) [ "$live" -le "$expect" ] && hit_live=1; [ "$file_val" -le "$expect" ] && hit_file=1 ;;
            esac
            if [ $hit_live -eq 1 ] && [ $hit_file -eq 1 ]; then
                _ck_pass "${label}  =  ${live}"
            elif [ $hit_file -eq 1 ] && [ $hit_live -eq 0 ]; then
                _ck_warn "${label}  →  配置文件正确(${file_val})，但内核实际值 ${live} 不符（需重载 sysctl）"
            else
                _ck_fail "${label}  =  ${live}  （配置值 ${file_val}，期望 ${op} ${expect}）"
            fi
        }

        echo -e "\n${L_BLUE}[ TCP 内核调优 ]${NC}"
        _ck_pass_file net.ipv4.tcp_congestion_control     bbr      eq  "拥塞控制"
        _ck_pass_file net.core.default_qdisc              fq       eq  "队列调度"
        _ck_pass_file net.ipv4.tcp_timestamps             1        eq  "tcp_timestamps"
        _ck_pass_file net.ipv4.tcp_tw_reuse               1        eq  "TIME_WAIT 复用"
        _ck_pass_file net.ipv4.tcp_syncookies             1        eq  "SYN Cookies"
        _ck_pass_file net.ipv4.ip_forward                 1        eq  "IP 转发"
        _ck_pass_file net.ipv4.tcp_slow_start_after_idle  0        eq  "慢启动(空闲后)"
        _ck_pass_file net.ipv4.tcp_ecn                    2        eq  "ECN (仅对端支持时启用)"
        _ck_pass_file net.ipv4.tcp_no_metrics_save        1        eq  "路由指标缓存"
        _ck_pass_file fs.file-max                         1000000  ge  "文件句柄上限"

        echo -e "\n${L_BLUE}[ Keepalive ]${NC}"
        _ck_pass_file net.ipv4.tcp_keepalive_time    600   le  "Keepalive 启动(s)"
        _ck_pass_file net.ipv4.tcp_keepalive_intvl   30    le  "Keepalive 间隔(s)"
        _ck_pass_file net.ipv4.tcp_keepalive_probes  5     le  "Keepalive 探测次数"

        echo -e "\n${L_BLUE}[ 故障检测 ]${NC}"
        _ck_pass_file net.ipv4.tcp_syn_retries     3   le  "SYN 重试次数"
        _ck_pass_file net.ipv4.tcp_retries2        6   le  "数据重传上限"
        _ck_pass_file net.ipv4.tcp_orphan_retries  1   eq  "孤儿连接重试"
        _ck_pass_file net.ipv4.tcp_fin_timeout     20  le  "FIN 超时(s)"

        echo -e "\n${L_BLUE}[ 缓冲区 ]${NC}"
        _ck_pass_file net.core.rmem_max  8388608  ge  "最大读缓冲"
        _ck_pass_file net.core.wmem_max  8388608  ge  "最大写缓冲"

        echo -e "\n${L_BLUE}[ Conntrack ]${NC}"
        local _expected_ct
        _expected_ct=$(awk -F'=' '/nf_conntrack_max/{gsub(/ /,"",$2); print $2}' "$_sysctl_conf" 2>/dev/null)
        _expected_ct=${_expected_ct:-131072}
        _ck_pass_file net.netfilter.nf_conntrack_max                     "$_expected_ct"  ge  "Conntrack 上限"
        _ck_pass_file net.netfilter.nf_conntrack_tcp_timeout_established  3600  le  "ESTABLISHED 超时"
        _ck_pass_file net.netfilter.nf_conntrack_tcp_timeout_time_wait    30    le  "TIME_WAIT 超时"
        _ck_pass_file net.netfilter.nf_conntrack_tcp_timeout_fin_wait     30    le  "FIN_WAIT 超时"
        _ck_pass_file net.netfilter.nf_conntrack_tcp_timeout_close_wait   15    le  "CLOSE_WAIT 超时"
    fi

    # ── 6. BBR 模块 & XanMod 内核 ───────────────────────
    echo -e "\n${L_BLUE}[ BBR 模块 & 内核 ]${NC}"
    local _avail_cc _active_cc
    _avail_cc=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo "")
    _active_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    # XanMod 内核检测
    if uname -r | grep -qi "xanmod"; then
        _ck_pass "XanMod 内核已运行 ($(uname -r | sed 's/-x64v.*//'))"
    else
        _ck_warn "未运行 XanMod 内核，x86_64 建议安装 XanMod 6.13+ 以获取 BBR v3（当前: $(uname -r)）"
    fi
    if echo "$_avail_cc" | grep -q "bbr"; then
        _ck_pass "BBR 在内核可用列表"
    else
        _ck_fail "BBR 不在内核可用列表（内核版本过低或模块未加载）"
    fi
    if [ "$_active_cc" = "bbr" ]; then
        local _bbr_ver_label=""
        [[ "$(_get_bbr_version)" == "v3" ]] && _bbr_ver_label=" (v3)" || _bbr_ver_label=" (v1)"
        _ck_pass "BBR${_bbr_ver_label} 当前激活"
    else
        _ck_fail "BBR 未激活（当前使用 ${_active_cc:-?}）"
    fi

    # ── 6.5. tc qdisc ─────────────────────────────────────
    echo -e "\n${L_BLUE}[ tc qdisc ]${NC}"
    local _def_if_ck _qdisc_info
    _def_if_ck=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    if [ -n "$_def_if_ck" ] && command -v tc >/dev/null 2>&1; then
        _qdisc_info=$(tc qdisc show dev "$_def_if_ck" 2>/dev/null | head -1 || true)
        if echo "$_qdisc_info" | grep -q "fq "; then
            local _mr
            _mr=$(echo "$_qdisc_info" | grep -oP 'maxrate \K[^ ]+' || echo "?")
            _ck_pass "qdisc fq 已生效 → ${_def_if_ck}  maxrate=${_mr}"
        else
            _ck_warn "qdisc 未使用 fq（当前: ${_qdisc_info:-未知}），BBR 重传优化可能未生效"
        fi
    else
        _ck_warn "无法检测 tc qdisc（tc 未安装或无默认路由）"
    fi

    # ── 7. IPv6 ──────────────────────────────────────────
    echo -e "\n${L_BLUE}[ IPv6 ]${NC}"
    if [ -f "/etc/sysctl.d/99-disable-ipv6.conf" ]; then
        _ck_sysctl net.ipv6.conf.all.disable_ipv6 1 eq "IPv6 已禁用"
    else
        _ck_warn "IPv6 未禁用（若需禁用请在菜单 [12] 切换）"
    fi

    # ── 8. Swap ──────────────────────────────────────────
    echo -e "\n${L_BLUE}[ Swap ]${NC}"
    local _swap_kb
    _swap_kb=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
    if [ "${_swap_kb:-0}" -gt 0 ]; then
        _ck_pass "Swap 已启用 $((_swap_kb / 1024)) MB"
    else
        _ck_warn "未启用 Swap（物理内存充足时可忽略）"
    fi

    # ── 9. 文件描述符 ────────────────────────────────────
    echo -e "\n${L_BLUE}[ 文件描述符 ]${NC}"
    # '*' 在 limits.conf 中不匹配 root，需同时检测 root 专属条目
    local _fd_val=""
    _fd_val=$(grep -rE '^(root|\*)\s+soft\s+nofile' \
        /etc/security/limits.conf /etc/security/limits.d/ 2>/dev/null \
        | awk '{print $NF}' | sort -n | tail -1 || true)
    if [ -n "$_fd_val" ]; then
        if [ "${_fd_val:-0}" -ge 512000 ]; then
            _ck_pass "limits.conf soft nofile = ${_fd_val}"
        else
            _ck_fail "limits.conf soft nofile = ${_fd_val}（期望 >= 512000，请重新运行选项 1 一键初始化）"
        fi
    else
        _ck_fail "limits.conf 未配置 nofile（请重新运行选项 1 一键初始化）"
    fi
    # 检查当前会话实际生效值
    local _ulimit_cur
    _ulimit_cur=$(ulimit -Sn 2>/dev/null || echo "unknown")
    if [[ "$_ulimit_cur" == "unlimited" ]] || { [[ "$_ulimit_cur" =~ ^[0-9]+$ ]] && [ "$_ulimit_cur" -ge 512000 ]; }; then
        _ck_pass "当前会话 ulimit -n = ${_ulimit_cur}"
    else
        _ck_warn "当前会话 ulimit -n = ${_ulimit_cur}（重新登录后自动生效）"
    fi

    # ── 10. DNS ──────────────────────────────────────────
    echo -e "\n${L_BLUE}[ DNS ]${NC}"
    if grep -q "8.8.8.8" /etc/resolv.conf 2>/dev/null && \
       grep -q "1.1.1.1" /etc/resolv.conf 2>/dev/null && \
       grep -q "94.140.14.14" /etc/resolv.conf 2>/dev/null; then
        _ck_pass "DNS 已配置（8.8.8.8 / 1.1.1.1 / 94.140.14.14）"
    else
        _ck_fail "DNS 配置异常，resolv.conf 未包含全部目标 DNS（请运行选项 1 重新初始化）"
    fi
    if [ -L /etc/resolv.conf ]; then
        _ck_warn "resolv.conf 是符号链接，chattr +i 无效（请运行选项 1 重新初始化）"
    else
        local _res_attrs
        _res_attrs=$(lsattr /etc/resolv.conf 2>/dev/null | awk '{print $1}')
        if echo "$_res_attrs" | grep -q "i"; then
            _ck_pass "resolv.conf 已锁定（chattr +i）"
        else
            _ck_warn "resolv.conf 未锁定，可能被 DHCP/cloud-init 覆盖"
        fi
    fi

    # ── 11. 防火墙 ───────────────────────────────────────
    echo -e "\n${L_BLUE}[ 防火墙 ]${NC}"
    if ! command -v iptables >/dev/null 2>&1; then
        _ck_fail "iptables 未安装（请运行选项 1）"
    else
        local _fw_policy
        _fw_policy=$(iptables -L INPUT -n 2>/dev/null | head -1 | awk '{print $4}' | tr -d '()')
        case "$_fw_policy" in
            DROP)   _ck_pass "INPUT 策略 = DROP（安全模式）" ;;
            ACCEPT) _ck_warn "INPUT 策略 = ACCEPT（开放模式，无过滤防护）" ;;
            *)      _ck_fail "INPUT 策略 = ${_fw_policy:-未知}" ;;
        esac

        local _fw_rules
        _fw_rules=$(iptables -S INPUT 2>/dev/null | grep -c '^-A' 2>/dev/null) || _fw_rules=0
        if [ "${_fw_rules:-0}" -gt 0 ]; then
            _ck_pass "INPUT 规则 ${_fw_rules} 条"
        else
            _ck_warn "无 INPUT ACCEPT 规则（所有入站均被拒绝，含 SSH）"
        fi

        local _ssh_port
        _ssh_port=$(get_current_ssh_port 2>/dev/null || echo "22")
        if [ "$_fw_policy" = "ACCEPT" ] || iptables -C INPUT -p tcp --dport "$_ssh_port" -j ACCEPT 2>/dev/null; then
            _ck_pass "SSH 端口 ${_ssh_port} 已放行"
        else
            _ck_fail "SSH 端口 ${_ssh_port} 未放行！（有断联风险）"
        fi

        if systemctl is-enabled --quiet netfilter-persistent 2>/dev/null; then
            _ck_pass "netfilter-persistent 已启用（规则重启持久）"
        elif [ -f "/etc/iptables/rules.v4" ]; then
            _ck_warn "/etc/iptables/rules.v4 存在但 netfilter-persistent 未启用"
        else
            _ck_fail "防火墙规则未持久化（重启后将丢失，请运行选项 1）"
        fi
    fi

    # ── 12. 代理服务 ─────────────────────────────────────
    echo -e "\n${L_BLUE}[ 代理服务 ]${NC}"
    local _proxy_found=0
    if [ -f "/usr/local/bin/snell-server" ]; then
        _proxy_found=1
        if systemctl list-units --type=service --state=active 'snell@*' --no-legend 2>/dev/null | grep -q 'snell@'; then
            _ck_pass "Snell 运行中"
        else
            _ck_warn "Snell 已安装但未运行"
        fi
    fi
    if [ -f "/usr/local/bin/ssserver" ]; then
        _proxy_found=1
        if systemctl is-active --quiet shadowsocks-rust 2>/dev/null; then
            _ck_pass "Shadowsocks-Rust 运行中"
        else
            _ck_warn "Shadowsocks-Rust 已安装但未运行"
        fi
    fi
    if [ -f "/usr/local/bin/realm" ]; then
        _proxy_found=1
        if systemctl is-active --quiet realm 2>/dev/null; then
            _ck_pass "Realm 运行中"
        else
            _ck_warn "Realm 已安装但未运行"
        fi
    fi
    [ $_proxy_found -eq 0 ] && _ck_warn "未检测到代理服务（Snell/SS/Realm）"

    # ── 汇总 ─────────────────────────────────────────────
    local _total
    _total=$((_ok + _warn + _fail))
    echo -e "\n${L_PURPLE}================================================${NC}"
    printf "  检测项目: ${WHITE}%-4s${NC}  ${GREEN}通过: %-4s${NC}  ${YELLOW}警告: %-4s${NC}  ${RED}失败: %-4s${NC}\n" \
        "$_total" "$_ok" "$_warn" "$_fail"
    if [ $_fail -eq 0 ] && [ $_warn -eq 0 ]; then
        echo -e "  ${GREEN}所有参数均已正确配置！${NC}"
    elif [ $_fail -eq 0 ]; then
        echo -e "  ${YELLOW}存在 ${_warn} 个警告项，核心配置正常。${NC}"
    else
        echo -e "  ${RED}存在 ${_fail} 个失败项，请按提示重新运行对应选项修复。${NC}"
    fi
    echo -e "${L_PURPLE}================================================${NC}"
    # N-02: 清理内嵌函数，避免其串漏到全局命名空间后引用已销毁的局部计数器
    unset -f _ck_pass _ck_warn _ck_fail _ck_sysctl _ck_pass_file
}


# 开放单个协议端口（幂等：已存在则不重复添加）
_firewall_open_port() {
    local proto="$1" port="$2"
    iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null \
        || iptables -I INPUT 1 -p "$proto" --dport "$port" -j ACCEPT
}


# ==============================================================================
# 一键初始化 & 系统更新
# ==============================================================================

do_retune_bandwidth() {
    clear
    echo -e "${L_BLUE}=== 带宽重调 (sysctl + tc) ===${NC}"
    echo
    local _def_if
    _def_if=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    local _cur_rmem; _cur_rmem=$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)
    local _cur_maxrate="?"
    [ -n "$_def_if" ] && _cur_maxrate=$(tc qdisc show dev "$_def_if" 2>/dev/null | grep -oP 'maxrate \K[^ ]+' || echo "?")
    local _cur_bw_est="?"
    if [[ "$_cur_maxrate" =~ ^([0-9]+)Mbit$ ]]; then
        _cur_bw_est=$(( ${BASH_REMATCH[1]} * 100 / 98 ))
    fi
    local _bw_default="1000"
    [[ "$_cur_bw_est" =~ ^[0-9]+$ ]] && _bw_default="$_cur_bw_est"
    echo -e "  当前 rmem_max  : ${CYAN}$(( _cur_rmem / 1048576 )) MB${NC}"
    echo -e "  当前 tc maxrate: ${CYAN}${_cur_maxrate}${NC}  (对应带宽约 ${CYAN}${_cur_bw_est} Mbps${NC})"
    echo
    echo -e "  填入实际物理端口带宽，脚本自动重算 sysctl 缓冲区并更新 tc 限速"
    echo -ne "${L_PURPLE}输入新带宽 Mbps [${_bw_default}]: ${NC}"
    local bw_mbps; read -r bw_mbps
    bw_mbps="${bw_mbps:-${_bw_default}}"
    if ! [[ "$bw_mbps" =~ ^[0-9]+$ ]] || [ "$bw_mbps" -lt 10 ]; then
        echo -e "${RED}✗ 无效输入（需为正整数 Mbps）${NC}"; return 1
    fi
    local _pmem_kb; _pmem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local _pmem_mb=$(( _pmem_kb / 1024 ))
    local _cc; _cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo bbr)

    echo -e "\n${L_BLUE}[ 1/3 ] 重新计算 sysctl 参数${NC}"
    _calc_sysctl_params "$_pmem_mb" "$bw_mbps"
    _write_sysctl_conf "$bw_mbps" "$_pmem_mb" "$_cc"
    sysctl --system >/dev/null 2>&1 || true
    echo -e "  ${GREEN}✓ sysctl 已更新${NC}"
    echo -e "    rmem_max     = ${CYAN}$(( _P_RMEM_MAX / 1048576 )) MB${NC}"
    echo -e "    tcp_rmem mid = ${CYAN}$(( _P_TCP_RMEM_MID / 1048576 )) MB${NC}"

    echo -e "\n${L_BLUE}[ 2/3 ] 更新 tc qdisc${NC}"
    local _fq_maxrate=$(( bw_mbps * 98 / 100 ))
    [ "$_fq_maxrate" -lt 100 ] && _fq_maxrate=100
    if [ -n "$_def_if" ]; then
        if tc qdisc replace dev "$_def_if" root fq maxrate "${_fq_maxrate}mbit" flow_limit 250 2>/dev/null; then
            echo -e "  ${GREEN}✓ fq maxrate=${_fq_maxrate}mbit → ${_def_if}${NC}"
        else
            tc qdisc add dev "$_def_if" root fq maxrate "${_fq_maxrate}mbit" flow_limit 250 2>/dev/null || true
            echo -e "  ${YELLOW}⚠ replace 失败，已尝试 add${NC}"
        fi
    else
        echo -e "  ${YELLOW}⚠ 无默认路由，跳过 tc${NC}"
    fi

    echo -e "\n${L_BLUE}[ 3/3 ] 持久化${NC}"
    local _rc_local="/etc/rc.local" _rc_tmp
    _rc_tmp=$(mktemp)
    {
        if [ -f "$_rc_local" ]; then
            head -n 1 "$_rc_local" | grep -qE '^#!' && head -n 1 "$_rc_local" || echo '#!/bin/bash'
            grep -v "^#!" "$_rc_local" \
                | grep -v "tc qdisc replace.*root fq" \
                | grep -v 'IFACE=.*ip route show default' \
                | grep -v "^exit 0" || true
        else
            echo '#!/bin/bash'
        fi
        printf 'IFACE=$(ip route show default 2>/dev/null | awk '"'"'{print $5; exit}'"'"')\n[ -n "$IFACE" ] && tc qdisc replace dev "$IFACE" root fq maxrate %smbit flow_limit 250 2>/dev/null || true\n' "$_fq_maxrate"
        echo 'exit 0'
    } > "$_rc_tmp" && mv "$_rc_tmp" "$_rc_local" || rm -f "$_rc_tmp"
    chmod +x "$_rc_local"
    if [ -d /etc/networkd-dispatcher/routable.d ]; then
        printf '#!/bin/bash\nIFACE=$(ip route show default 2>/dev/null | awk '"'"'{print $5; exit}'"'"')\n[ -n "$IFACE" ] && tc qdisc replace dev "$IFACE" root fq maxrate %smbit flow_limit 250 2>/dev/null || true\n' \
            "$_fq_maxrate" > /etc/networkd-dispatcher/routable.d/10-fq-qdisc.sh
        chmod +x /etc/networkd-dispatcher/routable.d/10-fq-qdisc.sh
    fi
    echo -e "  ${GREEN}✓ rc.local + networkd-dispatcher 已更新${NC}"
    echo
    echo -e "${GREEN}✓ 带宽重调完成${NC}  新带宽: ${CYAN}${bw_mbps} Mbps${NC}  tc maxrate: ${CYAN}${_fq_maxrate}Mbit${NC}  rmem_max: ${CYAN}$(( _P_RMEM_MAX / 1048576 ))MB${NC}"
}

do_system_update() {
    clear
    echo -e "${L_BLUE}=== 系统更新 ===${NC}"
    echo

    local _kernel_before
    _kernel_before=$(uname -r)
    rm -f /var/run/reboot-required /var/run/reboot-required.pkgs 2>/dev/null || true

    echo -e "${L_BLUE}[ 1/2 ] apt update${NC}"
    apt-get update || { echo -e "${RED}✗ apt update 失败${NC}"; return 1; }

    echo -e "\n${L_BLUE}[ 2/2 ] apt upgrade${NC}"
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y || { echo -e "${RED}✗ apt upgrade 失败${NC}"; return 1; }
    echo -e "\n${GREEN}✓ 系统更新完成${NC}"

    # 检测是否有新内核
    local _need_reboot=0 _new_kernel=""
    [ -f /var/run/reboot-required ] && _need_reboot=1
    _new_kernel=$(dpkg -l 'linux-image-*' 2>/dev/null \
        | awk '/^ii/{print $2}' | sed 's/linux-image-//' \
        | grep -v 'dbg\|devel' | grep -E '^[0-9]' | sort -V | tail -1 || true)
    [ -n "$_new_kernel" ] && [ "$_new_kernel" != "$_kernel_before" ] && _need_reboot=1

    if [ $_need_reboot -eq 1 ]; then
        echo
        echo -e "${YELLOW}━━ 检测到新内核，需要重启 ━━${NC}"
        echo -e "  当前运行: ${CYAN}${_kernel_before}${NC}"
        [ -n "$_new_kernel" ] && [ "$_new_kernel" != "$_kernel_before" ] && \
            echo -e "  已安装:   ${GREEN}${_new_kernel}${NC}"
        [ -f /var/run/reboot-required.pkgs ] && \
            echo -e "  相关包:   ${WHITE}$(tr '\n' ' ' < /var/run/reboot-required.pkgs)${NC}"
        echo -ne "${L_PURPLE}立即重启？[Y/n]: ${NC}"
        read -r _r
        [[ ! "${_r:-Y}" =~ ^[Nn]$ ]] && { for _i in 3 2 1; do printf "\r${GREEN}%d 秒后重启...${NC}" $_i; sleep 1; done; echo; reboot; }
    else
        echo -e "  ${GREEN}内核无更新，无需重启${NC}"
    fi
}

do_quick_init() {
    clear
    echo -e "${L_PURPLE}════ 一键初始化 ════${NC}"
    echo -e " 执行顺序: ${CYAN}关闭IPv6${NC} → ${CYAN}系统更新${NC} → ${CYAN}服务器名称${NC} → ${CYAN}XanMod内核${NC} → ${CYAN}网络优化${NC} → ${CYAN}防火墙${NC} → ${CYAN}TCPing${NC}"
    echo -e " 带宽需人工确认，安装内核后需重启以启用 BBR v3"
    echo

    local _ok_sys=0 _ok_net=0 _ok_fw=0 _ok_f2b=0 _ok_tg=0
    local _net_bw=0 _rmem_mb=0 _cc="cubic"
    local _xanmod_done=0 _xanmod_pkg="" _xanmod_avx=""
    local _init_srv_name=""

    # ── [1/5] IPv6 ───────────────────────────────────────────
    local _cur_ipv6=""
    echo -e "\n${L_BLUE}[1/5] IPv6 配置${NC}"
    if [ -f "/etc/sysctl.d/99-disable-ipv6.conf" ]; then
        echo -e "  IPv6: ${RED}已禁用（跳过）${NC}"
    else
        _write_disable_ipv6_conf
        echo -e "  IPv6: ${RED}已禁用${NC}"
    fi

    # ── [2/5] 系统更新 & 依赖安装 ───────────────────────────
    echo -e "\n${L_BLUE}[2/5] 系统更新 & 依赖安装${NC}"

    if ! check_package_manager_lock; then return; fi

    local _dns_pkg="dnsutils"
    apt-cache show bind9-dnsutils >/dev/null 2>&1 && _dns_pkg="bind9-dnsutils"
    local _qi_deps=(
        curl wget ca-certificates apt-transport-https openssl
        unzip zip tar gzip xz-utils jq gnupg gnupg2 lsb-release
        bc net-tools iproute2 iputils-ping "$_dns_pkg" vim nano htop tree lsof
        screen psmisc bsdmainutils iptables iptables-persistent netfilter-persistent
        at mtr iperf3 ipset isc-dhcp-client conntrack procps systemd-timesyncd
        socat netcat-openbsd fail2ban python3-systemd
    )

    if ! dpkg-query -W -f='${Status}' "iptables-persistent" 2>/dev/null | grep -q "ok installed"; then
        echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections 2>/dev/null || true
        echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections 2>/dev/null || true
    fi

    (apt-get update -qq < /dev/null >/dev/null 2>&1) &
    local _upd_pid=$!
    show_spinner $_upd_pid "  更新软件源"
    wait $_upd_pid && echo -e "  更新软件源: ${GREEN}完成${NC}" || echo -e "  更新软件源: ${YELLOW}失败（继续）${NC}"

    (DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq < /dev/null >/dev/null 2>&1) &
    local _upg_pid=$!
    show_spinner $_upg_pid "  升级系统组件"
    wait $_upg_pid && echo -e "  升级系统组件: ${GREEN}完成${NC}" || echo -e "  升级系统组件: ${YELLOW}部分失败（继续）${NC}"

    echo -e "  ${CYAN}--- 依赖检查 ---${NC}"
    local _to_install=() _pkg
    if apt-cache show software-properties-common >/dev/null 2>&1; then
        if ! dpkg-query -W -f='${Status}' "software-properties-common" 2>/dev/null | grep -q "ok installed"; then
            _to_install+=("software-properties-common")
        fi
    fi
    for _pkg in "${_qi_deps[@]}"; do
        if dpkg-query -W -f='${Status}' "$_pkg" 2>/dev/null | grep -q "ok installed"; then
            echo -e "  [${_pkg}]: ${GREEN}已安装${NC}"
        elif apt-cache show "$_pkg" >/dev/null 2>&1; then
            echo -e "  [${_pkg}]: ${YELLOW}缺失（将安装）${NC}"
            _to_install+=("$_pkg")
        else
            echo -e "  [${_pkg}]: ${CYAN}源中未找到（跳过）${NC}"
        fi
    done

    local _step_ok=1
    if [ ${#_to_install[@]} -gt 0 ]; then
        echo -e "  ${CYAN}--- 安装缺失组件 ---${NC}"
        (DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${_to_install[@]}" < /dev/null >/dev/null 2>&1) &
        local _inst_pid=$!
        show_spinner $_inst_pid "  安装中"
        wait $_inst_pid || _step_ok=0

        echo -e "  ${CYAN}--- 安装结果 ---${NC}"
        local _install_fail=0  # H-02: 改名以区分 do_check_all 中的 _fail
        for _pkg in "${_to_install[@]}"; do
            if dpkg-query -W -f='${Status}' "$_pkg" 2>/dev/null | grep -q "ok installed"; then
                echo -e "  [${_pkg}]: ${GREEN}安装成功${NC}"
            else
                echo -e "  [${_pkg}]: ${RED}安装失败${NC}"
                _install_fail=$(( _install_fail + 1 ))
            fi
        done
        [ $_install_fail -gt 0 ] && _step_ok=0 && \
            echo -e "  ${YELLOW}⚠ ${_install_fail} 个组件失败，建议手动: apt-get install -y ${_to_install[*]}${NC}"
    fi

    # 依赖装完后获取服务器 IP 和地理信息并写缓存，后续启动直接读缓存无需 curl
    if command -v curl &>/dev/null; then
        local _ip
        _ip=$(get_public_ip 2>/dev/null || true)
        if [[ "$_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            SERVER_IP="$_ip"
            get_geo_info "$_ip" || true
            local _flag; _flag=$(get_flag_emoji "$SERVER_COUNTRY_CODE")
            echo -e "  公网IP: ${CYAN}${SERVER_IP}${NC}  ${_flag} ${SERVER_COUNTRY_NAME}${SERVER_CITY:+ · ${SERVER_CITY}}"
            mkdir -p "$WORK_DIR"
            {
                printf 'SERVER_IP=%s\n'           "$SERVER_IP"
                printf 'SERVER_COUNTRY_CODE=%s\n' "$SERVER_COUNTRY_CODE"
                printf 'SERVER_COUNTRY_NAME=%s\n' "$SERVER_COUNTRY_NAME"
                printf 'SERVER_CITY=%s\n'         "$SERVER_CITY"
            } > "$CACHE_FILE"
            chmod 600 "$CACHE_FILE"
        fi
    fi

    systemctl enable --now atd >/dev/null 2>&1 || true
    systemctl enable --now iptables >/dev/null 2>&1 || true
    systemctl enable --now netfilter-persistent >/dev/null 2>&1 || true
    # iperf3 服务设为手动模式（避免随机自启监听 5201，需要时手动 iperf3 -s）
    if systemctl list-unit-files iperf3.service &>/dev/null; then
        systemctl stop iperf3 >/dev/null 2>&1 || true
        systemctl disable iperf3 >/dev/null 2>&1 || true
        echo -e "  ${GREEN}iperf3 服务已禁用 (手动运行模式)${NC}"
    fi

    # 自动时区设置（根据 IP 地理位置）
    local _tz=""
    for _tz_url in "https://ipinfo.io/timezone" "https://ipapi.co/timezone"; do
        _tz=$(curl -s --max-time 5 "$_tz_url" 2>/dev/null | tr -d '[:space:]')
        [[ "$_tz" =~ ^[A-Za-z]+/[A-Za-z_]+ ]] && break
        _tz=""
    done
    if [[ -n "$_tz" ]]; then
        timedatectl set-timezone "$_tz" >/dev/null 2>&1 && \
            echo -e "  ${GREEN}时区: 已自动设置为 ${_tz}${NC}" || \
            echo -e "  ${YELLOW}⚠ 时区设置失败: ${_tz}${NC}"
    else
        echo -e "  ${YELLOW}⚠ 时区自动检测失败，当前保持: $(timedatectl show -p Timezone --value 2>/dev/null)${NC}"
    fi

    # 写入时区自动同步脚本，每 24 小时检测一次（应对 IP 位置库延迟更新）
    cat > /usr/local/bin/sync-timezone.sh << 'EOF'
#!/usr/bin/env bash
_tz=""
for _url in "https://ipinfo.io/timezone" "https://ipapi.co/timezone"; do
    _tz=$(curl -s --max-time 5 "$_url" 2>/dev/null | tr -d '[:space:]')
    [[ "$_tz" =~ ^[A-Za-z]+/[A-Za-z_]+ ]] && break
    _tz=""
done
[ -z "$_tz" ] && exit 0
_cur=$(timedatectl show -p Timezone --value 2>/dev/null)
[ "$_tz" = "$_cur" ] && exit 0
timedatectl set-timezone "$_tz" && logger "sync-timezone: updated $_cur -> $_tz"
EOF
    chmod +x /usr/local/bin/sync-timezone.sh
    # 每天 03:00 执行，避免高峰期
    if ! crontab -l 2>/dev/null | grep -q "sync-timezone"; then
        (crontab -l 2>/dev/null || true; echo "0 3 * * * /usr/local/bin/sync-timezone.sh") | crontab -
        echo -e "  ${GREEN}时区自动同步: 已设置 cron (每天 03:00)${NC}"
    else
        echo -e "  ${GREEN}时区自动同步: cron 已存在，跳过${NC}"
    fi

    # NTP 时间同步
    if timedatectl show 2>/dev/null | grep -q "NTPSynchronized=yes"; then
        echo -e "  ${GREEN}NTP 时间同步: 已同步${NC}"
    else
        if systemctl enable --now systemd-timesyncd >/dev/null 2>&1 && \
           timedatectl set-ntp true >/dev/null 2>&1; then
            echo -e "  ${GREEN}NTP 时间同步: 已启用 (systemd-timesyncd)${NC}"
        else
            echo -e "  ${YELLOW}⚠ NTP 时间同步启用失败，请手动检查 systemd-timesyncd${NC}"
        fi
    fi

    _ok_sys=$_step_ok

    # ── 服务器名称 ────────────────────────────────────────────
    echo -ne "\n  服务器名称 (如 🇯🇵SR_JP_Std，回车自动填): "
    read -r _init_srv_name < /dev/tty || true

    # ── [3/5] XanMod 内核安装 (BBR v3) ──────────────────────
    echo -e "\n${L_BLUE}[3/5] XanMod 内核安装 (BBR v3)${NC}"
    if [ "$(uname -m)" != "x86_64" ]; then
        echo -e "  ${YELLOW}跳过（XanMod 仅支持 x86_64，当前架构: $(uname -m)）${NC}"
        local _arm_bv; _arm_bv=$(_get_bbr_version)
        if [ "$_arm_bv" = "v3" ]; then
            echo -e "  ${GREEN}当前内核 $(uname -r) 已支持 BBR v3，无需 XanMod${NC}"
        else
            echo -e "  ${YELLOW}当前内核 $(uname -r) 支持 BBR ${_arm_bv}，BBR v3 需主线内核 ≥ 6.9${NC}"
        fi
        _xanmod_done=2
    elif uname -r | grep -qi "xanmod"; then
        echo -e "  ${GREEN}✓ 已运行 XanMod ($(uname -r))，无需重新安装${NC}"
        _xanmod_done=2
    else
        if grep -q "avx2" /proc/cpuinfo; then
            _xanmod_pkg="linux-xanmod-x64v3"; _xanmod_avx="x64v3 (AVX2)"
        else
            _xanmod_pkg="linux-xanmod-x64v2"; _xanmod_avx="x64v2 (无AVX2)"
        fi
        echo -e "  CPU: ${CYAN}${_xanmod_avx}${NC} → 将安装 ${CYAN}${_xanmod_pkg}${NC}"
        echo -ne "  安装 XanMod 内核以启用 BBR v3？[Y/n]: "
        local _xm_ans; read -r _xm_ans < /dev/tty || true
        local _pre_mem_mb _pre_swap_mb
        _pre_mem_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 1024)
        _pre_swap_mb=$(awk '/SwapTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
        if [[ "${_xm_ans:-Y}" =~ ^[Nn]$ ]]; then
            echo -e "  ${YELLOW}跳过（BBR v3 需要此内核）${NC}"
        elif [ "$_pre_mem_mb" -lt 400 ]; then
            echo -e "  ${RED}✗ 跳过（物理内存 ${_pre_mem_mb}MB < 400MB，XanMod 启动时会 OOM Panic）${NC}"
            echo -e "  ${CYAN}提示: 升级内存至 512MB+ 后可手动安装${NC}"
        else
            # RAM < 512MB 且无 Swap 时，临时建 512MB Swap 防止安装 OOM
            # 标志文件让 [4/5] _ensure_swap 在 XanMod 装完后按实际磁盘重建正式 Swap
            if [ "$_pre_mem_mb" -lt 512 ] && [ "$_pre_swap_mb" -eq 0 ]; then
                echo -e "  ${YELLOW}内存 ${_pre_mem_mb}MB，临时创建 512MB Swap 供安装使用...${NC}"
                fallocate -l 512M /swapfile 2>/dev/null || \
                    dd if=/dev/zero of=/swapfile bs=1M count=512 status=none
                chmod 600 /swapfile
                mkswap /swapfile >/dev/null 2>&1 && swapon /swapfile >/dev/null 2>&1 || true
                touch /tmp/.swap_is_temp
            fi
            local _xm_ok=1
            # Debian 13 默认无 gpg 命令，须先装 gnupg2
            if ! command -v gpg >/dev/null 2>&1; then
                DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gnupg2 < /dev/null >/dev/null 2>&1 || true
            fi
            # 导入 GPG Key
            if [ ! -f /usr/share/keyrings/xanmod-archive-keyring.gpg ]; then
                (curl -fsSL https://dl.xanmod.org/archive.key | \
                    gpg --dearmor -o /usr/share/keyrings/xanmod-archive-keyring.gpg 2>/dev/null) &
                local _gpg_pid=$!
                show_spinner $_gpg_pid "  导入 XanMod GPG key"
                wait $_gpg_pid || { echo -e "  ${RED}✗ GPG key 导入失败${NC}"; _xm_ok=0; }
            fi
            if [ "$_xm_ok" -eq 1 ]; then
                # 写入仓库源
                local _xm_codename; _xm_codename=$(lsb_release -sc 2>/dev/null || grep -oP 'VERSION_CODENAME=\K\S+' /etc/os-release)
                echo "deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org ${_xm_codename} main" \
                    > /etc/apt/sources.list.d/xanmod-release.list
                (apt-get update -qq < /dev/null >/dev/null 2>&1) &
                local _xm_pid=$!
                show_spinner $_xm_pid "  更新软件源 (含 XanMod)"
                wait $_xm_pid || true
                # 安装内核
                local _xm_img _xm_hdr
                _xm_img=$(apt-cache show "${_xanmod_pkg}" 2>/dev/null \
                    | grep -m1 "^Depends:" | grep -oP 'linux-image-\S+' | head -1) || true
                _xm_hdr="${_xm_img/image/headers}"
                if [ -z "$_xm_img" ]; then
                    echo -e "  ${RED}✗ 无法获取内核包名，请手动: apt-get install -y ${_xanmod_pkg}${NC}"
                else
                    (DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$_xm_img" "$_xm_hdr" < /dev/null >/dev/null 2>&1) &
                    _xm_pid=$!
                    show_spinner $_xm_pid "  安装 ${_xm_img}"
                    if wait $_xm_pid; then
                        sed -i 's|^GRUB_DEFAULT=.*|GRUB_DEFAULT=0|' /etc/default/grub
                        update-grub >/dev/null 2>&1 || true
                        echo -e "  ${GREEN}✓ 安装完成，GRUB 已更新，重启后自动加载 XanMod${NC}"
                        _xanmod_done=1
                    else
                        echo -e "  ${RED}✗ 安装失败，请手动: apt-get install -y ${_xm_img} ${_xm_hdr}${NC}"
                    fi
                fi
            fi
        fi
    fi

    # ── [4/5] 网络优化 (DNS + Swap + sysctl) ────────────────
    echo -e "\n${L_BLUE}[4/5] 网络优化 (DNS + sysctl)${NC}"
    local phys_mem_mb
    phys_mem_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "1024")

    # DNS
    # 若 /etc/resolv.conf 是符号链接（systemd-resolved 系统），先删除再创建真实文件
    # 否则 chattr +i 对 tmpfs 目标静默失败，重启后 DNS 被 systemd-resolved 覆盖
    if [ -L /etc/resolv.conf ]; then
        rm -f /etc/resolv.conf
    fi
    if [ -f /etc/resolv.conf ] || [ ! -e /etc/resolv.conf ]; then
        chattr -i /etc/resolv.conf 2>/dev/null || true
        cat > /etc/resolv.conf <<'DNSEOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 94.140.14.14
options timeout:2 attempts:2
DNSEOF
        chattr +i /etc/resolv.conf 2>/dev/null || true
        echo -e "  DNS: ${GREEN}8.8.8.8 / 1.1.1.1 / 94.140.14.14 (已锁定)${NC}"
    fi

    # Swap（幂等，已存在则跳过）
    _ensure_swap

    # 带宽测速 + 端口速度（单一确认，同时用于 sysctl buffer 和 tc maxrate）
    printf "  测速中 (curl 8线程→Cloudflare)..."
    _measure_bandwidth 1000
    local bw_mbps=$_BW_MBPS
    echo -ne "  ${BLUE}端口速度 Mbps (回车用测速值，低于实际口速可手填) [${bw_mbps}]: ${NC}"
    local _port_input; read -r _port_input < /dev/tty || true
    _port_input=$(echo "$_port_input" | tr -d '[:space:]')
    [[ "$_port_input" =~ ^[0-9]+$ ]] && [ "$_port_input" -gt 0 ] && bw_mbps=$_port_input
    echo -e "  端口速度: ${GREEN}${bw_mbps} Mbps${NC}"

    # BBR / 拥塞控制
    if [ "$_xanmod_done" -eq 1 ]; then
        # XanMod 已安装但未重启；预写 sysctl，重启后 BBR v3 自动生效
        _cc="bbr"
        modprobe tcp_bbr 2>/dev/null || true
        sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
        sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
        echo -e "  ${GREEN}✓ BBR v3 待重启后生效 (${_xanmod_pkg}，sysctl 已预写入)${NC}"
    else
        modprobe tcp_bbr 2>/dev/null || true
        if grep -q "bbr" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
            _cc="bbr"
            sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
            sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
            if [ "$_xanmod_done" -eq 2 ]; then
                local _bv; _bv=$(_get_bbr_version)
                echo -e "  ${GREEN}✓ BBR ${_bv} 已生效 (XanMod $(uname -r | cut -d- -f1))${NC}"
            else
                echo -e "  ${GREEN}✓ BBR 已加载 (原版内核 BBR v1)${NC}"
            fi
        else
            echo -e "  ${YELLOW}⚠ BBR 模块不可用，将使用默认拥塞控制 (${_cc})${NC}"
        fi
    fi

    # 动态参数计算 & sysctl 写入
    _calc_sysctl_params "$phys_mem_mb" "$bw_mbps"
    _write_sysctl_conf "$bw_mbps" "$phys_mem_mb" "$_cc"
    sysctl --system >/dev/null 2>&1 || true
    sysctl -w net.ipv4.route.flush=1 >/dev/null 2>&1 || true
    _apply_conntrack_sysctl "$_P_CONNTRACK_MAX"
    _apply_nofile_limits

    _ok_net=1; _net_bw=$bw_mbps; _rmem_mb=$(( _P_RMEM_MAX / 1048576 ))
    echo -e "  ${GREEN}✓ sysctl 写入完成  rmem: ${_rmem_mb}MB  CC: ${_cc}${NC}"

    # sysctl default_qdisc=fq 只对新建接口生效，已有接口须用 tc 显式切换
    local _def_if _fq_maxrate
    _def_if=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    if [ -n "$_def_if" ] && command -v tc >/dev/null 2>&1; then
        _fq_maxrate=$(( bw_mbps * 98 / 100 ))
        [ "$_fq_maxrate" -lt 100 ] && _fq_maxrate=100
        if tc qdisc replace dev "$_def_if" root fq maxrate "${_fq_maxrate}mbit" flow_limit 250 2>/dev/null; then
            echo -e "  ${GREEN}✓ qdisc fq maxrate=${_fq_maxrate}mbit(${bw_mbps}Mbps×98%) flow_limit=250 → ${_def_if}${NC}"
            local _rc_local="/etc/rc.local" _rc_tmp
            _rc_tmp=$(mktemp)
            [ -f "$_rc_local" ] && cp "$_rc_local" "${_rc_local}.bak.$(TZ=Asia/Shanghai date +%Y%m%d%H%M%S)" 2>/dev/null || true
            {
                if [ -f "$_rc_local" ]; then
                    head -n 1 "$_rc_local" | grep -qE '^#!' && head -n 1 "$_rc_local" || echo '#!/bin/bash'
                    grep -v "^#!" "$_rc_local" \
                        | grep -v "tc qdisc replace.*root fq" \
                        | grep -v 'IFACE=.*ip route show default' \
                        | grep -v "^exit 0" || true
                else
                    echo '#!/bin/bash'
                fi
                printf 'IFACE=$(ip route show default 2>/dev/null | awk '"'"'{print $5; exit}'"'"')\n[ -n "$IFACE" ] && tc qdisc replace dev "$IFACE" root fq maxrate %smbit flow_limit 250 2>/dev/null || true\n' \
                    "$_fq_maxrate"
                echo 'exit 0'
            } > "$_rc_tmp" && mv "$_rc_tmp" "$_rc_local" || rm -f "$_rc_tmp"
            chmod +x "$_rc_local"
            if [ -d /etc/networkd-dispatcher/routable.d ]; then
                printf '#!/bin/bash\nIFACE=$(ip route show default 2>/dev/null | awk '"'"'{print $5; exit}'"'"')\n[ -n "$IFACE" ] && tc qdisc replace dev "$IFACE" root fq maxrate %smbit flow_limit 250 2>/dev/null || true\n' \
                    "$_fq_maxrate" > /etc/networkd-dispatcher/routable.d/10-fq-qdisc.sh
                chmod +x /etc/networkd-dispatcher/routable.d/10-fq-qdisc.sh
            fi
        else
            echo -e "  ${YELLOW}⚠ qdisc fq 切换失败（继续）${NC}"
        fi
    fi

    # ── [5/5] 防火墙初始化 ──────────────────────────────────
    echo -e "\n${L_BLUE}[5/5] 防火墙初始化${NC}"
    if command -v iptables >/dev/null 2>&1 && command -v at >/dev/null 2>&1; then
        do_init_firewall --auto
        _ok_fw=1
    else
        echo -e "  ${YELLOW}iptables/at 未就绪，跳过（请检查步骤 2 的安装结果）${NC}"
    fi

    # TG 推送配置
    echo -e "\n${L_BLUE}[+] TG 推送配置${NC}"
    if [[ -f "$TG_CONF" ]] && grep -q "^TG_BOT_TOKEN=" "$TG_CONF" 2>/dev/null; then
        echo -e "  TG 推送: ${GREEN}已配置（跳过）${NC}"
        _ok_tg=1
    else
        echo -ne "  是否现在配置 TG 推送？[Y/n]: "
        local _tg_ans; read -r _tg_ans < /dev/tty || true
        if [[ ! "${_tg_ans}" =~ ^[Nn]$ ]]; then
            _tg_input_tokens "$_init_srv_name" && _ok_tg=1 || true
        else
            echo -e "  ${YELLOW}跳过（可后续从选项 3 配置）${NC}"
        fi
    fi

    # Fail2Ban 规则配置
    echo -e "\n${L_BLUE}[+] Fail2Ban${NC}"
    if [[ -f /etc/fail2ban/jail.d/sshd.conf ]]; then
        echo -e "  Fail2Ban: ${GREEN}已配置（跳过）${NC}"
        _ok_f2b=1
    else
        _install_fail2ban && _ok_f2b=1 || true
    fi

    # TCPing 监控（依赖 socat，防火墙就绪后才有意义）
    if command -v socat &>/dev/null || apt-get install -y -qq socat >/dev/null 2>&1; then
        _tcping_setup_silent
    else
        echo -e "  TCPing    ${YELLOW}跳过（socat 不可用）${NC}"
    fi

    # ── 汇总报告 ─────────────────────────────────────────────
    echo
    echo -e "${L_PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    [ $_ok_sys -eq 1 ] \
        && echo -e "  系统更新  ${GREEN}✓${NC}" \
        || echo -e "  系统更新  ${RED}✗${NC}"
    if [ "$_xanmod_done" -eq 1 ]; then
        echo -e "  XanMod    ${GREEN}✓${NC}  ${WHITE}${_xanmod_pkg} 已安装，重启后生效${NC}"
    elif [ "$_xanmod_done" -eq 2 ]; then
        echo -e "  XanMod    ${GREEN}✓${NC}  ${WHITE}已运行 $(uname -r | sed 's/-x64v.*//')${NC}"
    else
        echo -e "  XanMod    ${YELLOW}跳过${NC}"
    fi
    [ $_ok_net -eq 1 ] \
        && echo -e "  网络优化  ${GREEN}✓${NC}  ${WHITE}${_net_bw}Mbps  rmem ${_rmem_mb}MB  CC: ${_cc}${NC}" \
        || echo -e "  网络优化  ${RED}✗${NC}"
    [ $_ok_fw -eq 1 ] \
        && echo -e "  防火墙    ${GREEN}✓${NC}" \
        || echo -e "  防火墙    ${YELLOW}跳过${NC}"
    [ $_ok_tg -eq 1 ] \
        && echo -e "  TG 推送   ${GREEN}✓${NC}" \
        || echo -e "  TG 推送   ${YELLOW}跳过${NC}"
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        local _fb_banned; _fb_banned=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | awk '{print $NF}' || echo "0")
        echo -e "  Fail2Ban  ${GREEN}✓${NC}  ${WHITE}封禁 ${_fb_banned}${NC}"
    else
        echo -e "  Fail2Ban  ${YELLOW}跳过${NC}"
    fi
    if systemctl is-active --quiet "$TCPING_SERVICE_NAME" 2>/dev/null; then
        local _tp; _tp=$(grep "^PORT=" "$TCPING_CONFIG_FILE" 2>/dev/null | cut -d= -f2 || echo "?")
        echo -e "  TCPing    ${GREEN}✓${NC}  ${WHITE}端口 ${_tp}${NC}"
    else
        echo -e "  TCPing    ${YELLOW}跳过${NC}"
    fi
    if [ "$_cc" = "bbr" ]; then
        if [ "$_xanmod_done" -eq 1 ]; then
            echo -e "  BBR v3    ${CYAN}⟳${NC}  ${WHITE}待重启后生效 (sysctl 已预写入)${NC}"
        elif [ "$_xanmod_done" -eq 2 ]; then
            echo -e "  BBR v3    ${GREEN}✓${NC}  ${WHITE}已生效 (XanMod 内核)${NC}"
        else
            echo -e "  BBR       ${GREEN}✓${NC}  ${WHITE}已启用 (原版内核 BBR v1)${NC}"
        fi
    else
        echo -e "  BBR       ${RED}✗${NC}  ${WHITE}内核不支持，当前使用 ${_cc}${NC}"
    fi
    echo -e "${L_PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    # 新安装内核后给出重启提示
    if [ "$_xanmod_done" -eq 1 ]; then
        echo
        echo -e "  ${L_PURPLE}★ 请重启服务器以加载 XanMod 内核，BBR v3 方可生效${NC}"
        echo -ne "  ${L_PURPLE}立即重启？[Y/n]: ${NC}"
        local _rb_ans; read -r _rb_ans < /dev/tty || true
        [[ "${_rb_ans:-Y}" =~ ^[Nn]$ ]] || reboot
    fi
}


# ==============================================================================
# BBR 状态检测
# ==============================================================================

_get_bbr_version() {
    # M-02: 使用会话级缓存，内核内 BBR 版本在一次运行期间不会改变
    [ -n "$_G_BBR_VER" ] && { echo "$_G_BBR_VER"; return; }
    if ! grep -q "bbr" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        _G_BBR_VER="none"; echo "none"; return
    fi
    # 通过模块版本号检测：modinfo tcp_bbr | version 字段，v3 补丁内核（XanMod 等）输出 3
    local _bmod
    _bmod=$(modinfo tcp_bbr 2>/dev/null | awk '/^version:/{print $2}')
    if [ "$_bmod" = "3" ]; then
        _G_BBR_VER="v3"; echo "v3"
    else
        _G_BBR_VER="v1"; echo "v1"
    fi
}


# ==============================================================================
# 主菜单
# ==============================================================================

# 全局日志辅助函数（定义在全局，避免在循环内重复定义污染命名空间）
_filter_fw_logs() {
    # L-04 修复: 匹配包含 DROP/REJECT/BLOCK 的内核日志行（包含 INPUT 方向 OUT= 为空的情况）
    grep -E --line-buffered 'IPT-DROP:|IN=[^ ]+.*\b(DROP|REJECT|BLOCK)\b' || true
}
_run_live_log() {
    if command -v journalctl &>/dev/null; then
        journalctl -k -f
    elif [ -f /var/log/kern.log ]; then
        tail -f /var/log/kern.log
    else
        dmesg -w
    fi
}
_run_static_log() {
    if command -v journalctl &>/dev/null; then
        journalctl -k -n 100 --no-pager
    elif [ -f /var/log/kern.log ]; then
        tail -n 100 /var/log/kern.log
    else
        dmesg | tail -n 100
    fi
}

# 两列菜单行输出函数：内部直接读取 COLUMNS，不依赖任何外部变量（H-03 修复）
_f2b_iptables_accept() {
    local _action="$1" _ip="$2"
    if [ "$_action" = "add" ]; then
        iptables -C INPUT -s "$_ip" -m comment --comment "f2b-whitelist" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT 1 -s "$_ip" -m comment --comment "f2b-whitelist" -j ACCEPT
    else
        iptables -D INPUT -s "$_ip" -m comment --comment "f2b-whitelist" -j ACCEPT 2>/dev/null || true
    fi
}

_f2b_apply_all_iptables() {
    [ -f "$F2B_WHITELIST" ] || return 0
    while IFS= read -r _line; do
        [[ -z "$_line" || "$_line" == \#* ]] && continue
        _f2b_iptables_accept add "$_line"
    done < "$F2B_WHITELIST"
    _persist_iptables
}

_f2b_build_ignoreip() {
    local _ips="127.0.0.1/8 ::1"
    if [ -f "$F2B_WHITELIST" ]; then
        while IFS= read -r _line; do
            [[ -z "$_line" || "$_line" == \#* ]] && continue
            _ips="$_ips $_line"
        done < "$F2B_WHITELIST"
    fi
    echo "$_ips"
}

_f2b_reload_whitelist() {
    local _ignoreip
    _ignoreip=$(_f2b_build_ignoreip)
    if [ -f /etc/fail2ban/jail.d/sshd.conf ]; then
        if grep -q "^ignoreip" /etc/fail2ban/jail.d/sshd.conf; then
            sed -i "s|^ignoreip.*|ignoreip = ${_ignoreip}|" /etc/fail2ban/jail.d/sshd.conf
        else
            sed -i "/^\[sshd\]/a ignoreip = ${_ignoreip}" /etc/fail2ban/jail.d/sshd.conf
        fi
    fi
    systemctl is-active --quiet fail2ban 2>/dev/null && \
        fail2ban-client reload sshd >/dev/null 2>&1 || true
}

_install_fail2ban() {
    if command -v fail2ban-client &>/dev/null; then
        echo -e "\n${L_CYAN}配置 Fail2Ban...${NC}"
    else
        echo -e "\n${L_CYAN}安装 Fail2Ban...${NC}"
        if ! command -v apt-get &>/dev/null; then
            echo -e "${RED}仅支持 apt 系统${NC}"; return 1
        fi
        apt-get update -qq || { echo -e "${RED}✗ apt-get update 失败${NC}"; return 1; }
        if ! apt-get install -y fail2ban python3-systemd >/dev/null 2>&1; then
            echo -e "${RED}✗ Fail2Ban 安装失败，请检查 apt 源${NC}"; return 1
        fi
        command -v fail2ban-client &>/dev/null || { echo -e "${RED}✗ 安装后未找到 fail2ban-client${NC}"; return 1; }
    fi

    local _ssh_port
    _ssh_port=$(get_current_ssh_port)
    local _f2b_action="%(action_)s"
    [ -f /etc/fail2ban/action.d/tg-notify.conf ] && \
        _f2b_action="${_f2b_action}
           tg-notify"
    cat > /etc/fail2ban/jail.d/sshd.conf <<EOF
[sshd]
enabled  = true
port     = ${_ssh_port}
maxretry = 3
bantime  = -1
findtime = 24h
backend  = systemd
ignoreip = $(_f2b_build_ignoreip)
action   = ${_f2b_action}
EOF
    _f2b_apply_all_iptables
    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban 2>/dev/null || true
    sleep 2
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        echo -e "${GREEN}✓ Fail2Ban 已启动${NC}"
        echo -e "  SSH 配置: 24小时内失败 3 次 → 永久封禁  端口: ${_ssh_port}"
        fail2ban-client status sshd 2>/dev/null || true
    else
        echo -e "${RED}✗ fail2ban 启动失败，请检查: journalctl -u fail2ban${NC}"
    fi
}

_setup_ssh_tg_monitor() {
    echo -e "\n${L_CYAN}配置 SSH 登录 TG 通知${NC}"

    local _token="" _chat="" _alias=""
    if [ -f "$SSH_TG_CONF" ]; then
        _token=$(grep "^TG_BOT_TOKEN=" "$SSH_TG_CONF" 2>/dev/null | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" || true)
        _chat=$(grep  "^TG_CHAT_ID="   "$SSH_TG_CONF" 2>/dev/null | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" || true)
        _alias=$(grep "^SERVER_NAME="  "$SSH_TG_CONF" 2>/dev/null | cut -d= -f2- | sed 's/^"//;s/"$//' || true)
    fi

    if [ -z "$_token" ] || [ -z "$_chat" ]; then
        echo -e "${RED}未找到 TG Token/Chat ID，请先在主菜单 ★4「TG 推送配置」中设置${NC}"
        return 1
    fi
    echo -e "  使用已配置的 Token=${_token:0:20}...  ChatID=${_chat}"

    # 停止旧服务并杀掉所有残留进程
    systemctl stop "$SSH_TG_SERVICE" 2>/dev/null || true
    pkill -9 -f "$(basename "$SSH_TG_SCRIPT")" 2>/dev/null || true
    local _wait=0
    while pgrep -f "$(basename "$SSH_TG_SCRIPT")" >/dev/null 2>&1; do
        sleep 1; (( _wait++ )); [ "$_wait" -ge 5 ] && break
    done

    cat > "$SSH_TG_SCRIPT" <<'MONITOR_EOF'
#!/bin/bash
CONF="/etc/ssh-tg-monitor.conf"
[ -f "$CONF" ] || { echo "Config not found" >&2; exit 1; }
# shellcheck source=/dev/null
source "$CONF"

SERVER_NAME=$(grep "^SERVER_NAME=" "$CONF" 2>/dev/null | cut -d= -f2- | sed 's/^"//;s/"$//' || true)
if [ -z "$SERVER_NAME" ]; then
    SERVER_NAME=$(curl -4 -s --max-time 8 https://ip.sb 2>/dev/null \
               || curl -4 -s --max-time 8 https://ifconfig.me 2>/dev/null \
               || echo "unknown")
fi

# 纯字母数字标签 → 国旗 + #tag；已含 emoji/空格 → 直接显示
_srv_display() {
    local _n="$1"
    if [[ "$_n" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        local _cc; _cc=$(grep "^SERVER_COUNTRY_CODE=" /opt/proxy-manager/server_info.cache 2>/dev/null | cut -d= -f2- | tr -d '[:space:]"' || true)
        local _f=""
        if [[ ${#_cc} -eq 2 && "$_cc" =~ ^[A-Za-z]+$ ]]; then
            _f=$(python3 -c "cc='${_cc^^}'; print(chr(0x1F1E6+ord(cc[0])-65)+chr(0x1F1E6+ord(cc[1])-65),end='')" 2>/dev/null || true)
        fi
        echo "${_f:+${_f} }#${_n}"
    else
        echo "$_n"
    fi
}
send_tg() {
    curl -s --max-time 10 \
        "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT_ID}" \
        -d "parse_mode=HTML" \
        --data-urlencode "text=$1" \
        >/dev/null 2>&1 || true
}

_wl_remark() {
    local _ip="$1" _wl="/etc/fail2ban/f2b-whitelist.conf"
    [ -f "$_wl" ] && grep -qxF "$_ip" "$_wl" && echo "管理IP"
}

_unit=""
for _u in ssh sshd; do
    systemctl cat "${_u}.service" &>/dev/null && _unit="$_u" && break
done
[ -z "$_unit" ] && { echo "SSH service not found" >&2; exit 1; }

journalctl -u "$_unit" --follow --lines=0 --output=cat 2>/dev/null \
| while IFS= read -r line; do
    ts=$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')
    SERVER_DISPLAY=$(_srv_display "$SERVER_NAME")
    if echo "$line" | grep -qE 'Accepted (password|publickey)'; then
        user=$(echo "$line"   | grep -oP 'for \K\S+(?= from)'  | head -1 || true)
        ip=$(echo "$line"     | grep -oP 'from \K[\d.]+'        | head -1 || true)
        method=$(echo "$line" | grep -oP '(?<=Accepted )\w+'    | head -1 || true)
        remark=$(_wl_remark "$ip")
        ip_label="<code>${ip:-unknown}</code>${remark:+ → #${remark}}"
        send_tg "✅ #SSH登录成功
服务器: ${SERVER_DISPLAY}
用户: ${user:-unknown}  来源: ${ip_label}
方式: ${method:-unknown}  时间: ${ts}"
    elif echo "$line" | grep -qE 'Failed (password|publickey) for'; then
        user=$(echo "$line" | grep -oP 'for (invalid user )?\K\S+(?= from)' | head -1 || true)
        ip=$(echo "$line"   | grep -oP 'from \K[\d.]+' | head -1 || true)
        remark=$(_wl_remark "$ip")
        ip_label="<code>${ip:-unknown}</code>${remark:+ → #${remark}}"
        send_tg "⚠️ #SSH登录失败
服务器: ${SERVER_DISPLAY}
用户: ${user:-unknown}  来源: ${ip_label}
时间: ${ts}"
    fi
done
MONITOR_EOF
    chmod 700 "$SSH_TG_SCRIPT"

    # fail2ban 封禁通知脚本
    mkdir -p /etc/fail2ban/action.d
    cat > /usr/local/bin/fail2ban-tg-notify.sh <<'F2B_EOF'
#!/bin/bash
CONF="/etc/ssh-tg-monitor.conf"
[ -f "$CONF" ] || exit 0
# shellcheck source=/dev/null
source "$CONF"
IP="$1" JAIL="$2" FAILURES="$3"
SERVER_NAME=$(grep "^SERVER_NAME=" "$CONF" 2>/dev/null | cut -d= -f2- | sed 's/^"//;s/"$//' || true)
if [ -z "$SERVER_NAME" ]; then
    SERVER_NAME=$(curl -4 -s --max-time 5 https://ip.sb 2>/dev/null \
               || hostname -I 2>/dev/null | awk '{print $1}' \
               || echo "unknown")
fi
if [[ "$SERVER_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    _cc=$(grep "^SERVER_COUNTRY_CODE=" /opt/proxy-manager/server_info.cache 2>/dev/null | cut -d= -f2- | tr -d '[:space:]"' || true)
    _f=""
    [[ ${#_cc} -eq 2 && "$_cc" =~ ^[A-Za-z]+$ ]] && _f=$(python3 -c "cc='${_cc^^}'; print(chr(0x1F1E6+ord(cc[0])-65)+chr(0x1F1E6+ord(cc[1])-65),end='')" 2>/dev/null || true)
    SERVER_DISPLAY="${_f:+${_f} }#${SERVER_NAME}"
else
    SERVER_DISPLAY="$SERVER_NAME"
fi
ts=$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')
curl -s --max-time 10 \
    "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    -d "parse_mode=HTML" \
    --data-urlencode "text=🚫 #IP已封禁
服务器: ${SERVER_DISPLAY}
封禁IP: <code>${IP}</code>
原因: 登录失败3次，永久封禁
时间: ${ts}" \
    >/dev/null 2>&1 || true
F2B_EOF
    chmod 700 /usr/local/bin/fail2ban-tg-notify.sh

    cat > /etc/fail2ban/action.d/tg-notify.conf <<'F2B_ACT'
[Definition]
actionban = conntrack -D -s <ip> >/dev/null 2>&1 || true
            /usr/local/bin/fail2ban-tg-notify.sh <ip> <name> <failures>
actionunban =
F2B_ACT

    cat > "/etc/systemd/system/${SSH_TG_SERVICE}.service" <<EOF
[Unit]
Description=SSH Login TG Notifier
After=network.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SSH_TG_SCRIPT}
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable "$SSH_TG_SERVICE" 2>/dev/null || true
    systemctl restart "$SSH_TG_SERVICE" 2>/dev/null || true
    sleep 1
    if systemctl is-active --quiet "$SSH_TG_SERVICE" 2>/dev/null; then
        # 发送启动测试消息
        local _ts _alias_display
        _ts=$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')
        if [[ "$_alias" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            local _cc_s _gf=""
            _cc_s=$(grep -E '^SERVER_COUNTRY_CODE=' "$CACHE_FILE" 2>/dev/null | head -1 | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" || true)
            # cache 无效时现场查 geo
            if [[ -z "$_cc_s" || "$_cc_s" == "UN" || ${#_cc_s} -ne 2 ]]; then
                _cc_s=$(curl -sf --max-time 8 "https://ipinfo.io/country" 2>/dev/null | tr -d '[:space:]' || true)
            fi
            if [[ ${#_cc_s} -eq 2 && "$_cc_s" =~ ^[A-Za-z]+$ ]]; then
                _gf=$(python3 -c "cc='${_cc_s^^}'; print(chr(0x1F1E6+ord(cc[0])-65)+chr(0x1F1E6+ord(cc[1])-65),end='')" 2>/dev/null || true)
            fi
            _alias_display="${_gf:+${_gf} }#${_alias}"
        else
            _alias_display="$_alias"
        fi
        curl -s --max-time 10 \
            "https://api.telegram.org/bot${_token}/sendMessage" \
            -d "chat_id=${_chat}" \
            -d "parse_mode=HTML" \
            --data-urlencode "text=✅ #SSH监控已启动
服务器: ${_alias_display}
时间: ${_ts}" >/dev/null 2>&1 || true
        echo -e "${GREEN}✓ TG 推送服务已启动，已发送测试消息${NC}"
    else
        echo -e "${RED}✗ 服务启动失败，请检查: journalctl -u ${SSH_TG_SERVICE}${NC}"
    fi

}

do_ssh_security() {
    while true; do
        clear
        echo -e "${L_BLUE}:: Fail2Ban ::${NC}\n"

        local _fb_st
        if systemctl is-active --quiet fail2ban 2>/dev/null; then
            local _banned
            _banned=$(fail2ban-client status sshd 2>/dev/null \
                      | grep "Currently banned" | awk '{print $NF}' || echo "?")
            _fb_st="${GREEN}运行中 (已封禁: ${_banned})${NC}"
        elif command -v fail2ban-client &>/dev/null; then
            _fb_st="${YELLOW}已安装未运行${NC}"
        else
            _fb_st="${RED}未安装${NC}"
        fi

        echo -e "  Fail2Ban : $_fb_st\n"
        local _wl_count
        _wl_count=$(awk '!/^#|^[[:space:]]*$/{c++} END{print c+0}' "$F2B_WHITELIST" 2>/dev/null || echo 0)
        echo -e "  1. 白名单管理  [${_wl_count} 个 IP]"
        echo -e "  2. 查看封禁 IP 列表"
        echo -e "  0. 返回\n"
        echo -ne "${BLUE}请选择 [0-2]: ${NC}"; read -r _sec_ch
        case "$_sec_ch" in
            1)
                clear
                echo -e "${L_BLUE}--- Fail2Ban 白名单 ---${NC}\n"
                echo -e "  当前白名单:"
                if [ -f "$F2B_WHITELIST" ] && grep -qv "^#\|^[[:space:]]*$" "$F2B_WHITELIST" 2>/dev/null; then
                    grep -v "^#\|^[[:space:]]*$" "$F2B_WHITELIST" | awk '{print $1}' | nl -ba | \
                        while IFS= read -r _l; do echo -e "    ${CYAN}${_l}${NC}"; done
                else
                    echo -e "    ${YELLOW}（空）${NC}"
                fi
                echo
                echo -ne "${L_PURPLE}输入要添加的 IP/CIDR (回车跳过): ${NC}"; read -r _wl_add < /dev/tty || true
                if [[ -n "$_wl_add" ]]; then
                    if validate_ip_cidr "$_wl_add"; then
                        echo "${_wl_add}" >> "$F2B_WHITELIST"
                        _f2b_reload_whitelist
                        _f2b_iptables_accept add "$_wl_add"
                        _persist_iptables
                        fail2ban-client set sshd unbanip "$_wl_add" >/dev/null 2>&1 || true
                        echo -e "${GREEN}✓ ${_wl_add} 已加入白名单${NC}"
                    else
                        echo -e "${RED}✗ IP 格式无效${NC}"
                    fi
                fi
                echo -ne "${L_PURPLE}输入要删除的 IP (回车跳过): ${NC}"; read -r _wl_del < /dev/tty || true
                if [[ -n "$_wl_del" ]]; then
                    if grep -qxF "$_wl_del" "$F2B_WHITELIST" 2>/dev/null; then
                        sed -i "/^${_wl_del//\./\\.}$/d" "$F2B_WHITELIST"
                        _f2b_reload_whitelist
                        _f2b_iptables_accept del "$_wl_del"
                        _persist_iptables
                        echo -e "${GREEN}✓ ${_wl_del} 已从白名单移除${NC}"
                    else
                        echo -e "${RED}✗ 未在白名单中找到该 IP${NC}"
                    fi
                fi
                pause
                ;;
            2)
                clear
                echo -e "${L_YELLOW}--- Fail2Ban 封禁 IP 列表 ---${NC}\n"
                if ! command -v fail2ban-client &>/dev/null; then
                    echo -e "${RED}Fail2Ban 未安装${NC}"; pause; continue
                fi
                fail2ban-client status sshd 2>/dev/null || echo -e "${YELLOW}fail2ban 未运行${NC}"
                echo
                echo -ne "${L_PURPLE}输入要解封的 IP (直接回车跳过): ${NC}"; read -r _unban_ip
                if [[ -n "$_unban_ip" ]]; then
                    if fail2ban-client set sshd unbanip "$_unban_ip" 2>/dev/null; then
                        echo -e "${GREEN}✓ ${_unban_ip} 已解封${NC}"
                    else
                        echo -e "${RED}✗ 解封失败，请确认 IP 是否在封禁列表中${NC}"
                    fi
                    pause
                fi
                ;;
            0|"") return ;;
            *) continue ;;
        esac
    done
}


# ==============================================================================
# 系统管理子菜单包装函数
# ==============================================================================

# 子菜单 5：系统维护 & 诊断
sys_maintenance_menu() {
    while true; do
        clear
        printf "${C_CYAN}=== 系统维护 & 诊断 ===${C_RESET}\n\n"
        printf " ${C_GREEN}1.${C_RESET} 系统更新\n"
        printf " ${C_GREEN}2.${C_RESET} 带宽重调 (sysctl+tc)\n"
        printf " ${C_GREEN}3.${C_RESET} IPv6 管理\n"
        printf " ${C_GREEN}4.${C_RESET} 一键参数检测\n"
        printf " ${C_GREEN}5.${C_RESET} 查看系统详情\n"
        printf " ${C_GREEN}6.${C_RESET} 修改服务器名称\n"
        printf " ${C_GREEN}7.${C_RESET} TCPing 监控\n"
        printf " ${C_GREEN}0.${C_RESET} 返回主菜单\n"
        printf "\n${C_CYAN}请选择 [0-7]: ${C_RESET}"
        read -r _msub
        case "$_msub" in
            1) do_system_update || true; pause ;;
            2) do_retune_bandwidth || true; pause ;;
            3) toggle_ipv6; pause ;;
            4) do_check_all; pause ;;
            6) _set_server_name; pause ;;
            7) do_tcping_monitor; pause ;;
            5)
                clear
                echo -e "${L_GREEN}--- 系统深度信息 ---${NC}"
                echo -e "${L_CYAN}Kernel:${NC} $(uname -r)"
                echo -e "${L_CYAN}Uptime:${NC} $(uptime -p)"
                echo -e "${L_CYAN}CPU Model:${NC} $(grep 'model name' /proc/cpuinfo | head -1 | awk -F: '{print $2}' | sed 's/^[ \t]*//')"
                echo -e "${L_CYAN}Load Avg:${NC} $(uptime | awk -F'load average:' '{print $2}')"
                echo
                free -h
                echo
                echo -e "${L_BLUE}[ 网络连接 ]${NC}"
                if command -v ss &>/dev/null; then
                    echo -e "TCP: $(ss -s | grep TCP | head -1 | awk '{print $2}')   UDP: $(ss -s | grep UDP | head -1 | awk '{print $2}')"
                else
                    echo "TCP/UDP info unavailable (ss missing)"
                fi
                echo -e "\n${L_BLUE}[ 流量统计 (主要接口) ]${NC}"
                local DEF_IF; DEF_IF=$(ip route show default 2>/dev/null | head -1 | awk '{print $5}')
                if [ -n "$DEF_IF" ]; then
                    echo -e "接口: ${GREEN}$DEF_IF${NC}"
                    ip -s link show "$DEF_IF" | awk '/RX:/{getline; print "RX: " $1 " bytes (" $2 " pkts)"} /TX:/{getline; print "TX: " $1 " bytes (" $2 " pkts)"}'
                else
                    echo "Default interface not found."
                fi
                echo -e "\n${L_BLUE}[ 磁盘使用 ]${NC}"
                df -hT | grep -E "^/dev|^Filesystem" | head -5
                pause
                ;;
            0|"") return ;;
            *) msg_warn "无效选项"; sleep 1 ;;
        esac
    done
}

# 子菜单 6：防火墙 & 规则
sys_firewall_menu() {
    while true; do
        clear
        printf "${C_CYAN}=== 防火墙 & 规则 ===${C_RESET}\n\n"
        printf " ${C_GREEN}1.${C_RESET} 重置防火墙策略\n"
        printf " ${C_GREEN}2.${C_RESET} 开放端口\n"
        printf " ${C_GREEN}3.${C_RESET} 删除规则\n"
        printf " ${C_GREEN}4.${C_RESET} IP 黑白名单管理\n"
        printf " ${C_GREEN}5.${C_RESET} 查看详细规则\n"
        printf " ${C_GREEN}6.${C_RESET} 查看监听端口\n"
        printf " ${C_GREEN}7.${C_RESET} 查看系统日志\n"
        printf " ${C_GREEN}0.${C_RESET} 返回主菜单\n"
        printf "\n${C_CYAN}请选择 [0-7]: ${C_RESET}"
        read -r _fsub
        case "$_fsub" in
            1) do_init_firewall; pause ;;
            2)
                echo -ne "${BLUE}端口: ${NC}"; read -r p
                if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
                    echo -e "${RED}无效端口号${NC}"; sleep 1; continue
                fi
                echo -ne "${BLUE}协议(tcp/udp/all)[tcp]: ${NC}"; read -r pr
                pr=${pr:-tcp}
                if [[ "$pr" != "tcp" && "$pr" != "udp" && "$pr" != "all" ]]; then
                    echo -e "${RED}无效协议，请输入 tcp/udp/all${NC}"; sleep 1; continue
                fi
                if [ "$pr" = "all" ]; then
                    _firewall_open_port "tcp" "$p"; _firewall_open_port "udp" "$p"
                else
                    _firewall_open_port "$pr" "$p"
                fi
                _persist_iptables
                echo -e "${GREEN}已开放${NC}"
                pause
                ;;
            3)
                local c del_mode del_port l
                echo -ne "${BLUE}链(INPUT/OUTPUT/FORWARD): ${NC}"; read -r c; c=${c:-INPUT}
                case "$c" in
                    INPUT|OUTPUT|FORWARD|PREROUTING|POSTROUTING) ;;
                    *) echo -e "${RED}无效链名${NC}"; sleep 1; continue ;;
                esac
                while true; do
                    clear
                    echo -e "${L_BLUE}:: 删除规则 ($c) ::${NC}"
                    echo -e "1. 按行号删除 (循环模式)"
                    echo -e "2. 按端口删除 (TCP+UDP 批量)"
                    echo -e "0. 返回"
                    echo
                    echo -ne "${L_PURPLE}请选择: ${NC}"; read -r del_mode
                    case "$del_mode" in
                        1)
                            while true; do
                                clear
                                iptables -L "$c" -nv --line-numbers
                                echo -e "\n${L_YELLOW}输入行号 (输入 0 返回上一级)${NC}"
                                echo -ne "${L_PURPLE}行号: ${NC}"; read -r l
                                if [[ -z "$l" ]]; then continue; fi
                                if [[ "$l" == "0" ]]; then break; fi
                                if ! [[ "$l" =~ ^[0-9]+$ ]]; then echo -e "${RED}无效数字${NC}"; sleep 1; continue; fi
                                if iptables -D "$c" "$l" 2>/dev/null; then
                                    _persist_iptables
                                    echo -e "${GREEN}规则 $l 已删除${NC}"
                                else
                                    echo -e "${RED}删除失败 (检查行号是否存在)${NC}"
                                fi
                                sleep 1
                            done
                            ;;
                        2)
                            echo -e "${L_BLUE}:: 本机监听端口 ::${NC}"
                            ss -tulpn 2>/dev/null | awk 'NR>1{
                                n=split($5,a,":");port=a[n]
                                proc=(NF>=7&&$7~/users/)?$7:"-"
                                gsub(/.*\(\("/,"",proc); gsub(/".*/, "",proc)
                                if(port+0>0) print port,proc
                            }' | sort -n | uniq | while read -r p name; do
                                echo -e "   -> ${GREEN}${p}${NC}\t(${name})"
                            done
                            echo
                            echo -ne "${L_PURPLE}请输入端口号: ${NC}"; read -r del_port
                            if [[ -n "$del_port" && "$del_port" =~ ^[0-9]+$ ]]; then
                                if _safe_iptables_remove_rule "dport ${del_port}[^0-9]" -E; then
                                    _persist_iptables
                                    echo -e "${GREEN}端口 $del_port 关联规则已全部移除${NC}"
                                else
                                    echo -e "${RED}删除失败，防火墙规则未更改${NC}"
                                fi
                                pause
                            else
                                echo -e "${RED}无效端口${NC}"; sleep 1
                            fi
                            ;;
                        0) break ;;
                        *) continue ;;
                    esac
                done
                ;;
            4)
                while true; do
                    clear
                    echo -e "${L_BLUE}:: IP 黑白名单管理 ::${NC}"
                    echo -e "1. 白名单 IP - 放行指定 IP/CIDR"
                    echo -e "2. 黑名单 IP - 屏蔽指定 IP/CIDR"
                    echo -e "0. 返回"
                    echo
                    echo -ne "${L_PURPLE}请选择: ${NC}"; read -r bw_choice
                    case "$bw_choice" in
                        1)
                            echo -ne "${BLUE}IP (支持CIDR): ${NC}"; read -r i
                            if [[ -z "$i" ]] || ! validate_ip_cidr "$i"; then
                                echo -e "${RED}无效 IP/CIDR${NC}"; sleep 1; continue
                            fi
                            iptables -C INPUT -s "$i" -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -s "$i" -j ACCEPT
                            _persist_iptables
                            echo -e "${GREEN}完成${NC}"; pause; break ;;
                        2)
                            echo -ne "${BLUE}IP (支持CIDR): ${NC}"; read -r i
                            if [[ -z "$i" ]] || ! validate_ip_cidr "$i"; then
                                echo -e "${RED}无效 IP/CIDR${NC}"; sleep 1; continue
                            fi
                            iptables -C INPUT -s "$i" -j DROP 2>/dev/null || iptables -I INPUT 1 -s "$i" -j DROP
                            _persist_iptables
                            echo -e "${GREEN}完成${NC}"; pause; break ;;
                        0) break ;;
                        *) continue ;;
                    esac
                done
                ;;
            5) clear; iptables -L -nv --line-numbers; pause ;;
            6) clear; ss -tulpn; pause ;;
            7)
                echo -e "\n${L_BLUE}:: 日志查看模式 ::${NC}"
                echo -e "1. 拦截日志-静态 (仅显示被墙记录)"
                echo -e "2. 拦截日志-实时"
                echo -e "3. 完整日志-实时"
                echo -ne "${BLUE}请选择: ${NC}"; read -r log_opt
                case "$log_opt" in
                    1)
                        clear
                        echo -e "${L_YELLOW}--- 拦截日志 (最后 100 条) ---${NC}"
                        _run_static_log | _filter_fw_logs
                        pause
                        ;;
                    2)
                        echo -e "${L_YELLOW}正在监控拦截日志... (按任意键退出)${NC}"
                        _run_live_log | _filter_fw_logs &
                        local PID=$!
                        read -n 1 -s -r
                        local _pgid
                        _pgid=$(ps -o pgid= -p "$PID" 2>/dev/null | tr -d ' ')
                        if [ -n "$_pgid" ] && [ "$_pgid" != "$$" ]; then
                            kill -- -"$_pgid" 2>/dev/null || kill "$PID" 2>/dev/null || true
                        else
                            kill "$PID" 2>/dev/null || true
                        fi
                        ;;
                    3)
                        echo -e "${L_YELLOW}正在监控完整内核日志... (按任意键退出)${NC}"
                        _run_live_log &
                        local PID=$!
                        read -n 1 -s -r
                        kill "$PID" 2>/dev/null || true
                        ;;
                    *) echo -e "${RED}无效选项${NC}"; sleep 1 ;;
                esac
                ;;
            0|"") return ;;
            *) msg_warn "无效选项"; sleep 1 ;;
        esac
    done
}


# ==============================================================================
# SECTION 7: 代理服务模块（来自 Snell+Realm+SS.sh）
# ==============================================================================


get_country_code_for_ip() {
    local ip=$1
    local code=""
    code=$(curl -s --max-time 3 "https://ipapi.co/${ip}/country/" | tr -d '[:space:]')
    if [[ -z "$code" || ${#code} -ne 2 ]]; then
        code=$(curl -s --max-time 3 "https://ipinfo.io/${ip}/country" | tr -d '[:space:]')
    fi
    if [[ -z "$code" || ${#code} -ne 2 ]]; then
        code=$(curl -s --max-time 3 "https://ip-api.com/json/${ip}" | jq -r '.countryCode // empty' 2>/dev/null || true)
    fi
    if [[ -z "$code" || ${#code} -ne 2 ]]; then
        echo "UN"
    else
        echo "${code^^}"
    fi
}

check_system() {
    if ! command -v systemctl &>/dev/null; then
        die "此脚本需要 systemd 支持。"
    fi
    mkdir -p "$WORK_DIR"
    chmod 700 "$WORK_DIR"
}

setup_log_rotation() {
    if command -v logrotate &>/dev/null; then
        # 总是覆盖写入最新的日志轮转配置，确保旧版本升级后能生效
        cat > /etc/logrotate.d/proxy-manager <<'EOF' || { msg_warn "logrotate 配置写入失败"; return 1; }
/var/log/proxy-manager.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    create 600 root root
}
EOF
        chmod 644 /etc/logrotate.d/proxy-manager
    fi
}

heal_ss_config() {
    if [[ -f "$SS_CONFIG_FILE" ]] && [[ $(jq 'type' "$SS_CONFIG_FILE" 2>/dev/null) == '"array"' ]]; then
        msg_warn "检测到旧版不兼容的 Shadowsocks 配置文件格式。"
        msg_step "正在自动修复配置文件..."
        local temp_json
        temp_json=$(mktemp)
        trap "rm -f '$temp_json'" RETURN
        if jq '{servers: .}' "$SS_CONFIG_FILE" > "$temp_json" \
                && jq -e '.servers | type == "array"' "$temp_json" >/dev/null 2>&1; then
            mv "$temp_json" "$SS_CONFIG_FILE"
            chown "${SS_USER}:${SS_USER}" "$SS_CONFIG_FILE"
            chmod 600 "$SS_CONFIG_FILE"
            systemctl restart "shadowsocks-rust.service" || true
            msg_success "配置文件已成功修复为新格式。"
        else
            rm -f "$temp_json"
            msg_error "自动修复失败 (jq 转换出错)，配置文件未修改。"
        fi
    fi
}


# ------------------------------------------------------------------------------
# 配置文件验证
# ------------------------------------------------------------------------------
validate_ss_config() {
    local config_file=$1
    if [[ ! -f "$config_file" ]]; then return 1; fi
    # 增强验证: 检查是否为有效JSON且包含 servers 数组
    if ! jq -e '.servers | type == "array"' "$config_file" >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

validate_realm_config() {
    local config_file=$1
    [[ ! -f "$config_file" ]] && return 1
    # 校验 JSON 有效 + endpoints 为数组 + 每个 endpoint 含 listen/remote 字符串字段
    jq -e '
        (.endpoints | type == "array") and
        ([.endpoints[] | select((.listen | type) != "string" or (.remote | type) != "string")] | length == 0)
    ' "$config_file" >/dev/null 2>&1
}

# 创建 snell 模板服务文件 (snell@.service，%i = 端口号)
create_snell_template_service() {
    cat > "$SNELL_SERVICE_FILE" <<EOF
[Unit]
Description=Snell Proxy Service (port %i)
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=${SNELL_USER}
Group=${SNELL_USER}
AmbientCapabilities=CAP_NET_BIND_SERVICE
ExecStart="${SNELL_BIN}" -c "${SNELL_CONFIG_DIR}/snell-%i.conf"
Restart=on-failure
RestartSec=2
LimitNOFILE=${ULIMIT_NOFILE}
LimitNPROC=${ULIMIT_NOFILE}
OOMScoreAdjust=-200
NoNewPrivileges=yes
ProtectSystem=strict
PrivateTmp=true
PrivateDevices=true
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
}

# 将旧版单文件多 section 配置迁移到每端口独立文件 + 模板服务
migrate_snell_config() {
    [[ -f "$SNELL_LEGACY_CONFIG" ]] || return 0
    [[ -f "$SNELL_BIN" ]] || return 0

    # 已有独立节点文件则只清理旧文件
    if find "$SNELL_CONFIG_DIR" -name "snell-[0-9]*.conf" -type f -print -quit 2>/dev/null | grep -q .; then
        rm -f "$SNELL_LEGACY_CONFIG"
        return 0
    fi

    msg_step "检测到旧版 Snell 单文件配置，正在迁移至多实例模式..."

    # 解析所有 [snell-server] 段
    local ports=() psks=()
    local cur_port="" cur_psk="" in_sec=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^\[snell-server\] ]]; then
            if [[ -n "$cur_port" && -n "$cur_psk" ]]; then
                ports+=("$cur_port"); psks+=("$cur_psk")
            fi
            cur_port="" cur_psk="" in_sec=true
        elif $in_sec; then
            if [[ "$line" =~ ^listen ]]; then
                cur_port=$(echo "$line" | grep -oP ':\K\d+$' || true)
            elif [[ "$line" =~ ^psk ]]; then
                cur_psk=$(echo "$line" | awk '{sub(/^psk[[:space:]]*=[[:space:]]*/,""); print}')
            fi
        fi
    done < "$SNELL_LEGACY_CONFIG"
    [[ -n "$cur_port" && -n "$cur_psk" ]] && ports+=("$cur_port") && psks+=("$cur_psk")

    if [[ ${#ports[@]} -eq 0 ]]; then
        msg_warn "旧配置无法解析，跳过迁移。"
        return 0
    fi

    # 创建模板服务（如尚不存在）
    if ! systemctl cat "snell@.service" &>/dev/null; then
        create_snell_template_service
    fi

    # 停止并移除旧 snell.service
    systemctl stop  "snell.service" &>/dev/null || true
    systemctl disable "snell.service" &>/dev/null || true
    rm -f "/etc/systemd/system/snell.service"
    systemctl daemon-reload

    local i
    for i in "${!ports[@]}"; do
        local port="${ports[$i]}" psk="${psks[$i]}"
        local ncf="${SNELL_CONFIG_DIR}/snell-${port}.conf"
        cat > "$ncf" <<EOF
[snell-server]
listen = 0.0.0.0:${port}
psk = ${psk}
ipv6 = false
EOF
        chown "${SNELL_USER}:${SNELL_USER}" "$ncf"
        chmod 600 "$ncf"
        systemctl enable "snell@${port}.service" 2>/dev/null || msg_warn "snell@${port} enable 失败，重启后不会自启。"
        systemctl start  "snell@${port}.service" || msg_warn "启动 snell@${port} 失败"
        msg_info "  已迁移节点: 端口 ${port}"
    done

    rm -f "$SNELL_LEGACY_CONFIG"
    msg_success "Snell 迁移完成，共 ${#ports[@]} 个节点已独立运行。"
}


# ------------------------------------------------------------------------------
# 网络与服务器信息
# ------------------------------------------------------------------------------




get_geo_info() {
    local ip=$1 data _parsed country_code="" country_name="" city=""
    local sources=(
        "https://ipapi.co/${ip}/json/"
        "https://ipinfo.io/${ip}/json"
        "https://ip-api.com/json/${ip}"
    )
    for api in "${sources[@]}"; do
        data=$(curl -sf --max-time 8 "$api" 2>/dev/null) || continue
        _parsed=$(printf '%s' "$data" | jq -r '
            if .country_code then
                [.country_code, (.country_name // .country // ""), (.city // "")]
            elif .countryCode then
                [.countryCode, (.country // ""), (.city // "")]
            elif .country then
                [.country, .country, (.city // "")]
            else empty
            end | @tsv' 2>/dev/null) || continue
        [[ -z "$_parsed" ]] && continue
        IFS=$'\t' read -r country_code country_name city <<< "$_parsed"
        country_code="${country_code^^}"
        [[ -n "$country_code" ]] && { SERVER_COUNTRY_CODE=$country_code; SERVER_COUNTRY_NAME=${country_name:-$country_code}; SERVER_CITY=${city:-Unknown}; return 0; }
    done
    return 1
}

# 安全解析缓存文件（仅提取白名单字段，不使用 source 以防代码注入）
_read_cache_value() {
    # $1: key, $2: file — awk 逐字段精确匹配，无正则注入风险
    local _val
    _val=$(awk -F= -v k="$1" \
        '$1 == k { v = substr($0, length(k)+2); gsub(/^["'"'"']|["'"'"']$/, "", v); print v; exit }' \
        "$2" 2>/dev/null || true)
    printf '%s' "$_val"
}

get_server_info() {
    if [[ -f "$CACHE_FILE" ]] && [[ $(($(date +%s) - $(stat -c %Y "$CACHE_FILE"))) -lt $CACHE_TTL ]]; then
        local _ip _cc _cn _city
        _ip=$(_read_cache_value   "SERVER_IP"           "$CACHE_FILE")
        _cc=$(_read_cache_value   "SERVER_COUNTRY_CODE" "$CACHE_FILE")
        _cn=$(_read_cache_value   "SERVER_COUNTRY_NAME" "$CACHE_FILE")
        _city=$(_read_cache_value "SERVER_CITY"         "$CACHE_FILE")
        if [[ -n "$_cc" && "$_cc" != "UN" && "$_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            SERVER_IP="$_ip"
            SERVER_COUNTRY_CODE="$_cc"
            SERVER_COUNTRY_NAME="${_cn:-$_cc}"
            SERVER_CITY="${_city:-Unknown}"
        fi
    else
        local _ip
        _ip=$(get_public_ip 2>/dev/null || true)
        if [[ "$_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            SERVER_IP="$_ip"
            get_geo_info "$_ip" || true
            mkdir -p "$WORK_DIR"
            {
                printf 'SERVER_IP=%s\n'           "$SERVER_IP"
                printf 'SERVER_COUNTRY_CODE=%s\n' "$SERVER_COUNTRY_CODE"
                printf 'SERVER_COUNTRY_NAME=%s\n' "$SERVER_COUNTRY_NAME"
                printf 'SERVER_CITY=%s\n'         "$SERVER_CITY"
            } > "$CACHE_FILE"
            chmod 600 "$CACHE_FILE"
        fi
    fi
}


# ------------------------------------------------------------------------------
# 核心服务管理逻辑
# ------------------------------------------------------------------------------

# 获取已安装的版本号
get_installed_version() {
    local service_name=$1
    local bin_path=$2
    local ver=""
    case "$service_name" in
        snell)
            # Snell 无 --version，直接使用脚本内置版本号（与下载地址一致）
            if [[ -f "$SNELL_BIN" ]]; then
                ver="${SNELL_VERSION_OVERRIDE}"
            fi
            ;;
        shadowsocks-rust)
            if [[ -f "$SS_BIN" ]]; then
                # ssserver --version 输出形如: shadowsocks 1.21.0 / ssserver 1.21.0
                local raw
                raw=$("$SS_BIN" --version 2>&1 || true)
                ver=$(echo "$raw" | grep -oP '(?<=\s)v?[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
                [[ -n "$ver" && "$ver" != v* ]] && ver="v${ver}"
            fi
            ;;
        realm)
            if [[ -f "$REALM_BIN" ]]; then
                # realm 输出形如: realm x.x.x 或带 v 前缀，同时兼容 stderr
                local raw
                raw=$("$REALM_BIN" --version 2>&1 || "$REALM_BIN" -V 2>&1 || true)
                ver=$(echo "$raw" | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
                [[ -n "$ver" && "$ver" != v* ]] && ver="v${ver}"
            fi
            ;;
        socks5)
            if command -v danted &>/dev/null; then
                local raw
                raw=$(danted --version 2>&1 || true)
                ver=$(echo "$raw" | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
                [[ -n "$ver" && "$ver" != v* ]] && ver="v${ver}"
            fi
            ;;
    esac
    echo "${ver:-未知}"
}

check_service_status() {
    local service_name=$1
    local bin_path=$2

    if [[ ! -f "$bin_path" ]]; then
        printf '%b' "${C_RED}未安装${C_RESET}"
        return
    fi

    # Snell 使用模板服务 snell@.service，每个节点是独立实例
    if [[ "$service_name" == "snell" ]]; then
        if ! systemctl cat "snell@.service" &>/dev/null; then
            printf '%b' "${C_YELLOW}已安装 (模板服务丢失)${C_RESET}"
            return
        fi
        local active_cnt
        active_cnt=$(systemctl list-units --type=service --state=active 'snell@*' --no-legend 2>/dev/null | grep -c 'snell@' || echo 0)
        if [[ "$active_cnt" -gt 0 ]]; then
            printf '%b' "${C_GREEN}运行中 (${active_cnt} 实例)${C_RESET}"
        else
            printf '%b' "${C_YELLOW}已停止${C_RESET}"
        fi
        return
    fi

    if ! systemctl cat "${service_name}.service" &>/dev/null; then
        printf '%b' "${C_YELLOW}已安装 (服务丢失)${C_RESET}"
        return
    fi
    if systemctl is-active --quiet "${service_name}.service"; then
        printf '%b' "${C_GREEN}运行中${C_RESET}"
    elif systemctl is-enabled --quiet "${service_name}.service"; then
        printf '%b' "${C_YELLOW}已停止${C_RESET}"
    else
        printf '%b' "${C_RED}已禁用${C_RESET}"
    fi
}

# ------------------------------------------------------------------------------
# 版本检查与更新
# ------------------------------------------------------------------------------

# 后台空闲检查新版本 (每24小时一次)，结果写入缓存
check_updates_background() {
    # 如果缓存文件存在且未超期，跳过
    if [[ -f "$UPDATE_CHECK_CACHE" ]] && \
       [[ $(( $(date +%s) - $(stat -c %Y "$UPDATE_CHECK_CACHE" 2>/dev/null || echo 0) )) -lt $UPDATE_CHECK_INTERVAL ]]; then
        return 0
    fi

    # 在后台执行，不阻塞启动（子 shell 继承函数作用域，变量天然隔离）
    (
        results=""
        NL=$'\n'

        # 检查 Snell (固定下载源，无 GitHub API；仅当已安装版本与脚本固化版本不一致时提示)
        snell_installed=""
        [[ -f "$SNELL_BIN" ]] && snell_installed=$(get_installed_version snell "$SNELL_BIN")
        if [[ -n "$snell_installed" && -f "$SNELL_BIN" ]]; then
            snell_latest="${SNELL_VERSION_OVERRIDE}"
            if [[ "$snell_installed" != "$snell_latest" && "$snell_installed" != "未知" ]]; then
                results+="snell:${snell_latest}${NL}"
            fi
        fi

        # 检查 Shadowsocks-Rust 和 Realm（并发请求减少等待时间）
        _ss_latest_file=$(mktemp)
        _realm_latest_file=$(mktemp)
        trap 'rm -f "$_ss_latest_file" "$_realm_latest_file"' EXIT
        if [[ -f "$SS_BIN" ]]; then
            curl -s --max-time 10 "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest" \
                | jq -r '.tag_name // empty' > "$_ss_latest_file" 2>/dev/null &
        fi
        if [[ -f "$REALM_BIN" ]]; then
            curl -s --max-time 10 "https://api.github.com/repos/zhboner/realm/releases/latest" \
                | jq -r '.tag_name // empty' > "$_realm_latest_file" 2>/dev/null &
        fi
        wait

        if [[ -f "$SS_BIN" ]]; then
            ss_latest=$(cat "$_ss_latest_file" 2>/dev/null || true)
            rm -f "$_ss_latest_file"
            ss_installed=$(get_installed_version shadowsocks-rust "$SS_BIN")
            if [[ -n "$ss_latest" && -n "$ss_installed" && "$ss_latest" != "$ss_installed" && "$ss_installed" != "未知" ]]; then
                results+="shadowsocks-rust:${ss_latest}${NL}"
            fi
        fi

        if [[ -f "$REALM_BIN" ]]; then
            realm_latest=$(cat "$_realm_latest_file" 2>/dev/null || true)
            rm -f "$_realm_latest_file"
            realm_installed=$(get_installed_version realm "$REALM_BIN")
            if [[ -n "$realm_latest" && -n "$realm_installed" && "$realm_latest" != "$realm_installed" && "$realm_installed" != "未知" ]]; then
                results+="realm:${realm_latest}${NL}"
            fi
        fi

        # 写入缓存 (真实换行)
        printf '%s' "$results" > "$UPDATE_CHECK_CACHE"
    ) &
    disown 2>/dev/null || true
}

# 读取缓存，返回某服务的最新版本 (如有)
get_cached_latest_version() {
    local service_name=$1
    if [[ ! -f "$UPDATE_CHECK_CACHE" ]]; then echo ""; return; fi
    grep -m1 "^${service_name}:" "$UPDATE_CHECK_CACHE" 2>/dev/null | cut -d: -f2 || true
}

# 更新单个服务
update_service() {
    local service_name=$1

    case "$service_name" in
        snell)
            if [[ ! -f "$SNELL_BIN" ]]; then msg_error "Snell 未安装。"; return; fi
            local installed
            installed=$(get_installed_version snell "$SNELL_BIN")
            printf "  当前已安装: ${C_YELLOW}%s${C_RESET}\n" "$installed"
            printf "  脚本内置版本: ${C_GREEN}%s${C_RESET}\n" "${SNELL_VERSION_OVERRIDE}"
            printf "\n${C_CYAN}请输入目标版本号或完整下载链接 (直接回车使用内置版本 %s):${C_RESET}\n" "${SNELL_VERSION_OVERRIDE}"
            printf "  格式1 - 版本号: ${C_WHITE}v5.0.2${C_RESET}\n"
            printf "  格式2 - 完整URL: ${C_WHITE}https://dl.nssurge.com/snell/snell-server-vX.X.X-linux-amd64.zip${C_RESET}\n"
            printf "${C_PURPLE}>>> ${C_RESET}"
            read -r snell_input
            snell_input="${snell_input// /}"

            local target_version snell_download_url
            if [[ -z "$snell_input" ]]; then
                target_version="${SNELL_VERSION_OVERRIDE}"
                snell_download_url="https://dl.nssurge.com/snell/snell-server-${target_version}-linux-${SNELL_ARCH}.zip"
            elif [[ "$snell_input" =~ ^https:// ]]; then
                snell_download_url="$snell_input"
                target_version=$(echo "$snell_input" | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "(自定义)")
            elif [[ "$snell_input" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                [[ "$snell_input" != v* ]] && snell_input="v${snell_input}"
                target_version="$snell_input"
                snell_download_url="https://dl.nssurge.com/snell/snell-server-${target_version}-linux-${SNELL_ARCH}.zip"
            else
                msg_error "格式无法识别，请输入版本号 (如 v5.0.2) 或完整 URL。"
                return
            fi

            if [[ "$installed" == "$target_version" && "$target_version" != "(自定义)" ]]; then
                msg_info "Snell 已是 ${target_version}，无需更新。"
                printf "\n${C_CYAN}按任意键返回...${C_RESET}"; read -rsn1; return
            fi

            msg_step "正在更新 Snell -> ${target_version}..."
            printf "  下载: ${C_CYAN}%s${C_RESET}\n" "$snell_download_url"
            install_service "snell" "$SNELL_USER" "$SNELL_BIN" "$SNELL_CONFIG_DIR" "$snell_download_url" "zip" "true"
            # 同步更新 template service 文件（含 OOMScoreAdjust/RestartSec/StartLimitIntervalSec）
            create_snell_template_service
            systemctl daemon-reload
            manage_services "restart" "snell"
            msg_success "Snell 已更新到 ${target_version}。"
            rm -f "$UPDATE_CHECK_CACHE"
            ;;
        shadowsocks-rust)
            if [[ ! -f "$SS_BIN" ]]; then msg_error "Shadowsocks-Rust 未安装。"; return; fi
            local installed
            installed=$(get_installed_version shadowsocks-rust "$SS_BIN")
            msg_step "正在查询 Shadowsocks-Rust 最新版本..."
            local latest
            latest=$(curl -s --max-time 15 "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest" | jq -r '.tag_name // empty' 2>/dev/null || true)
            if [[ -z "$latest" ]]; then msg_error "无法获取最新版本，请检查网络。"; return; fi
            printf "  已安装版本: ${C_YELLOW}%s${C_RESET}\n" "$installed"
            printf "  GitHub 最新: ${C_GREEN}%s${C_RESET}\n" "$latest"
            if [[ "$installed" == "$latest" ]]; then
                msg_info "Shadowsocks-Rust 已是最新版本，无需更新。"
                printf "\n${C_CYAN}按任意键返回...${C_RESET}"; read -rsn1; return
            fi
            msg_step "正在更新 Shadowsocks-Rust ${installed} -> ${latest}..."
            local arch_suffix="x86_64-unknown-linux-gnu"
            [[ "$SS_ARCH" == "aarch64" ]] && arch_suffix="aarch64-unknown-linux-gnu"
            [[ "$SS_ARCH" == "armv7l" ]] && arch_suffix="armv7-unknown-linux-gnueabihf"
            local url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${latest}/shadowsocks-${latest}.${arch_suffix}.tar.xz"
            install_service "shadowsocks-rust" "$SS_USER" "$SS_BIN" "$SS_CONFIG_DIR" "$url" "tar" "true"
            # 同步更新 service 文件（含 OOMScoreAdjust/RestartSec/StartLimitIntervalSec）
            create_service_file "$SS_SERVICE_FILE" "$SS_USER" "$SS_BIN" "$SS_CONFIG_FILE" "Shadowsocks-Rust Service"
            # 确保 config.json 含全局优化参数
            _ensure_ss_global_config
            systemctl daemon-reload
            manage_services "restart" "shadowsocks-rust"
            msg_success "Shadowsocks-Rust 已更新到 ${latest}。"
            rm -f "$UPDATE_CHECK_CACHE"
            ;;
        realm)
            if [[ ! -f "$REALM_BIN" ]]; then msg_error "Realm 未安装。"; return; fi
            local installed
            installed=$(get_installed_version realm "$REALM_BIN")
            msg_step "正在查询 Realm 最新版本..."
            local latest
            latest=$(curl -s --max-time 15 "https://api.github.com/repos/zhboner/realm/releases/latest" | jq -r '.tag_name // empty' 2>/dev/null || true)
            if [[ -z "$latest" ]]; then msg_error "无法获取最新版本，请检查网络。"; return; fi
            printf "  已安装版本: ${C_YELLOW}%s${C_RESET}\n" "$installed"
            printf "  GitHub 最新: ${C_GREEN}%s${C_RESET}\n" "$latest"
            if [[ "$installed" == "$latest" ]]; then
                msg_info "Realm 已是最新版本，无需更新。"
                printf "\n${C_CYAN}按任意键返回...${C_RESET}"; read -rsn1; return
            fi
            msg_step "正在更新 Realm ${installed} -> ${latest}..."
            local arch_name="x86_64-unknown-linux-gnu"
            [[ "$SS_ARCH" == "aarch64" ]] && arch_name="aarch64-unknown-linux-gnu"
            [[ "$SS_ARCH" == "armv7l"  ]] && arch_name="armv7-unknown-linux-gnueabihf"
            local url="https://github.com/zhboner/realm/releases/download/${latest}/realm-${arch_name}.tar.gz"
            install_service "realm" "$REALM_USER" "$REALM_BIN" "$REALM_CONFIG_DIR" "$url" "tar" "true"
            # 同步更新 service 文件（含 OOMScoreAdjust/RestartSec/StartLimitIntervalSec）
            create_realm_service_file
            # 确保 config.json 含 network/dns 优化块
            _ensure_realm_network_config
            systemctl daemon-reload
            _realm_safe_restart
            msg_success "Realm 已更新到 ${latest}。"
            rm -f "$UPDATE_CHECK_CACHE"
            ;;
        *) msg_error "未知服务: $service_name" ;;
    esac
}

check_acl_status() {
    if [[ -f "$SS_CONFIG_FILE" ]] && jq -e '.acl | type == "string" and length > 0' "$SS_CONFIG_FILE" >/dev/null 2>&1; then
        printf "${C_GREEN}已开启${C_RESET}"
    else
        printf "${C_YELLOW}已关闭${C_RESET}"
    fi
}

install_service() {
    local service_name=$1
    local user=$2
    local bin_path=$3
    local config_dir=$4
    local download_url=$5
    local archive_type=$6
    local force_overwrite="${7:-false}"  # true = 更新场景，跳过覆盖确认

    msg_step "开始安装 ${service_name}..."
    if [[ -f "$bin_path" ]]; then
        if [[ "$force_overwrite" == "true" ]]; then
            msg_info "检测到旧版本，将直接替换二进制（配置文件不受影响）..."
        else
            printf "${C_YELLOW}%s 已存在, 是否覆盖安装? [y/N]: ${C_RESET}" "$service_name"
            read -r answer
            if [[ "${answer,,}" != "y" ]]; then
                msg_warn "安装已取消。"
                return 1
            fi
        fi
    fi

    systemctl stop "${service_name}.service" &>/dev/null || true
    if ! id "$user" &>/dev/null; then
        useradd -r -s /usr/sbin/nologin -d /nonexistent "$user"
    fi
    mkdir -p "$config_dir"
    
    local tmp_dir
    tmp_dir=$(mktemp -d)
    # RETURN trap 仅在函数 return 时触发，die() 调用 exit，需在 die 前手动清理
    trap "rm -rf '$tmp_dir'" RETURN
    local archive_file="${tmp_dir}/archive"

    msg_step "正在下载 ${service_name}..."
    if ! wget -qO "$archive_file" "$download_url"; then
        rm -rf "$tmp_dir"
        die "下载失败。"
    fi

    msg_step "正在解压文件..."
    if [[ "$archive_type" == "zip" ]]; then
        if ! unzip -oq "$archive_file" -d "$tmp_dir"; then rm -rf "$tmp_dir"; die "ZIP 解压失败"; fi
    else
        if ! tar -xf "$archive_file" -C "$tmp_dir"; then rm -rf "$tmp_dir"; die "TAR 解压失败"; fi
    fi

    local bin_in_archive
    # 多文件场景下只取第一个匹配，避免 mv 失败
    bin_in_archive=$(find "$tmp_dir" -type f \( -name "snell-server" -o -name "ssserver" -o -name "realm" \) | head -n 1)
    if [[ -z "$bin_in_archive" ]]; then rm -rf "$tmp_dir"; die "找不到程序文件"; fi

    mv -f "$bin_in_archive" "$bin_path"
    chmod +x "$bin_path"
    rm -rf "$tmp_dir"
    msg_info "${service_name} 核心程序已安装。"
}

# 根据 CPU 架构选择最优加密算法
# x86_64 有 AES-NI 硬件指令，aes-128-gcm 更快；ARM 无 AES-NI，chacha20 软件实现更快
_ss_default_method() {
    case "$SS_ARCH" in
        aarch64|armv7l) echo "chacha20-ietf-poly1305" ;;
        *)              echo "aes-128-gcm" ;;
    esac
}

# 为已有 SS config.json 补全全局优化参数（存量机器迁移用）
# fast_open  : TCP Fast Open，减少握手 RTT（需 sysctl tcp_fastopen=3，iptables+rely.sh 已配置）
# no_delay   : TCP_NODELAY，消除 Nagle 缓冲延迟
# mode       : tcp_and_udp，同时开启 UDP 中继（DNS/游戏加速等）
# timeout    : 连接空闲超时 300s，防止僵尸连接耗尽资源
# udp_timeout: UDP 关联超时 60s
_ensure_ss_global_config() {
    [[ -f "$SS_CONFIG_FILE" ]] || return 0
    local tmp
    tmp=$(mktemp)
    trap "rm -f '$tmp'" RETURN

    # 用 has() 检测 key 是否存在（jq -e 对 false/null 也返回非零，会误判用户的显式配置）
    local needs_update=0
    jq -e 'has("fast_open") and has("no_delay") and has("mode") and has("timeout") and has("udp_timeout")' \
        "$SS_CONFIG_FILE" >/dev/null 2>&1 || needs_update=1
    [[ "$needs_update" -eq 0 ]] && return 0

    # 单次 jq 调用完成所有补全，失败时 graceful 退出（不中止脚本启动）
    jq '
        if has("fast_open")   then . else . + {"fast_open": true}        end |
        if has("no_delay")    then . else . + {"no_delay": true}         end |
        if has("mode")        then . else . + {"mode": "tcp_and_udp"}    end |
        if has("timeout")     then . else . + {"timeout": 300}           end |
        if has("udp_timeout") then . else . + {"udp_timeout": 60}        end
    ' "$SS_CONFIG_FILE" > "$tmp" || return 0

    mv "$tmp" "$SS_CONFIG_FILE"
    chown "${SS_USER}:${SS_USER}" "$SS_CONFIG_FILE"
    chmod 600 "$SS_CONFIG_FILE"
    msg_info "Shadowsocks config.json 已补全全局优化参数 (fast_open/no_delay/mode/timeout)"
}

# 为已有 Realm config.json 补全 network/dns 优化块（存量机器迁移用）
_ensure_realm_network_config() {
    [[ -f "$REALM_CONFIG_FILE" ]] || return 0
    local tmp
    tmp=$(mktemp)
    trap "rm -f '$tmp'" RETURN

    # 用 has() 检测 key 存在性，一次 jq 调用完成所有补全（原子写入）
    local needs_update=0
    jq -e 'has("network") and has("dns") and has("log")' \
        "$REALM_CONFIG_FILE" >/dev/null 2>&1 || needs_update=1
    [[ "$needs_update" -eq 0 ]] && return 0

    jq '
        if has("network") then . else . + {"network": {"no_delay": true, "keepalive": true, "zero_copy": true, "buf_size": 16384}} end |
        if has("dns")     then . else . + {"dns": {"mode": "ipv4_then_ipv6", "min_ttl": 60, "max_ttl": 3600, "cache_size": 512}} end |
        if has("log")     then . else . + {"log": {"level": "warn"}} end
    ' "$REALM_CONFIG_FILE" > "$tmp" || return 0

    mv "$tmp" "$REALM_CONFIG_FILE"
    chown "${REALM_USER}:${REALM_USER}" "$REALM_CONFIG_FILE"
    chmod 600 "$REALM_CONFIG_FILE"
    msg_info "Realm config.json 已补全 network/dns 优化配置"
}

install_realm() {
    if [[ "$SS_ARCH" == "unsupported" ]]; then die "不支持架构"; fi
    local arch="$SS_ARCH"

    local latest_tag
    latest_tag=$(get_latest_github_release "zhboner/realm" "v2.7.0")
    local arch_name=""
    case "$arch" in
        amd64) arch_name="x86_64-unknown-linux-gnu" ;;
        aarch64) arch_name="aarch64-unknown-linux-gnu" ;; 
        armv7l) arch_name="armv7-unknown-linux-gnueabihf" ;;
        *) die "不支持 Realm 的当前架构: $arch" ;;
    esac

    local url="https://github.com/zhboner/realm/releases/download/${latest_tag}/realm-${arch_name}.tar.gz"
    
    install_service "realm" "$REALM_USER" "$REALM_BIN" "$REALM_CONFIG_DIR" "$url" "tar" || return

    # 初始化空配置
    # network.no_delay     : TCP_NODELAY，消除 Nagle 缓冲延迟
    # network.keepalive    : SO_KEEPALIVE，依赖 sysctl keepalive_time=600 检测死连接
    # network.zero_copy    : splice() 内核零拷贝，大幅降低中转 CPU 占用
    # network.buf_size 16384: 16KB 缓冲区，50+ 节点高并发下减少 read/write 系统调用次数
    # dns.cache_size 512   : 缓存远端 DNS，避免每条连接重复解析（50+ 节点必要）
    # dns.min/max_ttl      : 60-3600s 缓存窗口，max_ttl 1h 避免50+节点高频DNS重解析
    if [[ ! -f "$REALM_CONFIG_FILE" ]]; then
        cat > "$REALM_CONFIG_FILE" <<'REALM_INIT_EOF'
{
  "log": {"level": "warn"},
  "dns": {
    "mode": "ipv4_then_ipv6",
    "min_ttl": 60,
    "max_ttl": 3600,
    "cache_size": 512
  },
  "network": {
    "no_delay": true,
    "keepalive": true,
    "zero_copy": true,
    "buf_size": 16384
  },
  "endpoints": []
}
REALM_INIT_EOF
        chown "${REALM_USER}:${REALM_USER}" "$REALM_CONFIG_FILE"
        chmod 600 "$REALM_CONFIG_FILE"
    fi

    # 初始化元数据文件
    if [[ ! -f "$REALM_META_FILE" ]]; then
        echo '{}' > "$REALM_META_FILE"
        chown "${REALM_USER}:${REALM_USER}" "$REALM_META_FILE"
        chmod 600 "$REALM_META_FILE"
    fi

    create_realm_service_file
    
    systemctl daemon-reload
    manage_services "enable" "realm"
    manage_services "start" "realm"
    msg_success "Realm 安装完成。"

    # 安装后引导
    printf "\n${C_CYAN}是否立即添加转发规则?${C_RESET}\n"
    printf "   1) 智能粘贴 Snell 配置 (默认)\n"
    printf "   2) 手动输入 IP:Port\n"
    printf "   0) 暂不添加\n"
    printf "${C_PURPLE}请选择 [1]: ${C_RESET}"
    read -r guide_choice
    guide_choice=${guide_choice:-1}
    
    case $guide_choice in
        1) add_realm_forward_advanced "auto" ;;
        2) add_realm_forward "auto" ;;
        *) msg_info "已跳过配置，后续可在主菜单中管理。" ;;
    esac
}

uninstall_service() {
    local service_name=$1
    local user=$2
    local bin_path=$3
    local config_dir=$4
    local service_file_path=$5
    local config_file=$6

    printf "${C_RED}确认彻底卸载 %s 吗? [y/N]: ${C_RESET}" "$service_name"
    read -r answer
    if [[ "${answer,,}" != "y" ]]; then return; fi

    msg_step "正在卸载 ${service_name}..."
    if [[ "$service_name" == "snell" ]]; then
        # 停止并关闭所有 snell@ 实例
        local _sf _sp
        while IFS= read -r _sf; do
            _sp=$(grep -oP 'listen\s*=\s*[^:]+:\K\d+' "$_sf" 2>/dev/null | head -1 || true)
            if [[ -n "$_sp" ]]; then
                systemctl stop    "snell@${_sp}.service" &>/dev/null || true
                systemctl disable "snell@${_sp}.service" &>/dev/null || true
                close_firewall_port "$_sp"
            fi
        done < <(find "$SNELL_CONFIG_DIR" -name "snell-[0-9]*.conf" -type f 2>/dev/null)
    else
        systemctl stop    "${service_name}.service" &>/dev/null || true
        systemctl disable "${service_name}.service" &>/dev/null || true
    fi

    if [[ "$service_name" != "snell" ]] && [[ -f "$config_file" ]]; then
        if [[ "$service_name" == "shadowsocks-rust" ]]; then
            local ports
            ports=$(jq -r '.servers[]?.server_port' "$config_file" 2>/dev/null || true)
            for p in $ports; do [[ -n "$p" ]] && close_firewall_port "$p"; done
            # 同时清理 CN 封禁的 iptables 规则（toggle_cn_block "disable" 会自动检查状态）
            toggle_cn_block "disable" 2>/dev/null || true
        elif [[ "$service_name" == "realm" ]]; then
            local ports
            ports=$(jq -r '.endpoints[]?.listen' "$config_file" 2>/dev/null | cut -d: -f2 || true)
            for p in $ports; do [[ -n "$p" ]] && close_firewall_port "$p"; done
        fi
    fi

    rm -f "$bin_path" "$service_file_path"
    rm -rf "$config_dir"
    if id "$user" &>/dev/null; then userdel "$user" &>/dev/null || true; fi
    systemctl daemon-reload
    msg_success "${service_name} 已成功卸载。"
}


# ------------------------------------------------------------------------------
# 防火墙管理
# ------------------------------------------------------------------------------


parse_snell_nodes() {
    local f port psk
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        port=$(awk '/^\[snell-server\]/{in_s=1} in_s&&/^listen/{n=split($NF,a,":");print a[n];exit}' "$f" 2>/dev/null || true)
        psk=$(awk '/^\[snell-server\]/{in_s=1} in_s&&/^psk[[:space:]]*=/{sub(/^psk[[:space:]]*=[[:space:]]*/,""); print; exit}' "$f" 2>/dev/null || true)
        [[ -n "$port" && -n "$psk" ]] && echo "$port $psk"
    done < <(find "$SNELL_CONFIG_DIR" -name "snell-[0-9]*.conf" -type f 2>/dev/null | sort)
}

get_connection_stats() {
    local total_connections=0
    local connection_details=()
    
    if find "$SNELL_CONFIG_DIR" -name "snell-[0-9]*.conf" -type f -print -quit 2>/dev/null | grep -q . && \
       systemctl list-units --type=service --state=active 'snell@*' --no-legend 2>/dev/null | grep -q .; then
        while IFS=' ' read -r s_port _; do
            [[ -z "$s_port" ]] && continue
            local snell_conns
            snell_conns=$(ss -tn state established "sport = :$s_port" 2>/dev/null | wc -l)
            snell_conns=$((snell_conns - 1))
            [[ $snell_conns -lt 0 ]] && snell_conns=0
            if [[ $snell_conns -gt 0 ]]; then
                connection_details+=("Snell(${s_port}): ${snell_conns}")
                total_connections=$((total_connections + snell_conns))
            fi
        done < <(parse_snell_nodes)
    fi
    
    if [[ -f "$SS_CONFIG_FILE" ]] && systemctl is-active --quiet shadowsocks-rust.service; then
        local ss_ports
        ss_ports=$(jq -r '.servers[]?.server_port' "$SS_CONFIG_FILE" 2>/dev/null || true)
        for port in $ss_ports; do
            if [[ -n "$port" ]]; then
                local ss_conns
                ss_conns=$(ss -tn state established "sport = :$port" 2>/dev/null | wc -l)
                ss_conns=$((ss_conns - 1))
                [[ $ss_conns -lt 0 ]] && ss_conns=0
                if [[ $ss_conns -gt 0 ]]; then
                    connection_details+=("SS(${port}): ${ss_conns}")
                    total_connections=$((total_connections + ss_conns))
                fi
            fi
        done
    fi

    if [[ -f "$REALM_CONFIG_FILE" ]] && systemctl is-active --quiet realm.service; then
        local realm_ports
        realm_ports=$(jq -r '.endpoints[]?.listen' "$REALM_CONFIG_FILE" 2>/dev/null | cut -d: -f2 || true)
        for port in $realm_ports; do
            if [[ -n "$port" ]]; then
                local realm_conns
                realm_conns=$(ss -tn state established "sport = :$port" 2>/dev/null | wc -l)
                realm_conns=$((realm_conns - 1))
                [[ $realm_conns -lt 0 ]] && realm_conns=0
                if [[ $realm_conns -gt 0 ]]; then
                    connection_details+=("Realm(${port}): ${realm_conns}")
                    total_connections=$((total_connections + realm_conns))
                fi
            fi
        done
    fi
    echo "$total_connections:${connection_details[*]}"
}

show_detailed_connections() {
    clear
    printf "${C_CYAN}=== 用户连接详情 (实时) ===${C_RESET}\n\n"
    
    if ! command -v ss &>/dev/null; then
        msg_error "系统中未找到 'ss' 命令，无法查看。"
    else
        echo "正在获取连接信息..."
        echo "------------------------------------------------------------------"
        # 直接输出所有 established 连接（ss 本身会带表头一行）
        ss -tn state established
        echo "------------------------------------------------------------------"
        printf "${C_GREEN}提示: 上方显示的是当前所有已建立的 TCP 连接。${C_RESET}\n"
    fi

    printf "\n${C_CYAN}按任意键返回主菜单...${C_RESET}"
    read -rsn1
}


# ------------------------------------------------------------------------------
# ACL 管理功能 (核心新增)
# ------------------------------------------------------------------------------

ensure_acl_exists() {
    if [[ ! -f "$SS_ACL_FILE" ]]; then
        msg_info "未找到 ACL 文件，正在创建默认列表..."
        create_ss_acl
    fi
}

create_ss_acl() {
    local _old_umask
    _old_umask=$(umask)
    umask 077
    cat > "$SS_ACL_FILE" <<EOF
[outbound_block_list]
ip138.com
whoer.net
ipinfo.io
ifconfig.me
ifconfig.co
ip-api.com
ipip.net
myip.com
myip.la
ip.sb
ipleak.net
browserleaks.com
dnsleak.com
showmyip.com
whatismyip.com
ping0.cc
ipaddress.com
EOF
    umask "$_old_umask"
    chown "${SS_USER}:${SS_USER}" "$SS_ACL_FILE"
    chmod 600 "$SS_ACL_FILE"
}

toggle_acl() {
    if [[ ! -f "$SS_CONFIG_FILE" ]]; then die "未安装 Shadowsocks。"; fi

    local temp_json
    temp_json=$(mktemp)
    trap "rm -f '$temp_json'" RETURN

    # 检查当前状态
    if jq -e '.acl' "$SS_CONFIG_FILE" >/dev/null 2>&1; then
        # 当前为开启，执行关闭
        jq 'del(.acl)' "$SS_CONFIG_FILE" > "$temp_json"
        msg_success "已关闭防检测功能。"
    else
        # 当前为关闭，执行开启
        ensure_acl_exists
        jq --arg acl "$SS_ACL_FILE" '. + {"acl": $acl}' "$SS_CONFIG_FILE" > "$temp_json"
        msg_success "已开启防检测功能。"
    fi
    
    mv "$temp_json" "$SS_CONFIG_FILE"
    chown "${SS_USER}:${SS_USER}" "$SS_CONFIG_FILE"
    chmod 600 "$SS_CONFIG_FILE"
    manage_services "restart" "shadowsocks-rust"
}

add_acl_rule() {
    ensure_acl_exists
    printf "${C_CYAN}请输入要屏蔽的域名或IP (例如 example.com / 1.2.3.4 / 192.168.0.0/24): ${C_RESET}"
    read -r entry
    if [[ -z "$entry" ]]; then msg_error "输入不能为空。"; return; fi

    if grep -qF "$entry" "$SS_ACL_FILE"; then
        msg_warn "'$entry' 已存在。"
        return
    fi

    echo "$entry" >> "$SS_ACL_FILE"
    msg_success "已添加封禁规则: $entry"

    # 如果功能已开启，重启生效
    if jq -e '.acl' "$SS_CONFIG_FILE" >/dev/null 2>&1; then
        manage_services "restart" "shadowsocks-rust"
    else
        msg_info "提示: 防检测功能当前处于关闭状态，规则将在开启后生效。"
    fi
}

view_acl_rules() {
    ensure_acl_exists
    echo "=== 当前屏蔽列表 ==="
    cat "$SS_ACL_FILE"
    echo "===================="
    printf "${C_CYAN}按任意键返回...${C_RESET}"
    read -rsn1
}

# ------------------------------------------------------------------------------
# CN IP 封禁功能 (SS 专用)
# ------------------------------------------------------------------------------

ensure_ipset_exists() {
    local set_name="ss_cn_block"
    if ! command -v ipset &>/dev/null; then msg_error "未安装 ipset 组件。"; return 1; fi
    
    if ! ipset list "$set_name" &>/dev/null; then
        msg_step "正在初始化 CN IP 数据库 (ipset)..."
        ipset create "$set_name" hash:net
        
        local cn_list_url="https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt"
        local temp_list
        temp_list=$(mktemp)
        
        msg_info "正在下载最新 CN IP 列表..."
        if wget -qO "$temp_list" "$cn_list_url" && [[ -s "$temp_list" ]]; then
             msg_info "正在导入 IP 规则 (约 8000+ 条)..."
             grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$' "$temp_list" \
                 | sed "s/^/add $set_name /" | ipset restore -!
             rm -f "$temp_list"
             msg_success "CN IP 列表导入完成。"
        else
             msg_error "下载失败或文件为空，请检查网络连接。"
             rm -f "$temp_list"
             ipset destroy "$set_name"
             return 1
        fi
    fi
    return 0
}

setup_cn_block_timer() {
    # 1. Create Update Service
    cat > /etc/systemd/system/ss-cn-update.service <<-'EOF'
[Unit]
Description=Update CN IP Block List for Shadowsocks
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c '\
    set -e; \
    ipset create ss_cn_block_temp hash:net 2>/dev/null || ipset flush ss_cn_block_temp; \
    tmp_list=$(mktemp); \
    trap "rm -f \"$tmp_list\"" EXIT; \
    if wget -qO "$tmp_list" https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt && [ -s "$tmp_list" ]; then \
        grep -E '"'"'^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'"'"' "$tmp_list" | sed "s/^/add ss_cn_block_temp /" | ipset restore -! && \
        ipset swap ss_cn_block_temp ss_cn_block && \
        ipset destroy ss_cn_block_temp; \
    else \
        ipset destroy ss_cn_block_temp 2>/dev/null; \
        echo "cn-ip-update: wget failed, keeping existing ruleset" >&2; \
    fi'
EOF

    # 2. Create Timer (Weekly)
    cat > /etc/systemd/system/ss-cn-update.timer <<-'EOF'
[Unit]
Description=Weekly Update for CN IP Block List

[Timer]
OnCalendar=weekly
Persistent=true
RandomizedDelaySec=3600

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now ss-cn-update.timer >/dev/null 2>&1
    msg_info "已配置 CNS IP 库自动更新任务 (每周一次)。"
}

check_cn_block_status() {
    # 检查 iptables 中是否有引用 ss_cn_block 的 DROP 规则
    if iptables-save 2>/dev/null | grep -q "match-set ss_cn_block src"; then
        printf "${C_GREEN}已开启${C_RESET}"
    else
        printf "${C_YELLOW}已关闭${C_RESET}"
    fi
}

toggle_cn_block() {
    local action=${1:-"toggle"} # toggle, enable, disable
    
    if [[ ! -f "$SS_CONFIG_FILE" ]]; then msg_error "未安装 Shadowsocks。"; return; fi
    
    local ss_ports
    ss_ports=$(jq -r '.servers[]?.server_port' "$SS_CONFIG_FILE" 2>/dev/null || true)
    if [[ -z "$ss_ports" ]]; then msg_error "未找到 Shadowsocks 端口配置。"; return; fi
    
    # Check current status
    local is_enabled=false
    if iptables-save 2>/dev/null | grep -q "match-set ss_cn_block src"; then
        is_enabled=true
    fi
    
    # Determine target state
    local target_state=""
    if [[ "$action" == "enable" ]]; then
        target_state="enable"
    elif [[ "$action" == "disable" ]]; then
        if ! $is_enabled; then return; fi # Already disabled
        target_state="disable"
    else
        if $is_enabled; then target_state="disable"; else target_state="enable"; fi
    fi
    
    if [[ "$target_state" == "disable" ]]; then
        # Disable
        msg_step "正在移除 CN 封禁规则..."
        for port in $ss_ports; do
            iptables -D INPUT -p tcp --dport "$port" -m set --match-set ss_cn_block src -j DROP 2>/dev/null || true
            iptables -D INPUT -p udp --dport "$port" -m set --match-set ss_cn_block src -j DROP 2>/dev/null || true
        done
        msg_success "已关闭 CN IP 封禁。"
        
        # Disable Timer
        systemctl stop ss-cn-update.timer &>/dev/null || true
        systemctl disable ss-cn-update.timer &>/dev/null || true
        rm -f /etc/systemd/system/ss-cn-update.timer /etc/systemd/system/ss-cn-update.service
        systemctl daemon-reload
    else
        # Enable
        if ! ensure_ipset_exists; then return; fi
        msg_step "正在应用 CN 封禁规则 (SS 端口)..."
        local count=0
        for port in $ss_ports; do
            # Add checks to prevent duplicate rules
            if ! iptables -C INPUT -p tcp --dport "$port" -m set --match-set ss_cn_block src -j DROP 2>/dev/null; then
               iptables -I INPUT 1 -p tcp --dport "$port" -m set --match-set ss_cn_block src -j DROP || true
               count=$((count+1))
            fi
            if ! iptables -C INPUT -p udp --dport "$port" -m set --match-set ss_cn_block src -j DROP 2>/dev/null; then
               iptables -I INPUT 1 -p udp --dport "$port" -m set --match-set ss_cn_block src -j DROP || true
               count=$((count+1))
            fi
        done
        msg_success "CN IP 封禁已开启 (应用于 $count 条规则)。"
        
        # Setup Auto-Update Timer
        setup_cn_block_timer
    fi
    
    # Save firewall
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save >/dev/null
    else
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null
    fi
}

update_cn_ipset() {
    local set_name="ss_cn_block"
    local temp_set="${set_name}_temp"
    local cn_list_url="https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt"

    if ! command -v ipset &>/dev/null; then msg_error "未安装 ipset 组件。"; return 1; fi

    msg_step "正在下载最新 CN IP 列表..."
    local temp_list
    temp_list=$(mktemp)
    trap "rm -f '$temp_list'" RETURN

    if ! wget -qO "$temp_list" "$cn_list_url" || [[ ! -s "$temp_list" ]]; then
        msg_error "下载失败，现有规则保持不变。"
        return 1
    fi

    msg_info "正在原子替换 ipset (不中断现有封禁)..."
    ipset create "$temp_set" hash:net 2>/dev/null || ipset flush "$temp_set"
    grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$' "$temp_list" \
        | sed -e "s/^/add $temp_set /" | ipset restore -!

    if ipset list "$set_name" &>/dev/null; then
        ipset swap "$temp_set" "$set_name"
        ipset destroy "$temp_set"
    else
        ipset rename "$temp_set" "$set_name"
    fi

    msg_success "CN IP 列表已更新（原子替换，规则无中断）。"
}

_snell_manage_menu() {
    while true; do
        clear
        printf "${C_CYAN}=== Snell 节点管理 ===${C_RESET}\n\n"
        printf " ${C_GREEN}1.${C_RESET} 添加 Snell 节点\n"
        printf " ${C_GREEN}2.${C_RESET} 删除 Snell 节点\n"
        printf " ${C_GREEN}3.${C_RESET} 编辑配置文件\n"
        printf " ${C_GREEN}4.${C_RESET} 查看连接详情\n"
        printf " ${C_GREEN}5.${C_RESET} 重新安装 (保留配置)\n"
        printf " ${C_GREEN}0.${C_RESET} 返回主菜单\n\n"
        printf "${C_PURPLE}请选择: ${C_RESET}"
        read -r sub
        case "$sub" in
            1) add_snell_node            || true ;;
            2) delete_snell_node         || true ;;
            3) edit_config               || true ;;
            4) show_detailed_connections || true ;;
            5) manage_services "stop" "snell" || true
               rm -f "$SNELL_BIN"
               local _sv="${SNELL_VERSION_OVERRIDE}"
               local _url="https://dl.nssurge.com/snell/snell-server-${_sv}-linux-${SNELL_ARCH}.zip"
               if install_service "snell" "$SNELL_USER" "$SNELL_BIN" "$SNELL_CONFIG_DIR" "$_url" "zip"; then
                   create_snell_template_service
                   systemctl daemon-reload
                   manage_services "start" "snell" || true
                   msg_success "Snell 重新安装完成，已重启所有节点"
               fi ;;
            0) return ;;
            *) msg_warn "无效选项" ;;
        esac
        printf "\n${C_GREEN}按任意键继续...${C_RESET}"; read -rsn1
    done
}

_ss_manage_menu() {
    while true; do
        clear
        printf "${C_CYAN}=== SS-Rust 用户管理 ===${C_RESET}\n\n"
        printf " ${C_GREEN}1.${C_RESET} 添加 SS 用户\n"
        printf " ${C_GREEN}2.${C_RESET} 删除 SS 用户\n"
        printf " ${C_GREEN}3.${C_RESET} 编辑配置文件\n"
        printf " ${C_GREEN}4.${C_RESET} 查看连接详情\n"
        printf " ${C_GREEN}5.${C_RESET} 重新安装 (保留配置)\n"
        printf " ${C_GREEN}6.${C_RESET} 安全与防检测设置\n"
        printf " ${C_GREEN}0.${C_RESET} 返回主菜单\n\n"
        printf "${C_PURPLE}请选择: ${C_RESET}"
        read -r sub
        case "$sub" in
            1) add_ss_user               || true ;;
            2) delete_ss_user            || true ;;
            3) edit_config               || true ;;
            4) show_detailed_connections || true ;;
            5) manage_services "stop" "shadowsocks-rust" || true
               rm -f "$SS_BIN"
               local _ss_tag _ss_suffix _ss_url
               _ss_tag=$(get_latest_github_release "shadowsocks/shadowsocks-rust" "v1.21.0")
               _ss_suffix="x86_64-unknown-linux-gnu"
               [[ "$SS_ARCH" == "aarch64" ]] && _ss_suffix="aarch64-unknown-linux-gnu"
               [[ "$SS_ARCH" == "armv7l"  ]] && _ss_suffix="armv7-unknown-linux-gnueabihf"
               _ss_url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${_ss_tag}/shadowsocks-${_ss_tag}.${_ss_suffix}.tar.xz"
               if install_service "shadowsocks-rust" "$SS_USER" "$SS_BIN" "$SS_CONFIG_DIR" "$_ss_url" "tar"; then
                   create_service_file "$SS_SERVICE_FILE" "$SS_USER" "$SS_BIN" "$SS_CONFIG_FILE" "Shadowsocks-Rust Service"
                   systemctl daemon-reload
                   manage_services "start" "shadowsocks-rust" || true
                   msg_success "Shadowsocks-Rust 重新安装完成，配置已保留"
               fi ;;
            6) manage_security_menu || true ;;
            0) return ;;
            *) msg_warn "无效选项" ;;
        esac
        printf "\n${C_GREEN}按任意键继续...${C_RESET}"; read -rsn1
    done
}

manage_security_menu() {
    while true; do
        clear
        printf "${C_CYAN}=== 安全与防检测设置 ===${C_RESET}\n\n"
        printf "   [SS] 域名/IP屏蔽 (ACL) : $(check_acl_status)\n"
        printf "   [SS] 屏蔽国内连接 (IP) : $(check_cn_block_status)\n\n"
        
        printf "   1) 开启/关闭 域名/IP屏蔽 (ACL - 屏蔽 ip138 等)\n"
        printf "   2) 添加 ACL 屏蔽规则 (域名/IP)\n"
        printf "   3) 查看 ACL 屏蔽列表\n"
        printf "   --------------------------------------------\n"
        printf "   4) 开启/关闭 屏蔽国内 IP (防 GFW 主动探测)\n"
        printf "   5) 更新 CN IP 数据库\n"
        printf "\n"
        printf "   0) 返回主菜单\n\n"
        printf "${C_CYAN}请选择: ${C_RESET}"
        read -r choice
        case $choice in
            1) toggle_acl; sleep 1 ;;
            2) add_acl_rule; sleep 1 ;;
            3) view_acl_rules ;;
            4) toggle_cn_block; sleep 1.5 ;;
            5) update_cn_ipset; sleep 1 ;;
            0) return ;;
            *) msg_warn "无效选项" ;;
        esac
    done
}

manage_realm_menu() {
    if [[ ! -f "$REALM_CONFIG_FILE" ]]; then msg_error "Realm 未安装或配置文件缺失。"; return; fi
    
    while true; do
        clear
        printf "${C_CYAN}=== Realm 端口转发管理 ===${C_RESET}\n\n"
        printf "${C_BLUE}当前规则列表:${C_RESET}\n"
        if jq -e '.endpoints | length > 0' "$REALM_CONFIG_FILE" >/dev/null; then
            jq -r '.endpoints[] | "  [本地端口: \(.listen | split(":")[-1])] -> [远程: \(.remote)]"' "$REALM_CONFIG_FILE"
        else
            printf "  (暂无转发规则)\n"
        fi
        
        printf "\n"
        printf "   1) 智能粘贴 Snell 配置 (自动解析添加)\n"
        printf "   2) 手动添加转发规则 (IP:Port)\n"
        printf "   3) 删除转发规则\n"
        printf "   4) 编辑配置文件 (Snell/SS/Realm)\n"
        printf "   5) 查看连接详情 (实时)\n"
        printf "   6) 重新安装 (保留配置)\n"
        printf "   0) 返回主菜单\n\n"
        printf "${C_CYAN}请选择: ${C_RESET}"
        read -r choice

        case $choice in
            1) add_realm_forward_advanced ;;
            2) add_realm_forward ;;
            3) delete_realm_forward ;;
            4) edit_config ;;
            5) show_detailed_connections ;;
            6) manage_services "stop" "realm" || true
               rm -f "$REALM_BIN"
               install_realm || true ;;
            0) return ;;
            *) msg_warn "无效选项" ;;
        esac
    done
}

# 检测失效的 Realm 转发规则并批量删除
check_realm_dead_forwards() {
    local _dead_strict_was_on=false
    [[ $- == *e* ]] && _dead_strict_was_on=true
    set +e
    set +o pipefail
    # shellcheck disable=SC2064
    trap '{ [[ $_dead_strict_was_on == true ]] && set -eo pipefail; }; trap - RETURN' RETURN

    clear
    printf "${C_CYAN}=== 检测失效的 Realm 转发规则 ===${C_RESET}\n"
    printf "${C_YELLOW}将对每条转发规则的远端目标进行 TCP 连通性检测（超时 4 秒判定失效）。${C_RESET}\n\n"

    local total
    total=$(jq '.endpoints | length' "$REALM_CONFIG_FILE" 2>/dev/null || echo 0)
    if [[ $total -eq 0 ]]; then
        msg_info "暂无转发规则。"
        printf "\n${C_CYAN}按任意键返回...${C_RESET}"; read -rsn1
        return
    fi

    # 开始检测
    local dead_indices=()   # 失效的 JSON 索引
    local dead_info=()      # 失效的显示信息
    local i=0

    while IFS= read -r line; do
        local listen remote
        listen=$(echo "$line" | jq -r '.listen')
        remote=$(echo "$line" | jq -r '.remote')
        local l_port r_host r_port alias
        l_port=$(echo "$listen" | cut -d: -f2)
        r_host=$(echo "$remote" | cut -d: -f1)
        r_port=$(echo "$remote" | cut -d: -f2)
        alias=""
        [[ -f "$REALM_META_FILE" ]] && alias=$(jq -r --arg p "$l_port" '.[$p].alias // empty' "$REALM_META_FILE" 2>/dev/null || true)
        [[ -z "$alias" ]] && alias="${l_port} → ${r_host}:${r_port}"

        printf "  [%2d/%2d] 检测: %-30s -> %s:%s " "$((i+1))" "$total" "$alias" "$r_host" "$r_port"

        # TCP 连接测试：nc 优先，socat 兜底
        local reachable=false
        if command -v nc &>/dev/null; then
            nc -z -w 4 "$r_host" "$r_port" 2>/dev/null && reachable=true
        else
            socat /dev/null "TCP4:${r_host}:${r_port},connect-timeout=4" 2>/dev/null && reachable=true
        fi

        if $reachable; then
            printf "${C_GREEN}[正常]${C_RESET}\n"
        else
            printf "${C_RED}[失效]${C_RESET}\n"
            dead_indices+=("$i")
            dead_info+=("  本地:${l_port} -> 远端:${r_host}:${r_port}  (${alias})")
        fi

        ((i++)) || true
    done < <(jq -c '.endpoints[]' "$REALM_CONFIG_FILE" 2>/dev/null)

    printf "\n"

    if [[ ${#dead_indices[@]} -eq 0 ]]; then
        msg_success "所有转发规则连採正常，无需清理。"
        return
    fi

    # 展示失效列表让用户确认
    printf "${C_RED}以下 ${#dead_indices[@]} 条规则检测失效:${C_RESET}\n"
    for info in "${dead_info[@]}"; do
        printf "${C_RED}%s${C_RESET}\n" "$info"
    done

    printf "\n${C_YELLOW}确认删除以上 ${#dead_indices[@]} 条失效规则？ [y/N]: ${C_RESET}"
    read -r confirm
    if [[ "${confirm,,}" != "y" ]]; then
        msg_info "已取消，未做任何修改。"
        return
    fi

    # 从后向前删除，避免索引偏移
    local sorted_indices=()
    mapfile -t sorted_indices < <(printf '%s\n' "${dead_indices[@]}" | sort -rn)

    for idx in "${sorted_indices[@]}"; do
        local del_listen del_port
        del_listen=$(jq -r ".endpoints[$idx].listen" "$REALM_CONFIG_FILE")
        del_port=$(echo "$del_listen" | cut -d: -f2)

        # 删除 JSON 并关闭防火墙端口
        local tmp_json
        tmp_json=$(mktemp)
        jq "del(.endpoints[$idx])" "$REALM_CONFIG_FILE" > "$tmp_json" && mv "$tmp_json" "$REALM_CONFIG_FILE" || rm -f "$tmp_json"
        chown "${REALM_USER}:${REALM_USER}" "$REALM_CONFIG_FILE"

        [[ -f "$REALM_META_FILE" ]] && {
            local meta_tmp
            meta_tmp=$(mktemp)
            jq --arg p "$del_port" 'del(.[$p])' "$REALM_META_FILE" > "$meta_tmp" && mv "$meta_tmp" "$REALM_META_FILE" || rm -f "$meta_tmp"
            chown "${REALM_USER}:${REALM_USER}" "$REALM_META_FILE"
        }

        close_firewall_port "$del_port" 2>/dev/null || true
    done

    msg_success "已删除 ${#dead_indices[@]} 条失效规则。"
    msg_info "配置已更新，请手动重启 Realm 服务以生效。"

}

_realm_safe_restart() {
    if ! validate_realm_config "$REALM_CONFIG_FILE"; then
        msg_error "Realm 配置文件格式错误，已中止重启，请检查: $REALM_CONFIG_FILE"
        return 1
    fi
    local _bak="${REALM_CONFIG_FILE}.bak"
    cp "$REALM_CONFIG_FILE" "$_bak" 2>/dev/null || true
    if ! manage_services "restart" "realm"; then
        msg_warn "Realm 重启失败，正在回滚配置..."
        if [[ -f "$_bak" ]]; then
            mv "$_bak" "$REALM_CONFIG_FILE"
            chown "${REALM_USER}:${REALM_USER}" "$REALM_CONFIG_FILE"
            chmod 600 "$REALM_CONFIG_FILE"
            manage_services "restart" "realm" || true
        fi
        msg_error "已回滚，请检查日志: journalctl -u realm"
        return 1
    fi
    rm -f "$_bak"
}

_process_realm_rule() {
    # 临时禁用严格模式，防止因解析错误导致脚本退出；RETURN 时自动恢复
    local _strict_was_on=false
    [[ $- == *e* ]] && _strict_was_on=true
    set +e
    set +o pipefail
    trap '{ [[ $_strict_was_on == true ]] && set -eo pipefail; }; trap - RETURN' RETURN

    local raw_config="$1"
    local silent_mode="${2:-false}" # true to suppress some success messages during batch

    # 提取信息 (Regex)
    local remote_host
    remote_host=$(echo "$raw_config" | grep -oP 'snell,\s*\K\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}' | head -n 1 || true)
    if [[ -z "$remote_host" ]]; then
        remote_host=$(echo "$raw_config" | grep -oP 'snell,\s*\K[a-zA-Z0-9][-a-zA-Z0-9.]{0,253}' | head -n 1 || true)
    fi

    local remote_port
    # 精准匹配 IP 之后紧跟的端口，避免误取 IP 第一段
    local _escaped_host
    if [[ ! "$remote_host" =~ ^[0-9a-zA-Z._-]+$ ]]; then
        msg_warn "远端主机格式异常，跳过端口解析: $remote_host"
        return 1
    fi
    _escaped_host=$(echo "$remote_host" | sed 's/\./\\./g; s/\[/\\[/g; s/\]/\\]/g; s/+/\\+/g')
    remote_port=$(echo "$raw_config" | grep -oP "${_escaped_host},\s*\K\d+" | head -1 || true)
    local psk
    psk=$(echo "$raw_config" | grep -oP 'psk=["'\'']?\K[^,"'\'']+' | head -n 1 || true)
    # 尝试提取指定的本地端口
    local manual_listening_port
    manual_listening_port=$(echo "$raw_config" | grep -oP 'listening=\K\d+' | head -n 1 || true)
    
    local node_alias
    node_alias=$(echo "$raw_config" | grep -oP '^[^=]+(?=\s*=)' | xargs || true)
    
    local remote_ip=""
    
    if [[ "$remote_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        remote_ip="$remote_host"
    elif [[ -n "$remote_host" ]]; then
        remote_ip=$(getent hosts "$remote_host" 2>/dev/null | awk 'NR==1 {print $1}' || true)
        if [[ -z "$remote_ip" ]]; then
             remote_ip=$(dig +short "$remote_host" 2>/dev/null | grep -E '^[0-9]+\.' | head -1 || true)
        fi
        if [[ -z "$remote_ip" ]]; then
             remote_ip=$(nslookup "$remote_host" 2>/dev/null | awk '/^Address: / {print $2}' | head -1 || true)
        fi
        if [[ -z "$remote_ip" ]] || [[ "$remote_ip" == "0.0.0.0" ]]; then
            if [[ "$silent_mode" == "false" ]]; then msg_error "无法解析主机名 '$remote_host'，请检查 DNS 或输入 IP 地址"; fi
            return 1
        fi
    fi

    if [[ -z "$remote_ip" || -z "$remote_port" ]]; then
        if [[ "$silent_mode" == "false" ]]; then msg_error "无法解析: $raw_config"; fi
        return 1
    fi
    
    local remote_addr="${remote_host}:${remote_port}"

    # 防止重复添加同一远端地址
    if jq -e --arg r "$remote_addr" '.endpoints[] | select(.remote == $r)' "$REALM_CONFIG_FILE" >/dev/null 2>&1; then
        if [[ "$silent_mode" == "false" ]]; then msg_warn "该远端地址已存在转发规则: ${remote_addr}，跳过。"; fi
        return 1
    fi

    local local_port

    # === 端口分配逻辑 ===
    # 如果配置行里指定了 listening 端口 (且该端口确实可用)，则优先复用
    if [[ -n "$manual_listening_port" ]] && ! (ss -tln | grep -q ":${manual_listening_port} " || ss -uln | grep -q ":${manual_listening_port} "); then
         # 双重检查: 确保 config 文件里也没占用 (防止重复添加导致 JSON 冲突)
         if ! jq -e --argjson p "$manual_listening_port" '.endpoints[] | select(.listen | endswith(":" + ($p|tostring)))' "$REALM_CONFIG_FILE" >/dev/null 2>&1; then
             local_port="$manual_listening_port"
         else
             # 端口已被本配置文件占用，回退到随机
             local_port=$(get_available_port)
         fi
    else
         # 未指定或端口已占用，回退到随机
         local_port=$(get_available_port)
    fi
    
    local listen_addr="0.0.0.0:$local_port"

    # 1. 准备 config.json 临时文件（暂不提交）
    local temp_json
    temp_json=$(mktemp)
    if ! jq --arg l "$listen_addr" --arg r "$remote_addr" \
       '.endpoints += [{"listen": $l, "remote": $r}]' \
       "$REALM_CONFIG_FILE" > "$temp_json" || ! jq -e . "$temp_json" >/dev/null 2>&1; then
        rm -f "$temp_json"; msg_error "生成配置 JSON 失败，已中止。"; return 1
    fi

    # Smart Naming Logic
    local new_name=""
    local remote_country_code="UN"
    local flag=""

    if [[ -n "$node_alias" && -n "$manual_listening_port" ]]; then
         # 恢复模式: 保持原名，仅查询国旗用于元数据
         new_name="$node_alias"
         remote_country_code=$(get_country_code_for_ip "$remote_ip" || echo "UN")
         flag=$(get_flag_emoji "$remote_country_code")
    else
        # 新增模式: 走完整的智能命名逻辑
        remote_country_code=$(get_country_code_for_ip "$remote_ip" || echo "UN")
        flag=$(get_flag_emoji "$remote_country_code")
        local clean_alias
        clean_alias=$(echo "$node_alias" | tr -d '"' | sed 's/->/ → /g' | sed -E 's/\[\.([0-9]+)\]/_\1/g' | sed -E 's/\[[0-9]+\.[0-9]+\.[0-9]+\.([0-9]+)\]/_\1/g')

        local local_d
        local_d=$(echo "$SERVER_IP" | cut -d. -f4)
        local local_c
        local_c=$(echo "$SERVER_IP" | cut -d. -f3)
        local local_suffix="_${local_d}"
        local remote_d
        remote_d=$(echo "$remote_ip" | cut -d. -f4)
        local remote_suffix="_${remote_d}"
        local local_iso="${SERVER_COUNTRY_CODE}"
        local current_tag="${local_iso}${local_suffix}"

        # 智能判重与命名生成
        if [[ "$clean_alias" == *"${current_tag}" ]]; then
             new_name="$clean_alias"
        elif [[ "$clean_alias" == *" → "* ]]; then
             if [[ "$clean_alias" == *"_${local_d}" ]]; then local_suffix="_${local_c}.${local_d}"; fi
             local current_tag_c="${local_iso}${local_suffix}"
             if [[ "$clean_alias" == *"${current_tag_c}" ]]; then
                 new_name="$clean_alias"
             else
                 new_name="${clean_alias} → ${current_tag_c}"
             fi
        else
             if [[ "$clean_alias" == *"_"* ]] && [[ "$clean_alias" != *" → "* ]]; then
                  if [[ "$clean_alias" == *"_${local_d}" ]]; then local_suffix="_${local_c}.${local_d}"; fi
                  new_name="${clean_alias} → ${local_iso}${local_suffix}"
             else
                  if [[ "$remote_d" == "$local_d" ]]; then local_suffix="_${local_c}.${local_d}"; fi
                  new_name="${flag}${remote_suffix} → ${local_iso}${local_suffix}"
             fi
        fi
    fi

    # 2. 准备 metadata 临时文件（暂不提交）
    if [[ ! -f "$REALM_META_FILE" ]]; then echo '{}' > "$REALM_META_FILE"; chown "${REALM_USER}:${REALM_USER}" "$REALM_META_FILE"; chmod 600 "$REALM_META_FILE"; fi
    local safe_alias
    safe_alias=$(echo "$new_name" | tr -d '"\\')
    local meta_final
    meta_final=$(mktemp)
    if ! jq --arg p "$local_port" \
            --arg psk "$psk" \
            --arg alias "$safe_alias" \
            --arg cc "$remote_country_code" \
       '. + {($p): {"psk": $psk, "alias": $alias, "country_code": $cc}}' \
       "$REALM_META_FILE" > "$meta_final"; then
        rm -f "$temp_json" "$meta_final"; return 1
    fi

    # 3. 两个文件都就绪后一次性提交，保证原子性
    mv "$temp_json" "$REALM_CONFIG_FILE"
    chown "${REALM_USER}:${REALM_USER}" "$REALM_CONFIG_FILE"
    chmod 600 "$REALM_CONFIG_FILE"
    mv "$meta_final" "$REALM_META_FILE"
    chown "${REALM_USER}:${REALM_USER}" "$REALM_META_FILE"
    chmod 600 "$REALM_META_FILE"

    open_firewall_port "$local_port" || msg_warn "防火墙端口 $local_port 放行失败，节点已添加但外部可能不可达，请手动检查 iptables。"

    if [[ "$silent_mode" == "false" ]]; then
        local display_prefix="$flag"
        if [[ "$new_name" == *" → "* ]]; then display_prefix=""; fi
        msg_success "添加成功: ${new_name} (Port $local_port)"
        if [[ -n "$psk" ]]; then
             printf "${C_GREEN}%s%s = snell, %s, %s, psk=\"%s\", version=5, reuse=true, tfo=true${C_RESET}\n" "$display_prefix" "$new_name" "$SERVER_IP" "$local_port" "$psk"
        fi
    else
        echo "   [OK] $new_name (Port: $local_port)"
    fi
    return 0
}

add_realm_forward_advanced() {
    local _restart_mode=${1:-"ask"}  # auto=直接重启（首次安装）  ask=询问（后期添加）
    if [[ ! -f "$REALM_CONFIG_FILE" ]]; then
        msg_error "Realm 未安装，请先从主菜单安装 Realm 转发服务。"
        return
    fi
    msg_step "智能添加转发规则（支持多行批量粘贴）"
    printf "${C_YELLOW}请粘贴落地机的 Snell 配置行，支持多行，粘贴完成后回车空行确认:${C_RESET}\n"

    local lines=() raw_config
    while IFS= read -r raw_config; do
        [[ -z "$raw_config" ]] && break
        lines+=("$raw_config")
    done

    if [[ ${#lines[@]} -eq 0 ]]; then msg_error "输入不能为空。"; return; fi

    local ok=0 fail=0
    local silent_mode="false"
    [[ ${#lines[@]} -gt 1 ]] && silent_mode="true"

    for raw_config in "${lines[@]}"; do
        if _process_realm_rule "$raw_config" "$silent_mode"; then
            (( ok++ )) || true
        else
            (( fail++ )) || true
        fi
    done

    [[ ${#lines[@]} -gt 1 ]] && printf "${C_CYAN}批量添加完成: ${C_GREEN}成功 %d${C_CYAN} / ${C_RED}失败 %d${C_RESET}\n" "$ok" "$fail"

    if [[ $ok -gt 0 ]]; then
        if [[ "$_restart_mode" == "auto" ]]; then
            _realm_safe_restart
        else
            msg_info "配置已更新，请手动重启 Realm 服务以生效。"
        fi
    fi
}


add_realm_forward() {
    local _restart_mode=${1:-"ask"}  # auto=直接重启（首次安装）  ask=询问（后期添加）
    msg_step "添加 Realm 转发规则 (手动)"
    
    echo "请输入本地监听端口 (Local Port) [回车自动分配]:"
    local local_port input_port
    read -r input_port
    if [[ -z "$input_port" ]]; then
        local_port=$(get_available_port)
    elif [[ "$input_port" =~ ^[0-9]+$ ]] && [[ $input_port -ge 1 ]] && [[ $input_port -le 65535 ]]; then
        if ss -tln | grep -q ":${input_port} " || ss -uln | grep -q ":${input_port} "; then
            msg_error "端口 ${input_port} 已被占用，请选择其他端口。"
            return
        fi
        local_port=$input_port
    else
        msg_error "端口号无效，请输入 1-65535 之间的数字。"
        return
    fi
    
    printf "${C_CYAN}请输入目标地址 (格式 IP:Port, 例如 1.2.3.4:8080): ${C_RESET}"
    read -r remote_addr
    
    if [[ ! "$remote_addr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$ ]] && [[ ! "$remote_addr" =~ ^\[.*\]:[0-9]+$ ]] && [[ ! "$remote_addr" =~ ^[a-zA-Z0-9.-]+:[0-9]+$ ]]; then
        msg_error "格式不正确，请确保为 IP:Port 格式。"
        return
    fi
    
    if jq -e --arg r "$remote_addr" '.endpoints[] | select(.remote == $r)' "$REALM_CONFIG_FILE" >/dev/null 2>&1; then
        msg_warn "该远端地址已存在转发规则: ${remote_addr}，跳过。"
        return
    fi

    local listen_addr="0.0.0.0:$local_port"
    local temp_json
    temp_json=$(mktemp)

    # 构建新对象并追加
    jq --arg l "$listen_addr" --arg r "$remote_addr" \
       '.endpoints += [{"listen": $l, "remote": $r}]' \
       "$REALM_CONFIG_FILE" > "$temp_json"
       
    if ! jq -e . "$temp_json" >/dev/null; then
        msg_error "更新配置失败 (JSON 错误)。"
        rm -f "$temp_json"
        return
    fi
    
    mv "$temp_json" "$REALM_CONFIG_FILE"
    chown "${REALM_USER}:${REALM_USER}" "$REALM_CONFIG_FILE"
    chmod 600 "$REALM_CONFIG_FILE"

    # 同步写入 metadata（别名使用 remote_addr，psk 留空）
    if [[ ! -f "$REALM_META_FILE" ]]; then
        echo '{}' > "$REALM_META_FILE"
        chown "${REALM_USER}:${REALM_USER}" "$REALM_META_FILE"
        chmod 600 "$REALM_META_FILE"
    fi
    local _meta_tmp
    _meta_tmp=$(mktemp)
    if jq --arg p "$local_port" --arg alias "$remote_addr" \
       '. + {($p): {"psk": "", "alias": $alias, "country_code": "UN"}}' \
       "$REALM_META_FILE" > "$_meta_tmp"; then
        mv "$_meta_tmp" "$REALM_META_FILE"
        chown "${REALM_USER}:${REALM_USER}" "$REALM_META_FILE"
        chmod 600 "$REALM_META_FILE"
    else
        rm -f "$_meta_tmp"
    fi

    open_firewall_port "$local_port" || msg_warn "防火墙端口 $local_port 放行失败，请手动检查 iptables。"
    msg_success "转发规则已添加: $local_port -> $remote_addr"
    if [[ "$_restart_mode" == "auto" ]]; then
        _realm_safe_restart
    else
        msg_info "配置已更新，请手动重启 Realm 服务以生效。"
    fi
}

delete_realm_forward() {
    msg_step "删除 Realm 转发规则"

    local count
    count=$(jq '.endpoints | length' "$REALM_CONFIG_FILE")
    if [[ $count -eq 0 ]]; then msg_warn "没有规则可删除。"; return; fi

    echo "当前规则:"
    jq -r '.endpoints[] | "\(.listen | split(":")[1]) -> \(.remote)"' "$REALM_CONFIG_FILE" | cat -n

    printf "${C_CYAN}请输入要删除的本地端口号, 0 取消: ${C_RESET}"
    read -r deleted_port

    [[ "$deleted_port" == "0" ]] && return
    if [[ ! "$deleted_port" =~ ^[0-9]+$ ]]; then
        msg_error "无效端口号。"
        return
    fi

    # 按端口直接定位，避免序号与数组下标歧义
    if ! jq -e --arg p "$deleted_port" '.endpoints[] | select(.listen | endswith(":" + $p))' "$REALM_CONFIG_FILE" >/dev/null 2>&1; then
        msg_error "未找到本地端口 $deleted_port 的转发规则。"
        return
    fi

    local temp_json
    temp_json=$(mktemp)
    if ! jq --arg p "$deleted_port" 'del(.endpoints[] | select(.listen | endswith(":" + $p)))' "$REALM_CONFIG_FILE" > "$temp_json"; then
        rm -f "$temp_json"; msg_error "删除规则失败 (jq 错误)。"; return
    fi
    mv "$temp_json" "$REALM_CONFIG_FILE"
    chown "${REALM_USER}:${REALM_USER}" "$REALM_CONFIG_FILE"
    chmod 600 "$REALM_CONFIG_FILE"

    # 清理 metadata
    if [[ -f "$REALM_META_FILE" ]]; then
        local meta_temp
        meta_temp=$(mktemp)
        if jq --arg p "$deleted_port" 'del(.[$p])' "$REALM_META_FILE" > "$meta_temp"; then
            if ! mv "$meta_temp" "$REALM_META_FILE"; then
                msg_warn "metadata.json 更新失败，规则与元数据可能不同步"
                rm -f "$meta_temp"
            else
                chown "${REALM_USER}:${REALM_USER}" "$REALM_META_FILE"
            fi
        else
            rm -f "$meta_temp"
        fi
    fi
    
    # 自动关闭防火墙端口
    close_firewall_port "$deleted_port"
    
    msg_success "规则已删除。"
    msg_info "配置已更新，请手动重启 Realm 服务以生效。"
}


# ------------------------------------------------------------------------------
# Snell/SS 具体实现
# ------------------------------------------------------------------------------

# 返回 0=可用, 1=已占用（含系统监听端口和所有配置文件中声明的端口）
_check_port_available() {
    local port="$1"
    if ss -tln | grep -q ":${port} " || ss -uln | grep -q ":${port} "; then return 1; fi
    if find "$SNELL_CONFIG_DIR" -name "snell-[0-9]*.conf" -type f \
            -exec grep -ql ":${port}" {} \; 2>/dev/null | grep -q .; then return 1; fi
    if [[ -f "$SS_CONFIG_FILE" ]] && \
            jq -e --argjson p "$port" '.servers[] | select(.server_port == $p)' \
            "$SS_CONFIG_FILE" >/dev/null 2>&1; then return 1; fi
    if [[ -f "$REALM_CONFIG_FILE" ]] && \
            jq -e --argjson p "$port" \
            '.endpoints[] | select(.listen | endswith(":" + ($p|tostring)))' \
            "$REALM_CONFIG_FILE" >/dev/null 2>&1; then return 1; fi
    return 0
}

get_available_port() {
    local port
    local attempts=0
    while [[ $attempts -lt 100 ]]; do
        if command -v shuf >/dev/null 2>&1; then
            port=$(shuf -i "${RAND_PORT_MIN}-${RAND_PORT_MAX}" -n 1)
        else
            # RANDOM 范围是 0-32767，两次组合扩展到 0-1073741823 再取模覆盖完整端口段
            port=$(( (RANDOM * 32768 + RANDOM) % (RAND_PORT_MAX - RAND_PORT_MIN + 1) + RAND_PORT_MIN ))
        fi
        if _check_port_available "$port"; then
            echo "$port"
            return 0
        fi
        attempts=$(( attempts + 1 ))
    done
    die "无法找到可用端口。"
}

get_port_interactive() {
    printf "${C_YELLOW}是否手动指定端口? (默认自动分配，亦可直接输入端口号) [y/N/Port]: ${C_RESET}" >&2
    read -r input

    # 尝试直接识别为端口号 (处理用户直接输入端口的情况)
    if [[ "$input" =~ ^[0-9]+$ ]] && [[ "$input" -ge 1 && "$input" -le 65535 ]]; then
        if ! _check_port_available "$input"; then
            msg_error "端口 ${input} 已被占用，将自动分配可用端口。" >&2
            get_available_port
            return 0
        fi
        echo "$input"
        return 0
    fi

    # 识别 yes/y
    if [[ "${input,,}" == "y" || "${input,,}" == "yes" ]]; then
        while true; do
            printf "${C_CYAN}请输入端口号 (1-65535): ${C_RESET}" >&2
            read -r manual_port
            if [[ "$manual_port" =~ ^[0-9]+$ ]] && [[ "$manual_port" -ge 1 && "$manual_port" -le 65535 ]]; then
                if ! _check_port_available "$manual_port"; then
                    msg_error "端口 ${manual_port} 已被占用，请重新输入。" >&2
                    continue
                fi
                echo "$manual_port"
                return 0
            else
                msg_error "无效的端口号。"
            fi
        done
    else
        get_available_port
    fi
}

create_realm_service_file() {
    cat > "$REALM_SERVICE_FILE" <<EOF
[Unit]
Description=Realm Forwarding Service
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=${REALM_USER}
Group=${REALM_USER}
AmbientCapabilities=CAP_NET_BIND_SERVICE
ExecStart="${REALM_BIN}" -c "${REALM_CONFIG_FILE}"
Restart=always
RestartSec=3
TimeoutStopSec=15
LimitNOFILE=262144
LimitNPROC=262144
OOMScoreAdjust=-200
NoNewPrivileges=yes
ProtectSystem=strict
PrivateTmp=true
PrivateDevices=true
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
}

create_service_file() {
    local service_file_path=$1
    local user=$2
    local bin_path=$3
    local config_file=$4
    local description=$5
    local nofile_limit="${6:-51200}"
    cat > "$service_file_path" <<EOF
[Unit]
Description=$description
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=$user
Group=$user
AmbientCapabilities=CAP_NET_BIND_SERVICE
ExecStart="$bin_path" -c "$config_file"
Restart=on-failure
RestartSec=2
LimitNOFILE=${nofile_limit}
LimitNPROC=${nofile_limit}
OOMScoreAdjust=-200
NoNewPrivileges=yes
ProtectSystem=strict
PrivateTmp=true
PrivateDevices=true
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
}

install_snell() {
    if [[ "$SNELL_ARCH" == "unsupported" ]]; then die "不支持架构"; fi

    local snell_version="${SNELL_VERSION_OVERRIDE}"
    local snell_download_url="https://dl.nssurge.com/snell/snell-server-${snell_version}-linux-${SNELL_ARCH}.zip"

    install_service "snell" "$SNELL_USER" "$SNELL_BIN" "$SNELL_CONFIG_DIR" "$snell_download_url" "zip" || return

    # 创建/更新模板服务文件
    create_snell_template_service
    systemctl daemon-reload

    msg_step "生成首个 Snell 节点配置..."
    local port
    port=$(get_port_interactive)
    local psk
    psk=$(openssl rand -base64 32)
    local node_conf="${SNELL_CONFIG_DIR}/snell-${port}.conf"
    cat > "$node_conf" <<EOF
[snell-server]
listen = 0.0.0.0:${port}
psk = ${psk}
ipv6 = false
EOF
    chown -R "${SNELL_USER}:${SNELL_USER}" "$SNELL_CONFIG_DIR"
    chmod 600 "$node_conf"

    systemctl daemon-reload
    systemctl enable "snell@${port}.service" 2>/dev/null || msg_warn "snell@${port} enable 失败，重启后不会自启。"
    systemctl start  "snell@${port}.service" || msg_warn "启动 snell@${port} 失败，请检查: journalctl -u snell@${port}.service"
    open_firewall_port "$port"
    msg_success "Snell 安装完成，端口: ${port}"
}

add_snell_node() {
    if [[ ! -f "$SNELL_BIN" ]]; then msg_error "Snell 未安装，请先安装。"; return; fi
    msg_step "添加新 Snell 节点..."
    local port
    port=$(get_port_interactive)
    local psk
    psk=$(openssl rand -base64 32)
    local node_conf="${SNELL_CONFIG_DIR}/snell-${port}.conf"
    cat > "$node_conf" <<EOF
[snell-server]
listen = 0.0.0.0:${port}
psk = ${psk}
ipv6 = false
EOF
    chown "${SNELL_USER}:${SNELL_USER}" "$node_conf"
    chmod 600 "$node_conf"
    systemctl daemon-reload
    systemctl enable "snell@${port}.service" 2>/dev/null || msg_warn "snell@${port} enable 失败，重启后不会自启。"
    systemctl start  "snell@${port}.service" || msg_warn "启动 snell@${port} 失败，请检查: journalctl -u snell@${port}.service"
    open_firewall_port "$port"
    msg_success "Snell 节点已添加，端口: ${port}"
}

delete_snell_node() {
    local configs=()
    mapfile -t configs < <(find "$SNELL_CONFIG_DIR" -name "snell-[0-9]*.conf" -type f 2>/dev/null | sort)
    local count=${#configs[@]}

    if [[ $count -eq 0 ]]; then
        msg_error "没有找到 Snell 节点配置。"
        return
    fi
    if [[ $count -eq 1 ]]; then
        msg_warn "当前只有一个节点，如需移除请卸载 Snell 服务（选项 13）。"
        return
    fi

    printf "${C_CYAN}当前 Snell 节点:${C_RESET}\n"
    local ports=()
    local i=1
    for f in "${configs[@]}"; do
        local p
        p=$(grep -oP 'listen\s*=\s*[^:]+:\K\d+' "$f" 2>/dev/null | head -1 || true)
        ports+=("$p")
        printf "  ${C_GREEN}%d.${C_RESET} 端口 %s\n" "$i" "$p"
        i=$((i + 1))
    done

    printf "\n${C_YELLOW}请输入要删除的节点编号 (0=取消): ${C_RESET}"
    read -r choice

    [[ "$choice" == "0" || -z "$choice" ]] && return
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 || "$choice" -gt $count ]]; then
        msg_error "无效选项。"
        return
    fi

    local target_port="${ports[$((choice - 1))]}"
    local target_conf="${SNELL_CONFIG_DIR}/snell-${target_port}.conf"

    systemctl stop    "snell@${target_port}.service" &>/dev/null || true
    systemctl disable "snell@${target_port}.service" &>/dev/null || true
    rm -f "$target_conf"
    close_firewall_port "$target_port"
    msg_success "Snell 节点已删除，端口: ${target_port}"
}

install_shadowsocks() {
    if [[ "$SS_ARCH" == "unsupported" ]]; then die "不支持架构"; fi
    local latest_tag
    latest_tag=$(get_latest_github_release "shadowsocks/shadowsocks-rust" "v1.21.0")
    local arch_suffix="x86_64-unknown-linux-gnu"
    [[ "$SS_ARCH" == "aarch64" ]] && arch_suffix="aarch64-unknown-linux-gnu"
    [[ "$SS_ARCH" == "armv7l" ]] && arch_suffix="armv7-unknown-linux-gnueabihf"
    local url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${latest_tag}/shadowsocks-${latest_tag}.${arch_suffix}.tar.xz"

    install_service "shadowsocks-rust" "$SS_USER" "$SS_BIN" "$SS_CONFIG_DIR" "$url" "tar" || return

    local enable_acl_choice="n"
    printf "${C_YELLOW}是否启用防 IP 检测 (屏蔽 ip138/whoer)? [y/N]: ${C_RESET}"
    read -r enable_acl_choice

    msg_step "生成 Shadowsocks 配置..."
    local port
    port=$(get_port_interactive)
    local password
    password=$(openssl rand -base64 32)
    local method
    method=$(_ss_default_method)
    local temp_config
    temp_config=$(mktemp)
    trap "rm -f '$temp_config'" RETURN

    if [[ "${enable_acl_choice,,}" == "y" ]]; then
        create_ss_acl
        jq -n --arg port "$port" --arg password "$password" \
              --arg method "$method" --arg acl "$SS_ACL_FILE" \
        '{"servers": [{"server": "0.0.0.0", "server_port": ($port | tonumber),
           "password": $password, "method": $method}],
          "mode": "tcp_and_udp", "fast_open": true, "no_delay": true,
          "timeout": 300, "udp_timeout": 60, "acl": $acl}' > "$temp_config"
    else
        jq -n --arg port "$port" --arg password "$password" --arg method "$method" \
        '{"servers": [{"server": "0.0.0.0", "server_port": ($port | tonumber),
           "password": $password, "method": $method}],
          "mode": "tcp_and_udp", "fast_open": true, "no_delay": true,
          "timeout": 300, "udp_timeout": 60}' > "$temp_config"
    fi

    if validate_ss_config "$temp_config"; then
        mv "$temp_config" "$SS_CONFIG_FILE"
        chown -R "${SS_USER}:${SS_USER}" "$SS_CONFIG_DIR"
        chmod 600 "$SS_CONFIG_FILE"
    else
        rm -f "$temp_config"
        die "配置验证失败。"
    fi

    create_service_file "$SS_SERVICE_FILE" "$SS_USER" "$SS_BIN" "$SS_CONFIG_FILE" "Shadowsocks-Rust Service"
    systemctl daemon-reload
    manage_services "enable" "shadowsocks-rust"
    manage_services "start" "shadowsocks-rust"
    open_firewall_port "$port"
    
    # Auto-enable CN Block for security (SS Only)
    msg_step "正在自动应用安全策略 (屏蔽国内 IP)..."
    toggle_cn_block "enable"
    msg_success "Shadowsocks-Rust 安装完成。"
}

add_ss_user() {
    if [[ ! -f "$SS_CONFIG_FILE" ]]; then die "请先安装 Shadowsocks。"; fi
    msg_step "正在添加新的 Shadowsocks 用户..."
    local port
    port=$(get_port_interactive)
    local password
    password=$(openssl rand -base64 32)

    cp "$SS_CONFIG_FILE" "${SS_CONFIG_FILE}.bak"
    chmod 600 "${SS_CONFIG_FILE}.bak"
    local temp_json
    temp_json=$(mktemp)
    trap "rm -f '$temp_json'" RETURN
    local method
    method=$(_ss_default_method)
    local new_user_json
    new_user_json=$(jq -n --arg port "$port" --arg password "$password" --arg method "$method" \
        '{"server": "0.0.0.0", "server_port": ($port | tonumber), "password": $password, "method": $method}')

    jq --argjson newUser "$new_user_json" '.servers += [$newUser]' "$SS_CONFIG_FILE" > "$temp_json"

    if ! jq -e . "$temp_json" >/dev/null; then
        mv "${SS_CONFIG_FILE}.bak" "$SS_CONFIG_FILE"
        die "JSON 格式错误，已恢复。"
    fi
    mv "$temp_json" "$SS_CONFIG_FILE"
    chown "${SS_USER}:${SS_USER}" "$SS_CONFIG_FILE"
    chmod 600 "$SS_CONFIG_FILE"

    if ! manage_services "restart" "shadowsocks-rust"; then
        msg_warn "SS 服务重启失败，正在回滚配置..."
        mv "${SS_CONFIG_FILE}.bak" "$SS_CONFIG_FILE"
        chown "${SS_USER}:${SS_USER}" "$SS_CONFIG_FILE"
        chmod 600 "$SS_CONFIG_FILE"
        manage_services "restart" "shadowsocks-rust" || true
        msg_error "已回滚，请检查配置或日志: journalctl -u shadowsocks-rust"
        return 1
    fi
    rm -f "${SS_CONFIG_FILE}.bak"
    open_firewall_port "$port"

    # 如果当前已开启 CN 屏蔽，自动为新端口应用规则
    if iptables-save 2>/dev/null | grep -q "match-set ss_cn_block src"; then
         msg_step "检测到 CN 屏蔽策略已启用，正在更新防火墙规则..."
         toggle_cn_block "enable"
    fi

    msg_success "新用户添加成功! 端口: $port"
}

delete_ss_user() {
    if [[ ! -f "$SS_CONFIG_FILE" ]]; then die "Shadowsocks 配置文件不存在。"; fi
    local user_count
    user_count=$(jq '.servers | length' "$SS_CONFIG_FILE")
    if [[ $user_count -eq 0 ]]; then msg_warn "没有可删除的用户。"; return; fi

    msg_step "当前 Shadowsocks 用户列表:"
    jq -r '.servers[] | "端口: \(.server_port) | 密码: \(.password)"' "$SS_CONFIG_FILE"
    printf "\n"
    printf "${C_CYAN}请输入要删除的端口号, 或输入 0 取消: ${C_RESET}"
    read -r port_to_delete

    port_to_delete=$(echo "$port_to_delete" | tr -d '[:space:]')
    if [[ "$port_to_delete" == "0" ]]; then return; fi
    if [[ -z "$port_to_delete" ]] || ! [[ "$port_to_delete" =~ ^[0-9]+$ ]]; then
        msg_error "无效端口号。"; return
    fi

    # 按端口定位，避免序号与数组下标歧义
    if ! jq -e --argjson p "$port_to_delete" '.servers[] | select(.server_port == $p)' "$SS_CONFIG_FILE" >/dev/null 2>&1; then
        msg_error "未找到端口 $port_to_delete 的用户。"; return
    fi

    printf "${C_RED}确认删除端口为 %s 的用户吗? [Y/n]: ${C_RESET}" "$port_to_delete"
    read -r confirm
    confirm=${confirm:-y}
    if [[ "${confirm,,}" != "y" ]]; then return; fi

    local temp_json
    temp_json=$(mktemp)
    trap "rm -f '$temp_json'" RETURN
    jq --argjson p "$port_to_delete" 'del(.servers[] | select(.server_port == $p))' "$SS_CONFIG_FILE" > "$temp_json"
    if ! jq -e . "$temp_json" >/dev/null 2>&1; then
        msg_error "JSON 生成失败，已中止。"; return
    fi
    mv "$temp_json" "$SS_CONFIG_FILE"
    chown "${SS_USER}:${SS_USER}" "$SS_CONFIG_FILE"
    chmod 600 "$SS_CONFIG_FILE"

    close_firewall_port "$port_to_delete"
    manage_services "restart" "shadowsocks-rust"
    msg_success "用户 (端口: ${port_to_delete}) 已被删除。"
}


# ------------------------------------------------------------------------------
# 主菜单与交互
# ------------------------------------------------------------------------------

manage_services() {
    local action=$1
    local service_param=$2
    case "${action}" in
        start|stop|restart|reload|enable|disable|status) ;;
        *) msg_warn "无效的操作: ${action}"; return 1 ;;
    esac
    case "${service_param}" in
        all|snell|shadowsocks-rust|realm) ;;
        *) msg_warn "无效的服务名: ${service_param}"; return 1 ;;
    esac
    local services_to_manage=()
    if [[ "$service_param" == "all" || "$service_param" == "snell" ]]; then services_to_manage+=("snell"); fi
    if [[ "$service_param" == "all" || "$service_param" == "shadowsocks-rust" ]]; then services_to_manage+=("shadowsocks-rust"); fi
    if [[ "$service_param" == "all" || "$service_param" == "realm" ]]; then services_to_manage+=("realm"); fi

    for service in "${services_to_manage[@]}"; do
        # Snell 使用模板服务，对所有节点实例逐一操作
        if [[ "$service" == "snell" ]]; then
            local _snell_insts=()
            local _sf _sp
            while IFS= read -r _sf; do
                _sp=$(grep -oP 'listen\s*=\s*[^:]+:\K\d+' "$_sf" 2>/dev/null | head -1 || true)
                [[ -n "$_sp" ]] && _snell_insts+=("snell@${_sp}.service")
            done < <(find "$SNELL_CONFIG_DIR" -name "snell-[0-9]*.conf" -type f 2>/dev/null | sort)

            if [[ ${#_snell_insts[@]} -eq 0 ]]; then
                msg_warn "未找到 Snell 节点配置，跳过。"
                continue
            fi
            for _inst in "${_snell_insts[@]}"; do
                if [[ "$action" == "enable" ]]; then
                    if systemctl enable "$_inst" &>/dev/null; then
                        msg_info "已启用 ${_inst}。"
                    else
                        msg_warn "启用 ${_inst} 失败。"
                    fi
                else
                    msg_info "正在 ${action} ${_inst}..."
                    if ! systemctl "$action" "$_inst"; then
                        msg_warn "${action} ${_inst} 失败。"
                    else
                        msg_success "${_inst} 已成功 ${action}。"
                    fi
                fi
            done
            continue
        fi

        if [[ "$action" == "enable" ]]; then
            if systemctl enable "${service}.service" &>/dev/null; then
                msg_info "已启用 ${service} 服务。"
            else
                msg_warn "启用 ${service} 服务失败。"
            fi
            continue
        fi
        msg_info "正在 ${action} ${service} 服务..."
        if ! systemctl "$action" "${service}.service"; then
            msg_warn "${action} ${service} 服务失败。"
        else
            msg_success "${service} 服务已成功 ${action}。"
        fi
    done
}

edit_config() {
    clear
    printf "${C_CYAN}=== 编辑配置文件 ===${C_RESET}\n"
    printf " ${C_GREEN}1.${C_RESET} 编辑 Snell 配置\n"
    printf " ${C_GREEN}2.${C_RESET} 编辑 Shadowsocks-Rust 配置\n"
    printf " ${C_GREEN}3.${C_RESET} 编辑 Realm 转发配置\n"
    printf " ${C_GREEN}0.${C_RESET} 取消\n"
    printf "\n${C_PURPLE}请选择 [0-3]: ${C_RESET}"
    read -r edit_choice
    
    local target_file=""
    local service_name=""
    
    case $edit_choice in
        1)
            # 多实例：列出所有节点配置，让用户选择
            local _snell_confs=()
            mapfile -t _snell_confs < <(find "$SNELL_CONFIG_DIR" -name "snell-[0-9]*.conf" -type f 2>/dev/null | sort)
            if [[ ${#_snell_confs[@]} -eq 0 ]]; then
                msg_error "未找到 Snell 节点配置文件。"; return
            elif [[ ${#_snell_confs[@]} -eq 1 ]]; then
                target_file="${_snell_confs[0]}"
            else
                printf "${C_CYAN}请选择要编辑的节点:${C_RESET}\n"
                local _i=1
                for _cf in "${_snell_confs[@]}"; do
                    printf "  ${C_GREEN}%d.${C_RESET} %s\n" "$_i" "$(basename "$_cf")"
                    _i=$((_i+1))
                done
                printf "${C_PURPLE}>>> ${C_RESET}"
                read -r _sel
                if [[ "$_sel" =~ ^[0-9]+$ ]] && (( _sel >= 1 && _sel <= ${#_snell_confs[@]} )); then
                    target_file="${_snell_confs[$((_sel-1))]}"
                else
                    msg_error "无效选择"; return
                fi
            fi
            service_name="snell"
            ;;
        2)
            target_file="$SS_CONFIG_FILE"
            service_name="shadowsocks-rust"
            ;;
        3)
            target_file="$REALM_CONFIG_FILE"
            service_name="realm"
            ;;
        0) return ;;
        *) msg_error "无效选项"; return ;;
    esac
    
    if [[ ! -f "$target_file" ]]; then
        msg_error "配置文件不存在: $target_file"
        return
    fi
    
    # Use nano or vim
    local editor
    if   command -v nano &>/dev/null; then editor="nano"
    elif command -v vim  &>/dev/null; then editor="vim"
    else editor="${VISUAL:-${EDITOR:-vi}}"
    fi
    
    "$editor" "$target_file"

    printf "${C_YELLOW}是否重启 %s 服务以应用修改? [Y/n]: ${C_RESET}" "$service_name"
    read -r restart_conf
    if [[ "${restart_conf,,}" != "n" ]]; then
        if [[ "$service_name" == "snell" ]]; then
            # 只重启修改的那个实例
            local _edit_port
            _edit_port=$(grep -oP 'listen\s*=\s*[^:]+:\K\d+' "$target_file" 2>/dev/null | head -1 || true)
            [[ -n "$_edit_port" ]] && systemctl restart "snell@${_edit_port}.service" || manage_services "restart" "snell"
        else
            manage_services "restart" "$service_name"
        fi
    fi

}

_do_update_menu() {
    clear
    printf "${C_BLUE}=== 更新服务 ===${C_RESET}\n\n"
    local _sv _sn _ssv _ssn _rv _rn _s5v
    _sv=$(get_installed_version snell "$SNELL_BIN")
    _sn=$(get_cached_latest_version snell)
    _ssv=$(get_installed_version shadowsocks-rust "$SS_BIN")
    _ssn=$(get_cached_latest_version shadowsocks-rust)
    _rv=$(get_installed_version realm "$REALM_BIN")
    _rn=$(get_cached_latest_version realm)
    _s5v=$(get_installed_version socks5 "")

    printf " ${C_GREEN}1.${C_RESET} Snell      "
    if [[ -f "$SNELL_BIN" ]]; then
        [[ -n "$_sn" && "$_sn" != "$_sv" ]] \
            && printf "  ${C_YELLOW}%s${C_RESET}  →  ${C_GREEN}%s${C_RESET} ${C_RED}[有更新]${C_RESET}\n" "$_sv" "$_sn" \
            || printf "  ${C_GREEN}%s${C_RESET}  (已是最新)\n" "$_sv"
    else
        printf "  ${C_DIM}未安装${C_RESET}\n"
    fi

    printf " ${C_GREEN}2.${C_RESET} SS-Rust    "
    if [[ -f "$SS_BIN" ]]; then
        [[ -n "$_ssn" && "$_ssn" != "$_ssv" ]] \
            && printf "  ${C_YELLOW}%s${C_RESET}  →  ${C_GREEN}%s${C_RESET} ${C_RED}[有更新]${C_RESET}\n" "$_ssv" "$_ssn" \
            || printf "  ${C_GREEN}%s${C_RESET}  (已是最新)\n" "$_ssv"
    else
        printf "  ${C_DIM}未安装${C_RESET}\n"
    fi

    printf " ${C_GREEN}3.${C_RESET} Realm      "
    if [[ -f "$REALM_BIN" ]]; then
        [[ -n "$_rn" && "$_rn" != "$_rv" ]] \
            && printf "  ${C_YELLOW}%s${C_RESET}  →  ${C_GREEN}%s${C_RESET} ${C_RED}[有更新]${C_RESET}\n" "$_rv" "$_rn" \
            || printf "  ${C_GREEN}%s${C_RESET}  (已是最新)\n" "$_rv"
    else
        printf "  ${C_DIM}未安装${C_RESET}\n"
    fi

    printf " ${C_GREEN}4.${C_RESET} SOCKS5     "
    if command -v danted &>/dev/null; then
        printf "  ${C_GREEN}%s${C_RESET}  (apt 升级)\n" "$_s5v"
    else
        printf "  ${C_DIM}未安装${C_RESET}\n"
    fi

    printf "\n ${C_GREEN}5.${C_RESET} 一键更新全部有更新的服务\n"
    printf " ${C_GREEN}0.${C_RESET} 返回\n"
    printf "\n${C_PURPLE}请选择: ${C_RESET}"
    read -r _upd_ch
    case "$_upd_ch" in
        1) [[ -f "$SNELL_BIN" ]] && update_service "snell" || msg_warn "Snell 未安装" ;;
        2) [[ -f "$SS_BIN" ]] && update_service "shadowsocks-rust" || msg_warn "SS-Rust 未安装" ;;
        3) [[ -f "$REALM_BIN" ]] && update_service "realm" || msg_warn "Realm 未安装" ;;
        4)
            if command -v danted &>/dev/null; then
                printf "${C_CYAN}正在更新 danted (SOCKS5)...${C_RESET}\n"
                apt-get update -qq && apt-get install --only-upgrade -y danted && \
                    printf "${C_GREEN}✓ 更新完成: %s${C_RESET}\n" "$(get_installed_version socks5 "")" || \
                    printf "${C_RED}✗ 更新失败，请检查 apt 源${C_RESET}\n"
            else
                msg_warn "SOCKS5 未安装"
            fi
            ;;
        5)
            local _did=0
            if [[ -f "$SNELL_BIN" && -n "$_sn" && "$_sn" != "$_sv" ]]; then
                update_service "snell"; _did=1
            fi
            if [[ -f "$SS_BIN" && -n "$_ssn" && "$_ssn" != "$_ssv" ]]; then
                update_service "shadowsocks-rust"; _did=1
            fi
            if [[ -f "$REALM_BIN" && -n "$_rn" && "$_rn" != "$_rv" ]]; then
                update_service "realm"; _did=1
            fi
            [[ $_did -eq 0 ]] && printf "${C_GREEN}所有服务均已是最新版本${C_RESET}\n"
            ;;
        0) return ;;
        *) msg_warn "无效选项" ;;
    esac
}

_do_uninstall_menu() {
    clear
    printf "${C_BLUE}=== 卸载服务 ===${C_RESET}\n\n"
    printf " ${C_GREEN}1.${C_RESET} 卸载 Snell\n"
    printf " ${C_GREEN}2.${C_RESET} 卸载 Shadowsocks-Rust\n"
    printf " ${C_GREEN}3.${C_RESET} 卸载 Realm\n"
    printf " ${C_GREEN}4.${C_RESET} 卸载 SOCKS5 代理\n"
    printf " ${C_GREEN}0.${C_RESET} 返回\n"
    printf "\n${C_PURPLE}请选择: ${C_RESET}"
    read -r _unin_ch
    case "$_unin_ch" in
        1) uninstall_service "snell" "$SNELL_USER" "$SNELL_BIN" "$SNELL_CONFIG_DIR" "$SNELL_SERVICE_FILE" "" ;;
        2) uninstall_service "shadowsocks-rust" "$SS_USER" "$SS_BIN" "$SS_CONFIG_DIR" "$SS_SERVICE_FILE" "$SS_CONFIG_FILE" ;;
        3) uninstall_service "realm" "$REALM_USER" "$REALM_BIN" "$REALM_CONFIG_DIR" "$REALM_SERVICE_FILE" "$REALM_CONFIG_FILE" ;;
        4) _socks5_uninstall ;;
        0) return ;;
        *) msg_warn "取消卸载" ;;
    esac
}



# ==============================================================================
# 中转监控模块（内嵌，原 relay-monitor.sh）
# ==============================================================================

readonly MONITOR_DIR="/opt/proxy-manager/monitor"
readonly MONITOR_CONFIG="${MONITOR_DIR}/config.conf"
readonly MONITOR_DATA_DIR="${MONITOR_DIR}/data"

readonly QUOTA_DIR="${WORK_DIR}/quota"
readonly QUOTA_CONFIG="${QUOTA_DIR}/quota.conf"
readonly QUOTA_DATA="${QUOTA_DIR}/quota.data"
readonly QUOTA_TG_CONFIG="${QUOTA_DIR}/tg.conf"
readonly QUOTA_CHAIN_IN="QUOTA_IN"
readonly QUOTA_CHAIN_OUT="QUOTA_OUT"

readonly CHECK_INTERVAL=30
readonly PROBE_COUNT=10     # 10包：丢包率分辨率10%，比5包的20%精细一倍
readonly PROBE_INTERVAL=0.3 # 包间隔300ms，分散采样，抗瞬间抖动
readonly PROBE_TIMEOUT=2.0  # 超时2s，兼容高延迟国际线路
readonly PROBE_SCRIPT_PATH="/usr/local/lib/ipt_prxy/probe.py"
readonly PROBE_SCRIPT_VER="1.1"
readonly LOSS_WARN=5
readonly LOSS_CRIT=15
readonly JITTER_WARN=20    # ms：延迟标准差超过此值扣分
readonly JITTER_CRIT=50    # ms：延迟标准差超过此值重度扣分
readonly DATA_RETENTION_DAYS=7

# 安全读取配置（不 source，防止代码注入）
load_config() {
    if [[ ! -f "$MONITOR_CONFIG" ]]; then
        die "未找到监控配置，请先在菜单选项 5 中配置 Telegram"
    fi
    TG_BOT_TOKEN=$(grep -E '^TG_BOT_TOKEN=' "$MONITOR_CONFIG" | head -1 \
        | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//")
    TG_CHAT_ID=$(grep -E '^TG_CHAT_ID=' "$MONITOR_CONFIG" | head -1 \
        | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//")
    if [[ -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]]; then
        die "监控配置不完整，请重新运行选项 5 配置 Telegram"
    fi
}

# 从缓存推导本机节点标识，格式: HK_197
get_node_id() {
    # 优先使用 SSH 监控配置的服务器别名
    local _ssh_name
    _ssh_name=$(grep "^SERVER_NAME=" /etc/ssh-tg-monitor.conf 2>/dev/null | cut -d= -f2- | sed 's/^"//;s/"$//' || true)
    if [[ -n "$_ssh_name" ]]; then
        # 纯字母数字下划线标签 → 前置国旗，使消息格式 🇺🇸 #Tag
        if [[ "$_ssh_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            local _cc _flag=""
            _cc=$(grep -E '^SERVER_COUNTRY_CODE=' "$CACHE_FILE" 2>/dev/null | head -1 | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" || true)
            if [[ ${#_cc} -eq 2 && "$_cc" =~ ^[A-Za-z]+$ ]]; then
                _flag=$(python3 -c "cc='${_cc^^}'; print(chr(0x1F1E6+ord(cc[0])-65)+chr(0x1F1E6+ord(cc[1])-65),end='')" 2>/dev/null || true)
            fi
            echo "${_flag:+${_flag} }${_ssh_name}"
        else
            echo "$_ssh_name"
        fi
        return
    fi

    local ip="" cc=""
    if [[ -f "$CACHE_FILE" ]]; then
        ip=$(grep -E '^SERVER_IP='           "$CACHE_FILE" | head -1 | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" || true)
        cc=$(grep -E '^SERVER_COUNTRY_CODE=' "$CACHE_FILE" | head -1 | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" || true)
    fi
    if [[ -z "$ip" ]]; then
        ip=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo "")
    fi
    local last="${ip##*.}"
    cc="${cc:-UN}"
    [[ -n "$last" ]] && echo "${cc}_${last}" || echo "$cc"
}

# 对别名倒数第二段加{}
highlight_local() {
    local alias=$1
    if [[ "$alias" != *" → "* ]]; then
        printf '%s' "$alias"
        return
    fi
    printf '%s' "$alias" | awk 'BEGIN { FS=" → " } {
        if (NF == 2) {
            print $1 " → " $2
        } else {
            r = $1
            for (i = 2; i <= NF-2; i++) r = r " → " $i
            r = r " → " $(NF-1) " → " $NF
            print r
        }
    }'
}

setup_config() {
    mkdir -p "$MONITOR_DIR"
    printf "${C_CYAN}=== 配置 Relay 监控 ===${C_RESET}\n\n"

    # 优先从 MONITOR_CONFIG 读取，回退到 TG_CONF
    local input_token="" input_chat_id=""
    if [[ -f "$MONITOR_CONFIG" ]]; then
        input_token=$(grep  "^TG_BOT_TOKEN=" "$MONITOR_CONFIG" 2>/dev/null | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" || true)
        input_chat_id=$(grep "^TG_CHAT_ID="  "$MONITOR_CONFIG" 2>/dev/null | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" || true)
    fi
    if [[ -z "$input_token" ]] && [[ -f "$TG_CONF" ]]; then
        input_token=$(grep "^TG_BOT_TOKEN=" "$TG_CONF" 2>/dev/null | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" || true)
    fi
    if [[ -z "$input_chat_id" ]] && [[ -f "$TG_CONF" ]]; then
        local _mon_chat
        _mon_chat=$(grep "^TG_CHAT_MONITOR=" "$TG_CONF" 2>/dev/null | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" || true)
        input_chat_id="${_mon_chat:-$(grep "^TG_CHAT_ID=" "$TG_CONF" 2>/dev/null | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" || true)}"
    fi

    if [[ -z "$input_token" || -z "$input_chat_id" ]]; then
        die "未找到 TG 配置，请先在主菜单 ★4「TG 推送配置」中设置 Token 和 Chat ID"
    fi
    msg_info "使用 Token: ${input_token:0:20}...  Chat ID: ${input_chat_id}"

    printf "TG_BOT_TOKEN='%s'\nTG_CHAT_ID='%s'\n" "$input_token" "$input_chat_id" > "$MONITOR_CONFIG"
    chmod 600 "$MONITOR_CONFIG"

    install_relay_services
    send_daily_report
}

# 对单个端点执行 PROBE_COUNT 次 TCP 探测，包间隔 PROBE_INTERVAL 秒
# 输出: "avg_ms min_ms max_ms loss_pct jitter_ms"
# jitter = max - min，反映延迟稳定性
tcping_check() {
    local host=$1 port=$2
    local success=0 total_ms=0 min_ms=999999 max_ms=0
    local -a times=()
    # PROBE_TIMEOUT 可能是小数(2.0)，nc/socat 需要整数秒
    local _to=${PROBE_TIMEOUT%.*}
    [[ -z "$_to" || "$_to" == "0" ]] && _to=2
    # 工具检测一次，10次探测复用
    local _probe_tool
    command -v nc &>/dev/null && _probe_tool="nc" || _probe_tool="socat"

    local i
    for (( i=1; i<=PROBE_COUNT; i++ )); do
        # 第一包不等待，后续包间隔 PROBE_INTERVAL
        # read -t 是 bash 内建，替代 sleep 子进程
        (( i > 1 )) && read -t "$PROBE_INTERVAL" -r _ 2>/dev/null || true
        # $EPOCHREALTIME 是 bash 5.0+ 内建变量，替代 date +%s%3N 子进程
        # 格式: 秒.微秒，去掉小数点后取前13位得到毫秒
        local _er_start=${EPOCHREALTIME/./} _er_end
        local _ok=false
        if [[ "$_probe_tool" == "nc" ]]; then
            nc -z -w "$_to" "$host" "$port" 2>/dev/null && _ok=true
        else
            socat /dev/null "TCP4:${host}:${port},connect-timeout=${_to}" 2>/dev/null && _ok=true
        fi
        if $_ok; then
            _er_end=${EPOCHREALTIME/./}
            local elapsed=$(( ${_er_end:0:13} - ${_er_start:0:13} ))
            success=$(( success + 1 ))
            total_ms=$(( total_ms + elapsed ))
            times+=("$elapsed")
            (( elapsed < min_ms )) && min_ms=$elapsed
            (( elapsed > max_ms )) && max_ms=$elapsed
        fi
    done

    local loss
    loss=$(( (PROBE_COUNT - success) * 100 / PROBE_COUNT ))

    if [[ $success -eq 0 ]]; then
        echo "0 0 0 100 0"
    else
        local avg_ms
        avg_ms=$((total_ms / success))
        [[ $min_ms -eq 999999 ]] && min_ms=0
        # 真实抖动：相邻成功探测差值的绝对均值
        local jitter=0
        if [[ ${#times[@]} -ge 2 ]]; then
            local sum_diff=0 j diff
            for (( j=1; j<${#times[@]}; j++ )); do
                diff=$(( times[j] - times[j-1] ))
                [[ $diff -lt 0 ]] && diff=$(( -diff ))
                sum_diff=$(( sum_diff + diff ))
            done
            jitter=$(( sum_diff / (${#times[@]} - 1) ))
        fi
        echo "$avg_ms $min_ms $max_ms $loss $jitter"
    fi
}

# 写入 Python asyncio 探测脚本（版本变更时自动重写）
_ensure_probe_script() {
    if [[ -f "$PROBE_SCRIPT_PATH" ]] && \
       grep -q "# ipt_probe_ver:${PROBE_SCRIPT_VER}" "$PROBE_SCRIPT_PATH" 2>/dev/null; then
        return 0
    fi
    mkdir -p "$(dirname "$PROBE_SCRIPT_PATH")"
    cat > "$PROBE_SCRIPT_PATH" << 'PYEOF'
#!/usr/bin/env python3
# ipt_probe_ver:1.1
import asyncio, json, sys, time, socket, struct

def _args():
    try:
        count    = int(sys.argv[1])
        interval = float(sys.argv[2])
        timeout  = float(sys.argv[3])
    except (IndexError, ValueError):
        count, interval, timeout = 10, 0.3, 2.0
    nodes = []
    for arg in sys.argv[4:]:
        try:
            h, p = arg.rsplit(":", 1)
            nodes.append((h, int(p)))
        except ValueError:
            pass
    return count, interval, timeout, nodes

async def probe_node(host, port, count, interval, timeout):
    times = []
    for i in range(count):
        if i > 0:
            await asyncio.sleep(interval)
        t0 = time.perf_counter()
        try:
            _, w = await asyncio.wait_for(
                asyncio.open_connection(host, port), timeout=timeout)
            ms = (time.perf_counter() - t0) * 1000
            # SO_LINGER=0: 发 RST 代替 FIN，连接立即消失，不进入 TIME-WAIT
            sock = w.transport.get_extra_info('socket')
            if sock:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                                struct.pack('ii', 1, 0))
            w.close()
            times.append(ms)
        except Exception:
            pass
    n = len(times)
    loss = round((count - n) * 100 / count)
    if n == 0:
        return {"host": host, "port": port,
                "avg": 0, "min": 0, "max": 0, "loss": 100, "jitter": 0}
    avg = sum(times) / n
    jitter = (sum(abs(times[i] - times[i-1]) for i in range(1, n)) / (n - 1)
              if n > 1 else 0)
    return {"host": host, "port": port,
            "avg": round(avg, 1), "min": round(min(times), 1),
            "max": round(max(times), 1), "loss": loss, "jitter": round(jitter, 1)}

async def main():
    count, interval, timeout, nodes = _args()
    if not nodes:
        print("[]")
        return
    results = await asyncio.gather(
        *[probe_node(h, p, count, interval, timeout) for h, p in nodes])
    print(json.dumps(list(results), separators=(",", ":")))

asyncio.run(main())
PYEOF
    chmod 644 "$PROBE_SCRIPT_PATH"
}

# 批量并发探测：一次 Python 调用替代多个子 shell + nc
# 参数: host:port ...
# 输出: 每行 "avg min max loss jitter"，顺序与输入一致
_tcping_batch() {
    _ensure_probe_script
    python3 "$PROBE_SCRIPT_PATH" \
        "$PROBE_COUNT" "$PROBE_INTERVAL" "$PROBE_TIMEOUT" "$@" \
    | jq -r '.[] | "\(.avg) \(.min) \(.max) \(.loss) \(.jitter)"'
}

get_data_file() {
    echo "${MONITOR_DATA_DIR}/$(TZ=Asia/Shanghai date '+%Y-%m-%d').dat"
}

# 写入一行检测记录（TAB 分隔）
# 格式: timestamp \t port \t alias \t avg_ms \t min_ms \t max_ms \t loss_pct \t jitter_ms
log_result() {
    local port=$1 alias=$2 avg=$3 min=$4 max=$5 loss=$6 jitter=${7:-0}
    local safe_alias="${alias//$'\t'/ }"
    safe_alias="${safe_alias//$'\n'/ }"
    safe_alias="${safe_alias//$'\r'/ }"
    mkdir -p "$MONITOR_DATA_DIR"
    local data_file
    data_file=$(get_data_file)
    # 防止 .dat 无限增长：超过 DATA_MAX_LINES 行时裁剪为一半（flock 保证裁剪与追加原子性）
    (
        flock -x -w 5 200 || { msg_warn "写入锁超时，跳过本轮"; return; }
        local _lines
        _lines=$(wc -l < "$data_file" 2>/dev/null || echo 0)
        if [[ $_lines -gt ${DATA_MAX_LINES:-86400} ]]; then
            local _trim_tmp
            _trim_tmp=$(mktemp)
            tail -n $(( DATA_MAX_LINES / 2 )) "$data_file" > "$_trim_tmp" \
                && mv "$_trim_tmp" "$data_file" || rm -f "$_trim_tmp"
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$(date +%s)" "$port" "$safe_alias" "$avg" "$min" "$max" "$loss" "$jitter" \
            >> "$data_file"
    ) 200>"${data_file}.lock"
}

# 从 Realm 配置读取所有端点，输出 "r_host r_port l_port alias" 行列表
get_realm_endpoints() {
    if [[ ! -f "$REALM_CONFIG_FILE" ]]; then return; fi
    jq -c '.endpoints[]' "$REALM_CONFIG_FILE" 2>/dev/null | while IFS= read -r ep; do
        local listen remote l_port r_host r_port alias
        listen=$(echo "$ep" | jq -r '.listen')
        remote=$(echo "$ep" | jq -r '.remote')
        l_port=$(echo "$listen" | cut -d: -f2)
        r_host=$(echo "$remote" | cut -d: -f1)
        r_port=$(echo "$remote" | cut -d: -f2)
        alias=""
        if [[ -f "$REALM_META_FILE" ]]; then
            alias=$(jq -r --arg p "$l_port" '.[$p].alias // empty' \
                "$REALM_META_FILE" 2>/dev/null || true)
        fi
        [[ -z "$alias" ]] && alias="${l_port} → ${r_host}:${r_port}"
        printf '%s\t%s\t%s\t%s\n' "$r_host" "$r_port" "$l_port" "$alias"
    done
}

run_daemon() {
    msg_info "中转监控守护进程启动 (检测间隔 ${CHECK_INTERVAL}s，探测 ${PROBE_COUNT} 包/轮)"

    # 守护进程被 systemd 停止时 (SIGTERM) 清理本轮临时目录
    local _daemon_cur_tmp=""
    trap 'rm -rf "$_daemon_cur_tmp" 2>/dev/null; exit 0' SIGTERM SIGINT

    mkdir -p "$MONITOR_DATA_DIR"
    find "$MONITOR_DATA_DIR" -name "*.dat" \
        -mtime +"$DATA_RETENTION_DAYS" -delete 2>/dev/null || true

    declare -A _consec_fail=()
    declare -A _was_notified=()
    local _cooldown_dir="/run/relay-dead-notify"
    mkdir -p "$_cooldown_dir"
    local _node_id
    _node_id=$(get_node_id)

    while true; do
        local t_round_start
        t_round_start=$(date +%s)

        if [[ -f "$REALM_CONFIG_FILE" ]]; then
            local tmp_dir
            tmp_dir=$(mktemp -d)
            _daemon_cur_tmp="$tmp_dir"
            # 收集所有端点，保持顺序（asyncio.gather 保序，结果可按下标对应）
            local -a _rh_arr=() _rp_arr=() _lp_arr=() _alias_arr=() _node_args=()
            while IFS=$'\t' read -r r_host r_port l_port alias; do
                [[ -z "$r_host" ]] && continue
                _rh_arr+=("$r_host"); _rp_arr+=("$r_port")
                _lp_arr+=("$l_port"); _alias_arr+=("$alias")
                _node_args+=("${r_host}:${r_port}")
            done < <(get_realm_endpoints)
            # 一次 Python 调用并发探测所有节点，替代 N 个子 shell + N×10 个 nc
            local -a _batch=()
            if [[ ${#_node_args[@]} -gt 0 ]]; then
                while IFS= read -r _line; do
                    _batch+=("$_line")
                done < <(_tcping_batch "${_node_args[@]}" 2>/dev/null)
            fi
            # 写入结果文件（格式与原逻辑完全一致，下游代码无需改动）
            local _idx
            for (( _idx=0; _idx<${#_rh_arr[@]}; _idx++ )); do
                local _lp="${_lp_arr[$_idx]}" _al="${_alias_arr[$_idx]}"
                local _avg _min _max _loss _jitter
                read -r _avg _min _max _loss _jitter <<< "${_batch[$_idx]:-0 0 0 100 0}"
                printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                    "$_lp" "$_al" "$_avg" "$_min" "$_max" "$_loss" "$_jitter" \
                    > "${tmp_dir}/${_lp}.result"
            done

            # 统计本轮失败数：全部端点同时100%丢包 = 本机网络中断，跳过写入避免污染统计
            local _total_eps=0 _failed_eps=0
            for f in "${tmp_dir}"/*.result; do
                [[ -f "$f" ]] || continue
                _total_eps=$((_total_eps + 1))
                local _chk_loss
                _chk_loss=$(cut -f6 "$f" 2>/dev/null || echo "0")
                [[ "$_chk_loss" == "100" ]] && _failed_eps=$((_failed_eps + 1))
            done

            local _write=true
            if [[ $_total_eps -ge 1 && $_total_eps -eq $_failed_eps ]]; then
                msg_warn "本轮全部 ${_total_eps} 条线路不可达，疑似本机网络中断，跳过写入"
                _write=false
            fi

            if [[ "$_write" == true ]]; then
                for f in "${tmp_dir}"/*.result; do
                    [[ -f "$f" ]] || continue
                    local l_port alias avg min max loss jitter
                    IFS=$'\t' read -r l_port alias avg min max loss jitter < "$f"
                    log_result "$l_port" "$alias" "$avg" "$min" "$max" "$loss" "$jitter" || true
                    echo "[probe] ${alias} | ${avg}ms (${min}-${max}ms) | 丢包 ${loss}% | 抖动 ${jitter}ms"

                    if [[ "$loss" == "100" ]]; then
                        _consec_fail[$l_port]=$(( ${_consec_fail[$l_port]:-0} + 1 ))
                        if [[ ${_consec_fail[$l_port]} -ge 3 ]]; then
                            local _cooldown_file="${_cooldown_dir}/${l_port}"
                            local _last_ts=0
                            [[ -f "$_cooldown_file" ]] && _last_ts=$(cat "$_cooldown_file" 2>/dev/null || echo 0)
                            local _now_ts
                            _now_ts=$(date +%s)
                            if (( _now_ts - _last_ts >= 4 * 3600 )); then
                                echo "$_now_ts" > "$_cooldown_file"
                                _was_notified[$l_port]=1
                                local _now_str
                                _now_str=$(TZ=Asia/Shanghai date '+%m-%d %H:%M')
                                send_telegram "🔴 #节点不可达   ${_node_id//[a-zA-Z0-9_]/}#${_node_id//[^a-zA-Z0-9_]/}
🕐 ${_now_str}
━━━━━━━━━━━━━━━━━
节点: ${alias}
连续 3 轮 100% 丢包" || true
                            fi
                        fi
                    else
                        if [[ ${_was_notified[$l_port]:-0} -eq 1 ]]; then
                            _was_notified[$l_port]=0
                            local _now_str
                            _now_str=$(TZ=Asia/Shanghai date '+%m-%d %H:%M')
                            send_telegram "🟢 #节点已恢复   ${_node_id//[a-zA-Z0-9_]/}#${_node_id//[^a-zA-Z0-9_]/}
🕐 ${_now_str}
━━━━━━━━━━━━━━━━━
节点: ${alias}
延迟: ${avg}ms | 丢包: ${loss}%" || true
                        fi
                        _consec_fail[$l_port]=0
                    fi
                done
            fi
            rm -rf "$tmp_dir" 2>/dev/null || true
            _daemon_cur_tmp=""
        fi

        local elapsed remaining
        elapsed=$(( $(date +%s) - t_round_start ))
        remaining=$(( CHECK_INTERVAL - elapsed ))
        [[ $remaining -gt 0 ]] && sleep "$remaining"
    done
}

# 聚合指定时间范围内的数据
# 参数: data_file  since_ts
# 输出每行: port \t alias \t avg_ms \t min_ms \t max_ms \t max_loss \t avg_loss \t count \t avg_jitter
aggregate_data() {
    local data_file=$1
    local since_ts=$2

    [[ ! -f "$data_file" ]] && return

    awk -F'\t' -v since="$since_ts" '
    NF >= 7 && $1+0 >= since {
        port  = $2
        alias = $3
        avg   = $4+0; mx = $6+0; loss = $7+0
        jit   = (NF >= 8) ? $8+0 : ($6+0 - $5+0)

        if (!(port in cnt)) {
            aliases[port]     = alias
            sum_avg[port]     = 0
            sum_sq[port]      = 0
            sum_loss[port]    = 0
            sum_jitter[port]  = 0
            g_max[port]       = 0
            cnt[port]         = 0
            max_jit[port]     = 0
            jit_spikes[port]  = 0
            loss_rounds[port] = 0
            cur_streak[port]  = 0
            max_streak[port]  = 0
        }
        cnt[port]++
        sum_avg[port]    += avg
        sum_sq[port]     += avg * avg
        sum_loss[port]   += loss
        sum_jitter[port] += jit
        if (mx > g_max[port])                g_max[port]  = mx
        if (jit > max_jit[port])             max_jit[port] = jit
        if (jit > 5)                         jit_spikes[port]++
        if (loss > 0)                        loss_rounds[port]++
        if (loss >= 100) {
            cur_streak[port]++
            if (cur_streak[port] > max_streak[port]) max_streak[port] = cur_streak[port]
        } else {
            cur_streak[port] = 0
        }
    }
    END {
        for (port in cnt) {
            a_avg    = sum_avg[port] / cnt[port]
            a_loss   = sprintf("%.2f", sum_loss[port] / cnt[port])
            a_jitter = sum_jitter[port] / cnt[port]
            variance = sum_sq[port] / cnt[port] - a_avg * a_avg
            stddev   = (variance > 0) ? sqrt(variance) : 0
            loss_pct = sprintf("%.1f", loss_rounds[port] * 100.0 / cnt[port])
            jit_pct  = sprintf("%.1f", jit_spikes[port]  * 100.0 / cnt[port])
            printf "%s\t%s\t%.1f\t%.1f\t%.1f\t%d\t%s\t%d\t%.1f\t%.1f\t%s\t%s\n",
                port, aliases[port], a_avg, stddev, g_max[port],
                max_streak[port], a_loss, cnt[port], a_jitter,
                max_jit[port], jit_pct, loss_pct
        }
    }
    ' "$data_file"
}

refresh_aliases() {
    # 从 get_realm_endpoints() 建查找表（含 metadata + fallback），覆盖数据文件里的旧别名
    # 输入/输出格式: port \t alias \t ...（其余字段原样透传）
    local -A _live
    while IFS=$'\t' read -r r_host r_port l_port alias; do
        _live["$l_port"]="$alias"
    done < <(get_realm_endpoints 2>/dev/null || true)

    while IFS=$'\t' read -r port alias rest; do
        [[ -n "${_live[$port]:-}" ]] && alias="${_live[$port]}"
        printf '%s\t%s\t%s\n' "$port" "$alias" "$rest"
    done
}

classify_line() {
    # Returns: ok | warn | crit | dead
    # Scoring: avg_loss(40/20) + max_streak(20/10) + jitter(20/8), tier at ≥40/≥8/0
    # max_streak: 连续 100% 丢包轮次；≥6轮(~3min)→crit加分，≥2轮(~1min)→warn加分
    local avg_loss=$1 max_streak=$2 avg_jitter=$3
    awk -v al="$avg_loss" -v ms="$max_streak" -v aj="$avg_jitter" \
        -v lw="$LOSS_WARN" -v lc="$LOSS_CRIT" \
        -v jw="$JITTER_WARN" -v jc="$JITTER_CRIT" \
    'BEGIN {
        if (al+0 >= 100) { print "dead"; exit }
        score = 0
        if      (al+0 >= lc+0) score += 40
        else if (al+0 >= lw+0) score += 20
        if      (ms+0 >= 6)    score += 20
        else if (ms+0 >= 2)    score += 10
        if      (aj+0 >= jc+0) score += 20
        else if (aj+0 >= jw+0) score += 8
        if      (score >= 40)  print "crit"
        else if (score >= 8)   print "warn"
        else                   print "ok"
    }'
}

sort_by_tier() {
    # Prepend tier number, sort (tier→avg_loss→jitter→peak), strip tier column
    # Ensures ranking order matches icon classification
    local input="$1"
    while IFS=$'\t' read -r port alias avg_ms stddev_ms max_ms max_streak avg_loss count avg_jitter max_jitter jitter_pct loss_pct; do
        local t
        case $(classify_line "$avg_loss" "$max_streak" "$avg_jitter") in
            ok)   t=0 ;; warn) t=1 ;; crit) t=2 ;; dead) t=3 ;; *) t=0 ;;
        esac
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$t" "$port" "$alias" "$avg_ms" "$stddev_ms" "$max_ms" "$max_streak" "$avg_loss" "$count" "$avg_jitter" "$max_jitter" "$jitter_pct" "$loss_pct"
    done <<< "$input" | sort -t$'\t' -k1,1n -k8,8g -k10,10g -k7,7n | cut -f2-
}

loss_emoji() {
    local avg_loss=$1 max_loss=$2 avg_jitter=$3
    case $(classify_line "$avg_loss" "$max_loss" "$avg_jitter") in
        dead) printf '🔴' ;;
        crit) printf '🔴' ;;
        warn) printf '🟡' ;;
        *)    printf '🟢' ;;
    esac
}



# 从已排序数据构建报告正文与排名，结果写入全局临时变量:
#   _rpt_body  _rpt_ranking  _rpt_ok  _rpt_warn  _rpt_crit  _rpt_dead
# $1=sorted_rows  $2=不可达标签(默认"全程不可达")
_build_report_content() {
    local sorted_rows="$1"
    local unreachable_label="${2:-全程不可达}"
    _rpt_body=""; _rpt_ranking=""
    _rpt_ok=0; _rpt_warn=0; _rpt_crit=0; _rpt_dead=0; _rpt_rounds=0
    local rank=1
    while IFS=$'\t' read -r port alias avg_ms stddev_ms max_ms max_streak avg_loss count avg_jitter max_jitter jitter_pct loss_pct; do
        [[ ${count:-0} -gt $_rpt_rounds ]] && _rpt_rounds=$count
        local icon display_alias
        icon=$(loss_emoji "$avg_loss" "$max_streak" "$avg_jitter")
        display_alias=$(highlight_local "$alias")
        case $(classify_line "$avg_loss" "$max_streak" "$avg_jitter") in
            dead) _rpt_dead=$((_rpt_dead + 1)) ;;
            crit) _rpt_crit=$((_rpt_crit + 1)) ;;
            warn) _rpt_warn=$((_rpt_warn + 1)) ;;
            *)    _rpt_ok=$((_rpt_ok + 1)) ;;
        esac
        if [[ ${avg_ms%%.*} -eq 0 && ${avg_loss%.*} -eq 100 ]]; then
            _rpt_body+="
${icon} ${display_alias}
   ${unreachable_label}  丢包 100%
────────────────────────"
        else
            _rpt_body+="
${icon} ${display_alias}
   延迟 ${avg_ms}ms ±${stddev_ms}ms / 高${max_ms}ms
   丢包 ${avg_loss}%  |  连续断 ${max_streak} 轮  |  轮占 ${loss_pct}%
   抖动 ${avg_jitter}ms  |  峰值 ${max_jitter}ms  |  >5ms ${jitter_pct}%
────────────────────────"
        fi
        local _sep
        _sep="╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌"
        _rpt_ranking+="
${_sep}
 ${rank}. ${icon} ${display_alias}
 延迟: <u><b>${avg_ms} ms / ${stddev_ms} ms / ${max_ms} ms</b></u>（均/σ/高）
 丢包: <u><b>${avg_loss} % / ${max_streak} R / ${loss_pct} %</b></u>（率/断/占）
 抖动: <u><b>${avg_jitter} ms / ${max_jitter} ms / ${jitter_pct} %</b></u>（均/峰/频）"
        rank=$((rank + 1))
    done <<< "$sorted_rows"
}

send_daily_report() {
    # 滚动24小时窗口：合并昨天+今天的数据，取最近24h内的记录
    # 不足24小时时有多少统计多少
    local now since
    now=$(date +%s)
    since=$((now - 86400))

    local _today_file _yesterday_file _combined
    _today_file=$(get_data_file)
    _yesterday_file="${MONITOR_DATA_DIR}/$(TZ=Asia/Shanghai date -d 'yesterday' '+%Y-%m-%d' 2>/dev/null \
        || TZ=Asia/Shanghai date -v-1d '+%Y-%m-%d' 2>/dev/null || echo "").dat"
    _combined=$(mktemp)
    trap "rm -f '$_combined'" RETURN
    [[ -f "$_yesterday_file" ]] && cat "$_yesterday_file" >> "$_combined" 2>/dev/null || true
    [[ -f "$_today_file"     ]] && cat "$_today_file"     >> "$_combined" 2>/dev/null || true

    local rows
    rows=$(aggregate_data "$_combined" "$since" | refresh_aliases)
    rm -f "$_combined"

    if [[ -z "$rows" ]]; then
        msg_warn "日报：无数据，跳过推送"
        return
    fi

    local sorted_rows
    sorted_rows=$(sort_by_tier "$rows")

    _build_report_content "$sorted_rows" "期间不可达"
    local ranking="$_rpt_ranking"
    local ok_rules=$_rpt_ok warn_rules=$_rpt_warn crit_rules=$_rpt_crit dead_rules=$_rpt_dead
    local total_rules=$(( _rpt_ok + _rpt_warn + _rpt_crit + _rpt_dead ))

    local node_id
    node_id=$(get_node_id)

    local time_end time_start
    time_end=$(TZ=Asia/Shanghai date '+%m-%d %H:%M')
    time_start=$(TZ=Asia/Shanghai date -d "@$since" '+%m-%d %H:%M' 2>/dev/null \
              || TZ=Asia/Shanghai date -r "$since" '+%m-%d %H:%M' 2>/dev/null || echo "N/A")

    local msg_ranking
    msg_ranking="📊 Realm 24h 稳定性排名 ${node_id//[a-zA-Z0-9_]/}#${node_id//[^a-zA-Z0-9_]/}
🕐 <b>${time_start} → ${time_end}</b>${ranking}
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
汇总: 共 ${total_rules} 条 ｜ 🟢 ${ok_rules} ｜ 🟡 ${warn_rules} ｜ 🔴 $(( crit_rules + dead_rules ))
📡 间隔 ${CHECK_INTERVAL}s | 探测 ${PROBE_COUNT} 包/次 | 共 ${_rpt_rounds} 轮"
    if send_telegram "$msg_ranking" "${node_id//[^a-zA-Z0-9_]/}"; then
        msg_info "24h稳定性排名已推送到 Telegram ✓"
    else
        msg_warn "24h稳定性排名推送失败"
    fi
}

install_relay_services() {
    [[ $EUID -ne 0 ]] && die "需要 root 权限"
    msg_step "安装中转监控 Systemd 服务..."

    local script_path
    script_path=$(realpath "$0")

    local _unit_dir="/etc/systemd/system"
    local _tmp
    _tmp=$(mktemp -d)
    trap "rm -rf '$_tmp'" RETURN

    cat > "${_tmp}/relay-monitor.service" <<EOF
[Unit]
Description=Relay TCPing Monitor Daemon
After=network.target realm.service
Wants=network.target

[Service]
Type=simple
ExecStart=/bin/bash "${script_path}" daemon
Restart=always
RestartSec=15
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    cat > "${_tmp}/relay-monitor-daily.service" <<EOF
[Unit]
Description=Relay Monitor Daily Report - Ranking (20:00 (北京时间))

[Service]
Type=oneshot
ExecStart=/bin/bash "${script_path}" daily
Environment=TZ=Asia/Shanghai
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/opt/proxy-manager /var/log/proxy-manager.log
EOF

    cat > "${_tmp}/relay-monitor-daily.timer" <<EOF
[Unit]
Description=Relay Monitor Daily Ranking Report Timer (20:00 (北京时间))

[Timer]
OnCalendar=*-*-* 12:00:00 UTC
RandomizedDelaySec=120
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # 原子性移入目标目录
    for _f in relay-monitor.service relay-monitor-daily.service relay-monitor-daily.timer; do
        mv "${_tmp}/${_f}" "${_unit_dir}/${_f}"
    done

    # 清理旧的小时定时器和旧的 daily-body 定时器（如有遗留）
    for _unit in relay-monitor-hourly relay-monitor-daily-body; do
        systemctl stop    "${_unit}.timer"   2>/dev/null || true
        systemctl disable "${_unit}.timer"   2>/dev/null || true
        rm -f "/etc/systemd/system/${_unit}.service" \
              "/etc/systemd/system/${_unit}.timer"
    done

    systemctl daemon-reload
    systemctl enable relay-monitor.service       || msg_warn "启用 relay-monitor.service 失败"
    systemctl enable relay-monitor-daily.timer   || msg_warn "启用 relay-monitor-daily.timer 失败"
    systemctl start  relay-monitor-daily.timer   || msg_warn "启动 relay-monitor-daily.timer 失败"
    systemctl restart relay-monitor.service      || msg_warn "启动 relay-monitor.service 失败"

    msg_info "守护进程已启动  → relay-monitor.service"
    msg_info "排名定时器已启动 → relay-monitor-daily.timer (每日 20:00 (北京时间))"
    printf "\n${C_GREEN}安装完成！24h稳定性排名每日 20:00 (北京时间) 推送到 Telegram。${C_RESET}\n"
}

uninstall_relay_services() {
    [[ $EUID -ne 0 ]] && die "需要 root 权限"
    printf "${C_RED}确认卸载中转监控服务? [y/N]: ${C_RESET}"
    read -r ans
    [[ "${ans,,}" != "y" ]] && return

    for unit in relay-monitor relay-monitor-hourly relay-monitor-daily relay-monitor-daily-body; do
        systemctl stop    "${unit}.service" 2>/dev/null || true
        systemctl stop    "${unit}.timer"   2>/dev/null || true
        systemctl disable "${unit}.service" 2>/dev/null || true
        systemctl disable "${unit}.timer"   2>/dev/null || true
        rm -f "/etc/systemd/system/${unit}.service" \
              "/etc/systemd/system/${unit}.timer" 2>/dev/null || true
    done
    systemctl daemon-reload

    printf "${C_YELLOW}是否同时删除历史监控数据? [y/N]: ${C_RESET}"
    read -r del
    [[ "${del,,}" == "y" ]] && rm -rf "$MONITOR_DIR" && msg_info "数据已删除"

    msg_info "中转监控已卸载。"
}

show_relay_status() {
    clear
    printf "${C_CYAN}=== 中转监控状态 ===${C_RESET}\n\n"

    printf "守护进程: "
    if systemctl is-active --quiet relay-monitor.service 2>/dev/null; then
        printf "${C_GREEN}运行中${C_RESET}\n"
    else
        printf "${C_RED}未运行${C_RESET}\n"
    fi

    local next_daily
    next_daily=$(systemctl list-timers relay-monitor-daily.timer \
        --no-pager 2>/dev/null | awk 'NR==2{print $1,$2}' || echo "N/A")
    printf "24h排名推送: %s\n\n" "$next_daily"

    local _today_file _yesterday_file _combined
    _today_file=$(get_data_file)
    _yesterday_file="${MONITOR_DATA_DIR}/$(TZ=Asia/Shanghai date -d 'yesterday' '+%Y-%m-%d' 2>/dev/null \
        || TZ=Asia/Shanghai date -v-1d '+%Y-%m-%d' 2>/dev/null || echo "").dat"
    if [[ ! -f "$_today_file" && ! -f "$_yesterday_file" ]]; then
        printf "${C_YELLOW}暂无数据。${C_RESET}\n"
        printf "\n${C_CYAN}按任意键返回...${C_RESET}"; read -rsn1; return
    fi
    _combined=$(mktemp)
    trap "rm -f '$_combined'" RETURN
    [[ -f "$_yesterday_file" ]] && cat "$_yesterday_file" >> "$_combined" 2>/dev/null || true
    [[ -f "$_today_file"     ]] && cat "$_today_file"     >> "$_combined" 2>/dev/null || true

    local now since rows
    now=$(date +%s)
    since=$((now - 86400))
    rows=$(aggregate_data "$_combined" "$since" | refresh_aliases)

    if [[ -z "$rows" ]]; then
        printf "${C_YELLOW}最近 24 小时无数据。${C_RESET}\n"
        printf "\n${C_CYAN}按任意键返回...${C_RESET}"; read -rsn1; return
    fi

    printf "${C_BLUE}最近 24 小时统计:${C_RESET}\n"
    printf "%-32s %7s %7s %7s %8s %6s\n" "节点" "均延迟" "最低" "最高" "丢包%" "抖动"
    printf '%s\n' "────────────────────────────────────────────────────────────────────"

    while IFS=$'\t' read -r port alias avg_ms min_ms max_ms max_loss avg_loss count avg_jitter max_jitter jitter_spikes loss_rounds; do
        local icon
        icon=$(loss_emoji "$avg_loss" "$max_loss" "$avg_jitter")
        printf "%s %-30s %5dms %5dms %5dms %7s%% %5dms\n" \
            "$icon" "${alias:0:30}" "$avg_ms" "$min_ms" "$max_ms" "$avg_loss" "$avg_jitter"
    done <<< "$rows"

    printf "\n${C_CYAN}按任意键返回...${C_RESET}"; read -rsn1
}

# ==============================================================================
# 流量配额与到期管理模块
# ==============================================================================

_qbytes_human() {
    local b=${1:-0}
    if   (( b >= 1099511627776 )); then
        awk -v b="$b" 'BEGIN{v=b/1099511627776; printf (v==int(v))?"%.0f TB":"%.2f TB",v}'
    elif (( b >= 1073741824 )); then
        awk -v b="$b" 'BEGIN{v=b/1073741824;    printf (v==int(v))?"%.0f GB":"%.2f GB",v}'
    elif (( b >= 1048576 )); then
        awk -v b="$b" 'BEGIN{v=b/1048576;       printf (v==int(v))?"%.0f MB":"%.1f MB",v}'
    elif (( b >= 1024 )); then
        awk -v b="$b" 'BEGIN{printf "%.0f KB", b/1024}'
    else
        echo "${b} B"
    fi
}

_qhuman_to_bytes() {
    local s="${1^^}" num
    num=$(echo "$s" | tr -dc '0-9.')
    [[ -z "$num" || "$num" == "0" ]] && echo 0 && return
    if   [[ "$s" == *T* ]]; then awk "BEGIN{printf \"%d\", $num*1099511627776}"
    elif [[ "$s" == *G* ]]; then awk "BEGIN{printf \"%d\", $num*1073741824}"
    elif [[ "$s" == *M* ]]; then awk "BEGIN{printf \"%d\", $num*1048576}"
    elif [[ "$s" == *K* ]]; then awk "BEGIN{printf \"%d\", $num*1024}"
    else echo "${num%%.*}"
    fi
}

# TG notify without dying on missing config (safe for timer/non-interactive use)
_quota_tg_notify() {
    local msg="$1"
    local tok="" chat=""
    # 优先使用配额独立频道配置
    if [[ -f "$QUOTA_TG_CONFIG" ]]; then
        tok=$(grep -E '^TG_BOT_TOKEN=' "$QUOTA_TG_CONFIG" | head -1 | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" || true)
        chat=$(grep -E '^TG_CHAT_ID='  "$QUOTA_TG_CONFIG" | head -1 | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" || true)
    fi
    # 未配置独立频道则 fallback 到监控频道
    if [[ -z "$tok" || -z "$chat" ]]; then
        [[ ! -f "$MONITOR_CONFIG" ]] && return 0
        tok=$(grep -E '^TG_BOT_TOKEN=' "$MONITOR_CONFIG" | head -1 | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" || true)
        chat=$(grep -E '^TG_CHAT_ID='  "$MONITOR_CONFIG" | head -1 | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" || true)
        [[ -z "$tok" || -z "$chat" ]] && return 0
    fi
    TG_BOT_TOKEN="$tok" TG_CHAT_ID="$chat" send_telegram "$msg" 2>/dev/null || true
}

# Ensure counting chains exist and are linked to INPUT/OUTPUT
quota_init() {
    mkdir -p "$QUOTA_DIR"
    [[ -f "$QUOTA_CONFIG" ]] || touch "$QUOTA_CONFIG"
    [[ -f "$QUOTA_DATA"   ]] || touch "$QUOTA_DATA"
    iptables -N "$QUOTA_CHAIN_IN"  2>/dev/null || true
    iptables -N "$QUOTA_CHAIN_OUT" 2>/dev/null || true
    iptables -C INPUT  -j "$QUOTA_CHAIN_IN"  2>/dev/null || \
        iptables -I INPUT  1 -j "$QUOTA_CHAIN_IN"
    iptables -C OUTPUT -j "$QUOTA_CHAIN_OUT" 2>/dev/null || \
        iptables -I OUTPUT 1 -j "$QUOTA_CHAIN_OUT"

    # Auto-reinstall timers if config exists, timer not running, and not manually disabled
    if grep -q '^[0-9]' "$QUOTA_CONFIG" 2>/dev/null && \
       ! systemctl is-active --quiet quota-check.timer 2>/dev/null && \
       [[ ! -f "${QUOTA_DIR}/.timer_disabled" ]]; then
        install_quota_services >/dev/null 2>&1 || true
    fi
}

# Add RETURN rules in counting chains (byte counter accumulates on RETURN)
quota_add_counting_rules() {
    local port="$1"
    for proto in tcp udp; do
        iptables -C "$QUOTA_CHAIN_IN"  -p "$proto" --dport "$port" -j RETURN 2>/dev/null || \
            iptables -A "$QUOTA_CHAIN_IN"  -p "$proto" --dport "$port" -j RETURN
        iptables -C "$QUOTA_CHAIN_OUT" -p "$proto" --sport "$port" -j RETURN 2>/dev/null || \
            iptables -A "$QUOTA_CHAIN_OUT" -p "$proto" --sport "$port" -j RETURN
    done
}

quota_remove_counting_rules() {
    local port="$1"
    for proto in tcp udp; do
        iptables -D "$QUOTA_CHAIN_IN"  -p "$proto" --dport "$port" -j RETURN 2>/dev/null || true
        iptables -D "$QUOTA_CHAIN_OUT" -p "$proto" --sport "$port" -j RETURN 2>/dev/null || true
    done
}

# Read accumulated bytes from a counting chain for a specific port
# -x / --exact: prevents iptables from abbreviating large counts (1234K, 2M, etc.)
_quota_iptables_bytes() {
    local chain="$1" direction="$2" port="$3"
    iptables -nvxL "$chain" 2>/dev/null | \
        awk -v d="$direction" -v p="$port" \
            '$0 ~ (d":"p"( |$)") { sum += $2 } END { print sum+0 }'
}

quota_get_port_bytes() {
    local port="$1"
    local in_b out_b
    in_b=$(_quota_iptables_bytes "$QUOTA_CHAIN_IN"  "dpt" "$port")
    out_b=$(_quota_iptables_bytes "$QUOTA_CHAIN_OUT" "spt" "$port")
    echo "$in_b $out_b"
}

# Read port data: outputs "month iptbl_in iptbl_out acc_in acc_out paused pause_reason"
_quota_read_data() {
    local port="$1"
    local line
    line=$(grep -m1 "^${port}|" "$QUOTA_DATA" 2>/dev/null || true)
    if [[ -z "$line" ]]; then
        echo "$(TZ=Asia/Shanghai date +%Y-%m) 0 0 0 0 0 -"
    else
        IFS='|' read -r _ month iptbl_in iptbl_out acc_in acc_out paused pause_reason <<< "$line"
        echo "${month:-$(TZ=Asia/Shanghai date +%Y-%m)} ${iptbl_in:-0} ${iptbl_out:-0} ${acc_in:-0} ${acc_out:-0} ${paused:-0} ${pause_reason:--}"
    fi
}

# Write/update port data line atomically
_quota_write_data() {
    local port="$1" month="$2" iptbl_in="$3" iptbl_out="$4" \
          acc_in="$5" acc_out="$6" paused="$7" pause_reason="$8"
    local newline="${port}|${month}|${iptbl_in}|${iptbl_out}|${acc_in}|${acc_out}|${paused}|${pause_reason}"
    local tmpfile
    tmpfile=$(mktemp)
    trap "rm -f '$tmpfile'" RETURN
    grep -v "^${port}|" "$QUOTA_DATA" > "$tmpfile" 2>/dev/null || true
    echo "$newline" >> "$tmpfile"
    mv "$tmpfile" "$QUOTA_DATA"
}

# Commit current iptables counters into accumulated data (mutating)
_quota_commit_port() {
    local port="$1" cur_month="$2"
    read -r month iptbl_in iptbl_out acc_in acc_out paused pause_reason \
        < <(_quota_read_data "$port")
    read -r cur_in cur_out < <(quota_get_port_bytes "$port")

    # New month: reset accumulators, take new snapshot baseline
    if [[ "$month" != "$cur_month" ]]; then
        _quota_write_data "$port" "$cur_month" "$cur_in" "$cur_out" \
            0 0 "$paused" "$pause_reason"
        return
    fi

    # Reboot/counter-reset detection: if current < snapshot, old bytes are gone
    (( cur_in  < iptbl_in  )) && iptbl_in=0
    (( cur_out < iptbl_out )) && iptbl_out=0

    _quota_write_data "$port" "$cur_month" "$cur_in" "$cur_out" \
        $(( acc_in  + cur_in  - iptbl_in  )) \
        $(( acc_out + cur_out - iptbl_out )) \
        "$paused" "$pause_reason"
}

# Pause a port by inserting DROP rules before the counting chain
quota_pause_port() {
    local port="$1" reason="${2:-manual}"
    for proto in tcp udp; do
        iptables -C INPUT  -p "$proto" --dport "$port" \
            -m comment --comment "QUOTA_PAUSE:${port}" -j DROP 2>/dev/null || \
        iptables -I INPUT  1 -p "$proto" --dport "$port" \
            -m comment --comment "QUOTA_PAUSE:${port}" -j DROP
        iptables -C OUTPUT -p "$proto" --sport "$port" \
            -m comment --comment "QUOTA_PAUSE:${port}" -j DROP 2>/dev/null || \
        iptables -I OUTPUT 1 -p "$proto" --sport "$port" \
            -m comment --comment "QUOTA_PAUSE:${port}" -j DROP
    done
    read -r month iptbl_in iptbl_out acc_in acc_out _p _r < <(_quota_read_data "$port")
    _quota_write_data "$port" "$month" "$iptbl_in" "$iptbl_out" \
        "$acc_in" "$acc_out" 1 "$reason"
}

# Resume a port by removing DROP rules
quota_resume_port() {
    local port="$1"
    for proto in tcp udp; do
        iptables -D INPUT  -p "$proto" --dport "$port" \
            -m comment --comment "QUOTA_PAUSE:${port}" -j DROP 2>/dev/null || true
        iptables -D OUTPUT -p "$proto" --sport "$port" \
            -m comment --comment "QUOTA_PAUSE:${port}" -j DROP 2>/dev/null || true
    done
    read -r month iptbl_in iptbl_out acc_in acc_out _p _r < <(_quota_read_data "$port")
    _quota_write_data "$port" "$month" "$iptbl_in" "$iptbl_out" \
        "$acc_in" "$acc_out" 0 "-"
}

# Periodic check: enforce quota/expiry, auto-resume on new month (called by timer)
quota_check_all() {
    [[ ! -f "$QUOTA_CONFIG" ]] && return 0

    # 防并发：定时器与交互操作可能同时触发，后者静默跳过
    local _qlock="/run/proxy-manager-quota.lock"
    exec 8>"$_qlock"
    if ! flock -n 8 2>/dev/null; then
        local _pid
        _pid=$(cat "$_qlock" 2>/dev/null || true)
        if [[ "$_pid" =~ ^[0-9]+$ ]] && kill -0 "$_pid" 2>/dev/null; then
            return 0
        fi
        return 0
    fi
    echo $$ >&8
    trap "rm -f '$_qlock'" RETURN

    quota_init
    local cur_month cur_date node_id
    cur_month=$(TZ=Asia/Shanghai date +%Y-%m)
    cur_date=$(TZ=Asia/Shanghai date +%Y-%m-%d)
    node_id=$(get_node_id)

    while IFS='|' read -r port alias quota_bytes expiry _bw; do
        [[ "$port" =~ ^[0-9]+$ ]] || continue

        _quota_commit_port "$port" "$cur_month"
        read -r _m _ii _io acc_in acc_out paused pause_reason \
            < <(_quota_read_data "$port")
        local total
        total=$(( acc_in + acc_out ))

        # ── 新月自动恢复 (quota暂停) ─────────────────────────────────────
        if [[ "$paused" == "1" && "$pause_reason" == "quota" ]]; then
            if [[ "${quota_bytes:-0}" -eq 0 || "$total" -lt "${quota_bytes}" ]]; then
                quota_resume_port "$port"
                _quota_tg_notify "🟢 流量已重置 ${node_id//[a-zA-Z0-9_]/}#${node_id//[^a-zA-Z0-9_]/}
#${alias} 端口 ${port} 新月份流量已重置，自动恢复运行。"
                paused=0; pause_reason="-"
            fi
        fi

        # ── 到期7天自动删除 ──────────────────────────────────────────────
        if [[ "$paused" == "1" && "$pause_reason" == "expiry" && "$expiry" != "-" && -n "$expiry" ]]; then
            local _exp_ts _days_since
            _exp_ts=$(TZ=Asia/Shanghai date -d "$expiry" +%s 2>/dev/null || echo 0)
            _days_since=$(( ( $(date +%s) - _exp_ts ) / 86400 ))
            if (( _days_since >= 7 )); then
                _quota_auto_delete "$port" "$alias"
                continue
            fi
        fi

        [[ "$paused" == "1" ]] && continue  # already paused, skip further checks

        # ── 到期检查 ─────────────────────────────────────────────────────
        if [[ "$expiry" != "-" && -n "$expiry" && "$cur_date" > "$expiry" ]]; then
            quota_pause_port "$port" "expiry"
            _quota_tg_notify "⏰ 端口已到期 ${node_id//[a-zA-Z0-9_]/}#${node_id//[^a-zA-Z0-9_]/}
#${alias} 端口 ${port} 已于 ${expiry} 到期，已自动暂停。"
            continue
        fi
        # 到期前1天提醒（每个到期日只推一次）
        if [[ "$expiry" != "-" && -n "$expiry" ]]; then
            local tomorrow
            tomorrow=$(TZ=Asia/Shanghai date -d "tomorrow" +%Y-%m-%d 2>/dev/null || TZ=Asia/Shanghai date -v+1d +%Y-%m-%d 2>/dev/null || true)
            local _exp_warn_flag="${QUOTA_DIR}/.expwarn_${port}_${expiry}"
            if [[ "$expiry" == "$tomorrow" && ! -f "$_exp_warn_flag" ]]; then
                _quota_tg_notify "🟡 到期预警 ${node_id//[a-zA-Z0-9_]/}#${node_id//[^a-zA-Z0-9_]/}
#${alias} 端口 ${port} 明天 (${expiry}) 到期，请及时处理。"
                touch "$_exp_warn_flag"
            fi
        fi

        # ── 流量超限检查 ─────────────────────────────────────────────────
        if [[ "${quota_bytes:-0}" -gt 0 && "$total" -ge "$quota_bytes" ]]; then
            quota_pause_port "$port" "quota"
            local used_h limit_h
            used_h=$(_qbytes_human "$total")
            limit_h=$(_qbytes_human "$quota_bytes")
            _quota_tg_notify "🚫 流量超限 ${node_id//[a-zA-Z0-9_]/}#${node_id//[^a-zA-Z0-9_]/}
#${alias} 端口 ${port} 流量已达 ${used_h}/${limit_h}，已自动暂停。"
            continue
        fi

        # ── 流量75%预警 ─────────────────────────────────────────────────
        if [[ "${quota_bytes:-0}" -gt 0 ]]; then
            local warn_threshold
            warn_threshold=$(( quota_bytes * 3 / 4 ))
            local warn_flag="${QUOTA_DIR}/.warned_${port}_$(TZ=Asia/Shanghai date +%Y-%m)"
            if [[ "$total" -ge "$warn_threshold" && ! -f "$warn_flag" ]]; then
                local used_h limit_h pct
                pct=$(( total * 100 / quota_bytes ))
                used_h=$(_qbytes_human "$total")
                limit_h=$(_qbytes_human "$quota_bytes")
                _quota_tg_notify "⚠️ 流量预警 ${node_id//[a-zA-Z0-9_]/}#${node_id//[^a-zA-Z0-9_]/}
#${alias} 端口 ${port} 流量已用 ${pct}%（${used_h}/${limit_h}），请注意。"
                touch "$warn_flag"
            fi
        fi

    done < <(grep -v '^[[:space:]]*#' "$QUOTA_CONFIG" 2>/dev/null)
}

# Build a visual progress bar (10 blocks)
_quota_bar() {
    local used="$1" total="$2"
    local pct=0 filled=0
    [[ "${total:-0}" -gt 0 ]] && pct=$(( used * 100 / total )) && \
        filled=$(( pct * 10 / 100 ))
    [[ $filled -gt 10 ]] && filled=10
    local bar="" i
    for (( i=0; i<filled; i++ )); do bar+="█"; done
    for (( i=filled; i<10; i++ )); do bar+="░"; done
    echo "$bar" "$pct"
}

# Daily 21:00 quota report pushed to Telegram
quota_daily_report() {
    [[ ! -f "$QUOTA_CONFIG" ]] && return 0
    quota_init
    local cur_month cur_date node_id
    cur_month=$(TZ=Asia/Shanghai date +%Y-%m)
    cur_date=$(TZ=Asia/Shanghai date +%Y-%m-%d)
    node_id=$(get_node_id)

    local msg="📊 配额日报 ${cur_date} ${node_id//[a-zA-Z0-9_]/}#${node_id//[^a-zA-Z0-9_]/}"$'\n'"━━━━━━━━━━━━━━━━━━"$'\n'
    local has_port=0

    while IFS='|' read -r port alias quota_bytes expiry _bw; do
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        has_port=1

        _quota_commit_port "$port" "$cur_month"
        read -r _m _ii _io acc_in acc_out paused pause_reason \
            < <(_quota_read_data "$port")
        local total
        total=$(( acc_in + acc_out ))

        local icon="🟢"
        [[ "$paused" == "1" ]] && icon="🔴"
        msg+="${icon} #${alias} (端口 ${port})"$'\n'

        if [[ "${quota_bytes:-0}" -gt 0 ]]; then
            read -r bar pct < <(_quota_bar "$total" "$quota_bytes")
            local used_h limit_h remain remain_h
            used_h=$(_qbytes_human "$total")
            limit_h=$(_qbytes_human "$quota_bytes")
            remain=$(( quota_bytes - total ))
            [[ $remain -lt 0 ]] && remain=0
            remain_h=$(_qbytes_human "$remain")
            msg+="  [${bar}] ${pct}%"$'\n'
            msg+="  已用 ${used_h} / 限制 ${limit_h} / 剩余 ${remain_h}"$'\n'
        else
            local used_h
            used_h=$(_qbytes_human "$total")
            msg+="  已用 ${used_h}（无流量限制）"$'\n'
        fi

        if [[ "$expiry" != "-" && -n "$expiry" ]]; then
            local days_left _exp_ts
            _exp_ts=$(TZ=Asia/Shanghai date -d "$expiry" +%s 2>/dev/null || echo 0)
            days_left=$(( ( _exp_ts - $(date +%s) ) / 86400 ))
            if (( days_left < 0 )); then
                msg+="  到期: ${expiry} 🔴 已过期"$'\n'
            else
                msg+="  到期: ${expiry}（剩余 ${days_left} 天）"$'\n'
            fi
        fi

        if [[ "$paused" == "1" ]]; then
            local reason_txt="手动暂停"
            [[ "$pause_reason" == "quota"  ]] && reason_txt="流量超限"
            [[ "$pause_reason" == "expiry" ]] && reason_txt="已到期"
            msg+="  状态: 已暂停（${reason_txt}）"$'\n'
        fi

        msg+="━━━━━━━━━━━━━━━━━━"$'\n'
    done < <(grep -v '^[[:space:]]*#' "$QUOTA_CONFIG" 2>/dev/null)

    [[ $has_port -eq 0 ]] && msg+="（暂无配置端口）"$'\n'

    _quota_tg_notify "$msg"
}

# Write/update a config entry for a port
_quota_write_config() {
    local port="$1" alias="$2" quota_bytes="$3" expiry="$4" bw_kbps="$5"
    local newline="${port}|${alias}|${quota_bytes}|${expiry}|${bw_kbps}"
    local tmpfile
    tmpfile=$(mktemp)
    trap "rm -f '$tmpfile'" RETURN
    grep -v "^${port}|" "$QUOTA_CONFIG" > "$tmpfile" 2>/dev/null || true
    echo "$newline" >> "$tmpfile"
    mv "$tmpfile" "$QUOTA_CONFIG"
}

# Interactive: add or update a port's quota settings
quota_set_port() {
    quota_init
    printf "\n${C_CYAN}=== 添加/修改端口配额 ===${C_RESET}\n\n"

    # ── 自动发现已安装服务的端口 ──────────────────────────────────────
    local -a _disc_ports=() _disc_descs=()
    local _p _desc

    # Snell（多实例，每个配置文件一个节点）
    while IFS= read -r _sf; do
        _p=$(grep -oP 'listen\s*=\s*[^:]+:\K\d+' "$_sf" 2>/dev/null | head -1 || true)
        [[ -n "$_p" ]] && _disc_ports+=("$_p") && _disc_descs+=("Snell          端口 ${_p}")
    done < <(find "$SNELL_CONFIG_DIR" -name "snell-[0-9]*.conf" -type f 2>/dev/null | sort)

    # Shadowsocks-Rust (支持多用户多端口)
    if [[ -f "$SS_CONFIG_FILE" ]]; then
        while IFS= read -r _p; do
            [[ "$_p" =~ ^[0-9]+$ ]] || continue
            local _ss_method
            _ss_method=$(jq -r --argjson p "$_p" \
                '.servers[]? | select(.server_port==$p) | .method // "-"' \
                "$SS_CONFIG_FILE" 2>/dev/null | head -1 || true)
            _disc_ports+=("$_p")
            _disc_descs+=("Shadowsocks    端口 ${_p}  (${_ss_method:-?})")
        done < <(jq -r '.servers[]?.server_port' "$SS_CONFIG_FILE" 2>/dev/null || true)
    fi

    # Realm (从 metadata 取别名，无 metadata 则用 listen→remote)
    if [[ -f "$REALM_CONFIG_FILE" ]]; then
        while IFS= read -r _line; do
            local _listen _remote _lport _ralias
            _listen=$(jq -r '.listen' <<< "$_line" 2>/dev/null || true)
            _remote=$(jq -r '.remote' <<< "$_line" 2>/dev/null || true)
            _lport=$(echo "$_listen" | cut -d: -f2)
            [[ "$_lport" =~ ^[0-9]+$ ]] || continue
            _ralias=""
            [[ -f "$REALM_META_FILE" ]] && \
                _ralias=$(jq -r --arg p "$_lport" '.[$p].alias // empty' \
                    "$REALM_META_FILE" 2>/dev/null || true)
            [[ -z "$_ralias" ]] && _ralias="${_lport} → ${_remote}"
            _disc_ports+=("$_lport")
            _disc_descs+=("Realm          端口 ${_lport}  ${_ralias}")
        done < <(jq -c '.endpoints[]?' "$REALM_CONFIG_FILE" 2>/dev/null || true)
    fi

    # ── 显示选择列表 ───────────────────────────────────────────────────
    local port=""
    if [[ ${#_disc_ports[@]} -gt 0 ]]; then
        printf "${C_BLUE}检测到以下服务端口:${C_RESET}\n"
        local _i
        for _i in "${!_disc_ports[@]}"; do
            local _already=""
            grep -q "^${_disc_ports[$_i]}|" "$QUOTA_CONFIG" 2>/dev/null && \
                _already=" ${C_YELLOW}[已配置]${C_RESET}"
            printf "  ${C_GREEN}%2d.${C_RESET} %s%b\n" \
                "$(( _i + 1 ))" "${_disc_descs[$_i]}" "$_already"
        done
        printf "  ${C_GREEN}%2d.${C_RESET} 手动输入端口号\n" "$(( ${#_disc_ports[@]} + 1 ))"
        printf "\n${C_CYAN}请选择 [1-%d]: ${C_RESET}" "$(( ${#_disc_ports[@]} + 1 ))"
        read -r _sel
        if [[ "$_sel" =~ ^[0-9]+$ ]] && \
           (( _sel >= 1 && _sel <= ${#_disc_ports[@]} )); then
            port="${_disc_ports[$(( _sel - 1 ))]}"
            printf "已选择端口: ${C_CYAN}%s${C_RESET}\n\n" "$port"
        else
            printf "端口号: "; read -r port
        fi
    else
        printf "端口号: "; read -r port
    fi

    [[ ! "$port" =~ ^[0-9]+$ ]] && { msg_error "无效端口号"; return; }

    # Pre-fill existing values if port already configured
    local old_alias="" old_quota="" old_expiry="" old_bw=""
    local existing
    existing=$(grep -m1 "^${port}|" "$QUOTA_CONFIG" 2>/dev/null || true)
    if [[ -n "$existing" ]]; then
        IFS='|' read -r _ old_alias old_quota old_expiry old_bw <<< "$existing"
    fi

    # 自动填入别名（从 Realm metadata 或服务类型）
    if [[ -z "$old_alias" ]]; then
        for _i in "${!_disc_ports[@]}"; do
            if [[ "${_disc_ports[$_i]}" == "$port" ]]; then
                # Extract: "Realm  端口 9003  HK → ..." → "HK → ..."
                # Or:      "Snell  端口 9001"            → "Snell:9001"
                local _raw="${_disc_descs[$_i]}"
                local _after_port
                _after_port=$(echo "$_raw" | sed 's/.*端口 [0-9]\+  *//')
                if [[ -n "$_after_port" && "$_after_port" != "$_raw" ]]; then
                    old_alias="$_after_port"
                else
                    # Snell/SS: no alias after port, use service type
                    old_alias=$(echo "$_raw" | awk '{print $1}')":${port}"
                fi
                break
            fi
        done
    fi

    printf "别名 [${old_alias:-Port${port}}]: "; read -r alias
    [[ -z "$alias" ]] && alias="${old_alias:-Port${port}}"
    alias="${alias//|/ }"   # 过滤管道符，防止破坏 pipe-delimited 配置文件格式

    printf "月流量限制 GB (纯数字=GB，也可加单位如 500MB，0=无限制) [${old_quota:+$(_qbytes_human "$old_quota")}]: "
    read -r quota_input
    local quota_bytes=0
    if [[ -n "$quota_input" ]]; then
        if [[ "$quota_input" == "0" ]]; then
            quota_bytes=0
        elif [[ "$quota_input" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            # 纯数字默认单位 GB
            quota_bytes=$(_qhuman_to_bytes "${quota_input}GB")
        else
            quota_bytes=$(_qhuman_to_bytes "$quota_input")
        fi
    else
        quota_bytes="${old_quota:-0}"
    fi

    printf "到期日期 (YYYY-MM-DD 或 YYYY-M-D，直接回车=无到期) [${old_expiry:--}]: "; read -r expiry
    if [[ -z "$expiry" ]]; then
        expiry="${old_expiry:--}"
    fi
    if [[ "$expiry" != "-" ]]; then
        # 补零：2026-4-3 → 2026-04-03
        expiry=$(awk -F- '{printf "%04d-%02d-%02d", $1, $2, $3}' <<< "$expiry" 2>/dev/null || true)
        if [[ ! "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            msg_error "日期格式错误，示例: 2026-05-31"; return
        fi
    fi

    local bw_kbps="${old_bw:-0}"

    _quota_write_config "$port" "$alias" "$quota_bytes" "$expiry" "$bw_kbps"
    quota_add_counting_rules "$port"

    msg_info "端口 ${port}【${alias}】配额已保存"
    [[ "$quota_bytes" -gt 0 ]] && \
        printf "  月流量限制: %s\n" "$(_qbytes_human "$quota_bytes")"
    [[ "$expiry" != "-" ]] && \
        printf "  到期日期:   %s\n" "$expiry"

    # Auto-install timers on first use
    if ! systemctl is-active --quiet quota-check.timer 2>/dev/null; then
        msg_info "首次配置配额，自动安装定时巡检服务..."
        install_quota_services
    fi
}

# Show configured quota ports as a numbered list; sets $port on selection.
# Returns 1 if no ports configured or user cancels.
_quota_pick_port() {
    local _prompt="${1:-请选择端口}"
    local -a _qports=() _qaliases=()
    local _cur_month
    _cur_month=$(TZ=Asia/Shanghai date +%Y-%m)

    while IFS='|' read -r _p _a _qb _exp _bw; do
        [[ "$_p" =~ ^[0-9]+$ ]] || continue
        _qports+=("$_p")
        # Build status suffix
        local _suf="" _paused
        read -r _m _ii _io _ai _ao _paused _r < <(_quota_read_data "$_p")
        local _total
        _total=$(( _ai + _ao ))
        local _used_h
        _used_h=$(_qbytes_human "$_total")
        if [[ "$_paused" == "1" ]]; then
            _suf=" ${C_RED}[暂停]${C_RESET}"
        fi
        local _limit_str="无限制"
        [[ "${_qb:-0}" -gt 0 ]] && _limit_str="限 $(_qbytes_human "$_qb")"
        local _exp_str=""
        [[ "$_exp" != "-" && -n "$_exp" ]] && _exp_str=" 到期${_exp}"
        _qaliases+=("$(printf "端口 %-6s %-16s 已用 %-10s %s%s" \
            "$_p" "$_a" "$_used_h" "$_limit_str" "$_exp_str")")
    done < <(grep -v '^[[:space:]]*#' "$QUOTA_CONFIG" 2>/dev/null)

    if [[ ${#_qports[@]} -eq 0 ]]; then
        msg_warn "暂无已配置配额的端口"; return 1
    fi

    printf "\n"
    local _i
    for _i in "${!_qports[@]}"; do
        printf "  ${C_GREEN}%2d.${C_RESET} %b%b\n" \
            "$(( _i + 1 ))" "${_qaliases[$_i]}" ""
    done
    printf "\n${C_CYAN}%s [1-%d，0=取消]: ${C_RESET}" "$_prompt" "${#_qports[@]}"
    read -r _sel
    [[ "$_sel" == "0" || -z "$_sel" ]] && return 1
    if [[ "$_sel" =~ ^[0-9]+$ ]] && (( _sel >= 1 && _sel <= ${#_qports[@]} )); then
        port="${_qports[$(( _sel - 1 ))]}"
        return 0
    fi
    msg_error "无效选择"; return 1
}

# 非交互：到期7天自动删除（在 quota_check_all 锁内调用，不重复加锁）
_quota_auto_delete() {
    local port="$1" alias="$2"
    local node_id; node_id=$(get_node_id)

    # ── Snell ──────────────────────────────────────────────────────────
    local snell_conf="${SNELL_CONFIG_DIR}/snell-${port}.conf"
    if [[ -f "$snell_conf" ]]; then
        systemctl stop    "snell@${port}.service" 2>/dev/null || true
        systemctl disable "snell@${port}.service" 2>/dev/null || true
        rm -f "$snell_conf"
        close_firewall_port "$port" 2>/dev/null || true
    fi

    # ── Shadowsocks-Rust ───────────────────────────────────────────────
    if [[ -f "$SS_CONFIG_FILE" ]]; then
        local ss_idx
        ss_idx=$(jq --argjson p "$port" \
            '.servers | to_entries[] | select(.value.server_port == $p) | .key' \
            "$SS_CONFIG_FILE" 2>/dev/null | head -1)
        if [[ -n "$ss_idx" ]]; then
            local tmp_ss
            tmp_ss=$(mktemp)
            if jq --argjson idx "$ss_idx" 'del(.servers[$idx])' "$SS_CONFIG_FILE" > "$tmp_ss"; then
                mv "$tmp_ss" "$SS_CONFIG_FILE"
                chown "${SS_USER}:${SS_USER}" "$SS_CONFIG_FILE" 2>/dev/null || true
                chmod 600 "$SS_CONFIG_FILE" 2>/dev/null || true
                manage_services "restart" "shadowsocks-rust" 2>/dev/null || true
            else
                rm -f "$tmp_ss"
            fi
            close_firewall_port "$port" 2>/dev/null || true
        fi
    fi

    # ── Realm ──────────────────────────────────────────────────────────
    if [[ -f "$REALM_CONFIG_FILE" ]]; then
        local realm_idx
        realm_idx=$(jq --arg p "$port" \
            '.endpoints | to_entries[] | select(.value.listen | endswith(":"+$p)) | .key' \
            "$REALM_CONFIG_FILE" 2>/dev/null | head -1)
        if [[ -n "$realm_idx" ]]; then
            local tmp_realm
            tmp_realm=$(mktemp)
            if jq "del(.endpoints[$realm_idx])" "$REALM_CONFIG_FILE" > "$tmp_realm"; then
                mv "$tmp_realm" "$REALM_CONFIG_FILE"
                chown "${REALM_USER}:${REALM_USER}" "$REALM_CONFIG_FILE" 2>/dev/null || true
            else
                rm -f "$tmp_realm"
            fi
            if [[ -f "$REALM_META_FILE" ]]; then
                local tmp_meta
                tmp_meta=$(mktemp)
                jq --arg p "$port" 'del(.[$p])' "$REALM_META_FILE" > "$tmp_meta" \
                    && mv "$tmp_meta" "$REALM_META_FILE" \
                    || rm -f "$tmp_meta"
            fi
            close_firewall_port "$port" 2>/dev/null || true
            _realm_safe_restart || true
        fi
    fi

    # ── 配额配置和数据 ─────────────────────────────────────────────────
    quota_remove_counting_rules "$port" 2>/dev/null || true
    local t1 t2
    t1=$(mktemp); t2=$(mktemp)
    grep -v "^${port}|" "$QUOTA_CONFIG" > "$t1" 2>/dev/null || true
    mv "$t1" "$QUOTA_CONFIG"
    grep -v "^${port}|" "$QUOTA_DATA"   > "$t2" 2>/dev/null || true
    mv "$t2" "$QUOTA_DATA"
    rm -f "${QUOTA_DIR}/.warned_${port}_"* "${QUOTA_DIR}/.expwarn_${port}_"*

    _quota_tg_notify "🗑️ 端口已删除 ${node_id//[a-zA-Z0-9_]/}#${node_id//[^a-zA-Z0-9_]/}
#${alias} 端口 ${port} 到期超过 7 天未续期，已自动删除。"
    log_message "INFO" "端口 ${port}【${alias}】到期 7 天自动删除"
}

# Interactive: delete a port's quota settings
quota_delete_port() {
    local port
    _quota_pick_port "选择要删除配额的端口" || return 0
    printf "${C_YELLOW}确认删除端口 ${port} 的配额配置？[y/N]: ${C_RESET}"
    read -r _confirm
    [[ "${_confirm,,}" != "y" ]] && { msg_info "已取消"; return; }
    # 获取配额锁，防止与后台 quota-check 定时器并发写 QUOTA_DATA
    # exec 10> 打开进程级 FD，操作完必须 exec 10>&- 关闭，否则锁持续整个脚本会话
    local _qlock="/run/proxy-manager-quota.lock"
    exec 10>"$_qlock"
    flock -w 5 10 2>/dev/null || { exec 10>&-; msg_warn "配额检测正在运行，请稍后重试"; return 1; }
    quota_remove_counting_rules "$port"
    quota_resume_port "$port"
    local tmpfile
    tmpfile=$(mktemp)
    trap "rm -f '$tmpfile'; exec 10>&-" RETURN
    grep -v "^${port}|" "$QUOTA_CONFIG" > "$tmpfile" 2>/dev/null || true
    mv "$tmpfile" "$QUOTA_CONFIG"
    local tmpfile2
    tmpfile2=$(mktemp)
    trap "rm -f '$tmpfile2'; exec 10>&-" RETURN
    grep -v "^${port}|" "$QUOTA_DATA"   > "$tmpfile2" 2>/dev/null || true
    mv "$tmpfile2" "$QUOTA_DATA"
    rm -f "${QUOTA_DIR}/.warned_${port}_"*
    exec 10>&-
    msg_info "端口 ${port} 配额配置已删除"
}

quota_manual_pause() {
    local port
    _quota_pick_port "选择要暂停的端口" || return 0
    local _qlock="/run/proxy-manager-quota.lock"
    exec 10>"$_qlock"
    flock -w 5 10 2>/dev/null || { exec 10>&-; msg_warn "配额检测正在运行，请稍后重试"; return 1; }
    quota_pause_port "$port" "manual"
    exec 10>&-
    msg_info "端口 ${port} 已手动暂停"
}

quota_manual_resume() {
    local port
    _quota_pick_port "选择要恢复的端口" || return 0
    local _qlock="/run/proxy-manager-quota.lock"
    exec 10>"$_qlock"
    flock -w 5 10 2>/dev/null || { exec 10>&-; msg_warn "配额检测正在运行，请稍后重试"; return 1; }
    quota_resume_port "$port"
    exec 10>&-
    msg_info "端口 ${port} 已恢复"
}

# Install/reinstall quota systemd timers
install_quota_services() {
    local script_path
    script_path=$(realpath "$0")
    local _unit_dir="/etc/systemd/system"
    local _tmp
    _tmp=$(mktemp -d)
    trap "rm -rf '$_tmp'" RETURN

    cat > "${_tmp}/quota-check.service" <<EOF
[Unit]
Description=Proxy Quota Check
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash "${script_path}" quota-check
NoNewPrivileges=true
PrivateTmp=true
EOF

    cat > "${_tmp}/quota-check.timer" <<EOF
[Unit]
Description=Proxy Quota Check Timer (every 5 min)

[Timer]
OnBootSec=60
OnUnitActiveSec=300
Persistent=true

[Install]
WantedBy=timers.target
EOF

    cat > "${_tmp}/quota-daily.service" <<EOF
[Unit]
Description=Proxy Quota Daily Report (21:00)

[Service]
Type=oneshot
ExecStart=/bin/bash "${script_path}" quota-daily
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=${WORK_DIR} /var/log/proxy-manager.log
EOF

    cat > "${_tmp}/quota-daily.timer" <<EOF
[Unit]
Description=Proxy Quota Daily Report Timer (21:00)

[Timer]
OnCalendar=*-*-* 21:00:00
RandomizedDelaySec=60
Persistent=true

[Install]
WantedBy=timers.target
EOF

    for _f in quota-check.service quota-check.timer quota-daily.service quota-daily.timer; do
        mv "${_tmp}/${_f}" "${_unit_dir}/${_f}"
    done
    # _tmp will be cleaned by trap RETURN

    systemctl daemon-reload
    systemctl enable quota-check.timer || msg_warn "启用 quota-check.timer 失败"
    systemctl enable quota-daily.timer || msg_warn "启用 quota-daily.timer 失败"
    systemctl start  quota-check.timer || msg_warn "启动 quota-check.timer 失败"
    systemctl start  quota-daily.timer || msg_warn "启动 quota-daily.timer 失败"

    rm -f "${QUOTA_DIR}/.timer_disabled"
    msg_info "配额检测定时器已启动 → quota-check.timer（每5分钟）"
    msg_info "配额日报定时器已启动 → quota-daily.timer（每日 21:00）"
    printf "\n${C_GREEN}安装完成！每5分钟自动检测，21:00 推送日报到 Telegram。${C_RESET}\n"
}

uninstall_quota_services() {
    for unit in quota-check quota-daily; do
        systemctl stop    "${unit}.timer"   2>/dev/null || true
        systemctl disable "${unit}.timer"   2>/dev/null || true
        rm -f "/etc/systemd/system/${unit}.service" \
              "/etc/systemd/system/${unit}.timer"
    done
    systemctl daemon-reload
    touch "${QUOTA_DIR}/.timer_disabled"
    msg_info "配额定时器已卸载"
}

manage_quota_menu() {
    while true; do
        clear
        printf "${C_CYAN}╔══════════════════════════════════════╗${C_RESET}\n"
        printf "${C_CYAN}║       流量配额与到期管理              ║${C_RESET}\n"
        printf "${C_CYAN}╚══════════════════════════════════════╝${C_RESET}\n\n"

        # Show current status table
        quota_init
        local cur_month cur_date
        cur_month=$(TZ=Asia/Shanghai date +%Y-%m)
        cur_date=$(TZ=Asia/Shanghai date +%Y-%m-%d)
        local count=0

        printf " ${C_YELLOW}端口   别名           [───进度───] 占比 已用      /配额        到期             状态${C_RESET}\n"
        printf " \033[2m%s\033[0m\n" "────────────────────────────────────────────────────────────────────────────────────"

        while IFS='|' read -r port alias quota_bytes expiry _bw; do
            [[ "$port" =~ ^[0-9]+$ ]] || continue
            count=$(( count + 1 ))
            _quota_commit_port "$port" "$cur_month"
            read -r _m _ii _io acc_in acc_out paused _r < <(_quota_read_data "$port")
            local total
            total=$(( acc_in + acc_out ))
            local used_h
            used_h=$(_qbytes_human "$total")

            local status_col="${C_GREEN}运行${C_RESET}"
            [[ "$paused" == "1" ]] && status_col="${C_RED}暂停${C_RESET}"

            if [[ "${quota_bytes:-0}" -gt 0 ]]; then
                read -r bar pct < <(_quota_bar "$total" "$quota_bytes")
                local limit_h
                limit_h=$(_qbytes_human "$quota_bytes")
                printf " %-6s %-14s [%s] %3d%% %-10s/%-10s" \
                    "$port" "$alias" "$bar" "$pct" "$used_h" "$limit_h"
            else
                printf " %-6s %-14s %-36s" "$port" "$alias" "已用: ${used_h}（无限制）"
            fi

            if [[ "$expiry" != "-" && -n "$expiry" ]]; then
                local days_left _exp_ts
                _exp_ts=$(TZ=Asia/Shanghai date -d "$expiry" +%s 2>/dev/null || echo 0)
                days_left=$(( ( _exp_ts - $(date +%s) ) / 86400 ))
                printf " 到期%s(%dd)" "$expiry" "$days_left"
            fi
            printf " [%b]\n" "$status_col"
        done < <(grep -v '^[[:space:]]*#' "$QUOTA_CONFIG" 2>/dev/null)

        if [[ $count -eq 0 ]]; then
            printf " ${C_YELLOW}暂无配置端口，请先选择 1 添加${C_RESET}\n"
        fi

        local _timer_st
        if systemctl is-active --quiet quota-check.timer 2>/dev/null; then
            _timer_st="${C_GREEN}运行中${C_RESET}"
        else
            _timer_st="${C_RED}未安装${C_RESET}"
        fi

        printf "\n"
        printf " ${C_GREEN}1.${C_RESET} 添加/修改端口配额设置\n"
        printf " ${C_GREEN}2.${C_RESET} 删除端口配额设置\n"
        printf " ${C_GREEN}3.${C_RESET} 手动暂停端口\n"
        printf " ${C_GREEN}4.${C_RESET} 手动恢复端口\n"
        printf " ${C_GREEN}5.${C_RESET} 立即推送配额日报\n"
        printf " ${C_GREEN}6.${C_RESET} 安装/重装配额定时器  [定时巡检: %b]\n" "$_timer_st"
        printf " ${C_GREEN}7.${C_RESET} 卸载配额定时器\n"
        printf " ${C_GREEN}0.${C_RESET} 返回主菜单\n"
        printf "\n${C_CYAN}请选择 [0-7]: ${C_RESET}"
        read -r q_choice

        printf "\n"
        case $q_choice in
            1) quota_set_port       || true ;;
            2) quota_delete_port    || true ;;
            3) quota_manual_pause   || true ;;
            4) quota_manual_resume  || true ;;
            5) load_config; quota_daily_report || true ;;
            6) install_quota_services  || true ;;
            7) uninstall_quota_services || true ;;
            0) return ;;
            *) msg_warn "无效选项" ;;
        esac
        printf "\n${C_GREEN}按任意键继续...${C_RESET}"; read -rsn1
    done
}

# ==============================================================================
# SOCKS5 代理模块（专供 vps_monitor 使用）
# ==============================================================================

_socks5_write_config() {
    local port="$1"
    local ext_if
    ext_if=$(ip route | awk '/^default/ {print $5; exit}')
    [[ -z "$ext_if" ]] && ext_if="eth0"

    # 读取已保存的白名单
    local whitelist=()
    if [[ -f "$SOCKS5_META_FILE" ]]; then
        local wl_line
        wl_line=$(grep "^SOCKS5_WHITELIST=" "$SOCKS5_META_FILE" | cut -d= -f2-)
        IFS=' ' read -r -a whitelist <<< "$wl_line"
    fi

    mkdir -p "$SOCKS5_CONFIG_DIR"
    {
        echo "logoutput: $SOCKS5_LOG_FILE"
        echo "internal: 0.0.0.0 port = $port"
        echo "external: $ext_if"
        echo ""
        echo "clientmethod: none"
        echo "socksmethod: username"
        echo ""
        if [[ ${#whitelist[@]} -gt 0 ]]; then
            for ip in "${whitelist[@]}"; do
                [[ "$ip" != */* ]] && ip="${ip}/32"
                printf "client pass {\n    from: %s to: 0.0.0.0/0\n}\n" "$ip"
            done
        fi
        echo "client block {"
        echo "    from: 0.0.0.0/0 to: 0.0.0.0/0"
        echo "    log: connect"
        echo "}"
        echo ""
        echo "socks pass {"
        echo "    from: 0.0.0.0/0 to: 0.0.0.0/0"
        echo "    socksmethod: username"
        echo "}"
    } > "$SOCKS5_CONFIG_FILE"
    chmod 600 "$SOCKS5_CONFIG_FILE"
}

install_socks5_proxy() {
    if [[ -f "$SOCKS5_CONFIG_FILE" ]]; then
        msg_warn "SOCKS5代理已安装，请重新进入选项 4 进行管理。"
        return
    fi

    msg_step "安装 Dante SOCKS5 服务器..."
    if ! command -v danted &>/dev/null; then
        local _arch; _arch=$(dpkg --print-architecture)
        local _deb_url="http://ftp.debian.org/debian/pool/main/d/dante/dante-server_1.4.2+dfsg-7+b8_${_arch}.deb"
        local _deb_tmp; _deb_tmp=$(mktemp /tmp/dante-server-XXXXXX.deb)
        if curl -fsSL "$_deb_url" -o "$_deb_tmp" && dpkg -i "$_deb_tmp" >/dev/null 2>&1; then
            rm -f "$_deb_tmp"
            msg_success "dante-server 安装成功"
        else
            rm -f "$_deb_tmp"
            msg_error "dante-server 安装失败，请检查网络"; return 1
        fi
    fi

    if ! command -v danted &>/dev/null; then
        msg_error "danted 安装后未找到可执行文件，请检查"; return 1
    fi

    msg_step "选择 SOCKS5 代理端口..."
    local port
    port=$(get_port_interactive)

    msg_step "生成随机密码..."
    local password
    password=$(openssl rand -base64 18 | tr -d '=/+' | head -c 18)

    msg_step "创建系统用户 ${SOCKS5_USER}..."
    if ! id "$SOCKS5_USER" &>/dev/null; then
        useradd -r -s /usr/sbin/nologin -M -d /nonexistent "$SOCKS5_USER"
    fi
    echo "${SOCKS5_USER}:${password}" | chpasswd

    msg_step "配置IP白名单（每行一个IP，空行结束）..."
    printf "  格式: 单IP填 1.2.3.4，网段填 1.2.3.0/24\n"
    printf "  %b直接回车跳过则拒绝所有未授权IP%b\n\n" "${C_YELLOW}" "${C_RESET}"
    local whitelist=()
    local _first=1
    while true; do
        if [[ $_first -eq 1 ]]; then
            read -r -p "  添加受信任IP: " ip
            _first=0
        else
            read -r -p "  继续添加 (回车结束): " ip
        fi
        [[ -z "$ip" ]] && break
        # Validate: must be IPv4 or CIDR (digits, dots, optional /prefix)
        if [[ ! "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(/([0-9]|[12][0-9]|3[0-2]))?$ ]] \
           || (( BASH_REMATCH[1]>255 || BASH_REMATCH[2]>255 || BASH_REMATCH[3]>255 || BASH_REMATCH[4]>255 )); then
            printf "  %b✗ 格式无效，请输入 IP（如 1.2.3.4）或网段（如 1.2.3.0/24）%b\n" "${C_RED}" "${C_RESET}"
            continue
        fi
        whitelist+=("$ip")
        printf "  %b✓ 已添加: %s%b\n" "${C_GREEN}" "$ip" "${C_RESET}"
    done

    # 写入元数据
    mkdir -p "$SOCKS5_CONFIG_DIR"
    {
        echo "SOCKS5_PORT=$port"
        echo "SOCKS5_PASSWORD=$password"
        printf "SOCKS5_WHITELIST=%s\n" "${whitelist[*]}"
    } > "$SOCKS5_META_FILE"
    chmod 600 "$SOCKS5_META_FILE"

    # 写入 Dante 配置
    _socks5_write_config "$port"

    # 停止 apt 自带的 danted.service（如有）
    systemctl stop danted.service 2>/dev/null || true
    systemctl disable danted.service 2>/dev/null || true

    # 写入专属 systemd 服务
    cat > "$SOCKS5_SERVICE_FILE" <<EOF
[Unit]
Description=SOCKS5 Proxy for VPS Monitor (Dante)
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/danted -f ${SOCKS5_CONFIG_FILE}
Restart=on-failure
RestartSec=5
LimitNOFILE=51200
NoNewPrivileges=yes
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable socks5-monitor.service
    systemctl restart socks5-monitor.service

    open_firewall_port "$port"

    printf "\n"
    msg_success "SOCKS5 代理安装完成！"
    printf '%b\n' "${C_PURPLE}================================================${C_RESET}"
    printf "  地址   : %s\n"  "$SERVER_IP"
    printf "  端口   : %s\n"  "$port"
    printf "  用户名 : %s\n"  "$SOCKS5_USER"
    printf "  密码   : %b%s%b\n" "${C_YELLOW}" "$password" "${C_RESET}"
    printf "  白名单 : %s\n"  "${whitelist[*]:-（未设置，所有连接均被拒绝）}"
    printf '%b\n' "${C_PURPLE}================================================${C_RESET}"
    printf "\n  vps_monitor 填写格式:\n"
    printf "  %bsocks5://%s:%s@%s:%s%b\n\n" \
        "${C_GREEN}" "$SOCKS5_USER" "$password" "$SERVER_IP" "$port" "${C_RESET}"
}

_socks5_reload() {
    local port
    port=$(grep "^SOCKS5_PORT=" "$SOCKS5_META_FILE" | cut -d= -f2-)
    _socks5_write_config "$port"
    systemctl restart socks5-monitor.service 2>/dev/null && \
        msg_success "配置已更新，服务已重启。" || msg_error "服务重启失败，请检查日志。"
}

_socks5_add_ip() {
    read -r -p "  请输入要添加的IP (如 1.2.3.4 或 1.2.3.0/24): " ip
    [[ -z "$ip" ]] && return
    local wl_line
    wl_line=$(grep "^SOCKS5_WHITELIST=" "$SOCKS5_META_FILE" | cut -d= -f2-)
    # 检查重复
    if echo "$wl_line" | grep -qw "$ip"; then
        msg_warn "$ip 已在白名单中"; return
    fi
    local new_wl="${wl_line:+$wl_line }$ip"
    sed -i "s|^SOCKS5_WHITELIST=.*|SOCKS5_WHITELIST=${new_wl}|" "$SOCKS5_META_FILE"
    _socks5_reload
    msg_success "已添加: $ip"
}

_socks5_remove_ip() {
    local wl_line
    wl_line=$(grep "^SOCKS5_WHITELIST=" "$SOCKS5_META_FILE" | cut -d= -f2-)
    local -a wl
    IFS=' ' read -r -a wl <<< "$wl_line"
    if [[ ${#wl[@]} -eq 0 ]]; then
        msg_warn "白名单为空"; return
    fi
    printf "\n  当前白名单:\n"
    local i
    for i in "${!wl[@]}"; do
        printf "  ${C_GREEN}%d.${C_RESET} %s\n" "$((i+1))" "${wl[$i]}"
    done
    printf "\n"
    read -r -p "  请输入要删除的编号: " idx
    if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#wl[@]} )); then
        unset 'wl[idx-1]'
        local new_wl="${wl[*]}"
        sed -i "s|^SOCKS5_WHITELIST=.*|SOCKS5_WHITELIST=${new_wl}|" "$SOCKS5_META_FILE"
        _socks5_reload
    else
        msg_error "无效编号"
    fi
}

_socks5_regen_password() {
    local new_pass
    new_pass=$(openssl rand -base64 18 | tr -d '=/+' | head -c 18)
    echo "${SOCKS5_USER}:${new_pass}" | chpasswd
    sed -i "s|^SOCKS5_PASSWORD=.*|SOCKS5_PASSWORD=${new_pass}|" "$SOCKS5_META_FILE"
    local port
    port=$(grep "^SOCKS5_PORT=" "$SOCKS5_META_FILE" | cut -d= -f2-)
    msg_success "密码已更新: ${C_YELLOW}${new_pass}${C_RESET}"
    printf "\n  新的代理地址:\n"
    printf "  %bsocks5://%s:%s@%s:%s%b\n\n" \
        "${C_GREEN}" "$SOCKS5_USER" "$new_pass" "$SERVER_IP" "$port" "${C_RESET}"
}

_socks5_uninstall() {
    read -r -p "  确认卸载 SOCKS5 代理? [y/N]: " confirm
    [[ "${confirm,,}" != "y" ]] && return
    systemctl stop    socks5-monitor.service 2>/dev/null || true
    systemctl disable socks5-monitor.service 2>/dev/null || true
    rm -f "$SOCKS5_SERVICE_FILE"
    systemctl daemon-reload
    if id "$SOCKS5_USER" &>/dev/null; then
        userdel "$SOCKS5_USER" 2>/dev/null || true
    fi
    rm -rf "$SOCKS5_CONFIG_DIR"
    msg_success "SOCKS5 代理已卸载。"
}

manage_socks5_menu() {
    if [[ ! -f "$SOCKS5_META_FILE" ]]; then
        msg_warn "SOCKS5代理尚未安装，请先选择选项 4 安装。"
        return
    fi
    while true; do
        clear
        local port password whitelist
        port=$(grep     "^SOCKS5_PORT="      "$SOCKS5_META_FILE" | cut -d= -f2-)
        password=$(grep "^SOCKS5_PASSWORD="  "$SOCKS5_META_FILE" | cut -d= -f2-)
        whitelist=$(grep "^SOCKS5_WHITELIST=" "$SOCKS5_META_FILE" | cut -d= -f2-)

        local svc_status
        if systemctl is-active --quiet socks5-monitor.service 2>/dev/null; then
            svc_status="${C_GREEN}运行中${C_RESET}"
        else
            svc_status="${C_RED}未运行${C_RESET}"
        fi

        printf '%b\n' "${C_PURPLE}================================================${C_RESET}"
        printf '%b\n' "${C_CYAN}      SOCKS5 代理管理 (专供 vps_monitor)${C_RESET}"
        printf '%b\n' "${C_PURPLE}================================================${C_RESET}"
        printf "${C_BLUE}:: 当前配置 ::%b\n" "${C_RESET}"
        printf "   服务状态 : %b\n"   "$svc_status"
        printf "   端口     : %s\n"   "$port"
        printf "   用户名   : %s\n"   "$SOCKS5_USER"
        printf "   密码     : %b%s%b\n" "${C_YELLOW}" "$password" "${C_RESET}"
        printf "   白名单   : %s\n"   "${whitelist:-（空，所有连接被拒绝）}"
        printf "\n   %b填入 vps_monitor 代理池:%b\n" "${C_DIM}" "${C_RESET}"
        printf "   %bsocks5://%s:%s@%s:%s%b\n" \
            "${C_GREEN}" "$SOCKS5_USER" "$password" "$SERVER_IP" "$port" "${C_RESET}"
        printf "\n"
        printf '%b\n' "${C_PURPLE}------------------------------------------------${C_RESET}"
        printf " ${C_GREEN}1.${C_RESET} 添加白名单IP\n"
        printf " ${C_GREEN}2.${C_RESET} 删除白名单IP\n"
        printf " ${C_GREEN}3.${C_RESET} 重新生成密码\n"
        printf " ${C_GREEN}4.${C_RESET} 重启服务\n"
        printf " ${C_GREEN}5.${C_RESET} 卸载 SOCKS5 代理\n"
        printf " ${C_GREEN}0.${C_RESET} 返回主菜单\n\n"
        read -r -p "  请选择 [0-5]: " sub
        printf "\n"
        case "$sub" in
            1) _socks5_add_ip ;;
            2) _socks5_remove_ip ;;
            3) _socks5_regen_password ;;
            4) systemctl restart socks5-monitor.service && msg_success "服务已重启" || msg_error "重启失败" ;;
            5) _socks5_uninstall; return ;;
            0) return ;;
            *) continue ;;
        esac
        printf "\n${C_GREEN}按任意键继续...${C_RESET}"; read -rsn1
    done
}



# ==============================================================================
# SECTION 8: 统一主菜单 + 主循环
# ==============================================================================

show_menu() {
    local flag
    flag=$(get_flag_emoji "$SERVER_COUNTRY_CODE")
    local node_name="${SERVER_CITY}-${SERVER_COUNTRY_CODE}"
    local _CFG_SEP="${C_PURPLE}----------------------------------------------------------------${C_RESET}"

    clear
    printf '%b\n' "${C_PURPLE}================================================================${C_RESET}"
    printf '%b\n' "${C_CYAN}    Server & Proxy Manager  ${C_BLUE}&${C_CYAN} Deploy Tool  ${C_YELLOW}v${SCRIPT_VERSION}${C_RESET}"
    printf '%b\n' "${C_PURPLE}================================================================${C_RESET}"

    local _srv_name=""
    [[ -f "${TG_CONF:-}" ]] && _srv_name=$(grep -E '^SERVER_NAME=' "$TG_CONF" 2>/dev/null | head -1 | cut -d= -f2- | sed "s/^['\"]//;s/['\"]$//" || true)
    printf "${C_BLUE}:: 服务器信息 ::${C_RESET}\n"
    if [[ -n "$_srv_name" ]]; then
        printf "   服务器: %s%s\n" "$flag" "$_srv_name"
    else
        printf "   服务器: %s %s, %s\n" "$flag" "$SERVER_COUNTRY_NAME" "$SERVER_CITY"
    fi
    printf "   IP    : %s\n" "$SERVER_IP"
    printf "${C_BLUE}:: 服务状态 ::${C_RESET}\n"
    # ---------- 版本信息与升级提示 ----------
    local snell_status snell_ver snell_new ss_status ss_ver ss_new realm_status realm_ver realm_new
    snell_status=$(check_service_status snell "$SNELL_BIN")
    ss_status=$(check_service_status shadowsocks-rust "$SS_BIN")
    realm_status=$(check_service_status realm "$REALM_BIN")

    # 版本号 (仅已安装时读取)
    if [[ -f "$SNELL_BIN" ]]; then
        snell_ver=$(get_installed_version snell "$SNELL_BIN")
        snell_new=$(get_cached_latest_version snell)
    else
        snell_ver="-"; snell_new=""
    fi
    if [[ -f "$SS_BIN" ]]; then
        ss_ver=$(get_installed_version shadowsocks-rust "$SS_BIN")
        ss_new=$(get_cached_latest_version shadowsocks-rust)
    else
        ss_ver="-"; ss_new=""
    fi
    if [[ -f "$REALM_BIN" ]]; then
        realm_ver=$(get_installed_version realm "$REALM_BIN")
        realm_new=$(get_cached_latest_version realm)
    else
        realm_ver="-"; realm_new=""
    fi

    # 输出行 (含版本号与可选升级提示)
    local snell_ver_str ss_ver_str realm_ver_str
    if [[ -n "$snell_new" && "$snell_new" != "$snell_ver" ]]; then
        snell_ver_str="${C_YELLOW}${snell_ver}${C_RESET} ${C_RED}→ 可升级 ${snell_new}${C_RESET}"
    else
        snell_ver_str="${C_CYAN}${snell_ver}${C_RESET}"
    fi
    if [[ -n "$ss_new" && "$ss_new" != "$ss_ver" ]]; then
        ss_ver_str="${C_YELLOW}${ss_ver}${C_RESET} ${C_RED}→ 可升级 ${ss_new}${C_RESET}"
    else
        ss_ver_str="${C_CYAN}${ss_ver}${C_RESET}"
    fi
    if [[ -n "$realm_new" && "$realm_new" != "$realm_ver" ]]; then
        realm_ver_str="${C_YELLOW}${realm_ver}${C_RESET} ${C_RED}→ 可升级 ${realm_new}${C_RESET}"
    else
        realm_ver_str="${C_CYAN}${realm_ver}${C_RESET}"
    fi

    # 中转监控状态
    local monitor_status monitor_info
    if systemctl is-active --quiet relay-monitor.service 2>/dev/null; then
        monitor_status="${C_GREEN}运行中${C_RESET}"
        local _rule_cnt=0
        if [[ -f "$REALM_CONFIG_FILE" ]]; then
            _rule_cnt=$(jq '.endpoints | length' "$REALM_CONFIG_FILE" 2>/dev/null || echo 0)
        fi
        local _last=""
        local _dat
        _dat=$(get_data_file)
        if [[ -f "$_dat" ]]; then
            local _ts=0
            if [[ -s "$_dat" ]]; then
                _ts=$(tail -1 "$_dat" 2>/dev/null | cut -f1)
                [[ "$_ts" =~ ^[0-9]+$ ]] || _ts=0
            fi
            if [[ "$_ts" -gt 0 ]]; then
                local _age
                _age=$(( $(date +%s) - ${_ts:-0} )) || _age=0
                if [[ $_age -lt 60 ]]; then
                    _last="  上次: ${_age}s前"
                else
                    _last="  上次: $(( _age / 60 ))m前"
                fi
            fi
        fi
        monitor_info="${C_CYAN}监控 ${_rule_cnt} 条规则${C_RESET}${_last}"
    elif [[ -f "$MONITOR_CONFIG" ]]; then
        monitor_status="${C_RED}未运行${C_RESET}"
        monitor_info="${C_YELLOW}已配置，服务未启动${C_RESET}"
    else
        monitor_status="${C_RED}未配置${C_RESET}"
        monitor_info="-"
    fi

    # Fail2Ban
    if systemctl is-active --quiet fail2ban 2>/dev/null && [[ -f /etc/fail2ban/jail.d/sshd.conf ]]; then
        local _fb_banned; _fb_banned=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | awk '{print $NF}' || echo "?")
        printf "   Fail2Ban         : %b  [%b]\n" "${C_GREEN}运行中${C_RESET}" "${C_CYAN}封禁 ${_fb_banned}${C_RESET}"
    else
        printf "   Fail2Ban         : [-]\n"
    fi
    # TG 推送
    if [[ -f "$TG_CONF" ]] && grep -q "^TG_BOT_TOKEN=" "$TG_CONF" 2>/dev/null; then
        local _tg_srv; _tg_srv=$(grep "^SERVER_NAME=" "$TG_CONF" 2>/dev/null | cut -d= -f2- | sed 's/^"//;s/"$//' || true)
        printf "   TG 推送          : %b  [%b]\n" "${C_GREEN}已配置${C_RESET}" "${C_CYAN}${_tg_srv:-主频道}${C_RESET}"
    else
        printf "   TG 推送          : [-]\n"
    fi
    # TCPing Monitor
    if systemctl is-active --quiet "$TCPING_SERVICE_NAME" 2>/dev/null; then
        local _tp_port; _tp_port=$(grep "^PORT=" "$TCPING_CONFIG_FILE" 2>/dev/null | cut -d= -f2 || echo "?")
        printf "   TCPing Monitor   : %b  [%b]\n" "${C_GREEN}运行中${C_RESET}" "${C_CYAN}${SERVER_IP}:${_tp_port}${C_RESET}"
    else
        printf "   TCPing Monitor   : [-]\n"
    fi
    # 代理服务
    if [[ -f "$SNELL_BIN" ]]; then
        printf "   Snell            : %b  [%b]\n" "$snell_status" "$snell_ver_str"
    else
        printf "   Snell            : [-]\n"
    fi
    if [[ -f "$SS_BIN" ]]; then
        printf "   Shadowsocks-Rust : %b  [%b]\n" "$ss_status" "$ss_ver_str"
    else
        printf "   Shadowsocks-Rust : [-]\n"
    fi
    if [[ -f "$REALM_BIN" ]]; then
        printf "   Realm Forwarding : %b  [%b]\n" "$realm_status" "$realm_ver_str"
    else
        printf "   Realm Forwarding : [-]\n"
    fi
    if [[ -f "$SOCKS5_META_FILE" ]]; then
        local _s5_status _s5_ver _s5_ver_str
        if systemctl is-active --quiet socks5-monitor.service 2>/dev/null; then
            _s5_status="${C_GREEN}运行中${C_RESET}"
        else
            _s5_status="${C_RED}未运行${C_RESET}"
        fi
        _s5_ver=$(get_installed_version socks5 "")
        _s5_ver_str="${C_CYAN}${_s5_ver}${C_RESET}"
        printf "   SOCKS5 Proxy     : %b  [%b]\n" "$_s5_status" "$_s5_ver_str"
    else
        printf "   SOCKS5 Proxy     : [-]\n"
    fi
    if systemctl is-active --quiet relay-monitor.service 2>/dev/null; then
        printf "   Relay Monitor    : %b  [%b]\n" "$monitor_status" "$monitor_info"
    else
        printf "   Relay Monitor    : [-]\n"
    fi

    # ---------- 防火墙状态 ----------
    printf "${C_BLUE}:: 防火墙 & 内核 ::${C_RESET}\n"
    if ! command -v iptables &>/dev/null; then
        printf "   ${C_RED}iptables 未安装${C_RESET}\n"
    else
        local _fw_policy _fw_rules _fw_svc _fw_cn_block _fw_acl ir policy
        local _ipt_l_out
        _ipt_l_out=$(iptables -L INPUT -n 2>/dev/null || echo "")
        ir=$(iptables -S INPUT 2>/dev/null || echo "")
        _fw_policy=$(echo "$_ipt_l_out" | head -1 | awk '{print $4}' | tr -d '()' || echo "N/A")
        policy="$_fw_policy"
        [[ -n "$_fw_policy" ]] || { _fw_policy="N/A"; policy="N/A"; }
        _fw_rules=$(echo "$ir" | grep -c '^-A' || true)
        # 服务状态：有规则或模块已加载即视为运行
        if lsmod 2>/dev/null | grep -q ip_tables || [[ "$_fw_rules" -gt 0 ]]; then
            _fw_svc="${C_GREEN}RUNNING${C_RESET}"
        else
            _fw_svc="${C_RED}STOPPED${C_RESET}"
        fi
        # 策略颜色：DROP=绿（安全），ACCEPT=红（全开放）
        local _policy_color="${C_GREEN}"
        [[ "$_fw_policy" != "DROP" ]] && _policy_color="${C_RED}"
        # CN 封禁状态
        if iptables-save 2>/dev/null | grep -q "match-set ss_cn_block src"; then
            _fw_cn_block="${C_GREEN}CN封禁:开${C_RESET}"
        else
            _fw_cn_block="${C_YELLOW}CN封禁:关${C_RESET}"
        fi
        # ACL 状态
        if [[ -f "$SS_CONFIG_FILE" ]] && jq -e '.acl' "$SS_CONFIG_FILE" >/dev/null 2>&1; then
            _fw_acl="${C_GREEN}域名封禁:开${C_RESET}"
        else
            _fw_acl="${C_YELLOW}域名封禁:关${C_RESET}"
        fi
        printf "   %b防火墙%b %b   %b策略%b %b%s%b   %b规则%b %b%s条%b   %b  %b\n" \
            "${C_BLUE}" "${C_RESET}" "$_fw_svc" \
            "${C_BLUE}" "${C_RESET}" "$_policy_color" "$_fw_policy" "${C_RESET}" \
            "${C_BLUE}" "${C_RESET}" "${C_GREEN}" "$_fw_rules" "${C_RESET}" \
            "$_fw_cn_block" "$_fw_acl"
        # BBR / 内核
        local _kver _bv _bbr_label _kcolor
        _kver=$(uname -r)
        _bv=$(_get_bbr_version)
        if [[ "$_bv" == "v3" ]]; then
            uname -r | grep -qi "xanmod" && _kcolor="${C_GREEN}" || _kcolor="${C_WHITE}"
            _bbr_label="${_kcolor}BBR v3${C_RESET}"
        elif [[ "$_bv" == "v1" ]]; then
            _kcolor="${C_YELLOW}"
            _bbr_label="${C_YELLOW}BBR v1${C_RESET}"
        else
            _kcolor="${C_RED}"
            _bbr_label="${C_RED}无BBR${C_RESET}"
        fi
        printf "   %b内  核%b  %b%s%b   %b\n" "${C_BLUE}" "${C_RESET}" "$_kcolor" "$_kver" "${C_RESET}" "$_bbr_label"
        # 端口状态 (SSH/HTTP/HTTPS + 其他开放端口)
        local _ssh_port
        _ssh_port=$(get_current_ssh_port 2>/dev/null || echo "22")
        printf "   %b端  口%b" "${C_BLUE}" "${C_RESET}"
        _port_dot "$_ssh_port" "SSH"
        _port_dot "80"  "HTTP"
        _port_dot "443" "HTTPS"
        printf "\n"
        if [[ "$policy" != "ACCEPT" ]]; then
            local _raw_ports _display_ports=()
            _raw_ports=$(echo "$ir" | grep -E '^-A INPUT.*-j ACCEPT' | grep -oE -- '--dport [0-9]+' | awk '{print $2}' | sort -nu || true)
            for _p in $_raw_ports; do
                [[ "$_p" == "$_ssh_port" || "$_p" == "80" || "$_p" == "443" ]] && continue
                _display_ports+=("$_p")
            done
            if [[ ${#_display_ports[@]} -gt 0 ]]; then
                printf "          "
                local _col=0
                for _p in "${_display_ports[@]}"; do
                    local _ht=0 _hu=0 _pa=""
                    echo "$ir" | grep -q -- "-p tcp.*--dport $_p.*-j ACCEPT" && _ht=1
                    echo "$ir" | grep -q -- "-p udp.*--dport $_p.*-j ACCEPT" && _hu=1
                    [[ $_ht -eq 1 && $_hu -eq 1 ]] && _pa="${C_CYAN}t${C_RESET}${C_WHITE}/${C_RESET}${C_PURPLE}u${C_RESET}"
                    [[ $_ht -eq 1 && $_hu -eq 0 ]] && _pa="${C_CYAN}t${C_RESET}"
                    [[ $_ht -eq 0 && $_hu -eq 1 ]] && _pa="${C_PURPLE}u${C_RESET}"
                    [[ -n "$_pa" ]] && printf "${C_GREEN}%s${C_WHITE}(${C_RESET}%b${C_WHITE})${C_RESET}  " "$_p" "$_pa"
                    _col=$(( _col + 1 ))
                    if [[ $(( _col % 4 )) -eq 0 && $_col -lt ${#_display_ports[@]} ]]; then
                        printf "\n          "
                    fi
                done
                printf "\n"
            fi
        else
            printf "          %b全端口开放 (ACCEPT策略)%b\n" "${C_GREEN}" "${C_RESET}"
        fi
    fi
    
    local connection_stats
    connection_stats=$(get_connection_stats)
    local total_conns=${connection_stats%%:*}
    local conn_details=${connection_stats#*:}
    
    if [[ $total_conns -gt 0 ]]; then
        printf "   ${C_GREEN}活跃连接: %d${C_RESET}\n" "$total_conns"
        if [[ -n "$conn_details" ]]; then
            printf "   ${C_YELLOW}详情: %s${C_RESET}\n" "$conn_details"
        fi
    else
        printf "   ${C_RED}活跃连接: 0${C_RESET}\n"
    fi
    # 测试模式 iperf3 命令提示
    if echo "${_ipt_l_out:-}" | grep -q "test-mode-iperf" 2>/dev/null; then
        local _my_ip_m _close_hint=""
        _my_ip_m=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || true)
        local _jf="/var/run/iptables-iperf-mode.job"
        if [[ -f "$_jf" ]]; then
            local _jid _jtime
            _jid=$(cat "$_jf" 2>/dev/null || true)
            _jtime=$(atq 2>/dev/null | grep "^${_jid}[[:space:]]" | awk '{print $3,$4,$5}' || true)
            [[ -n "$_jtime" ]] && _close_hint="  ${C_YELLOW}(自动关闭: ${_jtime})${C_RESET}"
        fi
        printf "   ${C_CYAN}本机:${C_RESET} iperf3 -s%b\n" "$_close_hint"
        [[ -n "$_my_ip_m" ]] && printf "   ${C_CYAN}对端:${C_RESET} iperf3 -c %s -P 1 -t 20 -R\n" "$_my_ip_m"
    fi

    if find "$SNELL_CONFIG_DIR" -name "snell-[0-9]*.conf" -type f -print -quit 2>/dev/null | grep -q .; then
        local short_suffix
        short_suffix="_$(echo "$SERVER_IP" | cut -d. -f4)"
        local _node_idx=0
        while IFS=' ' read -r s_port s_psk; do
            [[ -z "$s_port" || -z "$s_psk" ]] && continue
            if [[ $_node_idx -eq 0 ]]; then
                printf "${C_PURPLE}================================================================${C_RESET}\n"
                printf "${C_BLUE}:: Snell 配置 ::${C_RESET}\n"
            fi
            _node_idx=$((_node_idx + 1))
            local _sfx="${short_suffix}"
            [[ $_node_idx -gt 1 ]] && _sfx="${short_suffix}-${_node_idx}"
            printf "${C_GREEN}%s%s = snell, %s, %s, psk=\"%s\", version=5, reuse=true, tfo=true${C_RESET}\n" \
                "$flag" "$_sfx" "$SERVER_IP" "$s_port" "$s_psk"
        done < <(parse_snell_nodes)
    fi

    if [[ -f "$SS_CONFIG_FILE" ]] && validate_ss_config "$SS_CONFIG_FILE"; then
        printf "%b\n" "$_CFG_SEP"
        printf "${C_BLUE}:: Shadowsocks 配置 ::${C_RESET}\n"
        jq -r '.servers[]? | select(.server_port and .password and .method) | "   \(.server_port) \(.password) \(.method)"' "$SS_CONFIG_FILE" | \
        while read -r port password method; do
            printf "${C_GREEN}%s %s-ss-%s = ss, %s, %s, encrypt-method=%s, password=\"%s\", tfo=true, udp-relay=true${C_RESET}\n" "$flag" "$node_name" "$port" "$SERVER_IP" "$port" "$method" "$password"
        done
    fi

    if [[ -f "$REALM_CONFIG_FILE" ]] && validate_realm_config "$REALM_CONFIG_FILE"; then
         if jq -e '.endpoints | length > 0' "$REALM_CONFIG_FILE" >/dev/null; then
            printf "%b\n" "$_CFG_SEP"
            printf "${C_BLUE}:: Realm 转发配置 (Smart) ::${C_RESET}\n"
            # 读取所有 listen 端口
            jq -r '.endpoints[] | "\(.listen) \(.remote)"' "$REALM_CONFIG_FILE" | while read -r listen remote; do
                local l_port
                l_port=$(echo "$listen" | cut -d: -f2)
                local r_addr="$remote"
                local psk=""
                local alias=""
                local country_code=""
                
                # 尝试从 metadata 读取 PSK
                if [[ -f "$REALM_META_FILE" ]]; then
                    psk=$(jq -r --arg p "$l_port" '.[$p].psk // empty' "$REALM_META_FILE")
                    alias=$(jq -r --arg p "$l_port" '.[$p].alias // empty' "$REALM_META_FILE")
                    country_code=$(jq -r --arg p "$l_port" '.[$p].country_code // empty' "$REALM_META_FILE")
                fi
                
                # 确定显示的国旗 (优先使用目标落地机的国旗)
                local display_flag=""
                if [[ -n "$country_code" ]]; then
                    display_flag=$(get_flag_emoji "$country_code")
                else
                    # 如果元数据里没有目标国别，尝试用别名里的信息猜一下? 
                    # 算了，猜不准，回退到地球仪或者不显示，别显示本地旗帜误导
                    display_flag="🌐"
                fi

                if [[ -n "$psk" ]]; then
                    # 显示为 Snell 配置格式
                    local final_name
                    local r_ip
                    r_ip=$(echo "$r_addr" | cut -d: -f1)

                    # 对于Realm链式转发，直接显示存储的完整递归别名，不再做任何画蛇添足的处理
                    final_name="${alias}"
                    
                    # 如果别名为空 (极少数情况)，兜底显示
                    if [[ -z "$final_name" ]]; then
                         final_name="Relay-${SERVER_COUNTRY_CODE}->[${r_ip}]"
                    fi
                    
                    
                    
                    # 在菜单显示时，不再强制加国旗前缀(应包含在 final_name 里了)，但为了对齐好看，如果是新格式则不加
                    # 如果 name 已经包含 emoji (判断 ->), 则 display_flag 置空，否则保留
                    if [[ "$final_name" == *"->"* ]] || [[ "$final_name" == *" → "* ]]; then
                         display_flag="" 
                    fi

                    printf "${C_GREEN}%s%s = snell, %s, %s, psk=\"%s\", version=5, reuse=true, tfo=true${C_RESET}\n" \
                        "$display_flag" "$final_name" "$SERVER_IP" "$l_port" "$psk"
                else
                    # 无元数据，显示普通转发信息
                    printf "${C_YELLOW}Port %s -> %s${C_RESET}\n" "$l_port" "$r_addr"
                fi
            done
         fi
    fi

    if [[ -f "$SOCKS5_META_FILE" ]]; then
        local _cs5_port _cs5_pass
        _cs5_port=$(grep "^SOCKS5_PORT="     "$SOCKS5_META_FILE" | cut -d= -f2-)
        _cs5_pass=$(grep "^SOCKS5_PASSWORD=" "$SOCKS5_META_FILE" | cut -d= -f2-)
        printf "%b\n" "$_CFG_SEP"
        printf "${C_BLUE}:: SOCKS5 配置 ::${C_RESET}\n"
        printf "${C_GREEN}   socks5://%s:%s@%s:%s${C_RESET}\n" \
            "$SOCKS5_USER" "$_cs5_pass" "$SERVER_IP" "$_cs5_port"
    fi



    # ── 系统管理区 ────────────────────────────────────────────────
    # 动态状态
    local _tm_label="切换测试模式"
    { [ -f "/var/run/iptables-test-mode.job" ] || [ -f "/var/run/iptables-iperf-mode.job" ]; } && \
        _tm_label="${C_GREEN}● 测试模式 ON${C_RESET}  (再按4关闭)"





    local _snell_label _realm_label _ss_label _socks5_label
    [[ -f "$SNELL_BIN" ]]        && _snell_label="管理 Snell"      || _snell_label="安装 Snell"
    [[ -f "$REALM_BIN" ]]        && _realm_label="管理 Realm"      || _realm_label="安装 Realm"
    [[ -f "$SS_BIN"    ]]        && _ss_label="管理 SS-Rust"       || _ss_label="安装 SS-Rust"
    [[ -f "$SOCKS5_META_FILE" ]] && _socks5_label="管理 SOCKS5"    || _socks5_label="安装 SOCKS5"

    # 更新提示
    local _any_upd_hint="" snell_ver ss_ver realm_ver
    snell_ver=$(get_installed_version snell "$SNELL_BIN" 2>/dev/null || true)
    ss_ver=$(get_installed_version shadowsocks-rust "$SS_BIN" 2>/dev/null || true)
    realm_ver=$(get_installed_version realm "$REALM_BIN" 2>/dev/null || true)
    local _upd_snell _upd_ss _upd_realm
    _upd_snell=$(get_cached_latest_version snell 2>/dev/null || true)
    _upd_ss=$(get_cached_latest_version shadowsocks-rust 2>/dev/null || true)
    _upd_realm=$(get_cached_latest_version realm 2>/dev/null || true)
    { [[ -n "$_upd_snell" && "$_upd_snell" != "$snell_ver" ]] || \
      [[ -n "$_upd_ss"    && "$_upd_ss"    != "$ss_ver"    ]] || \
      [[ -n "$_upd_realm" && "$_upd_realm" != "$realm_ver" ]]; } && \
        _any_upd_hint=" ${C_RED}[有更新可用]${C_RESET}"

    printf "${C_PURPLE}================================================================${C_RESET}\n"
    printf " ${C_BLUE}[ 系统管理 ]${C_RESET}\n"
    printf " ${C_YELLOW}★${C_RESET} ${C_GREEN}1.${C_RESET} 一键初始化"; printf "\033[43G"; printf "${C_GREEN}4.${C_RESET} %b\n" "$_tm_label"
    printf "    ${C_GREEN}2.${C_RESET} Fail2Ban                           ${C_GREEN}5.${C_RESET} 防火墙规则\n"
    printf "    ${C_GREEN}3.${C_RESET} TG 推送配置                        ${C_GREEN}6.${C_RESET} 系统维护\n"
    printf "${C_PURPLE}----------------------------------------------------------------${C_RESET}\n"
    printf " ${C_BLUE}[ 代理服务 ]${C_RESET}                         ${C_BLUE}[ 规则与转发 ]${C_RESET}\n"
    printf "  ${C_GREEN}7.${C_RESET} %-38s ${C_GREEN}11.${C_RESET} 添加转发规则\n" "$_snell_label"
    printf "  ${C_GREEN}8.${C_RESET} %-38s ${C_GREEN}12.${C_RESET} 重启 Realm\n" "$_realm_label"
    printf "  ${C_GREEN}9.${C_RESET} %-38s ${C_GREEN}13.${C_RESET} 检测并删除失效规则\n" "$_ss_label"
    printf " ${C_GREEN}10.${C_RESET} %-38s ${C_GREEN}14.${C_RESET} 流量配额与到期管理\n" "$_socks5_label"
    printf "  %-39s ${C_GREEN}15.${C_RESET} 查看运行状态日志\n" ""
    printf "${C_PURPLE}----------------------------------------------------------------${C_RESET}\n"
    printf " ${C_BLUE}[ 进阶控制 ]${C_RESET}\n"
    printf " ${C_GREEN}16.${C_RESET} 启停服务\n"
    printf " ${C_GREEN}17.${C_RESET} 更新服务 (Snell/SS/Realm/SOCKS5)%b\n" "$_any_upd_hint"
    printf " ${C_GREEN}18.${C_RESET} 卸载服务 (Snell/SS/Realm/SOCKS5)\n"
    printf "${C_PURPLE}================================================================${C_RESET}\n"
    printf " ${C_GREEN}0.${C_RESET} 退出脚本\n"
    if [[ ! -f "$UPDATE_CHECK_CACHE" ]]; then
        printf "${C_YELLOW}  ⏳ 版本检测首次运行中（后台进行），直接回车可刷新菜单查看升级提示${C_RESET}\n"
    fi
    printf "\n${C_PURPLE}请输入选项 [0-18]: ${C_RESET}"
}


main_loop() {
    while true; do
        _G_BBR_VER=""
        show_menu
        read -r choice
        printf "\n"
        case $choice in
            # ── 系统管理 ──────────────────────────────────────────
            1) do_quick_init; pause ;;
            2) do_ssh_security ;;
            3) _do_tg_config ;;
            4)
                local mk_ping="/var/run/iptables-test-mode.job"
                local mk_iperf="/var/run/iptables-iperf-mode.job"
                if [ -f "$mk_ping" ] || [ -f "$mk_iperf" ]; then
                    [ -f "$mk_ping"  ] && { atrm "$(cat "$mk_ping")"  2>/dev/null || true; rm -f "$mk_ping"; }
                    [ -f "$mk_iperf" ] && { atrm "$(cat "$mk_iperf")" 2>/dev/null || true; rm -f "$mk_iperf"; }
                    iptables -D INPUT -p icmp -m comment --comment "test-mode-icmp"  -j ACCEPT 2>/dev/null || true
                    iptables -D INPUT -p tcp  --dport 5201 -m comment --comment "test-mode-iperf" -j ACCEPT 2>/dev/null || true
                    iptables -D INPUT -p udp  --dport 5201 -m comment --comment "test-mode-iperf" -j ACCEPT 2>/dev/null || true
                    conntrack -D -p icmp >/dev/null 2>&1 || true
                    _persist_iptables
                    echo -e "${GREEN}测试模式已关闭${NC}"
                else
                    iptables -I INPUT 1 -p icmp -m comment --comment "test-mode-icmp" -j ACCEPT
                    iptables -C INPUT -p tcp --dport 5201 -m comment --comment "test-mode-iperf" -j ACCEPT 2>/dev/null || \
                        iptables -I INPUT 1 -p tcp --dport 5201 -m comment --comment "test-mode-iperf" -j ACCEPT
                    iptables -C INPUT -p udp --dport 5201 -m comment --comment "test-mode-iperf" -j ACCEPT 2>/dev/null || \
                        iptables -I INPUT 1 -p udp --dport 5201 -m comment --comment "test-mode-iperf" -j ACCEPT
                    local sc
                    sc=$(mktemp /root/.iptfw-testmode-XXXXXX)
                    printf '%s\n' \
                        "iptables -D INPUT -p icmp -m comment --comment 'test-mode-icmp' -j ACCEPT 2>/dev/null || true" \
                        "iptables -D INPUT -p tcp --dport 5201 -m comment --comment 'test-mode-iperf' -j ACCEPT 2>/dev/null || true" \
                        "iptables -D INPUT -p udp --dport 5201 -m comment --comment 'test-mode-iperf' -j ACCEPT 2>/dev/null || true" \
                        "conntrack -D -p icmp >/dev/null 2>&1 || true" \
                        "_f=/etc/iptables/rules.v4; [ -f /etc/redhat-release ] && _f=/etc/sysconfig/iptables; mkdir -p \$(dirname \$_f); iptables-save > \$_f" \
                        "command -v netfilter-persistent >/dev/null && netfilter-persistent save >/dev/null 2>&1; command -v service >/dev/null && [ -f /etc/sysconfig/iptables ] && service iptables save >/dev/null 2>&1; true" \
                        "rm -f \"${mk_ping}\" \"${mk_iperf}\" \"${sc}\"" > "$sc"
                    local jid _at_out2 _at_ok=1
                    _at_out2=$(echo "bash $sc" | at now + 2 hours 2>&1) || _at_ok=0
                    jid=$(echo "$_at_out2" | grep -oP 'job \K[0-9]+' || echo "")
                    if [ -z "$jid" ] || [ "$_at_ok" -eq 0 ]; then
                        echo -e "${YELLOW}警告: atd 调度失败，测试模式已开启但不会自动关闭${NC}"
                        rm -f "$sc"; echo "" > "$mk_ping"; echo "" > "$mk_iperf"
                    else
                        echo "$jid" > "$mk_ping"; cp "$mk_ping" "$mk_iperf"
                        local my_ip; my_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
                        echo -e "${GREEN}测试模式已开启 (2h 后自动关闭)${NC}"
                        echo -e "  Ping  : 已放行 ICMP"
                        echo -e "  iperf3: ${CYAN}iperf3 -s${NC}  ← 手动在本机运行，Ctrl+C 即停"
                        echo -e "  对端  : ${CYAN}iperf3 -c ${my_ip} -P 1 -t 20 -R${NC}"
                    fi
                fi
                ;;
            5) sys_firewall_menu ;;
            6) sys_maintenance_menu ;;
            # ── 代理服务 ──────────────────────────────────────────
            7)
                if [[ -f "$SNELL_BIN" ]]; then _snell_manage_menu
                else install_snell || true; fi
                ;;
            8)
                if [[ -f "$REALM_BIN" ]]; then manage_realm_menu
                else install_realm || true; fi
                ;;
            9)
                if [[ -f "$SS_BIN" ]]; then _ss_manage_menu
                else install_shadowsocks || true; fi
                ;;
            10)
                if [[ -f "$SOCKS5_META_FILE" ]]; then manage_socks5_menu
                else install_socks5_proxy || true; fi
                ;;
            11) add_realm_forward_advanced || true ;;
            12) manage_services "restart" "realm" ;;
            13) check_realm_dead_forwards || true ;;
            14) manage_quota_menu ;;
            15)
                while true; do
                    clear
                    printf "${C_CYAN}=== 查看运行状态日志 ===${C_RESET}\n\n"
                    printf " ${C_GREEN}1.${C_RESET} 静态日志 (最后50行)\n"
                    printf " ${C_GREEN}2.${C_RESET} 实时日志 (任意键退出)\n"
                    printf " ${C_GREEN}0.${C_RESET} 返回主菜单\n"
                    printf "\n${C_CYAN}请选择 [0-2]: ${C_RESET}"
                    read -r log_opt
                    printf "\n"
                    case $log_opt in
                        2)
                            journalctl -u 'snell@*.service' -u shadowsocks-rust.service -u realm.service -f &
                            PID=$!
                            read -n 1 -s -r -p "按任意键退出实时日志..."
                            kill "$PID" 2>/dev/null || true
                            wait "$PID" 2>/dev/null || true ;;
                        1)
                            journalctl -u 'snell@*.service' -u shadowsocks-rust.service -u realm.service -n 50 --no-pager
                            printf "\n${C_GREEN}按任意键返回子菜单...${C_RESET}"; read -rsn1 ;;
                        0|"") break ;;
                        *) msg_warn "无效选项"
                           printf "\n${C_GREEN}按任意键返回子菜单...${C_RESET}"; read -rsn1 ;;
                    esac
                done
                ;;
            16)
                while true; do
                    clear
                    printf "${C_CYAN}=== 启停服务 ===${C_RESET}\n\n"
                    printf " ${C_GREEN}1.${C_RESET} 启动所有服务\n"
                    printf " ${C_GREEN}2.${C_RESET} 停止所有服务\n"
                    printf " ${C_GREEN}3.${C_RESET} 重启所有服务\n"
                    printf " ${C_GREEN}0.${C_RESET} 返回主菜单\n"
                    printf "\n${C_CYAN}请选择 [0-3]: ${C_RESET}"
                    read -r svc_sub
                    printf "\n"
                    case $svc_sub in
                        1) manage_services "start"   "all"
                           printf "\n${C_GREEN}按任意键返回子菜单...${C_RESET}"; read -rsn1 ;;
                        2) manage_services "stop"    "all"
                           printf "\n${C_GREEN}按任意键返回子菜单...${C_RESET}"; read -rsn1 ;;
                        3) manage_services "restart" "all"
                           printf "\n${C_GREEN}按任意键返回子菜单...${C_RESET}"; read -rsn1 ;;
                        0|"") break ;;
                        *) msg_warn "无效选项"
                           printf "\n${C_GREEN}按任意键返回子菜单...${C_RESET}"; read -rsn1 ;;
                    esac
                done
                ;;
            17) _do_update_menu ;;
            18) _do_uninstall_menu ;;
            0)  cleanup; exit 0 ;;
            "") continue ;;
            *) msg_error "无效选项，请重试。" ;;
        esac
        printf "\n${C_GREEN}按任意键返回主菜单...${C_RESET}"; read -rsn1
    done
}

main() {
    case "${1:-}" in
        daemon)
            command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
                || { echo "daemon 模式缺少依赖 (curl/jq)" >&2; exit 1; }
            load_config; run_daemon; return ;;
        daily)
            command -v curl >/dev/null 2>&1 \
                || { echo "daily 模式缺少 curl" >&2; exit 1; }
            load_config; send_daily_report; return ;;
        quota-check)
            command -v iptables >/dev/null 2>&1 \
                || { echo "quota-check 模式缺少 iptables" >&2; exit 1; }
            quota_check_all; return ;;
        quota-daily)
            command -v curl >/dev/null 2>&1 \
                || { echo "quota-daily 模式缺少 curl" >&2; exit 1; }
            load_config; quota_daily_report; return ;;
    esac

    check_root
    acquire_lock
    check_system
    get_server_info
    heal_ss_config
    migrate_snell_config
    _ensure_ss_global_config
    _ensure_realm_network_config
    check_updates_background
    main_loop
    msg_info "脚本已退出。"
}

main "$@"
