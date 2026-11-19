# ------------------------------------------------------------------------------
# 通用交互、系统识别与合法性校验
# ------------------------------------------------------------------------------
if [ -t 1 ]; then
    C_R='\033[31m'; C_G='\033[32m'; C_Y='\033[33m'; C_B='\033[36m'; C_N='\033[0m'
else
    C_R=''; C_G=''; C_Y=''; C_B=''; C_N=''
fi

info() { printf "${C_G}%s${C_N}\n" "$*"; }
warn() { printf "${C_Y}%s${C_N}\n" "$*"; }
err()  { printf "${C_R}%s${C_N}\n" "$*" >&2; }
line() { echo "================================================================"; }
pause() { printf "\n按回车返回菜单..."; read -r _ || exit 0; }

ask() {
    printf "%s" "$1"
    read -r REPLY || exit 0
}

confirm() {
    ask "$1 [y/N]: "
    case "$REPLY" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

need_root() {
    if [ "$(id -u)" != "0" ]; then
        err "❌ 请使用 root 用户运行"
        exit 1
    fi
}

detect_os() {
    if command -v apk >/dev/null 2>&1; then
        OS_TYPE="alpine"
    elif command -v apt-get >/dev/null 2>&1; then
        OS_TYPE="debian"
    else
        OS_TYPE="unknown"
    fi
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        INIT="systemd"
    elif command -v rc-update >/dev/null 2>&1; then
        INIT="openrc"
    else
        INIT="none"
    fi
}

install_pkg() {
    case "$OS_TYPE" in
        alpine)
            apk update && apk add --no-cache "$@"
            ;;
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y && apt-get install --no-install-recommends -y "$@"
            ;;
        *)
            err "❌ 未识别的包管理器（仅支持 Alpine apk 或 Debian/Ubuntu apt）"
            return 1
            ;;
    esac
}

install_deps() {
    if command -v curl >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
        return 0
    fi
    install_pkg curl unzip ca-certificates
}

is_ip() {
    printf '%s' "$1" | grep -Eq '^[0-9a-fA-F:.]+$' && printf '%s' "$1" | grep -q '[.:]'
}

is_public_ipv4() {
    case "$1" in
        127.*|10.*|192.168.*|169.254.*|0.*) return 1 ;;
        100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 1 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 1 ;;
    esac
    printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
}

is_public_ipv6() {
    case "$1" in
        ""|::1|fe80:*|fc*|fd*) return 1 ;;
    esac
    printf '%s' "$1" | grep -q ':'
}

_cf_trace_stack() {
    _stk="$1"
    _iface="${2:-}"
    if [ -n "$_iface" ]; then
        _raw=$(curl -s "-${_stk}" --max-time 4 --interface "$_iface" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
    else
        _raw=$(curl -s "-${_stk}" --max-time 4 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
    fi
    _ip=$(printf '%s\n' "$_raw" | awk -F= '/^ip=/{print $2; exit}' | tr -d ' \r\n')
    _wp=$(printf '%s\n' "$_raw" | awk -F= '/^warp=/{print $2; exit}' | tr -d ' \r\n')
    if ! is_ip "$_ip" && [ -z "$_iface" ]; then
        _ip=$(curl -s "-${_stk}" --max-time 3 https://api.ip.sb/ip 2>/dev/null || curl -s "-${_stk}" --max-time 3 https://ifconfig.me 2>/dev/null || true)
        _ip=$(printf '%s' "$_ip" | tr -d ' \r\n')
        is_ip "$_ip" || _ip=""
        _wp="off"
    fi
    is_ip "$_ip" || { echo "|"; return 1; }
    printf '%s|%s\n' "$_ip" "${_wp:-off}"
}

_phys_iface_and_ip() {
    _stk="$1"
    command -v ip >/dev/null 2>&1 || return 1
    _rt=$(ip "-${_stk}" route show table main default 2>/dev/null | head -n1 || true)
    [ -n "$_rt" ] || _rt=$(ip "-${_stk}" route show default 2>/dev/null | grep -Ev 'dev (warp|wg|tun|docker|br-)' | head -n1 || true)
    _dev=$(printf '%s\n' "$_rt" | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
    case "$_dev" in
        ""|warp|wg*|tun*|lo|docker*) return 1 ;;
    esac
    _src=$(printf '%s\n' "$_rt" | awk '{for(i=1;i<NF;i++) if($i=="src"){print $(i+1); exit}}')
    if [ -z "$_src" ]; then
        if [ "$_stk" = "4" ]; then
            _src=$(ip -4 addr show dev "$_dev" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)
        else
            _src=$(ip -6 addr show dev "$_dev" 2>/dev/null | awk '/inet6 / && !/fe80:/{print $2}' | cut -d/ -f1 | head -n1)
        fi
    fi
    printf '%s|%s\n' "$_dev" "$_src"
}

_detect_one_stack() {
    _stk="$1"
    _tr=$(_cf_trace_stack "$_stk" || true)
    _def_ip="${_tr%%|*}"
    _def_wp="${_tr#*|}"

    _phys=$(_phys_iface_and_ip "$_stk" || true)
    _pdev="${_phys%%|*}"
    _pip="${_phys#*|}"

    if [ "$_def_wp" = "on" ] || [ "$_def_wp" = "plus" ]; then
        _warp_ip="$_def_ip"
        _real_ip=""
        if [ "$_stk" = "4" ] && is_public_ipv4 "$_pip"; then
            _real_ip="$_pip"
        elif [ "$_stk" = "6" ] && is_public_ipv6 "$_pip"; then
            _real_ip="$_pip"
        else
            for _cand in "$_pip" "$_pdev"; do
                [ -n "$_cand" ] || continue
                _try=$(_cf_trace_stack "$_stk" "$_cand" || true)
                _tip="${_try%%|*}"
                _twp="${_try#*|}"
                if [ -n "$_tip" ] && [ "$_twp" = "off" ]; then
                    _real_ip="$_tip"
                    break
                fi
            done
        fi
        printf '%s|%s\n' "$_real_ip" "$_warp_ip"
        return 0
    fi

    if [ -z "$_def_ip" ]; then
        if [ "$_stk" = "4" ] && is_public_ipv4 "$_pip"; then
            _def_ip="$_pip"
        elif [ "$_stk" = "6" ] && is_public_ipv6 "$_pip"; then
            _def_ip="$_pip"
        fi
    fi
    printf '%s|\n' "$_def_ip"
}

detect_ip() {
    _ip_tmp4="/tmp/.ip_det4.$$"
    _ip_tmp6="/tmp/.ip_det6.$$"
    (_detect_one_stack 4 > "$_ip_tmp4") &
    _pid4=$!
    (_detect_one_stack 6 > "$_ip_tmp6") &
    _pid6=$!
    wait "$_pid4" 2>/dev/null || true
    wait "$_pid6" 2>/dev/null || true
    _r4=$(cat "$_ip_tmp4" 2>/dev/null || true)
    _r6=$(cat "$_ip_tmp6" 2>/dev/null || true)
    rm -f "$_ip_tmp4" "$_ip_tmp6"
    IPV4="${_r4%%|*}"
    WARP_IPV4="${_r4#*|}"
    IPV6="${_r6%%|*}"
    WARP_IPV6="${_r6#*|}"
}

core_pid() {
    _pname="${CORE_PROC_NAME:-xray-core}"
    for _d in /proc/[0-9]*; do
        if [ "$(cat "$_d/comm" 2>/dev/null)" = "$_pname" ]; then
            echo "${_d#/proc/}"
            return 0
        fi
    done
    return 1
}

core_version() {
    if [ -x "$CORE_BIN" ]; then
        "$CORE_BIN" version 2>/dev/null | awk '
            /^sing-box version / { print $3; found=1; exit }
            /^Xray / { print $2; found=1; exit }
            NR==1 && !found { print $2; found=1; exit }
        '
    else
        echo "未安装"
    fi
}

strategy_label() {
    case "$1" in
        AsIs)      echo "系统默认 (AsIs)" ;;
        UseIPv6v4) echo "IPv6 优先 (UseIPv6v4)" ;;
        UseIPv4v6) echo "IPv4 优先 (UseIPv4v6)" ;;
        UseIPv6)   echo "仅 IPv6 (UseIPv6)" ;;
        UseIPv4)   echo "仅 IPv4 (UseIPv4)" ;;
        *)         echo "$1" ;;
    esac
}

valid_port() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_path() {
    case "$1" in /*) ;; *) return 1 ;; esac
    case "$1" in *' '*|*'"'*|*"'"*|*'\'*|*'|'*) return 1 ;; esac
    return 0
}

valid_uuid() {
    printf '%s' "$1" | grep -Eq '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
}

valid_strategy() {
    case "$1" in AsIs|UseIPv6v4|UseIPv4v6|UseIPv6|UseIPv4) return 0 ;; *) return 1 ;; esac
}

valid_tag() {
    [ -n "$1" ] && [ "$1" != "api" ] && printf '%s' "$1" | grep -Eq '^[a-zA-Z0-9_-]{1,32}$'
}

valid_domain() {
    printf '%s' "$1" | grep -Eq '^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'
}

is_tls_port_risk() {
    case "$1" in
        443|8443|2053|2083|2087|2096) return 0 ;;
        *) return 1 ;;
    esac
}

find_helper_script() {
    _name="$1"
    for _cand in \
        "${ENTRY_DIR}/${_name}" \
        "/root/${_name}" \
        "$(pwd)/${_name}" \
        "/usr/local/bin/${_name}"; do
        if [ -f "$_cand" ]; then
            printf '%s\n' "$_cand"
            return 0
        fi
    done
    return 1
}

ensure_bash() {
    command -v bash >/dev/null 2>&1 && return 0
    info "📦 正在安装 bash 依赖..."
    install_pkg bash
}

ensure_warp_deps() {
    install_pkg curl wget bash wireguard-tools openresolv
}
