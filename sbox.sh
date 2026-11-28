#!/bin/sh
# SBOX_MENU_SCRIPT_MARKER (请勿删除此行：用于识别 /usr/local/bin/sbox 是管理脚本而非二进制)
# ==============================================================================
# 脚本名称: sbox.sh  (Alpine / Debian / Ubuntu 通用轻量 sing-box 多入站安装 + 管理脚本)
# 仓库项目: sboxwarpinone (全合一单文件版，支持内核态 WARP 多出口容灾与 age 加密内置 Origin TLS 证书)
# 版本    : 1.2.0
# 核心特性:
#   - 多入站管理：同实例原生支持 Hysteria2 / VLESS+WS (CF CDN) / VLESS+Reality 共存
#   - 新版无警告配置：完全对齐 sing-box 1.12+ / 1.14+ DNS 与 default_domain_resolver 语法
#   - 轻量 JSON 引擎：优先复用系统已有 python3 或 jq，均无时自动安装极轻量 jq (~1MB)
#   - 小内存容器保护：OpenRC / systemd 自动按容器内存上限配置 GOMEMLIMIT
#   - 加密 Origin TLS：支持内嵌经 age 加密的 Cloudflare Origin 证书，选定启用时提示输入口令解锁
#   - 双模 WARP 出口：支持「三路内核态 WireGuard UDP（默认）」与「WARP MASQUE (usque) 单路/双路热备」自由切换
#   - 配套完整生态：Reality SNI 探活优选池、CF 测速
# 文件布局:
#   /usr/local/bin/sing-box        官方 sing-box 核心二进制
#   /usr/local/bin/sbox            本管理脚本：无参数 -> 菜单；非保留参数 -> 透明转发给核心
#   /usr/local/bin/slink           快捷导出链接，等价于 `sbox link`
#   /etc/sing-box/config.json      sing-box 主配置文件（唯一事实源）
#   /etc/sing-box/certs/           HY2 自签证书与 Cloudflare Origin TLS 证书目录
#   /etc/sing-box/reality_keys.json Reality 私钥->公钥映射缓存
#   /etc/sing-box/node.env         全局策略与摘要缓存
# 常用命令:
#   首次安装 : chmod +x /root/sbox.sh && /root/sbox.sh [hy2|ws|reality] [端口] [参数...]
#   日常管理 : sbox                (弹出多入站交互菜单)
#   导出链接 : sbox link           (或 slink，导出全部业务入站链接)
#   查看节点 : sbox list           (命令行列出所有入站摘要)
#   CF 测速  : sbox speed          (默认 100MB 下载 + 50MB 上传)
# 源码构建: 由 src/*.sh 经 build.sh (及 GitHub Actions) 合并生成，请勿直接手改 sbox.sh
# ==============================================================================

CORE_BIN="/usr/local/bin/sing-box"
CORE_PROC_NAME="sing-box"
MENU_BIN="/usr/local/bin/sbox"
SLINK_BIN="/usr/local/bin/slink"
CONF_DIR="/etc/sing-box"
CONF_FILE="/etc/sing-box/config.json"
CERT_DIR="/etc/sing-box/certs"
KEY_MAP="/etc/sing-box/reality_keys.json"
NODE_ENV="/etc/sing-box/node.env"
LOG_FILE="/var/log/sing-box.log"
SCRIPT_VERSION="1.2.0"
GH_PROXY="${GH_PROXY:-}"

# 透明转发：以 sbox 名义被调用且带非保留参数时，直接交给官方 sing-box 核心
SELF_NAME=$(basename "$0" 2>/dev/null)
if [ "$SELF_NAME" = "sbox" ]; then
    case "$1" in
        ""|menu|link|list|speed|warp) ;;
        *)
            if [ -x "$CORE_BIN" ]; then
                exec "$CORE_BIN" "$@"
            fi
            echo "❌ 未找到 sing-box 核心: $CORE_BIN" >&2
            exit 1
            ;;
    esac
fi

IPV4=""
IPV6=""
WARP_IPV4=""
WARP_IPV6=""
STRATEGY="AsIs"
OS_TYPE=""
INIT=""
JSON_ENGINE=""

# === [module: 10_common.sh] ===
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
line() { printf '%b%s%b\n' "$C_B" "────────────────────────────────────────────────────────" "$C_N"; }

menu_title() {
    printf '\n%b┌─ %s%b\n' "$C_B" "$*" "$C_N"
    line
}

menu_section() {
    printf '\n%b%s%b\n' "$C_Y" "$*" "$C_N"
}

menu_option() {
    printf '  %b[%s]%b  ' "$C_B" "$1" "$C_N"
    shift
    printf '%s\n' "$*"
}

pause() { printf "\n%b按回车返回菜单...%b" "$C_B" "$C_N"; read -r _ || exit 0; }

ask() {
    printf "%b›%b %s" "$C_G" "$C_N" "$1"
    read -r REPLY || exit 0
    REPLY=$(printf '%s' "$REPLY" | tr -d '\r')
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

ensure_bash() {
    command -v bash >/dev/null 2>&1 && return 0
    info "📦 正在安装 bash 依赖..."
    install_pkg bash
}

# === [module: 20_json_engine.sh] ===
# ------------------------------------------------------------------------------
# sing-box 统一 JSON 引擎（优先系统已有 python3 或 jq；均无时自动安装极轻量 jq ~1MB）
# ------------------------------------------------------------------------------
detect_json_tool() {
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import json,sys' >/dev/null 2>&1; then
        JSON_ENGINE="python3"
    elif command -v jq >/dev/null 2>&1; then
        JSON_ENGINE="jq"
    else
        JSON_ENGINE=""
    fi
    [ -n "$JSON_ENGINE" ]
}

ensure_json_tool() {
    detect_json_tool && return 0
    info "📦 未检测到 python3 或 jq，正在安装轻量 JSON 工具 jq..."
    install_pkg jq || return 1
    detect_json_tool
}

sb_strategy_value() {
    case "$1" in
        UseIPv6v4) echo "prefer_ipv6" ;;
        UseIPv4v6) echo "prefer_ipv4" ;;
        UseIPv6)   echo "ipv6_only" ;;
        UseIPv4)   echo "ipv4_only" ;;
        *)         echo "" ;;
    esac
}

# 生成全新 sing-box 1.12+/1.14+ 无警告基础配置
json_init_base_config() {
    _strat="$1"
    _out="$2"
    _sbs=$(sb_strategy_value "$_strat")
    if [ -n "$_sbs" ]; then
        _dns_line="    \"strategy\": \"$_sbs\","
        _res_line="      \"strategy\": \"$_sbs\","
    else
        _dns_line=""
        _res_line=""
    fi
    cat > "$_out" <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "type": "local",
        "tag": "dns-local",
        "prefer_go": true
      }
    ],
${_dns_line}
    "final": "dns-local"
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "action": "sniff"
      }
    ],
    "final": "direct",
    "default_domain_resolver": {
${_res_line}
      "server": "dns-local"
    }
  }
}
EOF
    # 移除空行（当 strategy 为空时保持 JSON 干净整洁）
    sed '/^[[:space:]]*$/d' "$_out" > "$_out.clean" && mv -f "$_out.clean" "$_out"
}

json_exec() {
    _op="$1"
    shift
    detect_json_tool || { err "❌ 缺少 JSON 工具 (python3/jq)"; return 1; }

    if [ "$JSON_ENGINE" = "python3" ]; then
        python3 - "$_op" "$@" <<'PY'
import json, re, sys

op = sys.argv[1]
args = sys.argv[2:]

def load(p):
    with open(p, "r", encoding="utf-8") as f:
        return json.load(f)

def save(p, d):
    with open(p, "w", encoding="utf-8") as f:
        json.dump(d, f, indent=2, ensure_ascii=False)
        f.write("\n")

def to_sb_strategy(s):
    return {
        "UseIPv6v4": "prefer_ipv6",
        "UseIPv4v6": "prefer_ipv4",
        "UseIPv6": "ipv6_only",
        "UseIPv4": "ipv4_only",
    }.get(s, "")

def from_sb_strategy(s):
    return {
        "prefer_ipv6": "UseIPv6v4",
        "prefer_ipv4": "UseIPv4v6",
        "ipv6_only": "UseIPv6",
        "ipv4_only": "UseIPv4",
    }.get(s, "AsIs")

def parse_ws_path(wspath):
    m = re.match(r"^([^?]*)\?ed=([0-9]+)$", wspath or "")
    if m:
        cp = m.group(1) or "/"
        return cp, int(m.group(2))
    return (wspath or "/ws"), 0

def row(idx, ib):
    proto = ib.get("type", "")
    tag = ib.get("tag", "")
    port = str(ib.get("listen_port", ""))
    tls = ib.get("tls") or {}
    tr = ib.get("transport") or {}
    users = ib.get("users") or []
    clients = str(len(users))
    u0 = users[0] if users else {}

    net = "-"
    sec = "none"
    wspath = ""
    cred = ""
    flow = ""
    sni = ""
    priv = ""
    sid = ""
    obfs_pw = ""

    if proto == "vless":
        cred = u0.get("uuid", "")
        flow = u0.get("flow", "")
        if tr.get("type") == "ws":
            net = "ws"
            sec = "tls" if tls.get("enabled") else "none"
            cp = tr.get("path", "")
            med = tr.get("max_early_data")
            if isinstance(med, int) and med > 0 and "?ed=" not in cp:
                wspath = f"{cp}?ed={med}"
            else:
                wspath = cp
        elif (tls.get("reality") or {}).get("enabled"):
            net = "tcp"
            sec = "reality"
            rl = tls.get("reality") or {}
            sni = tls.get("server_name") or (rl.get("handshake") or {}).get("server", "")
            priv = rl.get("private_key", "")
            sids = rl.get("short_id") or []
            sid = sids[0] if sids else ""
        else:
            net = "tcp"
            sec = "tls" if tls.get("enabled") else "none"
    elif proto == "hysteria2":
        net = "udp"
        sec = "tls"
        cred = u0.get("password", "")
        wspath = tls.get("certificate_path", "")
        priv = tls.get("key_path", "")
        sni = tls.get("server_name", "")
        obfs = ib.get("obfs") or {}
        if obfs.get("type") == "salamander":
            obfs_pw = obfs.get("password", "")
    else:
        net = tr.get("type") or "-"
        sec = "tls" if tls.get("enabled") else "none"

    fields = [str(idx), tag, proto, port, net, sec, wspath, cred, flow, sni, priv, sid, clients, obfs_pw]
    return "|".join(x.replace("|", "") for x in fields)

if op == "get_strategy":
    cfg = load(args[0])
    s = (cfg.get("dns") or {}).get("strategy") or ((cfg.get("route") or {}).get("default_domain_resolver") or {}).get("strategy", "")
    print(from_sb_strategy(s))
elif op == "patch_strategy":
    cfg = load(args[0])
    sbs = to_sb_strategy(args[1])
    dns = cfg.setdefault("dns", {})
    if sbs:
        dns["strategy"] = sbs
    else:
        dns.pop("strategy", None)
    ddr = cfg.setdefault("route", {}).setdefault("default_domain_resolver", {"server": "dns-local"})
    if sbs:
        ddr["strategy"] = sbs
    else:
        ddr.pop("strategy", None)
    save(args[2], cfg)
elif op == "list":
    cfg = load(args[0])
    for i, ib in enumerate(cfg.get("inbounds", [])):
        print(row(i, ib))
elif op == "get":
    cfg = load(args[0])
    idx = int(args[1])
    ib = cfg["inbounds"][idx]
    print(row(idx, ib))
elif op == "port_used":
    cfg = load(args[0])
    port = str(args[1])
    excl = args[2] if len(args) > 2 else ""
    for i, ib in enumerate(cfg.get("inbounds", [])):
        if excl != "" and str(i) == excl:
            continue
        if str(ib.get("listen_port", "")) == port:
            sys.exit(0)
    sys.exit(1)
elif op == "tag_used":
    cfg = load(args[0])
    tag = args[1]
    for ib in cfg.get("inbounds", []):
        if ib.get("tag") == tag:
            sys.exit(0)
    sys.exit(1)
elif op == "add_ws":
    cfg = load(args[0])
    tag, port, wspath, uuid, out = args[1], int(args[2]), args[3], args[4], args[5]
    cp, med = parse_ws_path(wspath)
    tr = {"type": "ws", "path": cp}
    if med > 0:
        tr["max_early_data"] = med
        tr["early_data_header_name"] = "Sec-WebSocket-Protocol"
    cfg.setdefault("inbounds", []).append({
        "type": "vless",
        "tag": tag,
        "listen": "::",
        "listen_port": port,
        "users": [{"uuid": uuid}],
        "transport": tr,
    })
    save(out, cfg)
elif op == "add_reality":
    cfg = load(args[0])
    tag, port, sni, uuid, priv, sid, out = args[1], int(args[2]), args[3], args[4], args[5], args[6], args[7]
    cfg.setdefault("inbounds", []).append({
        "type": "vless",
        "tag": tag,
        "listen": "::",
        "listen_port": port,
        "users": [{"uuid": uuid, "flow": "xtls-rprx-vision"}],
        "tls": {
            "enabled": True,
            "server_name": sni,
            "reality": {
                "enabled": True,
                "handshake": {"server": sni, "server_port": 443},
                "private_key": priv,
                "short_id": [sid],
            },
        },
    })
    save(out, cfg)
elif op == "add_hy2":
    cfg = load(args[0])
    tag, port, pw, crt, key, obfs_pw, out = args[1], int(args[2]), args[3], args[4], args[5], args[6], args[7]
    ib = {
        "type": "hysteria2",
        "tag": tag,
        "listen": "::",
        "listen_port": port,
        "users": [{"password": pw}],
        "tls": {
            "enabled": True,
            "alpn": ["h3"],
            "certificate_path": crt,
            "key_path": key,
        },
    }
    if obfs_pw:
        ib["obfs"] = {"type": "salamander", "password": obfs_pw}
    cfg.setdefault("inbounds", []).append(ib)
    save(out, cfg)
elif op == "patch":
    cfg = load(args[0])
    idx, field, val, out = int(args[1]), args[2], args[3], args[4]
    ib = cfg["inbounds"][idx]
    if field == "port":
        ib["listen_port"] = int(val)
    elif field == "wspath":
        cp, med = parse_ws_path(val)
        tr = {"type": "ws", "path": cp}
        if med > 0:
            tr["max_early_data"] = med
            tr["early_data_header_name"] = "Sec-WebSocket-Protocol"
        ib["transport"] = tr
    elif field == "sni":
        tls = ib.setdefault("tls", {})
        tls["server_name"] = val
        rl = tls.get("reality") or {}
        if rl.get("enabled"):
            rl.setdefault("handshake", {})["server"] = val
            rl["handshake"]["server_port"] = 443
    elif field == "uuid":
        users = ib.get("users") or []
        if len(users) > 1:
            sys.exit(2)
        if users:
            users[0]["uuid"] = val
        else:
            ib["users"] = [{"uuid": val}]
    elif field == "password":
        users = ib.get("users") or []
        if len(users) > 1:
            sys.exit(2)
        if users:
            users[0]["password"] = val
        else:
            ib["users"] = [{"password": val}]
    elif field == "reality_keys":
        priv, sid = val.split("|", 1)
        rl = ib.setdefault("tls", {}).setdefault("reality", {})
        rl["private_key"] = priv
        rl["short_id"] = [sid]
    elif field == "ws_tls":
        crt, key = val.split("|", 1)
        ib["tls"] = {"enabled": True, "certificate_path": crt, "key_path": key}
    elif field == "hy2_obfs":
        if val:
            ib["obfs"] = {"type": "salamander", "password": val}
        else:
            ib.pop("obfs", None)
    elif field == "hy2_cert":
        crt, key = val.split("|", 1)
        ib["tls"] = {
            "enabled": True,
            "alpn": ["h3"],
            "certificate_path": crt,
            "key_path": key,
        }
    else:
        sys.exit(3)
    save(out, cfg)
elif op == "delete":
    cfg = load(args[0])
    idx, out = int(args[1]), args[2]
    del cfg["inbounds"][idx]
    save(out, cfg)
else:
    sys.exit(4)
PY
        return $?
    fi

    # jq 引擎分支（供无 python3 的极简 Debian/Alpine 系统使用）
    case "$_op" in
        get_strategy)
            jq -r '
              (.dns.strategy // .route.default_domain_resolver.strategy // "") as $s |
              if $s == "prefer_ipv6" then "UseIPv6v4"
              elif $s == "prefer_ipv4" then "UseIPv4v6"
              elif $s == "ipv6_only" then "UseIPv6"
              elif $s == "ipv4_only" then "UseIPv4"
              else "AsIs" end
            ' "$1"
            ;;
        patch_strategy)
            _sbs=$(sb_strategy_value "$2")
            if [ -n "$_sbs" ]; then
                jq --arg s "$_sbs" '
                  .dns.strategy = $s | .route.default_domain_resolver.strategy = $s
                ' "$1" > "$3"
            else
                jq 'del(.dns.strategy) | del(.route.default_domain_resolver.strategy)' "$1" > "$3"
            fi
            ;;
        list)
            jq -r '
              .inbounds // [] | to_entries[] |
              .key as $idx | .value as $ib |
              ($ib.type // "") as $proto |
              ($ib.tag // "") as $tag |
              ($ib.listen_port // "" | tostring) as $port |
              (($ib.users // []) | length | tostring) as $clients |
              (($ib.users // [])[0] // {}) as $u0 |
              (if $proto == "vless" and ($ib.transport.type // "") == "ws" then "ws"
               elif $proto == "vless" then "tcp"
               elif $proto == "hysteria2" then "udp"
               else ($ib.transport.type // "-") end) as $net |
              (if $proto == "vless" and ($ib.tls.reality.enabled // false) == true then "reality"
               elif ($ib.tls.enabled // false) == true then "tls"
               else "none" end) as $sec |
              (if $proto == "vless" and $net == "ws" then
                 (($ib.transport.path // "") + (if (($ib.transport.max_early_data // 0) > 0) and (($ib.transport.path // "") | contains("?ed=") | not) then ("?ed=" + ($ib.transport.max_early_data | tostring)) else "" end))
               elif $proto == "hysteria2" then ($ib.tls.certificate_path // "")
               else "" end) as $wspath |
              (if $proto == "hysteria2" then ($u0.password // "") else ($u0.uuid // "") end) as $cred |
              ($u0.flow // "") as $flow |
              (if $sec == "reality" then ($ib.tls.server_name // $ib.tls.reality.handshake.server // "")
               elif $proto == "hysteria2" then ($ib.tls.server_name // "")
               else "" end) as $sni |
              (if $sec == "reality" then ($ib.tls.reality.private_key // "")
               elif $proto == "hysteria2" then ($ib.tls.key_path // "")
               else "" end) as $priv |
              (if $sec == "reality" then (($ib.tls.reality.short_id // [])[0] // "") else "" end) as $sid |
              (if ($ib.obfs.type // "") == "salamander" then ($ib.obfs.password // "") else "" end) as $obfs |
              [$idx, $tag, $proto, $port, $net, $sec, $wspath, $cred, $flow, $sni, $priv, $sid, $clients, $obfs] | map(tostring | gsub("\\|"; "")) | join("|")
            ' "$1"
            ;;
        get)
            json_exec list "$1" | awk -F'|' -v i="$2" '$1 == i { print; exit }'
            ;;
        port_used)
            _excl="${3:-}"
            jq -e --arg p "$2" --arg ex "$_excl" '
              [(.inbounds // []) | to_entries[] | select(($ex == "" or (.key | tostring) != $ex) and ((.value.listen_port | tostring) == $p))] | length > 0
            ' "$1" >/dev/null 2>&1
            ;;
        tag_used)
            jq -e --arg t "$2" '[(.inbounds // [])[] | select((.tag // "") == $t)] | length > 0' "$1" >/dev/null 2>&1
            ;;
        add_ws)
            _cp="${4%%\?ed=*}"; _med=""
            case "$4" in *\?ed=*) _med="${4#*\?ed=}" ;; esac
            [ -n "$_cp" ] || _cp="/"
            if [ -n "$_med" ] && [ "$_med" -gt 0 ] 2>/dev/null; then
                jq --arg tag "$2" --argjson port "$3" --arg cp "$_cp" --argjson med "$_med" --arg u "$5" '
                  .inbounds = ((.inbounds // []) + [{
                    type: "vless", tag: $tag, listen: "::", listen_port: $port,
                    users: [{uuid: $u}],
                    transport: {type: "ws", path: $cp, max_early_data: $med, early_data_header_name: "Sec-WebSocket-Protocol"}
                  }])
                ' "$1" > "$6"
            else
                jq --arg tag "$2" --argjson port "$3" --arg cp "$4" --arg u "$5" '
                  .inbounds = ((.inbounds // []) + [{
                    type: "vless", tag: $tag, listen: "::", listen_port: $port,
                    users: [{uuid: $u}],
                    transport: {type: "ws", path: $cp}
                  }])
                ' "$1" > "$6"
            fi
            ;;
        add_reality)
            jq --arg tag "$2" --argjson port "$3" --arg sni "$4" --arg u "$5" --arg priv "$6" --arg sid "$7" '
              .inbounds = ((.inbounds // []) + [{
                type: "vless", tag: $tag, listen: "::", listen_port: $port,
                users: [{uuid: $u, flow: "xtls-rprx-vision"}],
                tls: {enabled: true, server_name: $sni, reality: {enabled: true, handshake: {server: $sni, server_port: 443}, private_key: $priv, short_id: [$sid]}}
              }])
            ' "$1" > "$8"
            ;;
        add_hy2)
            if [ -n "$7" ]; then
                jq --arg tag "$2" --argjson port "$3" --arg pw "$4" --arg crt "$5" --arg key "$6" --arg obfs "$7" '
                  .inbounds = ((.inbounds // []) + [{
                    type: "hysteria2", tag: $tag, listen: "::", listen_port: $port,
                    users: [{password: $pw}],
                    obfs: {type: "salamander", password: $obfs},
                    tls: {enabled: true, alpn: ["h3"], certificate_path: $crt, key_path: $key}
                  }])
                ' "$1" > "$8"
            else
                jq --arg tag "$2" --argjson port "$3" --arg pw "$4" --arg crt "$5" --arg key "$6" '
                  .inbounds = ((.inbounds // []) + [{
                    type: "hysteria2", tag: $tag, listen: "::", listen_port: $port,
                    users: [{password: $pw}],
                    tls: {enabled: true, alpn: ["h3"], certificate_path: $crt, key_path: $key}
                  }])
                ' "$1" > "$8"
            fi
            ;;
        patch)
            _idx="$2"; _field="$3"; _val="$4"; _out="$5"
            case "$_field" in
                port)
                    jq --argjson i "$_idx" --argjson p "$_val" '.inbounds[$i].listen_port = $p' "$1" > "$_out"
                    ;;
                wspath)
                    _cp="${_val%%\?ed=*}"; _med=""
                    case "$_val" in *\?ed=*) _med="${_val#*\?ed=}" ;; esac
                    [ -n "$_cp" ] || _cp="/"
                    if [ -n "$_med" ] && [ "$_med" -gt 0 ] 2>/dev/null; then
                        jq --argjson i "$_idx" --arg cp "$_cp" --argjson med "$_med" '
                          .inbounds[$i].transport = {type: "ws", path: $cp, max_early_data: $med, early_data_header_name: "Sec-WebSocket-Protocol"}
                        ' "$1" > "$_out"
                    else
                        jq --argjson i "$_idx" --arg cp "$_val" '
                          .inbounds[$i].transport = {type: "ws", path: $cp}
                        ' "$1" > "$_out"
                    fi
                    ;;
                sni)
                    jq --argjson i "$_idx" --arg s "$_val" '
                      .inbounds[$i].tls.server_name = $s |
                      if (.inbounds[$i].tls.reality.enabled // false) == true then
                        .inbounds[$i].tls.reality.handshake.server = $s | .inbounds[$i].tls.reality.handshake.server_port = 443
                      else . end
                    ' "$1" > "$_out"
                    ;;
                uuid)
                    _cnt=$(jq -r --argjson i "$_idx" '(.inbounds[$i].users // []) | length' "$1")
                    [ "${_cnt:-0}" -le 1 ] || return 2
                    jq --argjson i "$_idx" --arg u "$_val" '.inbounds[$i].users[0].uuid = $u' "$1" > "$_out"
                    ;;
                password)
                    _cnt=$(jq -r --argjson i "$_idx" '(.inbounds[$i].users // []) | length' "$1")
                    [ "${_cnt:-0}" -le 1 ] || return 2
                    jq --argjson i "$_idx" --arg p "$_val" '.inbounds[$i].users[0].password = $p' "$1" > "$_out"
                    ;;
                reality_keys)
                    _priv="${_val%%|*}"; _sid="${_val#*|}"
                    jq --argjson i "$_idx" --arg priv "$_priv" --arg sid "$_sid" '
                      .inbounds[$i].tls.reality.private_key = $priv | .inbounds[$i].tls.reality.short_id = [$sid]
                    ' "$1" > "$_out"
                    ;;
                ws_tls)
                    _crt="${_val%%|*}"; _key="${_val#*|}"
                    jq --argjson i "$_idx" --arg crt "$_crt" --arg key "$_key" '
                      .inbounds[$i].tls = {enabled: true, certificate_path: $crt, key_path: $key}
                    ' "$1" > "$_out"
                    ;;
                hy2_obfs)
                    if [ -n "$_val" ]; then
                        jq --argjson i "$_idx" --arg o "$_val" '.inbounds[$i].obfs = {type: "salamander", password: $o}' "$1" > "$_out"
                    else
                        jq --argjson i "$_idx" 'del(.inbounds[$i].obfs)' "$1" > "$_out"
                    fi
                    ;;
                hy2_cert)
                    _crt="${_val%%|*}"; _key="${_val#*|}"
                    jq --argjson i "$_idx" --arg crt "$_crt" --arg key "$_key" '
                      .inbounds[$i].tls = {enabled: true, alpn: ["h3"], certificate_path: $crt, key_path: $key}
                    ' "$1" > "$_out"
                    ;;
                *) return 3 ;;
            esac
            ;;
        delete)
            jq --argjson i "$2" 'del(.inbounds[$i])' "$1" > "$3"
            ;;
        *)
            return 4
            ;;
    esac
}

safe_apply_patch() {
    _tmp="$1"
    [ -f "$_tmp" ] || return 1
    if [ -x "$CORE_BIN" ]; then
        if ! "$CORE_BIN" check -c "$_tmp" >/dev/null 2>&1; then
            err "❌ 配置校验失败，已自动回滚未生效！详细错误："
            "$CORE_BIN" check -c "$_tmp" 2>&1 || true
            rm -f "$_tmp"
            return 1
        fi
    fi
    if [ -f "$CONF_FILE" ]; then
        cp -a "$CONF_FILE" "${CONF_FILE}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
        ls -1t "${CONF_FILE}".bak.* 2>/dev/null | sed -n '6,$p' | xargs -r rm -f 2>/dev/null || true
    fi
    mv -f "$_tmp" "$CONF_FILE"
    chmod 644 "$CONF_FILE"
    return 0
}

# === [module: 25_sni_pool.sh] ===
# ------------------------------------------------------------------------------
# Reality SNI 备选池与 TLS 1.3 + H2 探活优选
# 扩展方式：在下方 REALITY_SNI_POOL 中每行添加一个域名，重新运行 scripts/build.sh 即可
# ------------------------------------------------------------------------------
REALITY_SNI_POOL='
mmrrc.ucdavis.edu
'

list_sni_pool() {
    printf '%s\n' "$REALITY_SNI_POOL" | sed 's/#.*$//' | tr -d ' \t\r' | grep -v '^$'
}

probe_sni_host() {
    _host="$1"
    if ! command -v curl >/dev/null 2>&1; then
        echo "fail|无curl"
        return 1
    fi
    _res=$(curl -sILm 4 --tlsv1.3 --http2 -o /dev/null \
        -w '%{http_code} %{http_version} %{time_appconnect}' \
        "https://${_host}/" 2>/dev/null || true)
    _code=$(printf '%s' "$_res" | awk '{print $1}')
    _ver=$(printf '%s' "$_res" | awk '{print $2}')
    _t=$(printf '%s' "$_res" | awk '{print $3}')
    case "$_code" in
        [1-5][0-9][0-9])
            _ms=$(awk -v t="${_t:-0}" 'BEGIN{printf "%d", t * 1000}')
            if [ "$_ver" = "2" ] || [ "$_ver" = "2.0" ]; then
                echo "ok|${_ms}|h2"
                return 0
            fi
            echo "warn|${_ms}|http${_ver:-?}"
            return 0
            ;;
        *)
            echo "fail|0|timeout"
            return 1
            ;;
    esac
}

# 交互选择 Reality SNI，成功将域名写入 SELECTED_SNI
select_reality_sni() {
    SELECTED_SNI=""
    _pool=$(list_sni_pool)
    _cnt=$(printf '%s\n' "$_pool" | grep -c . 2>/dev/null || echo 0)

    menu_title "Reality SNI · ${_cnt} 个候选域名"
    menu_option 1 "探测 TLS 1.3 / H2 连通性和延迟"
    menu_option 2 "从候选列表选择，不测速"
    menu_option 3 "手动输入域名"
    menu_option 0 "取消"
    ask "请选择 [0-3] (回车默认 1): "
    case "${REPLY:-1}" in
        1)
            echo ""
            info "🔍 正在逐一探测备选池域名（TLS 1.3 + HTTP/2）..."
            _i=0
            _best=""
            _best_ms=999999
            _cands=""
            for _h in $_pool; do
                _i=$((_i + 1))
                _r=$(probe_sni_host "$_h")
                _st="${_r%%|*}"
                _rest="${_r#*|}"
                _ms="${_rest%%|*}"
                _proto="${_rest#*|}"
                if [ "$_st" = "ok" ]; then
                    printf " [%d] %-28s -> ${C_G}✅ 可用${C_N} (%sms, %s)\n" "$_i" "$_h" "$_ms" "$_proto"
                    if [ "${_ms:-999999}" -lt "$_best_ms" ]; then
                        _best="$_h"
                        _best_ms="$_ms"
                    fi
                elif [ "$_st" = "warn" ]; then
                    printf " [%d] %-28s -> ${C_Y}⚠️ 非H2${C_N} (%sms, %s)\n" "$_i" "$_h" "$_ms" "$_proto"
                else
                    printf " [%d] %-28s -> ${C_R}❌ 不可达/不支持TLS1.3${C_N}\n" "$_i" "$_h"
                fi
                _cands="${_cands}${_i}:${_h}
"
            done
            echo ""
            if [ -n "$_best" ]; then
                ask "输入序号或自定义域名 (回车使用推荐 $_best): "
                _pick="${REPLY:-$_best}"
            else
                warn "⚠️ 备选池均未通过 TLS 1.3 + H2 探测，建议手动输入其它低延迟站点。"
                ask "输入备选池序号或自定义域名 (回车取消): "
                _pick="$REPLY"
            fi
            [ -n "$_pick" ] || return 1
            case "$_pick" in
                *[!0-9]*)
                    valid_domain "$_pick" || { err "❌ 域名格式不正确: $_pick"; return 1; }
                    SELECTED_SNI="$_pick"
                    ;;
                *)
                    SELECTED_SNI=$(printf '%s' "$_cands" | awk -F: -v n="$_pick" '$1==n{print $2; exit}')
                    [ -n "$SELECTED_SNI" ] || { err "❌ 序号不存在"; return 1; }
                    ;;
            esac
            ;;
        2)
            _i=0
            for _h in $_pool; do
                _i=$((_i + 1))
                menu_option "$_i" "$_h"
            done
            ask "请选择序号 [1-${_i}] (回车默认 1): "
            _n="${REPLY:-1}"
            SELECTED_SNI=$(printf '%s\n' "$_pool" | sed -n "${_n}p")
            [ -n "$SELECTED_SNI" ] || { err "❌ 无效序号"; return 1; }
            ;;
        3)
            ask "请输入自定义 SNI 域名 (如 www.example.com): "
            valid_domain "$REPLY" || { err "❌ 域名格式不正确"; return 1; }
            SELECTED_SNI="$REPLY"
            if command -v curl >/dev/null 2>&1; then
                _r=$(probe_sni_host "$SELECTED_SNI")
                case "$_r" in
                    ok\|*) info "✅ 探测通过: $SELECTED_SNI (${_r#*|})" ;;
                    *) warn "⚠️ 该域名在本机未通过 TLS 1.3 + H2 探测 ($_r)，若后续握手失败可再修改 SNI。" ;;
                esac
            fi
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

# === [module: 30_service.sh] ===
# ------------------------------------------------------------------------------
# 服务管理、核心下载、GOMEMLIMIT 自适应、自签证书与 Reality 密钥映射
# ------------------------------------------------------------------------------
install_sbox_deps() {
    if command -v curl >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
        return 0
    fi
    install_pkg curl tar ca-certificates
}

ensure_openssl() {
    command -v openssl >/dev/null 2>&1 && return 0
    info "📦 正在安装 openssl 以生成自签证书..."
    install_pkg openssl
}

# 按容器 cgroup 内存上限或系统总内存计算约 50% 的 GOMEMLIMIT（小内存防 OOM）
calc_gomemlimit() {
    _bytes=""
    if [ -r /sys/fs/cgroup/memory.max ]; then
        _raw=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || true)
        case "$_raw" in ''|*[!0-9]*) ;; *) _bytes="$_raw" ;; esac
    elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        _raw=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || true)
        case "$_raw" in ''|*[!0-9]*) ;; *) _bytes="$_raw" ;; esac
    fi

    _mib=0
    if [ -n "$_bytes" ] && [ "$_bytes" -gt 0 ] 2>/dev/null; then
        _mib=$((_bytes / 1048576))
    fi
    if [ "$_mib" -le 0 ] || [ "$_mib" -gt 131072 ]; then
        _kb=$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)
        [ "${_kb:-0}" -gt 0 ] && _mib=$((_kb / 1024))
    fi

    if [ "$_mib" -gt 0 ] && [ "$_mib" -le 1024 ]; then
        _half=$((_mib / 2))
        [ "$_half" -ge 48 ] || _half=48
        echo "${_half}MiB"
    fi
}

write_service() {
    _gomem=$(calc_gomemlimit)
    case "$INIT" in
        systemd)
            {
                cat <<'EOF'
[Unit]
Description=sing-box service
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
EOF
                [ -n "$_gomem" ] && echo "Environment=\"GOMEMLIMIT=${_gomem}\""
                cat <<'EOF'
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
            } > /etc/systemd/system/sing-box.service
            systemctl daemon-reload
            systemctl enable sing-box >/dev/null 2>&1
            ;;
        openrc)
            {
                echo '#!/sbin/openrc-run'
                echo 'name="sing-box"'
                echo 'description="sing-box service"'
                [ -n "$_gomem" ] && echo "export GOMEMLIMIT=\"${_gomem}\""
                cat <<'EOF'
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
supervisor="supervise-daemon"
respawn_delay=3
respawn_max=0
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"

depend() {
    need net
    after firewall
}

start_pre() {
    if [ -f /var/log/sing-box.log ] && [ "$(wc -c < /var/log/sing-box.log)" -gt 5242880 ]; then
        : > /var/log/sing-box.log
    fi
    return 0
}
EOF
            } > /etc/init.d/sing-box
            chmod +x /etc/init.d/sing-box
            rc-update add sing-box default >/dev/null 2>&1

            mkdir -p /etc/local.d
            cat > /etc/local.d/sing-box.start <<'EOF'
#!/bin/sh
sleep 1
rc-service sing-box status >/dev/null 2>&1 || rc-service sing-box restart
EOF
            chmod +x /etc/local.d/sing-box.start
            rc-update add local default >/dev/null 2>&1
            ;;
        *)
            warn "⚠️ 未检测到 systemd 或 OpenRC，将以 nohup 后台方式运行（重启后需手动执行 sbox 选 7 启动）"
            ;;
    esac
}

svc() {
    case "$INIT" in
        systemd)
            systemctl "$1" sing-box
            ;;
        openrc)
            rc-service sing-box "$1"
            ;;
        *)
            case "$1" in
                stop)
                    pkill -x sing-box 2>/dev/null || killall sing-box 2>/dev/null || true
                    ;;
                start|restart)
                    pkill -x sing-box 2>/dev/null || killall sing-box 2>/dev/null || true
                    sleep 1
                    _gomem=$(calc_gomemlimit)
                    if [ -n "$_gomem" ]; then
                        GOMEMLIMIT="$_gomem" nohup "$CORE_BIN" run -c "$CONF_FILE" >>"$LOG_FILE" 2>&1 &
                    else
                        nohup "$CORE_BIN" run -c "$CONF_FILE" >>"$LOG_FILE" 2>&1 &
                    fi
                    ;;
                status)
                    core_pid >/dev/null
                    ;;
            esac
            ;;
    esac
}

show_log() {
    _n="${1:-50}"
    if [ "$INIT" = "systemd" ]; then
        journalctl -u sing-box -n "$_n" --no-pager 2>/dev/null
    elif [ -f "$LOG_FILE" ]; then
        tail -n "$_n" "$LOG_FILE"
    else
        warn "暂无日志文件: $LOG_FILE"
    fi
}

restart_and_check() {
    svc restart >/dev/null 2>&1
    sleep 1
    if core_pid >/dev/null; then
        info "✅ sing-box 已重启并正常运行"
        return 0
    fi
    err "❌ sing-box 启动失败，最近日志："
    show_log 20
    return 1
}

fetch_latest_singbox_ver() {
    if [ -n "${SINGBOX_VER:-}" ]; then
        printf '%s\n' "${SINGBOX_VER#v}"
        return 0
    fi
    _eff=$(curl -fsSLI -o /dev/null -w '%{url_effective}' --max-time 8 "${GH_PROXY}https://github.com/SagerNet/sing-box/releases/latest" 2>/dev/null || true)
    _ver=$(printf '%s' "$_eff" | sed -n 's|.*/tag/v\?\([^/?#]*\).*|\1|p')
    if [ -z "$_ver" ]; then
        _ver=$(curl -fsSL --max-time 8 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\?\([^"]*\)".*/\1/p' | head -n1)
    fi
    if [ -z "$_ver" ]; then
        _ver=$(curl -fsSL --max-time 10 "https://formulae.brew.sh/api/formula/sing-box.json" 2>/dev/null | sed -n 's/.*"stable"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
    fi
    printf '%s\n' "$_ver"
}

download_core() {
    case "$(uname -m)" in
        x86_64|amd64)  SARCH="amd64" ;;
        aarch64|arm64) SARCH="arm64" ;;
        *) err "❌ 不支持的系统架构: $(uname -m)"; return 1 ;;
    esac
    _ver=$(fetch_latest_singbox_ver)
    [ -n "$_ver" ] || { err "❌ 无法获取 sing-box 最新版本号（可设置 GH_PROXY 或 SINGBOX_VER 重试）"; return 1; }

    if [ -x "$CORE_BIN" ] && [ "$(core_version)" = "$_ver" ]; then
        info "✅ 当前已安装最新版 sing-box v${_ver}，无需重复下载。"
        return 0
    fi

    _libc=""
    if [ "$OS_TYPE" = "alpine" ] || ldd --version 2>&1 | grep -qi musl; then
        _libc="-musl"
    fi

    TMPD="/root/.sbox-dl.$$"
    rm -rf "$TMPD"
    mkdir -p "$TMPD"
    PKG="sing-box-${_ver}-linux-${SARCH}${_libc}"
    _rel_path="SagerNet/sing-box/releases/download/v${_ver}/${PKG}.tar.gz"
    URL="${GH_PROXY}https://github.com/${_rel_path}"
    info "⬇️  下载: $URL"
    if ! curl -fL --connect-timeout 8 --retry 1 -o "$TMPD/sbox.tar.gz" "$URL"; then
        if [ -z "${GH_PROXY:-}" ]; then
            URL="https://gh-v6.com/${_rel_path}"
            warn "⚠️ 直连 GitHub 下载失败，尝试 IPv6 加速源: $URL"
            if ! curl -fL --connect-timeout 10 --retry 2 -o "$TMPD/sbox.tar.gz" "$URL"; then
                err "❌ 下载失败（可设置 GH_PROXY 环境变量使用加速前缀后重试）"
                rm -rf "$TMPD"
                return 1
            fi
        else
            err "❌ 下载失败（可检查或更换 GH_PROXY 环境变量后重试）"
            rm -rf "$TMPD"
            return 1
        fi
    fi
    if ! tar -xzf "$TMPD/sbox.tar.gz" -C "$TMPD"; then
        err "❌ 解压失败"
        rm -rf "$TMPD"
        return 1
    fi
    _bin=$(find "$TMPD" -type f -name sing-box | head -n1)
    [ -n "$_bin" ] && chmod +x "$_bin" || { err "❌ 压缩包内未找到 sing-box"; rm -rf "$TMPD"; return 1; }
    if ! "$_bin" version >/dev/null 2>&1; then
        err "❌ 下载的核心无法执行（架构/libc 不匹配或文件损坏）："
        "$_bin" version 2>&1 || true
        rm -rf "$TMPD"
        return 1
    fi
    cp -f "$_bin" "$CORE_BIN.new" && mv -f "$CORE_BIN.new" "$CORE_BIN"
    rm -rf "$TMPD"
}

gen_uuid() {
    "$CORE_BIN" generate uuid 2>/dev/null
}

gen_rand_pass() {
    "$CORE_BIN" generate rand --hex 12 2>/dev/null
}

# 生成 Reality 密钥对并输出 "PRIV|PUB"，同时记录进 KEY_MAP 供后续导出链接
save_reality_keypair() {
    _priv="$1"
    _pub="$2"
    [ -n "$_priv" ] && [ -n "$_pub" ] || return 0
    mkdir -p "$CONF_DIR"
    [ -f "$KEY_MAP" ] || echo "{}" > "$KEY_MAP"
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import json,sys' >/dev/null 2>&1; then
        python3 - "$KEY_MAP" "$_priv" "$_pub" <<'PY'
import json, sys
p, k, v = sys.argv[1:4]
try:
    with open(p, "r", encoding="utf-8") as f:
        d = json.load(f)
except Exception:
    d = {}
d[k] = v
with open(p, "w", encoding="utf-8") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
PY
    elif command -v jq >/dev/null 2>&1; then
        _tmp="$KEY_MAP.tmp.$$"
        jq --arg k "$_priv" --arg v "$_pub" '.[$k] = $v' "$KEY_MAP" > "$_tmp" && mv -f "$_tmp" "$KEY_MAP"
    fi
}

gen_x25519_pair() {
    _raw=$("$CORE_BIN" generate reality-keypair 2>/dev/null || true)
    _pair=$(printf '%s\n' "$_raw" | awk -F'[:=]' '
        {
            k = tolower($1); gsub(/[ \t\r()]/, "", k)
            v = $2; gsub(/^[ \t]+|[ \t\r]+$/, "", v)
            if (k ~ /private/ && priv == "") priv = v
            else if (k ~ /public/ && pub == "") pub = v
        }
        END { printf "%s|%s\n", priv, pub }
    ')
    _priv="${_pair%%|*}"
    _pub="${_pair#*|}"
    [ -n "$_priv" ] && [ -n "$_pub" ] || return 1
    save_reality_keypair "$_priv" "$_pub"
    printf '%s|%s\n' "$_priv" "$_pub"
}

reality_pubkey_from_priv() {
    [ -f "$KEY_MAP" ] || return 1
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import json,sys' >/dev/null 2>&1; then
        python3 - "$KEY_MAP" "$1" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    d = json.load(f)
v = d.get(sys.argv[2], "")
if not v:
    sys.exit(1)
print(v)
PY
    elif command -v jq >/dev/null 2>&1; then
        _v=$(jq -r --arg k "$1" '.[$k] // empty' "$KEY_MAP" 2>/dev/null)
        [ -n "$_v" ] || return 1
        echo "$_v"
    else
        return 1
    fi
}

ensure_self_signed_cert() {
    _sni="${1:-deb.debian.org}"
    _crt="$2"
    _key="$3"
    ensure_openssl || return 1
    mkdir -p "$CERT_DIR"
    openssl ecparam -name prime256v1 -genkey -noout -out "$_key" >/dev/null 2>&1 || return 1
    openssl req -new -x509 -days 3650 -key "$_key" -out "$_crt" \
        -subj "/CN=${_sni}" -addext "subjectAltName=DNS:${_sni}" >/dev/null 2>&1 || \
        openssl req -new -x509 -days 3650 -key "$_key" -out "$_crt" -subj "/CN=${_sni}" >/dev/null 2>&1 || return 1
    chmod 644 "$_crt"
    chmod 600 "$_key"
}

detect_cert_cn() {
    _crt="$1"
    if [ -f "$_crt" ] && command -v openssl >/dev/null 2>&1; then
        _cn=$(openssl x509 -in "$_crt" -noout -subject 2>/dev/null | sed -n 's/.*CN[[:space:]]*=[[:space:]]*\([^,/]*\).*/\1/p' | head -n1 | tr -d ' \r\n')
        [ -n "$_cn" ] && { echo "$_cn"; return 0; }
    fi
    echo "deb.debian.org"
}

cert_sha256_fp() {
    _crt="$1"
    if [ -f "$_crt" ] && command -v openssl >/dev/null 2>&1; then
        openssl x509 -in "$_crt" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f' | tr -d ' \r\n'
    fi
}

is_installed() {
    [ -x "$CORE_BIN" ] && [ -f "$CONF_FILE" ]
}

install_self() {
    _self=$(readlink -f "$0" 2>/dev/null || echo "$0")
    if [ "$_self" != "$MENU_BIN" ] && [ -f "$_self" ]; then
        cp -f "$_self" "$MENU_BIN" && chmod +x "$MENU_BIN"
    fi
    ln -sf "$MENU_BIN" "$SLINK_BIN" 2>/dev/null || true
}

# === [module: 40_nodes.sh] ===
# ------------------------------------------------------------------------------
# sing-box 多入站管理：Hysteria2 / VLESS+WS / VLESS+Reality 增删改查与链接导出
# ------------------------------------------------------------------------------
load_strategy() {
    if [ -f "$CONF_FILE" ]; then
        _s=$(json_exec get_strategy "$CONF_FILE" 2>/dev/null || true)
        [ -n "$_s" ] && STRATEGY="$_s"
    fi
    [ -n "$STRATEGY" ] || STRATEGY="AsIs"
}

sync_compat_env() {
    [ -f "$CONF_FILE" ] || return 0
    load_strategy
    mkdir -p "$CONF_DIR"
    cat > "$NODE_ENV" <<EOF
STRATEGY='${STRATEGY}'
EOF
    chmod 600 "$NODE_ENV"
}

next_auto_tag() {
    _prefix="$1"
    _n=1
    while [ "$_n" -le 999 ]; do
        _cand="${_prefix}-${_n}"
        if ! json_exec tag_used "$CONF_FILE" "$_cand" 2>/dev/null; then
            echo "$_cand"
            return 0
        fi
        _n=$((_n + 1))
    done
    echo "${_prefix}-$$"
}

# 解析一行 14 列数据到 SEL_* 变量（关闭 glob 防止 ? 或 * 触发路径展开）
parse_node_row() {
    _old_ifs="$IFS"
    set -f
    IFS='|'
    set -- $1
    IFS="$_old_ifs"
    set +f
    SEL_IDX="$1"
    SEL_TAG="$2"
    SEL_PROTO="$3"
    SEL_PORT="$4"
    SEL_NET="$5"
    SEL_SEC="$6"
    SEL_WSPATH="$7"
    SEL_CRED="$8"
    SEL_FLOW="$9"
    shift 9
    SEL_SNI="$1"
    SEL_PRIV="$2"
    SEL_SID="$3"
    SEL_CLIENTS="$4"
    SEL_OBFS="$5"
}

node_summary_line() {
    _no="$1"
    parse_node_row "$2"
    _dtag="${SEL_TAG:-(默认无tag)}"
    if [ "$SEL_PROTO" = "hysteria2" ]; then
        _obfs_tag=$([ -n "$SEL_OBFS" ] && echo " | 混淆:salamander" || echo "")
        printf " [%d] %-16s | Hysteria2     | UDP:%-5s | 自签TLS%s\n" "$_no" "$_dtag" "$SEL_PORT" "$_obfs_tag"
    elif [ "$SEL_PROTO" = "vless" ] && [ "$SEL_NET" = "ws" ]; then
        _tlabel=$([ "$SEL_SEC" = "tls" ] && echo "TLS" || echo "明文")
        printf " [%d] %-16s | VLESS+WS      | TCP:%-5s | 路径:%s | %s\n" "$_no" "$_dtag" "$SEL_PORT" "$SEL_WSPATH" "$_tlabel"
    elif [ "$SEL_PROTO" = "vless" ] && [ "$SEL_SEC" = "reality" ]; then
        printf " [%d] %-16s | VLESS+Reality | TCP:%-5s | SNI:%s\n" "$_no" "$_dtag" "$SEL_PORT" "${SEL_SNI:-未设置}"
    else
        printf " [%d] %-16s | %-13s | 端口:%-5s | %s/%s\n" "$_no" "$_dtag" "$SEL_PROTO" "$SEL_PORT" "${SEL_NET:--}" "${SEL_SEC:--}"
    fi
}

list_nodes_brief() {
    [ -f "$CONF_FILE" ] || { echo " (暂无配置文件)"; return 1; }
    _rows=$(json_exec list "$CONF_FILE" 2>/dev/null || true)
    if [ -z "$_rows" ]; then
        echo " (当前未配置任何业务入站节点，可选择新增节点)"
        return 1
    fi
    _n=0
    printf '%s\n' "$_rows" | while IFS= read -r _row; do
        [ -n "$_row" ] || continue
        _n=$((_n + 1))
        node_summary_line "$_n" "$_row"
    done
    return 0
}

# 交互式选择节点，filter: all | ws；选中后填充 SEL_* 变量
pick_node() {
    _filter="${1:-all}"
    _rows=$(json_exec list "$CONF_FILE" 2>/dev/null || true)
    [ -n "$_rows" ] || { warn "⚠️ 当前没有任何业务节点。"; return 1; }

    _matched=""
    _n=0
    _ifs_old="$IFS"
    set -f
    IFS='
'
    for _row in $_rows; do
        [ -n "$_row" ] || continue
        parse_node_row "$_row"
        if [ "$_filter" = "ws" ]; then
            [ "$SEL_PROTO" = "vless" ] && [ "$SEL_NET" = "ws" ] && [ "$SEL_SEC" != "reality" ] || continue
        fi
        _n=$((_n + 1))
        node_summary_line "$_n" "$_row"
        _matched="${_matched}${_row}
"
    done
    IFS="$_ifs_old"
    set +f

    if [ "$_n" -eq 0 ]; then
        warn "⚠️ 没有符合条件的节点。"
        return 1
    fi

    if [ "$_n" -eq 1 ]; then
        _pick=1
    else
        ask "请选择节点序号 [1-${_n}] (0 取消): "
        _pick="$REPLY"
        [ "$_pick" = "0" ] || [ -z "$_pick" ] && return 1
    fi
    case "$_pick" in ''|*[!0-9]*) err "❌ 输入无效"; return 1 ;; esac
    [ "$_pick" -ge 1 ] && [ "$_pick" -le "$_n" ] || { err "❌ 序号超出范围"; return 1; }

    _chosen=$(printf '%s' "$_matched" | sed -n "${_pick}p")
    [ -n "$_chosen" ] || return 1
    parse_node_row "$_chosen"
    return 0
}

print_node_link() {
    parse_node_row "$1"
    _tag_label="${SEL_TAG:-Node-${SEL_PORT}}"
    if [ -n "$IPV4" ]; then
        _host="$IPV4"
    elif [ -n "$IPV6" ]; then
        _host="[$IPV6]"
    else
        _host="你的公网IP"
    fi

    if [ "$SEL_PROTO" = "hysteria2" ]; then
        _sni="${SEL_SNI:-$(detect_cert_cn "$SEL_WSPATH")}"
        _fp=$(cert_sha256_fp "$SEL_WSPATH" || true)
        _extra=""
        [ -n "$_fp" ] && _extra="${_extra}&pinSHA256=${_fp}"
        [ -n "$SEL_OBFS" ] && _extra="${_extra}&obfs=salamander&obfs-password=${SEL_OBFS}"
        echo "【${_tag_label} | Hysteria2 | UDP端口:${SEL_PORT} | SNI:${_sni}$( [ -n "$SEL_OBFS" ] && echo " | 混淆:salamander" )】"
        echo "  客户端链接: hy2://${SEL_CRED}@${_host}:${SEL_PORT}?sni=${_sni}&insecure=1${_extra}#${_tag_label}"
        [ -n "$_fp" ] && echo "  证书指纹  : $_fp"
        echo "  NAT提示   : 请确保面板已同时放行并映射 UDP ${SEL_PORT}。"
    elif [ "$SEL_PROTO" = "vless" ] && [ "$SEL_NET" = "ws" ]; then
        _encpath=$(printf '%s' "$SEL_WSPATH" | sed 's/\//%2F/g; s/?/%3F/g; s/=/%3D/g; s/&/%26/g')
        echo "【${_tag_label} | VLESS+WS | TCP端口:${SEL_PORT} | 路径:${SEL_WSPATH} | 安全:$( [ "$SEL_SEC" = "tls" ] && echo "TLS" || echo "明文" )】"
        if [ "$SEL_SEC" = "tls" ]; then
            echo "  直连(NAT改映射端口): vless://${SEL_CRED}@${_host}:${SEL_PORT}?encryption=none&security=tls&allowInsecure=1&type=ws&path=${_encpath}#${_tag_label}-Direct-TLS"
        else
            echo "  直连(NAT改映射端口): vless://${SEL_CRED}@${_host}:${SEL_PORT}?encryption=none&security=none&type=ws&path=${_encpath}#${_tag_label}-Direct"
        fi
        echo "  套CF CDN(换你域名) : vless://${SEL_CRED}@你的域名:443?encryption=none&security=tls&sni=你的域名&fp=chrome&type=ws&host=你的域名&path=${_encpath}#${_tag_label}-CF"
        if [ "$SEL_SEC" != "tls" ] && is_tls_port_risk "$SEL_PORT"; then
            warn "  ⚠️ 提示: 当前明文 WS 监听端口为 ${SEL_PORT}，直接套 CF 回源该端口会报 525（请改用 80/8080 等端口或开启 TLS）。"
        fi
    elif [ "$SEL_PROTO" = "vless" ] && [ "$SEL_SEC" = "reality" ]; then
        _pub=$(reality_pubkey_from_priv "$SEL_PRIV" 2>/dev/null || true)
        echo "【${_tag_label} | VLESS+Reality | TCP端口:${SEL_PORT} | SNI:${SEL_SNI}】"
        if [ -n "$_pub" ]; then
            echo "  直连链接: vless://${SEL_CRED}@${_host}:${SEL_PORT}?encryption=none&flow=${SEL_FLOW:-xtls-rprx-vision}&security=reality&sni=${SEL_SNI}&fp=chrome&pbk=${_pub}&sid=${SEL_SID}&type=tcp&headerType=none#${_tag_label}"
            echo "  中转提示: 将链接中的 ${_host}:${SEL_PORT} 替换为 中转机IP:中转端口，其余参数不变。"
        else
            warn "  ⚠️ 未在本地映射表中找到公钥（若是手动导入配置请在 ${KEY_MAP} 补充）。UUID=${SEL_CRED} SID=${SEL_SID}"
        fi
    else
        echo "【${_tag_label} | 协议:${SEL_PROTO} | 端口:${SEL_PORT} | 传输:${SEL_NET}/${SEL_SEC}】"
    fi
    echo ""
}

show_links_menu() {
    [ -n "$IPV4$IPV6" ] || detect_ip
    load_strategy
    _rows=$(json_exec list "$CONF_FILE" 2>/dev/null || true)
    if [ -z "$_rows" ]; then
        warn "⚠️ 当前没有可导出的节点。"
        return 1
    fi

    line
    echo "          sing-box 多入站节点链接 (全局解析: $(strategy_label "$STRATEGY"))"
    line
    _ifs_old="$IFS"
    set -f
    IFS='
'
    for _row in $_rows; do
        [ -n "$_row" ] || continue
        print_node_link "$_row"
    done
    IFS="$_ifs_old"
    set +f
    if [ -n "$WARP_IPV4$WARP_IPV6" ]; then
        echo "提示: 检测到 WARP，已自动绕过 WARP 获取真实公网 IP；直连与中转请直接使用以上链接。"
    fi
    line
}

prompt_unique_port() {
    _default="$1"
    _exclude_idx="${2:-}"
    while true; do
        if [ -n "$_default" ]; then
            ask "监听端口 [1-65535] (回车默认 $_default): "
            _p="${REPLY:-$_default}"
        else
            ask "监听端口 [1-65535]: "
            _p="$REPLY"
        fi
        valid_port "$_p" || { err "❌ 端口不合法: $_p"; continue; }
        if json_exec port_used "$CONF_FILE" "$_p" "$_exclude_idx"; then
            err "❌ 端口 $_p 已被本机另一个入站占用，请换一个端口！"
            continue
        fi
        PICKED_PORT="$_p"
        return 0
    done
}

prompt_unique_tag() {
    _prefix="$1"
    _def=$(next_auto_tag "$_prefix")
    while true; do
        ask "节点名称 tag (字母/数字/_/-，回车默认 $_def): "
        _t="${REPLY:-$_def}"
        valid_tag "$_t" || { err "❌ tag 不合法（仅支持 1-32 位字母/数字/_/-）"; continue; }
        if json_exec tag_used "$CONF_FILE" "$_t"; then
            err "❌ tag '$_t' 已存在，请换一个名称！"
            continue
        fi
        PICKED_TAG="$_t"
        return 0
    done
}

add_hy2_node_flow() {
    _interactive="${1:-1}"
    if [ "$_interactive" = "1" ]; then
        prompt_unique_tag "hy2" || return 1
        prompt_unique_port "" || return 1
        ask "认证密码 (回车随机生成): "
        _pw="${REPLY:-$(gen_rand_pass)}"
        ask "自签伪装域名 SNI (回车默认 deb.debian.org): "
        _sni="${REPLY:-deb.debian.org}"
        valid_domain "$_sni" || { err "❌ 域名格式不合法: $_sni"; return 1; }
        _obfs=""
        if confirm "是否开启 salamander 混淆？（绝大多数机主推荐关闭，直接回车跳过）"; then
            ask "请输入混淆密码 (回车随机生成): "
            _obfs="${REPLY:-$(gen_rand_pass)}"
        fi
    else
        PICKED_TAG=$(next_auto_tag "hy2")
        PICKED_PORT="$2"
        _pw="${3:-$(gen_rand_pass)}"
        _sni="${4:-deb.debian.org}"
        _obfs="${5:-}"
        valid_port "$PICKED_PORT" || { err "❌ 端口不合法: $PICKED_PORT"; return 1; }
        if json_exec port_used "$CONF_FILE" "$PICKED_PORT"; then
            err "❌ 端口 $PICKED_PORT 已被占用"
            return 1
        fi
    fi

    _crt="${CERT_DIR}/${PICKED_TAG}.crt"
    _key="${CERT_DIR}/${PICKED_TAG}.key"
    ensure_self_signed_cert "$_sni" "$_crt" "$_key" || { err "❌ 生成自签证书失败"; return 1; }

    _tmp="$CONF_DIR/config.patch.json"
    rm -f "$_tmp"
    json_exec add_hy2 "$CONF_FILE" "$PICKED_TAG" "$PICKED_PORT" "$_pw" "$_crt" "$_key" "$_obfs" "$_tmp" || { rm -f "$_tmp"; return 1; }

    if safe_apply_patch "$_tmp"; then
        sync_compat_env
        restart_and_check
        info "✅ 已新增 Hysteria2 节点: $PICKED_TAG (UDP端口: $PICKED_PORT, SNI: $_sni)"
        if [ "$_interactive" = "1" ]; then
            _new_row=$(json_exec list "$CONF_FILE" | awk -F'|' -v t="$PICKED_TAG" '$2==t{print; exit}')
            [ -n "$_new_row" ] && { line; print_node_link "$_new_row"; line; }
        fi
        return 0
    fi
    return 1
}

add_ws_node_flow() {
    _interactive="${1:-1}"
    if [ "$_interactive" = "1" ]; then
        prompt_unique_tag "vless-ws" || return 1
        prompt_unique_port "80" || return 1
        ask "WS 路径 (回车默认 /ws?ed=2048): "
        _wspath="${REPLY:-/ws?ed=2048}"
        valid_path "$_wspath" || { err "❌ WS 路径不合法"; return 1; }
    else
        PICKED_TAG=$(next_auto_tag "vless-ws")
        PICKED_PORT="$2"
        _wspath="$3"
        valid_port "$PICKED_PORT" || { err "❌ 端口不合法: $PICKED_PORT"; return 1; }
        valid_path "$_wspath" || { err "❌ WS 路径不合法: $_wspath"; return 1; }
        if json_exec port_used "$CONF_FILE" "$PICKED_PORT"; then
            err "❌ 端口 $PICKED_PORT 已被占用"
            return 1
        fi
    fi

    _uuid=$(gen_uuid)
    _tmp="$CONF_DIR/config.patch.json"
    rm -f "$_tmp"
    json_exec add_ws "$CONF_FILE" "$PICKED_TAG" "$PICKED_PORT" "$_wspath" "$_uuid" "$_tmp" || { rm -f "$_tmp"; return 1; }

    if safe_apply_patch "$_tmp"; then
        sync_compat_env
        info "✅ 已新增 VLESS+WS 节点: $PICKED_TAG (TCP端口: $PICKED_PORT, 路径: $_wspath)"
        if [ "$_interactive" = "1" ]; then
            if confirm "是否为刚创建的 $PICKED_TAG 注入 Cloudflare Origin TLS 证书？（套 CF Full/Full strict 推荐）"; then
                _row=$(json_exec list "$CONF_FILE" | awk -F'|' -v t="$PICKED_TAG" '$2==t{print; exit}')
                if [ -n "$_row" ]; then
                    parse_node_row "$_row"
                    run_tls_setup_for_idx "$SEL_IDX" "$PICKED_TAG" || true
                fi
            elif is_tls_port_risk "$PICKED_PORT"; then
                warn "⚠️ 注意: $PICKED_TAG 监听 ${PICKED_PORT} 且未开 TLS，若直接套 CF 回源该端口会报 525。"
            fi
            restart_and_check
            _new_row=$(json_exec list "$CONF_FILE" | awk -F'|' -v t="$PICKED_TAG" '$2==t{print; exit}')
            [ -n "$_new_row" ] && { line; print_node_link "$_new_row"; line; }
        fi
        return 0
    fi
    return 1
}

add_reality_node_flow() {
    _interactive="${1:-1}"
    if [ "$_interactive" = "1" ]; then
        prompt_unique_tag "vless-reality" || return 1
        prompt_unique_port "" || return 1
        select_reality_sni || { warn "已取消创建 Reality 节点"; return 1; }
    else
        PICKED_TAG=$(next_auto_tag "vless-reality")
        PICKED_PORT="$2"
        valid_port "$PICKED_PORT" || { err "❌ 端口不合法: $PICKED_PORT"; return 1; }
        if json_exec port_used "$CONF_FILE" "$PICKED_PORT"; then
            err "❌ 端口 $PICKED_PORT 已被占用"
            return 1
        fi
        if [ -n "${3:-}" ]; then
            SELECTED_SNI="$3"
        else
            pick_best_sni >/dev/null 2>&1 || true
            SELECTED_SNI="${BEST_SNI:-mmrrc.ucdavis.edu}"
        fi
    fi

    _uuid=$(gen_uuid)
    _pair=$(gen_x25519_pair) || { err "❌ Reality x25519 密钥生成失败"; return 1; }
    _priv="${_pair%%|*}"
    _pub="${_pair#*|}"
    [ -n "$_priv" ] && [ -n "$_pub" ] || { err "❌ Reality 密钥解析失败"; return 1; }
    _sid=$(printf '%s' "$_uuid" | tr -d '-' | cut -c1-8)

    _tmp="$CONF_DIR/config.patch.json"
    rm -f "$_tmp"
    json_exec add_reality "$CONF_FILE" "$PICKED_TAG" "$PICKED_PORT" "$SELECTED_SNI" "$_uuid" "$_priv" "$_sid" "$_tmp" || { rm -f "$_tmp"; return 1; }

    if safe_apply_patch "$_tmp"; then
        sync_compat_env
        restart_and_check
        info "✅ 已新增 VLESS+Reality 节点: $PICKED_TAG (TCP端口: $PICKED_PORT, SNI: $SELECTED_SNI)"
        if [ "$_interactive" = "1" ]; then
            _new_row=$(json_exec list "$CONF_FILE" | awk -F'|' -v t="$PICKED_TAG" '$2==t{print; exit}')
            [ -n "$_new_row" ] && { line; print_node_link "$_new_row"; line; }
        fi
        return 0
    fi
    return 1
}

menu_add_node() {
    menu_title "新增入站节点"
    menu_option 1 "Hysteria2  ·  UDP 传输，默认关闭混淆"
    menu_option 2 "VLESS + WS  ·  可接 Cloudflare CDN / Origin TLS"
    menu_option 3 "VLESS + Reality  ·  TCP Vision"
    menu_option 0 "返回"
    ask "请选择节点类型 [0-3]: "
    case "$REPLY" in
        1) add_hy2_node_flow 1 ;;
        2) add_ws_node_flow 1 ;;
        3) add_reality_node_flow 1 ;;
        *) return 0 ;;
    esac
    pause
}

menu_modify_node() {
    menu_title "选择要修改的节点"
    pick_node all || { pause; return 0; }

    _idx="$SEL_IDX"
    _tag="$SEL_TAG"
    _proto="$SEL_PROTO"
    _net="$SEL_NET"
    _sec="$SEL_SEC"
    _clients="$SEL_CLIENTS"
    _crt_old="$SEL_WSPATH"

    menu_title "${_tag:-默认节点} · ${_proto} · 端口 ${SEL_PORT}"
    menu_option 1 "修改监听端口"
    if [ "$_proto" = "hysteria2" ]; then
        menu_option 2 "更换连接密码（单用户安全模式）"
        menu_option 3 "重签自签证书 / 换伪装域名"
        menu_option 4 "开启或关闭 salamander 混淆"
    elif [ "$_sec" = "reality" ]; then
        menu_option 2 "修改 / 重测 Reality SNI"
        menu_option 3 "更换 UUID（单用户安全模式）"
        menu_option 4 "重新生成 Reality 密钥对与 ShortId"
    else
        menu_option 2 "修改 WS 路径"
        menu_option 3 "更换 UUID（单用户安全模式）"
    fi
    menu_option 0 "返回"
    ask "请选择操作: "
    _act="$REPLY"
    _tmp="$CONF_DIR/config.patch.json"
    rm -f "$_tmp"

    case "$_act" in
        1)
            prompt_unique_port "" "$_idx" || { pause; return 0; }
            json_exec patch "$CONF_FILE" "$_idx" "port" "$PICKED_PORT" "$_tmp"
            ;;
        2)
            if [ "$_proto" = "hysteria2" ]; then
                [ "${_clients:-0}" -le 1 ] || { err "❌ 安全保护: 包含 $_clients 个用户，请手动编辑 $CONF_FILE"; pause; return 0; }
                ask "输入新密码（回车随机生成）: "
                _npw="${REPLY:-$(gen_rand_pass)}"
                json_exec patch "$CONF_FILE" "$_idx" "password" "$_npw" "$_tmp"
            elif [ "$_sec" = "reality" ]; then
                select_reality_sni || { pause; return 0; }
                json_exec patch "$CONF_FILE" "$_idx" "sni" "$SELECTED_SNI" "$_tmp"
            else
                ask "新 WS 路径 (以 / 开头，如 /ws?ed=2048): "
                valid_path "$REPLY" || { err "❌ 路径不合法"; pause; return 0; }
                json_exec patch "$CONF_FILE" "$_idx" "wspath" "$REPLY" "$_tmp"
            fi
            ;;
        3)
            if [ "$_proto" = "hysteria2" ]; then
                ask "新自签伪装域名 SNI (回车默认 deb.debian.org): "
                _nsni="${REPLY:-deb.debian.org}"
                valid_domain "$_nsni" || { err "❌ 域名不合法"; pause; return 0; }
                _ncrt="${CERT_DIR}/${_tag:-hy2-${SEL_PORT}}.crt"
                _nkey="${CERT_DIR}/${_tag:-hy2-${SEL_PORT}}.key"
                ensure_self_signed_cert "$_nsni" "$_ncrt" "$_nkey" || { err "❌ 生成证书失败"; pause; return 0; }
                json_exec patch "$CONF_FILE" "$_idx" "hy2_cert" "${_ncrt}|${_nkey}" "$_tmp"
            else
                [ "${_clients:-0}" -le 1 ] || { err "❌ 安全保护: 包含 $_clients 个用户，请手动编辑 $CONF_FILE"; pause; return 0; }
                ask "输入新 UUID（回车随机生成）: "
                if [ -z "$REPLY" ]; then
                    _newu=$(gen_uuid)
                elif valid_uuid "$REPLY"; then
                    _newu="$REPLY"
                else
                    err "❌ UUID 格式不正确"; pause; return 0
                fi
                json_exec patch "$CONF_FILE" "$_idx" "uuid" "$_newu" "$_tmp"
            fi
            ;;
        4)
            if [ "$_proto" = "hysteria2" ]; then
                if confirm "是否启用 salamander 混淆？（选 N 将直接关闭混淆）"; then
                    ask "请输入混淆密码（回车随机生成）: "
                    _nobfs="${REPLY:-$(gen_rand_pass)}"
                else
                    _nobfs=""
                fi
                json_exec patch "$CONF_FILE" "$_idx" "hy2_obfs" "$_nobfs" "$_tmp"
            elif [ "$_sec" = "reality" ]; then
                _pair=$(gen_x25519_pair) || { err "❌ 密钥生成失败"; pause; return 0; }
                _priv="${_pair%%|*}"
                _sid=$(gen_uuid | tr -d '-' | cut -c1-8)
                json_exec patch "$CONF_FILE" "$_idx" "reality_keys" "${_priv}|${_sid}" "$_tmp"
            else
                return 0
            fi
            ;;
        *)
            return 0
            ;;
    esac

    if safe_apply_patch "$_tmp"; then
        sync_compat_env
        restart_and_check
        _updated=$(json_exec get "$CONF_FILE" "$_idx" 2>/dev/null || true)
        [ -n "$_updated" ] && { line; print_node_link "$_updated"; line; }
    fi
    pause
}

menu_delete_node() {
    menu_title "选择要删除的节点"
    pick_node all || { pause; return 0; }

    _dtag="${SEL_TAG:-默认节点}"
    warn "⚠️ 即将删除节点: $_dtag (端口: $SEL_PORT)"
    confirm "确认删除该入站？" || { pause; return 0; }

    _tmp="$CONF_DIR/config.patch.json"
    rm -f "$_tmp"
    json_exec delete "$CONF_FILE" "$SEL_IDX" "$_tmp" || { rm -f "$_tmp"; pause; return 0; }

    if safe_apply_patch "$_tmp"; then
        sync_compat_env
        restart_and_check
        info "✅ 已删除节点: $_dtag"
    fi
    pause
}

# === [module: 50_tls_warp_cf.sh] ===
# ------------------------------------------------------------------------------
# 解析策略、age 加密内置 Cloudflare Origin TLS 注入与 Cloudflare 测速
# ------------------------------------------------------------------------------
menu_strategy() {
    load_strategy
    _sbox_warp_v6=""
    if command -v warp_sbox_ipv6_exit >/dev/null 2>&1; then
        _sbox_warp_v6=$(warp_sbox_ipv6_exit 2>/dev/null || true)
    fi
    _eff_v6="${_sbox_warp_v6:-${WARP_IPV6:-$IPV6}}"
    _v6_note=""
    if [ -n "$_sbox_warp_v6" ]; then
        _v6_note="（由 sbox-warp 提供）"
    elif [ -n "$WARP_IPV6" ] && [ -z "$IPV6" ]; then
        _v6_note="（由 WARP 提供）"
    fi
    menu_title "DNS 解析策略"
    printf '  当前策略 %s\n' "$(strategy_label "$STRATEGY")"
    printf '  可用 IPv6 %s\n' "${_eff_v6:-未检测到}${_v6_note}"
    menu_option 1 "系统默认 · AsIs"
    menu_option 2 "IPv6 优先 · UseIPv6v4"
    menu_option 3 "IPv4 优先 · UseIPv4v6"
    menu_option 4 "仅 IPv6 · UseIPv6"
    menu_option 5 "仅 IPv4 · UseIPv4"
    menu_option 0 "返回"
    ask "请选择 [0-5]: "
    case "$REPLY" in
        1) _new="AsIs" ;;
        2) _new="UseIPv6v4" ;;
        3) _new="UseIPv4v6" ;;
        4) _new="UseIPv6" ;;
        5) _new="UseIPv4" ;;
        *) return 0 ;;
    esac
    case "$_new" in
        UseIPv6v4|UseIPv6)
            if [ -z "$_eff_v6" ]; then
                detect_ip
                if command -v warp_sbox_ipv6_exit >/dev/null 2>&1; then
                    _sbox_warp_v6=$(warp_sbox_ipv6_exit 2>/dev/null || true)
                fi
                _eff_v6="${_sbox_warp_v6:-${WARP_IPV6:-$IPV6}}"
            fi
            if [ -z "$_eff_v6" ]; then
                warn "⚠️ 当前未检测到可用的 IPv6 出口，开启后访问有 IPv6 的网站可能失败。"
                confirm "仍然要切换吗？" || return 0
            fi
            ;;
    esac
    _old="$STRATEGY"
    _tmp="$CONF_DIR/config.patch.json"
    rm -f "$_tmp"
    json_exec patch_strategy "$CONF_FILE" "$_new" "$_tmp" || { rm -f "$_tmp"; pause; return 1; }
    if safe_apply_patch "$_tmp"; then
        sync_compat_env
        restart_and_check
        info "✅ 解析策略: $(strategy_label "$_old") -> $(strategy_label "$STRATEGY")"
    fi
    pause
}

has_embedded_origin_age() {
    command -v write_embedded_origin_age >/dev/null 2>&1
}

ensure_age_bin() {
    command -v age >/dev/null 2>&1 && return 0
    info "🔐 首次使用内置加密证书功能，正在准备解密工具 age..."
    case "$OS_TYPE" in
        alpine)
            apk add --no-cache age >/dev/null 2>&1 || true
            ;;
        debian|ubuntu)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq --no-install-recommends age >/dev/null 2>&1 || true
            ;;
    esac
    command -v age >/dev/null 2>&1 && return 0

    case "$(uname -m)" in
        x86_64|amd64)  _aarch="amd64" ;;
        aarch64|arm64) _aarch="arm64" ;;
        *) err "❌ 不支持的系统架构: $(uname -m)，无法自动下载 age"; return 1 ;;
    esac
    _atmp="/tmp/.sbox-age-dl.$$"
    rm -rf "$_atmp"
    mkdir -p "$_atmp"

    _aver=""
    _eff=$(curl -fsSLI -o /dev/null -w '%{url_effective}' --max-time 10 "${GH_PROXY}https://github.com/FiloSottile/age/releases/latest" 2>/dev/null || true)
    _aver=$(printf '%s' "$_eff" | sed -n 's|.*/tag/\(v[^/?#]*\).*|\1|p')
    if [ -n "$_aver" ]; then
        _aurl="${GH_PROXY}https://github.com/FiloSottile/age/releases/download/${_aver}/age-${_aver}-linux-${_aarch}.tar.gz"
    else
        _aurl="https://dl.filippo.io/age/latest?for=linux/${_aarch}"
    fi
    info "⬇️  下载 age (${_aarch}): $_aurl"
    if ! curl -fL --retry 2 --max-time 30 -o "$_atmp/age.tar.gz" "$_aurl"; then
        rm -rf "$_atmp"
        err "❌ age 下载失败（可设置 GH_PROXY 加速前缀后重试）"
        return 1
    fi
    if ! tar -xzf "$_atmp/age.tar.gz" -C "$_atmp"; then
        rm -rf "$_atmp"
        err "❌ age 解压失败"
        return 1
    fi
    _abin=$(find "$_atmp" -type f -name age | head -n1)
    if [ -n "$_abin" ] && chmod +x "$_abin" && "$_abin" --version >/dev/null 2>&1; then
        cp -f "$_abin" /usr/local/bin/age && chmod +x /usr/local/bin/age
        rm -rf "$_atmp"
        info "✅ age 已就绪: $(/usr/local/bin/age --version 2>/dev/null || echo ok)"
        return 0
    fi
    rm -rf "$_atmp"
    err "❌ 获取的 age 二进制无法运行"
    return 1
}

_age_decrypt_with_passphrase() {
    _out_file="$1"
    _in_file="$2"
    _pw="$3"

    if command -v python3 >/dev/null 2>&1 && python3 -c 'import pty, select' >/dev/null 2>&1; then
        _SBOX_AGE_PW="$_pw" python3 - "$_out_file" "$_in_file" <<'__SBOX_AGE_PY_EOF__'
import os, pty, select, signal, sys, time

out_f, in_f = sys.argv[1], sys.argv[2]
pw = os.environ.get("_SBOX_AGE_PW", "")
pid, master = pty.fork()
if pid == 0:
    os.execvp("age", ["age", "-d", "-o", out_f, in_f])

buf = b""
sent = 0
timed_out = False
deadline = time.monotonic() + 20.0
while time.monotonic() < deadline:
    r, _, _ = select.select([master], [], [], 0.5)
    if not r:
        continue
    try:
        chunk = os.read(master, 4096)
    except OSError:
        break
    if not chunk:
        break
    buf += chunk
    if sent == 0 and b"passphrase" in buf.lower() and buf.rstrip().endswith(b":"):
        time.sleep(0.03)
        os.write(master, (pw + "\n").encode("utf-8"))
        buf = b""
        sent = 1
else:
    timed_out = True

try:
    os.close(master)
except OSError:
    pass
if timed_out:
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        pass
_, st = os.waitpid(pid, 0)
if timed_out:
    sys.stderr.write("age: decrypt timed out\n")
    sys.exit(124)
rc = os.waitstatus_to_exitcode(st) if hasattr(os, "waitstatus_to_exitcode") else (0 if st == 0 else (((st >> 8) & 0xff) or 1))
if rc != 0:
    msg = buf.decode("utf-8", "replace").strip()
    if msg:
        sys.stderr.write(msg + "\n")
    elif rc < 0 or rc == 137:
        sys.stderr.write(f"age: terminated by signal (rc={rc}, possibly OOM)\n")
sys.exit(rc)
__SBOX_AGE_PY_EOF__
        _rc=$?
        unset _SBOX_AGE_PW 2>/dev/null || true
        return $_rc
    fi

    if ! command -v expect >/dev/null 2>&1; then
        info "📦 正在准备交互辅助工具 expect..."
        install_pkg expect >/dev/null 2>&1 || true
    fi
    if command -v expect >/dev/null 2>&1; then
        _SBOX_AGE_PW="$_pw" expect -f - "$_out_file" "$_in_file" <<'__SBOX_AGE_EXP_EOF__'
log_user 0
set timeout 20
set pw $env(_SBOX_AGE_PW)
set out [lindex $argv 0]
set in  [lindex $argv 1]
spawn -noecho age -d -o $out $in
set sent 0
expect {
    -re {[Pp]assphrase.*:} {
        if {$sent == 0} {
            send -- "$pw\r"
            set sent 1
            exp_continue
        }
    }
    eof
    timeout {
        catch { close -i $spawn_id }
        exit 124
    }
}
set res [wait]
if {[llength $res] >= 4 && [lindex $res 2] == 0} {
    exit [lindex $res 3]
}
exit 1
__SBOX_AGE_EXP_EOF__
        _rc=$?
        unset _SBOX_AGE_PW 2>/dev/null || true
        return $_rc
    fi

    warn "⚠️ 未检测到 python3 或 expect，回退为原生隐藏输入模式。"
    age -d -o "$_out_file" "$_in_file"
}

decrypt_embedded_origin_cert() {
    if ! has_embedded_origin_age; then
        err "❌ 当前脚本副本尚未经 GitHub Actions 注入加密证书密文。"
        warn "   请先在仓库 Settings -> Secrets 配置 ORIGIN_CERT / ORIGIN_KEY / AGE_PASSPHRASE 并运行构建工作流，或改选方式 2 手动指定证书文件。"
        return 1
    fi
    ensure_age_bin || return 1
    ensure_openssl || return 1

    _age_file="/tmp/.sbox-origin.$$.age"
    _plain_file="/tmp/.sbox-origin.$$.plain"
    _crt_tmp="/tmp/.sbox-origin.$$.crt"
    _key_tmp="/tmp/.sbox-origin.$$.key"
    rm -f "$_age_file" "$_plain_file" "$_crt_tmp" "$_key_tmp"

    umask 077
    write_embedded_origin_age "$_age_file"
    chmod 600 "$_age_file" 2>/dev/null || true

    _try=1
    while [ "$_try" -le 3 ]; do
        info "🔑 请输入内置 Cloudflare Origin 证书解锁密码（第 ${_try}/3 次，输入内容直接可见）："
        ask "Enter passphrase: "
        _age_pw=$(printf '%s' "$REPLY" | tr -d '\r')
        REPLY=""
        if [ -z "$_age_pw" ]; then
            warn "⚠️ 密码不能为空。"
        elif _age_decrypt_with_passphrase "$_plain_file" "$_age_file" "$_age_pw"; then
            _age_pw=""
            _dom=$(awk -F= '/^DOMAIN=/{print $2; exit}' "$_plain_file" | tr -d ' \r\n')
            awk '/^---CERT---$/{f=1;next}/^---KEY---$/{f=0}f' "$_plain_file" > "$_crt_tmp"
            awk '/^---KEY---$/{f=1;next}f' "$_plain_file" > "$_key_tmp"
            rm -f "$_plain_file"

            if openssl x509 -in "$_crt_tmp" -noout >/dev/null 2>&1 && grep -q 'PRIVATE KEY' "$_key_tmp"; then
                _safe_dom=$(printf '%s' "${_dom:-origin}" | tr -cd 'A-Za-z0-9._-')
                [ -n "$_safe_dom" ] || _safe_dom="origin"
                mkdir -p "$CERT_DIR"
                DEC_DOMAIN="$_safe_dom"
                DEC_CRT="${CERT_DIR}/${_safe_dom}.crt"
                DEC_KEY="${CERT_DIR}/${_safe_dom}.key"
                cp -f "$_crt_tmp" "$DEC_CRT"
                cp -f "$_key_tmp" "$DEC_KEY"
                chmod 644 "$DEC_CRT"
                chmod 600 "$DEC_KEY"
                rm -f "$_age_file" "$_crt_tmp" "$_key_tmp"
                info "✅ 证书解密与完整性校验通过（适用域名: ${DEC_DOMAIN}）"
                return 0
            fi
            rm -f "$_crt_tmp" "$_key_tmp"
            err "❌ 解密后的证书或私钥内容无效。"
            rm -f "$_age_file"
            return 1
        else
            _age_pw=""
            rm -f "$_plain_file"
            warn "⚠️ 解密失败（请检查所输入的密码、大小写及前后是否多出空格）。"
        fi
        [ "$_try" -lt 3 ] && { confirm "是否重新输入密码重试？" || break; }
        _try=$((_try + 1))
    done

    _age_pw=""
    rm -f "$_age_file" "$_plain_file" "$_crt_tmp" "$_key_tmp"
    return 1
}

run_tls_setup_for_idx() {
    _idx="$1"
    _tag="$2"
    menu_title "Cloudflare Origin TLS"
    if has_embedded_origin_age; then
        menu_option 1 "使用内置加密证书（输入密码解锁，适用于 CF Full）"
    else
        menu_option 1 "使用内置证书（当前脚本未内置密文，需经 Actions 构建）"
    fi
    menu_option 2 "指定证书与私钥路径（自有域名 / CF Full strict）"
    menu_option 0 "取消"
    ask "请选择证书方式 [0-2]: "
    _crt_dest=""
    _key_dest=""
    case "$REPLY" in
        1)
            decrypt_embedded_origin_cert || return 1
            _crt_dest="$DEC_CRT"
            _key_dest="$DEC_KEY"
            ;;
        2)
            ask "请输入证书路径 (.crt/.pem): "
            _crt="$REPLY"
            ask "请输入私钥路径 (.key): "
            _key="$REPLY"
            if [ ! -f "$_crt" ] || [ ! -f "$_key" ]; then
                err "❌ 证书或私钥文件不存在: $_crt / $_key"
                return 1
            fi
            mkdir -p "$CERT_DIR"
            _crt_dest="${CERT_DIR}/custom-${_tag:-ws}.crt"
            _key_dest="${CERT_DIR}/custom-${_tag:-ws}.key"
            cp -f "$_crt" "$_crt_dest"
            cp -f "$_key" "$_key_dest"
            chmod 644 "$_crt_dest"
            chmod 600 "$_key_dest"
            ;;
        *)
            return 0
            ;;
    esac

    _tmp="$CONF_DIR/config.patch.json"
    rm -f "$_tmp"
    json_exec patch "$CONF_FILE" "$_idx" "ws_tls" "${_crt_dest}|${_key_dest}" "$_tmp" || { rm -f "$_tmp"; return 1; }
    if safe_apply_patch "$_tmp"; then
        sync_compat_env
        info "✨ 已为 ${_tag:-WS节点} 注入 TLS 证书（CF SSL/TLS 请开启 Full 或 Full strict）"
        return 0
    fi
    return 1
}

menu_tls_setup() {
    line
    echo " 选择要注入 Cloudflare Origin TLS 证书的 VLESS+WS 节点："
    echo " （已自动过滤 Hysteria2 与 Reality 入站，绝不误伤）"
    line
    pick_node ws || { pause; return 0; }
    if run_tls_setup_for_idx "$SEL_IDX" "$SEL_TAG"; then
        restart_and_check
    fi
    pause
}

_cf_speed_run_stack() {
    _flag="$1"
    _label="$2"
    _ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
    _ref="https://speed.cloudflare.com/"

    info "▶ [$_label] 正在测试 100MB 下载..."
    _dl=$(curl $_flag -s --max-time 60 -o /dev/null -A "$_ua" -e "$_ref" \
        -w '%{http_code} %{time_total} %{speed_download}' \
        'https://speed.cloudflare.com/__down?bytes=104857600')
    echo "$_dl" | awk '{
        if ($1 == "200")
            printf "  下载(100MB) -> 状态:%s | 耗时:%.2fs | 平均:%.2f MB/s (%.2f Mbps)\n", $1, $2, $3/1048576, $3*8/1048576
        else
            printf "  下载失败    -> 状态:%s | 耗时:%.2fs (如遇 403/拦截可改测兜底源)\n", ($1==""?"超时":$1), $2+0
    }'

    info "▶ [$_label] 正在测试 50MB 上传..."
    _ul=$(head -c 52428800 /dev/zero | curl $_flag -s --max-time 60 -X POST -o /dev/null -A "$_ua" -e "$_ref" \
        -w '%{http_code} %{time_total} %{speed_upload}' \
        --data-binary @- 'https://speed.cloudflare.com/__up')
    echo "$_ul" | awk '{
        if ($1 == "200")
            printf "  上传(50MB)  -> 状态:%s | 耗时:%.2fs | 平均:%.2f MB/s (%.2f Mbps)\n", $1, $2, $3/1048576, $3*8/1048576
        else
            printf "  上传失败    -> 状态:%s | 耗时:%.2fs\n", ($1==""?"超时":$1), $2+0
    }'
}

cf_speedtest() {
    command -v curl >/dev/null 2>&1 || { err "❌ 未安装 curl"; return 1; }
    [ -n "${IPV4}${IPV6}${WARP_IPV4}${WARP_IPV6}" ] || detect_ip
    _out4="${WARP_IPV4:-$IPV4}"
    _out6="${WARP_IPV6:-$IPV6}"
    line
    echo "   Cloudflare 测速 (默认 100MB 下载 + 50MB 上传，约消耗 150MB 流量)"
    line
    if [ -n "$_out4" ] && [ -n "$_out6" ]; then
        echo " 检测到双栈出口 (IPv4: $_out4 | IPv6: $_out6)"
        menu_title "选择测速协议"
        menu_option 1 "仅测 IPv4（默认）"
        menu_option 2 "仅测 IPv6"
        menu_option 3 "IPv4 与 IPv6 都测"
        menu_option 0 "返回"
        ask "请选择 [0-3] (回车默认 1): "
        case "${REPLY:-1}" in
            1) _cf_speed_run_stack "-4" "IPv4" ;;
            2) _cf_speed_run_stack "-6" "IPv6" ;;
            3) _cf_speed_run_stack "-4" "IPv4"; echo ""; _cf_speed_run_stack "-6" "IPv6" ;;
            *) return 0 ;;
        esac
    elif [ -n "$_out6" ]; then
        _cf_speed_run_stack "-6" "IPv6"
    else
        _cf_speed_run_stack "-4" "IPv4"
    fi
}

# === [module: 55_warp_kernel.sh] ===
# ------------------------------------------------------------------------------
# 内核态 WireGuard WARP、多出口容灾、保活与服务管理
# ------------------------------------------------------------------------------

WARP_DIR="${CONF_DIR}/warp"
WARP_FILE="${WARP_DIR}/accounts.json"
WARP_ROUTE_BACKUP="${WARP_DIR}/route-final.before-warp"
WARP_FALLBACK_STATE="${WARP_DIR}/fallback.state"
WARP_PAUSE_FLAG="${WARP_DIR}/paused"
WARP_FALLBACK_DIRECT="${WARP_FALLBACK_DIRECT:-1}"
WARP_LOG="/var/log/sbox-warp.log"
WARP_LOCK_DIR="${WARP_DIR}/.lock"
WARP_PEER_KEY="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
WARP_POOL="162.159.192.1:2408 162.159.195.1:2408 188.114.96.1:2408 188.114.97.1:2408"
WARP_CHECK_URL="https://www.cloudflare.com/cdn-cgi/trace"
WARP_INTERVAL="180"
WARP_EXIT_IP_CACHE_AT=0
WARP_EXIT_IP_CACHE=""

warp_log() {
    _warp_message="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    if [ -t 1 ]; then
        printf '%s\n' "$_warp_message"
    fi
    mkdir -p "$(dirname "$WARP_LOG")" 2>/dev/null || true
    printf '%s\n' "$_warp_message" >> "$WARP_LOG" 2>/dev/null || true
    if [ -f "$WARP_LOG" ] && [ "$(wc -l < "$WARP_LOG")" -gt 250 ]; then
        tail -n 200 "$WARP_LOG" > "${WARP_LOG}.tmp.$$" && mv -f "${WARP_LOG}.tmp.$$" "$WARP_LOG"
    fi
}

warp_prepare_store() {
    mkdir -p "$WARP_DIR" || return 1
    chmod 700 "$WARP_DIR" 2>/dev/null || true
    if [ ! -f "$WARP_FILE" ]; then
        printf '[]\n' > "$WARP_FILE" || return 1
    fi
    chmod 600 "$WARP_FILE" 2>/dev/null || true
    jq -e 'type == "array"' "$WARP_FILE" >/dev/null 2>&1
}

ensure_warp_deps() {
    _warp_missing=""
    for _warp_command in curl jq ip wg; do
        command -v "$_warp_command" >/dev/null 2>&1 || _warp_missing="${_warp_missing} $_warp_command"
    done
    [ -z "$_warp_missing" ] && return 0
    case "$OS_TYPE" in
        alpine)
            install_pkg curl ca-certificates jq iproute2 wireguard-tools-wg
            ;;
        debian)
            install_pkg curl ca-certificates jq iproute2 wireguard-tools
            ;;
        *)
            err "❌ 内核态 WARP 仅支持 Alpine、Debian 与 Ubuntu"
            return 1
            ;;
    esac
}

warp_lock() {
    mkdir -p "$WARP_DIR" || return 1
    chmod 700 "$WARP_DIR" 2>/dev/null || true
    if mkdir "$WARP_LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "${WARP_LOCK_DIR}/pid"
        return 0
    fi
    _warp_lock_pid=$(cat "${WARP_LOCK_DIR}/pid" 2>/dev/null || true)
    case "$_warp_lock_pid" in
        ''|*[!0-9]*) ;;
        *)
            if ! kill -0 "$_warp_lock_pid" 2>/dev/null; then
                rm -f "${WARP_LOCK_DIR}/pid"
                rmdir "$WARP_LOCK_DIR" 2>/dev/null || true
                if mkdir "$WARP_LOCK_DIR" 2>/dev/null; then
                    printf '%s\n' "$$" > "${WARP_LOCK_DIR}/pid"
                    return 0
                fi
            fi
            ;;
    esac
    warn "⚠️ WARP 管理任务正在运行，请稍后再试。"
    return 1
}

warp_unlock() {
    _warp_lock_pid=$(cat "${WARP_LOCK_DIR}/pid" 2>/dev/null || true)
    [ "$_warp_lock_pid" = "$$" ] || return 0
    rm -f "${WARP_LOCK_DIR}/pid"
    rmdir "$WARP_LOCK_DIR" 2>/dev/null || true
}

warp_interface_name() {
    printf 'sboxwg%s\n' "$1"
}

warp_route_table() {
    printf '5210%s\n' "$1"
}

warp_initial_endpoint() {
    case "$1" in
        1) printf '%s\n' "${WARP_POOL%% *}" ;;
        2) _warp_rest=${WARP_POOL#* }; printf '%s\n' "${_warp_rest%% *}" ;;
        3) _warp_rest=${WARP_POOL#* }; _warp_rest=${_warp_rest#* }; printf '%s\n' "${_warp_rest%% *}" ;;
    esac
}

warp_next_endpoint() {
    _warp_current="$1"
    _warp_next="${WARP_POOL%% *}"
    _warp_found=0
    for _warp_endpoint in $WARP_POOL; do
        if [ "$_warp_found" = "1" ]; then
            _warp_next="$_warp_endpoint"
            break
        fi
        [ "$_warp_endpoint" = "$_warp_current" ] && _warp_found=1
    done
    printf '%s\n' "$_warp_next"
}

warp_account_json() {
    jq -c --argjson slot "$1" '.[] | select(.slot == $slot)' "$WARP_FILE"
}

warp_account_value() {
    _warp_account=$(warp_account_json "$1") || return 1
    [ -n "$_warp_account" ] || return 1
    printf '%s\n' "$_warp_account" | jq -r "$2"
}

warp_save_account() {
    _warp_slot="$1"
    _warp_replacement="$2"
    _warp_tmp=$(mktemp "${WARP_DIR}/accounts.XXXXXX") || return 1
    chmod 600 "$_warp_tmp" 2>/dev/null || true
    if ! jq --argjson slot "$_warp_slot" --argjson replacement "$_warp_replacement" \
        'map(select(.slot != $slot)) + [$replacement] | sort_by(.slot)' \
        "$WARP_FILE" > "$_warp_tmp"; then
        rm -f "$_warp_tmp"
        return 1
    fi
    chmod 600 "$_warp_tmp" 2>/dev/null || true
    mv -f "$_warp_tmp" "$WARP_FILE"
}

warp_update_account_state() {
    _warp_slot="$1"
    _warp_endpoint="$2"
    _warp_failures="$3"
    _warp_heal_count="$4"
    _warp_next_retry="$5"
    _warp_tmp=$(mktemp "${WARP_DIR}/accounts.XXXXXX") || return 1
    chmod 600 "$_warp_tmp" 2>/dev/null || true
    if ! jq --argjson slot "$_warp_slot" --arg endpoint "$_warp_endpoint" \
        --argjson failures "$_warp_failures" --argjson heals "$_warp_heal_count" \
        --argjson retry "$_warp_next_retry" \
        'map(if .slot == $slot then .endpoint = $endpoint | .failures = $failures | .heal_count = $heals | .next_retry = $retry else . end)' \
        "$WARP_FILE" > "$_warp_tmp"; then
        rm -f "$_warp_tmp"
        return 1
    fi
    chmod 600 "$_warp_tmp" 2>/dev/null || true
    mv -f "$_warp_tmp" "$WARP_FILE"
}

warp_register_account() {
    _warp_slot="$1"
    _warp_attempt=1
    while [ "$_warp_attempt" -le 3 ]; do
        _warp_private=$(wg genkey 2>/dev/null) || return 1
        _warp_public=$(printf '%s\n' "$_warp_private" | wg pubkey 2>/dev/null) || return 1
        _warp_tos=$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')
        _warp_payload=$(jq -nc --arg key "$_warp_public" --arg tos "$_warp_tos" \
            '{key:$key,install_id:"",fcm_token:"",tos:$tos,model:"PC",type:"Android",locale:"en_US"}') || return 1
        _warp_response=$(curl -fsSL --connect-timeout 8 --max-time 20 \
            -X POST 'https://api.cloudflareclient.com/v0a2158/reg' \
            -H 'User-Agent: okhttp/3.12.1' \
            -H 'Content-Type: application/json; charset=UTF-8' \
            -d "$_warp_payload" 2>/dev/null || true)
        _warp_v4=$(printf '%s' "$_warp_response" | jq -r '.config.interface.addresses.v4 // empty' 2>/dev/null || true)
        _warp_v6=$(printf '%s' "$_warp_response" | jq -r '.config.interface.addresses.v6 // empty' 2>/dev/null || true)
        _warp_id=$(printf '%s' "$_warp_response" | jq -r '.id // empty' 2>/dev/null || true)
        _warp_v4=${_warp_v4%%/*}
        _warp_v6=${_warp_v6%%/*}
        if printf '%s' "$_warp_v4" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' &&
            printf '%s' "$_warp_v6" | grep -Eq '^[0-9a-fA-F:]+$'; then
            _warp_account=$(jq -nc --argjson slot "$_warp_slot" --arg id "$_warp_id" \
                --arg private_key "$_warp_private" --arg public_key "$_warp_public" \
                --arg v4 "${_warp_v4}/32" --arg v6 "${_warp_v6}/128" \
                --arg endpoint "$(warp_initial_endpoint "$_warp_slot")" \
                '{slot:$slot,id:$id,private_key:$private_key,public_key:$public_key,v4:$v4,v6:$v6,endpoint:$endpoint,failures:0,heal_count:0,next_retry:0}') || return 1
            printf '%s\n' "$_warp_account"
            return 0
        fi
        _warp_wait=$((_warp_attempt * 4))
        warp_log "槽位 ${_warp_slot} 注册未成功，等待 ${_warp_wait} 秒后重试 (${_warp_attempt}/3)" >&2
        sleep "$_warp_wait"
        _warp_attempt=$((_warp_attempt + 1))
    done
    warp_log "槽位 ${_warp_slot} 注册失败，Cloudflare 未返回有效的双栈地址" >&2
    return 1
}

warp_ensure_accounts() {
    warp_prepare_store || { err "❌ WARP 账号文件损坏或无法读取"; return 1; }
    _warp_slot=1
    while [ "$_warp_slot" -le 3 ]; do
        if [ -z "$(warp_account_json "$_warp_slot" 2>/dev/null)" ]; then
            [ "$_warp_slot" -le 1 ] || sleep 3
            info "正在注册第 $_warp_slot/3 路 Cloudflare WARP 账号..."
            _warp_account=$(warp_register_account "$_warp_slot") || return 1
            warp_save_account "$_warp_slot" "$_warp_account" || return 1
        fi
        _warp_slot=$((_warp_slot + 1))
    done
}

warp_add_policy_rule() {
    _warp_add_family="$1"
    _warp_add_iface="$2"
    _warp_add_table="$3"
    _warp_add_rules=$(ip "-$_warp_add_family" rule show 2>/dev/null) || return 1
    _warp_add_expected_count=$(printf '%s\n' "$_warp_add_rules" | grep -F -c "oif ${_warp_add_iface} lookup ${_warp_add_table}" || true)

    if [ "$_warp_add_expected_count" = "1" ]; then
        return 0
    fi

    if [ "$_warp_add_expected_count" -gt 1 ]; then
        warp_log "发现 sbox 接口 ${_warp_add_iface} 指向表 ${_warp_add_table} 的 IPv${_warp_add_family} 规则重复，正在重建"
        while ip "-$_warp_add_family" rule del oif "$_warp_add_iface" table "$_warp_add_table" 2>/dev/null; do :; done
    else
        warp_log "发现 sbox 接口 ${_warp_add_iface} 缺少指向表 ${_warp_add_table} 的 IPv${_warp_add_family} 策略规则，正在补回"
    fi

    _warp_add_rules=$(ip "-$_warp_add_family" rule show 2>/dev/null) || return 1
    _warp_add_pref=10000
    while [ "$_warp_add_pref" -lt 11000 ]; do
        if ! printf '%s\n' "$_warp_add_rules" | grep -q "^${_warp_add_pref}:"; then
            if ! ip "-$_warp_add_family" rule add pref "$_warp_add_pref" oif "$_warp_add_iface" table "$_warp_add_table"; then
                err "❌ 无法为 ${_warp_add_iface} 添加 IPv${_warp_add_family} 策略规则"
                return 1
            fi
            _warp_topology_changed=1
            _warp_add_expected_count=$(ip "-$_warp_add_family" rule show 2>/dev/null | grep -F -c "oif ${_warp_add_iface} lookup ${_warp_add_table}" || true)
            if [ "$_warp_add_expected_count" = "1" ]; then
                warp_log "已补回 sbox 接口 ${_warp_add_iface} 指向表 ${_warp_add_table} 的 IPv${_warp_add_family} 策略规则"
                return 0
            fi
            err "❌ ${_warp_add_iface} 的 IPv${_warp_add_family} 策略规则核验失败"
            return 1
        fi
        _warp_add_pref=$((_warp_add_pref + 1))
    done
    err "❌ 无法为 ${_warp_add_iface} 找到可用的 IPv${_warp_add_family} 策略路由优先级"
    return 1
}

warp_apply_interface() {
    _warp_slot="$1"
    _warp_endpoint="$2"
    _warp_account="${3:-$(warp_account_json "$_warp_slot")}"
    [ -n "$_warp_account" ] || return 1
    _warp_iface=$(warp_interface_name "$_warp_slot")
    _warp_table=$(warp_route_table "$_warp_slot")
    _warp_private=$(printf '%s\n' "$_warp_account" | jq -r '.private_key')
    _warp_v4=$(printf '%s\n' "$_warp_account" | jq -r '.v4')
    _warp_v6=$(printf '%s\n' "$_warp_account" | jq -r '.v6')

    _warp_v4_routes=$(ip -4 route show table "$_warp_table" 2>/dev/null || true)
    if [ -n "$_warp_v4_routes" ] && ! printf '%s\n' "$_warp_v4_routes" | grep -q "^default dev ${_warp_iface}"; then
        err "❌ 路由表 $_warp_table 已被占用，拒绝覆盖现有路由"
        return 1
    fi
    _warp_v6_routes=$(ip -6 route show table "$_warp_table" 2>/dev/null || true)
    if [ -n "$_warp_v6_routes" ] && ! printf '%s\n' "$_warp_v6_routes" | grep -q "^default dev ${_warp_iface}"; then
        err "❌ IPv6 路由表 $_warp_table 已被占用，拒绝覆盖现有路由"
        return 1
    fi

    if ip link show dev "$_warp_iface" >/dev/null 2>&1; then
        if ! ip -d link show dev "$_warp_iface" 2>/dev/null | grep -q wireguard; then
            err "❌ 网卡名冲突，$_warp_iface 已存在且不是 WireGuard 接口"
            return 1
        fi
    else
        ip link add dev "$_warp_iface" type wireguard || {
            err "❌ 无法创建内核态 WireGuard 接口 $_warp_iface。请确认宿主机内核和 LXC NET_ADMIN 权限"
            return 1
        }
    fi

    _warp_key_file=$(mktemp "${WARP_DIR}/private.XXXXXX") || return 1
    chmod 600 "$_warp_key_file" 2>/dev/null || true
    if ! printf '%s' "$_warp_private" > "$_warp_key_file"; then
        rm -f "$_warp_key_file"
        return 1
    fi
    if ! wg set "$_warp_iface" \
        private-key "$_warp_key_file" \
        fwmark 0xca6c \
        peer "$WARP_PEER_KEY" \
        endpoint "$_warp_endpoint" \
        allowed-ips '0.0.0.0/0,::/0' \
        persistent-keepalive 25; then
        rm -f "$_warp_key_file"
        err "❌ 配置 $_warp_iface 失败"
        return 1
    fi
    rm -f "$_warp_key_file"

    ip -4 address replace "$_warp_v4" dev "$_warp_iface" || return 1
    ip link set mtu 1280 up dev "$_warp_iface" || return 1
    ip -4 route replace default dev "$_warp_iface" table "$_warp_table" || return 1
    warp_add_policy_rule 4 "$_warp_iface" "$_warp_table" || return 1

    if ip -6 address replace "$_warp_v6" dev "$_warp_iface" 2>/dev/null; then
        ip -6 route replace default dev "$_warp_iface" table "$_warp_table" || return 1
        warp_add_policy_rule 6 "$_warp_iface" "$_warp_table" || return 1
    else
        warn "⚠️ $_warp_iface 的 IPv6 未能启用，将继续使用 IPv4 WARP 出口"
    fi
}

warp_probe_interface() {
    _warp_iface="$1"
    for _warp_probe_flag in "" "-4" "-6"; do
        if [ -n "$_warp_probe_flag" ]; then
            _warp_trace=$(curl -fsS "$_warp_probe_flag" --interface "$_warp_iface" --connect-timeout 4 --max-time 9 "$WARP_CHECK_URL" 2>/dev/null || true)
        else
            _warp_trace=$(curl -fsS --interface "$_warp_iface" --connect-timeout 4 --max-time 9 "$WARP_CHECK_URL" 2>/dev/null || true)
        fi
        if printf '%s\n' "$_warp_trace" | grep -Eq '^warp=(on|plus)$'; then
            return 0
        fi
    done
    return 1
}

warp_read_exit_ip() {
    _warp_ip_iface="$1"
    _warp_ip_family="$2"
    _warp_ip_trace=$(curl -fsS "-$_warp_ip_family" --interface "$_warp_ip_iface" \
        --connect-timeout 1 --max-time 3 "$WARP_CHECK_URL" 2>/dev/null) || return 1
    _warp_ip_mode=$(printf '%s\n' "$_warp_ip_trace" | awk -F= '$1 == "warp" { print $2; exit }')
    case "$_warp_ip_mode" in
        on|plus) ;;
        *) return 1 ;;
    esac
    _warp_ip_value=$(printf '%s\n' "$_warp_ip_trace" | awk -F= '$1 == "ip" { print $2; exit }' | tr -d '\r\n')
    [ -n "$_warp_ip_value" ] || return 1
    printf '%s\n' "$_warp_ip_value"
}

warp_collect_channel_exit_ips() (
    [ -s "$WARP_FILE" ] || exit 0
    _warp_ip_tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/sbox-warp-ip.XXXXXX") || exit 1
    trap 'rm -f "$_warp_ip_tmpdir"/*.v4 "$_warp_ip_tmpdir"/*.v6; rmdir "$_warp_ip_tmpdir" 2>/dev/null || true' EXIT

    _warp_ip_slot=1
    while [ "$_warp_ip_slot" -le 3 ]; do
        _warp_ip_iface=$(warp_interface_name "$_warp_ip_slot")
        _warp_ip_account=$(warp_account_json "$_warp_ip_slot" 2>/dev/null || true)
        if [ -z "$_warp_ip_account" ]; then
            printf '未注册\n' > "$_warp_ip_tmpdir/$_warp_ip_slot.v4"
            printf '未注册\n' > "$_warp_ip_tmpdir/$_warp_ip_slot.v6"
        elif ! ip link show dev "$_warp_ip_iface" >/dev/null 2>&1; then
            printf '接口未启动\n' > "$_warp_ip_tmpdir/$_warp_ip_slot.v4"
            printf '接口未启动\n' > "$_warp_ip_tmpdir/$_warp_ip_slot.v6"
        else
            (warp_read_exit_ip "$_warp_ip_iface" 4 || printf '不可达\n') > "$_warp_ip_tmpdir/$_warp_ip_slot.v4" &
            (warp_read_exit_ip "$_warp_ip_iface" 6 || printf '不可达\n') > "$_warp_ip_tmpdir/$_warp_ip_slot.v6" &
        fi
        _warp_ip_slot=$((_warp_ip_slot + 1))
    done
    wait

    _warp_ip_slot=1
    while [ "$_warp_ip_slot" -le 3 ]; do
        _warp_ip_v4=$(cat "$_warp_ip_tmpdir/$_warp_ip_slot.v4" 2>/dev/null || printf '不可达')
        _warp_ip_v6=$(cat "$_warp_ip_tmpdir/$_warp_ip_slot.v6" 2>/dev/null || printf '不可达')
        printf '%s|%s|%s\n' "$_warp_ip_slot" "$_warp_ip_v4" "$_warp_ip_v6"
        _warp_ip_slot=$((_warp_ip_slot + 1))
    done
)

warp_invalidate_exit_ip_cache() {
    WARP_EXIT_IP_CACHE_AT=0
    WARP_EXIT_IP_CACHE=""
}

warp_sbox_ipv6_exit() {
    [ -f "$CONF_FILE" ] || return 1
    _warp_v6_final=$(jq -r '.route.final // ""' "$CONF_FILE" 2>/dev/null || true)
    case "$_warp_v6_final" in
        sbox-warp-auto|sbox-warp-1|sbox-warp-2|sbox-warp-3) ;;
        *) return 1 ;;
    esac

    _warp_v6_now=$(date +%s)
    case "$WARP_EXIT_IP_CACHE_AT" in
        ''|*[!0-9]*) WARP_EXIT_IP_CACHE_AT=0 ;;
    esac
    if [ -z "$WARP_EXIT_IP_CACHE" ] || [ "$WARP_EXIT_IP_CACHE_AT" -eq 0 ] || [ $((_warp_v6_now - WARP_EXIT_IP_CACHE_AT)) -ge 120 ]; then
        WARP_EXIT_IP_CACHE=$(warp_collect_channel_exit_ips 2>/dev/null || true)
        WARP_EXIT_IP_CACHE_AT="$_warp_v6_now"
    fi
    [ -n "$WARP_EXIT_IP_CACHE" ] || return 1

    _warp_v6_pref=""
    case "$_warp_v6_final" in
        sbox-warp-1) _warp_v6_pref=1 ;;
        sbox-warp-2) _warp_v6_pref=2 ;;
        sbox-warp-3) _warp_v6_pref=3 ;;
        sbox-warp-auto) _warp_v6_pref=$(warp_query_active_lane 2>/dev/null || true) ;;
    esac
    if [ -n "$_warp_v6_pref" ]; then
        _warp_v6_val=$(printf '%s\n' "$WARP_EXIT_IP_CACHE" | awk -F'|' -v slot="$_warp_v6_pref" '$1 == slot { print $3; exit }')
        if is_public_ipv6 "$_warp_v6_val"; then
            printf '%s\n' "$_warp_v6_val"
            return 0
        fi
    fi
    for _warp_v6_slot in 1 2 3; do
        _warp_v6_val=$(printf '%s\n' "$WARP_EXIT_IP_CACHE" | awk -F'|' -v slot="$_warp_v6_slot" '$1 == slot { print $3; exit }')
        if is_public_ipv6 "$_warp_v6_val"; then
            printf '%s\n' "$_warp_v6_val"
            return 0
        fi
    done
    return 1
}

warp_pick_local_port() {
    _warp_port=9090
    while [ "$_warp_port" -le 9099 ]; do
        if command -v ss >/dev/null 2>&1; then
            if ! ss -lnt 2>/dev/null | grep -Eq "[:.]${_warp_port}[[:space:]]"; then
                printf '%s\n' "$_warp_port"
                return 0
            fi
        elif command -v netstat >/dev/null 2>&1; then
            if ! netstat -lnt 2>/dev/null | grep -Eq "[:.]${_warp_port}[[:space:]]"; then
                printf '%s\n' "$_warp_port"
                return 0
            fi
        else
            printf '%s\n' "$_warp_port"
            return 0
        fi
        _warp_port=$((_warp_port + 1))
    done
    printf '9090\n'
}

warp_gen_secret() {
    dd if=/dev/urandom bs=64 count=1 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 24
}

warp_query_active_lane() {
    [ -f "$CONF_FILE" ] || return 1
    _warp_ctrl=$(jq -r '.experimental.clash_api.external_controller // empty' "$CONF_FILE" 2>/dev/null || true)
    [ -n "$_warp_ctrl" ] || return 1
    case "$_warp_ctrl" in
        :*) _warp_ctrl="127.0.0.1${_warp_ctrl}" ;;
        0.0.0.0:*) _warp_ctrl="127.0.0.1:${_warp_ctrl#0.0.0.0:}" ;;
        \[::\]:*) _warp_ctrl="127.0.0.1:${_warp_ctrl#\[::\]:}" ;;
    esac
    _warp_secret=$(jq -r '.experimental.clash_api.secret // empty' "$CONF_FILE" 2>/dev/null || true)
    if [ -n "$_warp_secret" ]; then
        _warp_resp=$(curl -fsS --connect-timeout 1 --max-time 2 \
            -H "Authorization: Bearer ${_warp_secret}" \
            "http://${_warp_ctrl}/proxies/sbox-warp-auto" 2>/dev/null || true)
    else
        _warp_resp=$(curl -fsS --connect-timeout 1 --max-time 2 \
            "http://${_warp_ctrl}/proxies/sbox-warp-auto" 2>/dev/null || true)
    fi
    [ -n "$_warp_resp" ] || return 1
    _warp_now_tag=$(printf '%s' "$_warp_resp" | jq -r '.now // empty' 2>/dev/null || true)
    case "$_warp_now_tag" in
        sbox-warp-1) printf '1\n' ;;
        sbox-warp-2) printf '2\n' ;;
        sbox-warp-3) printf '3\n' ;;
        *) return 1 ;;
    esac
}

warp_show_channel_summary() {
    if command -v warp_load_mode_env >/dev/null 2>&1; then
        warp_load_mode_env
        if [ "$WARP_MODE" = "masque" ] && command -v masque_show_channel_summary >/dev/null 2>&1; then
            masque_show_channel_summary
            return 0
        fi
    fi
    _warp_now=$(date +%s)
    case "$WARP_EXIT_IP_CACHE_AT" in
        ''|*[!0-9]*) WARP_EXIT_IP_CACHE_AT=0 ;;
    esac
    if [ "$WARP_EXIT_IP_CACHE_AT" -eq 0 ] || [ $((_warp_now - WARP_EXIT_IP_CACHE_AT)) -ge 120 ]; then
        WARP_EXIT_IP_CACHE=$(warp_collect_channel_exit_ips 2>/dev/null || true)
        WARP_EXIT_IP_CACHE_AT="$_warp_now"
    fi

    _warp_default=$(jq -r '.route.final // "direct"' "$CONF_FILE" 2>/dev/null || printf '未知')
    if [ "$_warp_default" = "sbox-warp-auto" ]; then
        printf '  默认出站  %s（三路自动优选，每 3 分钟探测）\n' "$_warp_default"
        _warp_active_slot=$(warp_query_active_lane 2>/dev/null || true)
        if [ -n "$_warp_active_slot" ]; then
            _warp_active_row=$(printf '%s\n' "$WARP_EXIT_IP_CACHE" | awk -F'|' -v slot="$_warp_active_slot" '$1 == slot { print; exit }')
            _warp_active_vals=${_warp_active_row#*|}
            _warp_active_v4=${_warp_active_vals%%|*}
            printf '  当前胜出  %b[%s]%b %-8s IPv4 %s\n' \
                "$C_G" "$_warp_active_slot" "$C_N" "$(warp_interface_name "$_warp_active_slot")" \
                "${_warp_active_v4:-未知}"
        else
            printf '  当前胜出  未开启本机控制口（执行 sbox warp api 开启后实时显示）\n'
        fi
    elif warp_is_paused; then
        printf '  默认出站  %s（WARP 已临时暂停，选恢复可一键切回）\n' "$_warp_default"
    elif [ -f "$WARP_FALLBACK_STATE" ] && [ "$(warp_fallback_mode)" = "direct" ]; then
        printf '  默认出站  %s（WARP 全断直连兜底中）\n' "$_warp_default"
    else
        printf '  默认出站  %s\n' "$_warp_default"
    fi

    if [ ! -s "$WARP_FILE" ]; then
        printf '  WARP 通道  尚未配置\n'
        return 0
    fi

    _warp_ip_slot=1
    while [ "$_warp_ip_slot" -le 3 ]; do
        _warp_ip_row=$(printf '%s\n' "$WARP_EXIT_IP_CACHE" | awk -F'|' -v slot="$_warp_ip_slot" '$1 == slot { print; exit }')
        _warp_ip_values=${_warp_ip_row#*|}
        _warp_ip_v4=${_warp_ip_values%%|*}
        _warp_ip_v6=${_warp_ip_values#*|}
        [ -n "$_warp_ip_row" ] || { _warp_ip_v4="未获取"; _warp_ip_v6="未获取"; }
        printf '  %b[%s]%b %-8s IPv4 %-18s IPv6 %s\n' \
            "$C_B" "$_warp_ip_slot" "$C_N" "$(warp_interface_name "$_warp_ip_slot")" \
            "$_warp_ip_v4" "$_warp_ip_v6"
        _warp_ip_slot=$((_warp_ip_slot + 1))
    done
}

warp_ensure_address() {
    _warp_address_family="$1"
    _warp_address_iface="$2"
    _warp_address_value="$3"
    _warp_address_label="inet"
    [ "$_warp_address_family" = "6" ] && _warp_address_label="inet6"

    case "$_warp_address_value" in
        ""|null)
            warp_log "发现槽位接口 ${_warp_address_iface} 的 IPv${_warp_address_family} 地址为空或 null，跳过地址补写"
            _warp_topology_incomplete=1
            return 0
            ;;
    esac

    _warp_address_rows=$(ip "-o" "-$_warp_address_family" address show dev "$_warp_address_iface" 2>/dev/null || true)

    if printf '%s\n' "$_warp_address_rows" | grep -F "${_warp_address_label} ${_warp_address_value}" >/dev/null; then
        return 0
    fi

    warp_log "发现槽位接口 ${_warp_address_iface} 缺少 IPv${_warp_address_family} 地址，正在补回"
    if ! ip "-$_warp_address_family" address replace "$_warp_address_value" dev "$_warp_address_iface"; then
        err "❌ 无法补回槽位接口 ${_warp_address_iface} 的 IPv${_warp_address_family} 地址"
        return 1
    fi
    _warp_topology_changed=1
    _warp_address_rows=$(ip "-o" "-$_warp_address_family" address show dev "$_warp_address_iface" 2>/dev/null || true)
    if printf '%s\n' "$_warp_address_rows" | grep -F "${_warp_address_label} ${_warp_address_value}" >/dev/null; then
        warp_log "已补回槽位接口 ${_warp_address_iface} 的 IPv${_warp_address_family} 地址"
        return 0
    fi
    err "❌ 槽位接口 ${_warp_address_iface} 的 IPv${_warp_address_family} 地址补回后核验失败"
    return 1
}

warp_ensure_default_route() {
    _warp_route_family="$1"
    _warp_route_iface="$2"
    _warp_route_table="$3"
    _warp_route_rows=$(ip "-$_warp_route_family" route show table "$_warp_route_table" 2>/dev/null || true)
    _warp_route_count=$(printf '%s\n' "$_warp_route_rows" | grep -c '^default' || true)
    _warp_route_expected_count=$(printf '%s\n' "$_warp_route_rows" | grep -E -c "^default([[:space:]]|$).*dev ${_warp_route_iface}([[:space:]]|$)" || true)

    if [ "$_warp_route_count" = "1" ] && [ "$_warp_route_expected_count" = "1" ]; then
        return 0
    fi

    warp_log "发现槽位接口 ${_warp_route_iface} 的 IPv${_warp_route_family} 路由表 ${_warp_route_table} 默认路由缺失、重复或指向错误，正在修复"
    while ip "-$_warp_route_family" route del default table "$_warp_route_table" 2>/dev/null; do :; done
    ip "-$_warp_route_family" route replace default dev "$_warp_route_iface" table "$_warp_route_table" || return 1
    _warp_topology_changed=1
    _warp_route_rows=$(ip "-$_warp_route_family" route show table "$_warp_route_table" 2>/dev/null || true)
    _warp_route_count=$(printf '%s\n' "$_warp_route_rows" | grep -c '^default' || true)
    _warp_route_expected_count=$(printf '%s\n' "$_warp_route_rows" | grep -E -c "^default([[:space:]]|$).*dev ${_warp_route_iface}([[:space:]]|$)" || true)
    if [ "$_warp_route_count" = "1" ] && [ "$_warp_route_expected_count" = "1" ]; then
        warp_log "已补回槽位接口 ${_warp_route_iface} 的 IPv${_warp_route_family} 路由表 ${_warp_route_table} 默认路由"
        return 0
    fi
    err "❌ 槽位接口 ${_warp_route_iface} 的 IPv${_warp_route_family} 默认路由修复后核验失败"
    return 1
}

warp_ensure_interface_topology() {
    _warp_topology_slot="$1"
    _warp_topology_endpoint="$2"
    _warp_topology_account=$(warp_account_json "$_warp_topology_slot") || return 1
    _warp_topology_iface=$(warp_interface_name "$_warp_topology_slot")
    _warp_topology_table=$(warp_route_table "$_warp_topology_slot")
    _warp_topology_v4=$(printf '%s\n' "$_warp_topology_account" | jq -r '.v4')
    _warp_topology_v6=$(printf '%s\n' "$_warp_topology_account" | jq -r '.v6')
    _warp_topology_changed=0
    _warp_topology_incomplete=0

    if ! ip link show dev "$_warp_topology_iface" >/dev/null 2>&1; then
        warp_log "发现槽位接口 ${_warp_topology_iface} 不存在，正在重新创建"
        _warp_topology_changed=1
        if warp_apply_interface "$_warp_topology_slot" "$_warp_topology_endpoint" "$_warp_topology_account"; then
            warp_log "已重建槽位接口 ${_warp_topology_iface}"
        fi
    elif ! ip -d link show dev "$_warp_topology_iface" 2>/dev/null | grep -q wireguard; then
        err "❌ 槽位接口 ${_warp_topology_iface} 存在但不是 WireGuard 接口"
        return 1
    fi

    _warp_topology_link=$(ip -o link show dev "$_warp_topology_iface" 2>/dev/null) || return 1
    _warp_topology_flags=${_warp_topology_link#*<}
    _warp_topology_flags=${_warp_topology_flags%%>*}
    case ",${_warp_topology_flags}," in
        *,UP,*) ;;
        *)
            warp_log "发现槽位接口 ${_warp_topology_iface} 未启动，正在拉起"
            if ip link set mtu 1280 up dev "$_warp_topology_iface"; then
                _warp_topology_changed=1
                warp_log "已拉起槽位接口 ${_warp_topology_iface}"
            else
                err "❌ 无法拉起槽位接口 ${_warp_topology_iface}"
                _warp_topology_incomplete=1
            fi
            ;;
    esac

    warp_ensure_address 4 "$_warp_topology_iface" "$_warp_topology_v4" || _warp_topology_incomplete=1
    warp_ensure_address 6 "$_warp_topology_iface" "$_warp_topology_v6" || _warp_topology_incomplete=1
    warp_ensure_default_route 4 "$_warp_topology_iface" "$_warp_topology_table" || _warp_topology_incomplete=1
    warp_ensure_default_route 6 "$_warp_topology_iface" "$_warp_topology_table" || _warp_topology_incomplete=1
    warp_add_policy_rule 4 "$_warp_topology_iface" "$_warp_topology_table" || _warp_topology_incomplete=1
    warp_add_policy_rule 6 "$_warp_topology_iface" "$_warp_topology_table" || _warp_topology_incomplete=1
    [ "$_warp_topology_incomplete" = "0" ]
}

warp_build_install_config() {
    _warp_tmp="$1"
    if [ ! -f "$WARP_ROUTE_BACKUP" ]; then
        _warp_previous=$(jq -r '.route.final // "direct"' "$CONF_FILE") || return 1
        printf '%s\n' "$_warp_previous" > "$WARP_ROUTE_BACKUP" || return 1
        chmod 600 "$WARP_ROUTE_BACKUP" 2>/dev/null || true
    fi
    _warp_ctrl=$(jq -r '.experimental.clash_api.external_controller // empty' "$CONF_FILE" 2>/dev/null || true)
    _warp_secret=$(jq -r '.experimental.clash_api.secret // empty' "$CONF_FILE" 2>/dev/null || true)
    if [ -z "$_warp_ctrl" ]; then
        _warp_ctrl="127.0.0.1:$(warp_pick_local_port)"
        [ -n "$_warp_secret" ] || _warp_secret=$(warp_gen_secret)
    fi
    jq --slurpfile accounts "$WARP_FILE" --arg ctrl "$_warp_ctrl" --arg secret "$_warp_secret" '
        .outbounds = ((.outbounds // []) | map(select(
            (.tag // "") != "sbox-warp-auto" and
            (.tag // "") != "sbox-warp-1" and
            (.tag // "") != "sbox-warp-2" and
            (.tag // "") != "sbox-warp-3"
        ))) + [
            $accounts[0][] | {
                type: "direct",
                tag: ("sbox-warp-" + (.slot | tostring)),
                bind_interface: ("sboxwg" + (.slot | tostring))
            }
        ] + [{
            type: "urltest",
            tag: "sbox-warp-auto",
            outbounds: ["sbox-warp-1", "sbox-warp-2", "sbox-warp-3"],
            url: "https://www.cloudflare.com/cdn-cgi/trace",
            interval: "3m",
            tolerance: 50,
            idle_timeout: "30m"
        }]
        | .route = (.route // {})
        | .route.final = "sbox-warp-auto"
        | .experimental = (.experimental // {})
        | .experimental.clash_api = ((.experimental.clash_api // {}) + (
            if (.experimental.clash_api.external_controller // "") == "" then
                { external_controller: $ctrl } + (if $secret != "" then { secret: $secret } else {} end)
            else {} end
        ))
    ' "$CONF_FILE" > "$_warp_tmp"
}

warp_enable_clash_api() {
    [ -f "$CONF_FILE" ] || { err "❌ 未找到 sing-box 配置文件"; return 1; }
    _warp_ctrl=$(jq -r '.experimental.clash_api.external_controller // empty' "$CONF_FILE" 2>/dev/null || true)
    if [ -n "$_warp_ctrl" ]; then
        info "✅ 已开启本机 Clash API: $_warp_ctrl"
        return 0
    fi
    _warp_ctrl="127.0.0.1:$(warp_pick_local_port)"
    _warp_secret=$(warp_gen_secret)
    _warp_tmp="${CONF_DIR}/config.clash_api.$$"
    if ! jq --arg ctrl "$_warp_ctrl" --arg secret "$_warp_secret" '
        .experimental = (.experimental // {})
        | .experimental.clash_api = ((.experimental.clash_api // {}) + { external_controller: $ctrl } + (if $secret != "" then { secret: $secret } else {} end))
    ' "$CONF_FILE" > "$_warp_tmp"; then
        rm -f "$_warp_tmp"
        err "❌ 生成 Clash API 配置失败"
        return 1
    fi
    if ! warp_commit_config "$_warp_tmp"; then
        err "❌ 应用 Clash API 配置失败，已回滚"
        return 1
    fi
    info "✅ 已开启仅本机 Clash API ($_warp_ctrl)，菜单将实时显示当前胜出通道"
}

warp_build_restore_config() {
    _warp_tmp="$1"
    _warp_previous=$(warp_fallback_target)
    jq --arg previous "$_warp_previous" '
        .outbounds = ((.outbounds // []) | map(select(
            (.tag // "") != "sbox-warp-auto" and
            (.tag // "") != "sbox-warp-1" and
            (.tag // "") != "sbox-warp-2" and
            (.tag // "") != "sbox-warp-3"
        )))
        | if .route.final == "sbox-warp-auto" then .route.final = $previous else . end
    ' "$CONF_FILE" > "$_warp_tmp"
}

warp_is_paused() {
    [ -f "$WARP_PAUSE_FLAG" ]
}

warp_fallback_target() {
    _warp_target=""
    if [ -f "$WARP_ROUTE_BACKUP" ]; then
        _warp_target=$(tr -d ' \t\r\n' < "$WARP_ROUTE_BACKUP" 2>/dev/null || true)
    fi
    [ -n "$_warp_target" ] || _warp_target="direct"
    printf '%s\n' "$_warp_target"
}

warp_write_fallback_state() {
    _warp_state_mode="$1"
    _warp_st1="${2:-0}"
    _warp_st2="${3:-0}"
    _warp_st3="${4:-0}"
    mkdir -p "$WARP_DIR" || return 1
    chmod 700 "$WARP_DIR" 2>/dev/null || true
    _warp_tmp=$(mktemp "${WARP_DIR}/fallback.XXXXXX") || return 1
    chmod 600 "$_warp_tmp" 2>/dev/null || true
    if ! jq -nc --arg mode "$_warp_state_mode" \
        --argjson s1 "$_warp_st1" --argjson s2 "$_warp_st2" --argjson s3 "$_warp_st3" \
        '{mode:$mode,streak:{"1":$s1,"2":$s2,"3":$s3}}' > "$_warp_tmp"; then
        rm -f "$_warp_tmp"
        return 1
    fi
    chmod 600 "$_warp_tmp" 2>/dev/null || true
    mv -f "$_warp_tmp" "$WARP_FALLBACK_STATE"
}

warp_ensure_fallback_state() {
    if [ -f "$WARP_FALLBACK_STATE" ] &&
        jq -e '(.mode == "warp" or .mode == "direct") and (.streak | type == "object")' "$WARP_FALLBACK_STATE" >/dev/null 2>&1; then
        return 0
    fi
    _warp_cur_final=$(jq -r '.route.final // "direct"' "$CONF_FILE" 2>/dev/null || printf 'direct')
    if [ "$_warp_cur_final" = "sbox-warp-auto" ]; then
        warp_write_fallback_state "warp" 0 0 0
    else
        warp_write_fallback_state "direct" 0 0 0
    fi
}

warp_fallback_mode() {
    jq -r '.mode // "warp"' "$WARP_FALLBACK_STATE" 2>/dev/null || printf 'warp'
}

warp_fallback_streak() {
    jq -r --arg slot "$1" '.streak[$slot] // 0' "$WARP_FALLBACK_STATE" 2>/dev/null || printf '0'
}

warp_build_route_final_config() {
    _warp_tmp="$1"
    _warp_final_tag="$2"
    jq --arg final "$_warp_final_tag" '
        .route = (.route // {})
        | .route.final = $final
    ' "$CONF_FILE" > "$_warp_tmp"
}

warp_switch_route_final() {
    _warp_final_tag="$1"
    _warp_tmp="${CONF_DIR}/config.warp.switch.$$"
    if ! warp_build_route_final_config "$_warp_tmp" "$_warp_final_tag"; then
        rm -f "$_warp_tmp"
        return 1
    fi
    if [ -x "$CORE_BIN" ] && ! "$CORE_BIN" check -c "$_warp_tmp" >/dev/null 2>&1; then
        "$CORE_BIN" check -c "$_warp_tmp" 2>&1 || true
        rm -f "$_warp_tmp"
        return 1
    fi
    warp_commit_config "$_warp_tmp"
}

warp_commit_config() {
    _warp_tmp="$1"
    _warp_recovery="${WARP_DIR}/config.prechange.$$"
    cp -p "$CONF_FILE" "$_warp_recovery" || return 1
    if ! safe_apply_patch "$_warp_tmp"; then
        rm -f "$_warp_recovery"
        return 1
    fi
    if restart_and_check; then
        rm -f "$_warp_recovery"
        return 0
    fi
    warn "sing-box 未能使用新配置启动，正在还原原配置..."
    cp -p "$_warp_recovery" "$CONF_FILE"
    restart_and_check >/dev/null 2>&1 || true
    rm -f "$_warp_recovery"
    return 1
}

warp_install_service() {
    case "$INIT" in
        systemd)
            cat > /etc/systemd/system/sbox-warp-keepalive.service <<'EOF'
[Unit]
Description=sbox kernel WireGuard WARP keepalive
After=network-online.target
Wants=network-online.target
Before=sing-box.service

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/sbox warp daemon
Restart=always
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
            warp_systemd_add_dependency || return 1
            systemctl daemon-reload && systemctl enable sbox-warp-keepalive.service
            ;;
        openrc)
            cat > /etc/init.d/sbox-warp-keepalive <<'EOF'
#!/sbin/openrc-run
name="sbox-warp-keepalive"
description="sbox kernel WireGuard WARP keepalive"
command="/usr/local/bin/sbox"
command_args="warp daemon"
supervisor="supervise-daemon"
respawn_delay=5
respawn_max=0
pidfile="/run/sbox-warp-keepalive.pid"
output_log="/var/log/sbox-warp.log"
error_log="/var/log/sbox-warp.log"

depend() {
    need net
    before sing-box
}
EOF
            chmod +x /etc/init.d/sbox-warp-keepalive && rc-update add sbox-warp-keepalive default
            ;;
        *)
            err "❌ 未检测到 systemd 或 OpenRC，无法安装 WARP 开机保活服务"
            return 1
            ;;
    esac
}

warp_systemd_add_dependency() {
    mkdir -p /etc/systemd/system/sing-box.service.d || return 1
    cat > /etc/systemd/system/sing-box.service.d/10-sbox-warp.conf <<'EOF'
[Unit]
Wants=sbox-warp-keepalive.service
After=sbox-warp-keepalive.service
EOF
    systemctl daemon-reload
}

warp_restore_service_integration() {
    if [ "$INIT" = "systemd" ]; then
        warp_systemd_add_dependency || return 1
    fi
    warp_service_action start
}

warp_service_action() {
    case "$INIT" in
        systemd) systemctl "$1" sbox-warp-keepalive.service ;;
        openrc) rc-service sbox-warp-keepalive "$1" ;;
        *) return 1 ;;
    esac
}

warp_stop_service() {
    case "$INIT" in
        systemd)
            if systemctl is-active --quiet sbox-warp-keepalive.service; then
                systemctl stop sbox-warp-keepalive.service
            fi
            ;;
        openrc)
            if rc-service sbox-warp-keepalive status >/dev/null 2>&1; then
                rc-service sbox-warp-keepalive stop
            fi
            ;;
        *) return 1 ;;
    esac
}

warp_remove_service() {
    case "$INIT" in
        systemd)
            if systemctl is-active --quiet sbox-warp-keepalive.service; then
                systemctl stop sbox-warp-keepalive.service || return 1
            fi
            if [ -f /etc/systemd/system/sbox-warp-keepalive.service ]; then
                systemctl disable sbox-warp-keepalive.service >/dev/null 2>&1 || return 1
                rm -f /etc/systemd/system/sbox-warp-keepalive.service
            fi
            rm -f /etc/systemd/system/sing-box.service.d/10-sbox-warp.conf
            rmdir /etc/systemd/system/sing-box.service.d 2>/dev/null || true
            systemctl daemon-reload || return 1
            ;;
        openrc)
            if [ -f /etc/init.d/sbox-warp-keepalive ]; then
                if rc-service sbox-warp-keepalive status >/dev/null 2>&1; then
                    rc-service sbox-warp-keepalive stop || return 1
                fi
                rc-update del sbox-warp-keepalive default >/dev/null 2>&1 || true
                rm -f /etc/init.d/sbox-warp-keepalive
            fi
            ;;
        *) return 1 ;;
    esac
}

warp_free_interface() {
    _warp_slot="$1"
    _warp_iface=$(warp_interface_name "$_warp_slot")
    _warp_table=$(warp_route_table "$_warp_slot")
    _warp_has_link=0
    _warp_has_route=0
    _warp_has_rule=0
    ip -d link show dev "$_warp_iface" 2>/dev/null | grep -q wireguard && _warp_has_link=1
    { ip -4 route show table "$_warp_table" 2>/dev/null; ip -6 route show table "$_warp_table" 2>/dev/null; } |
        grep -q "^default dev ${_warp_iface}" && _warp_has_route=1
    { ip -4 rule show 2>/dev/null; ip -6 rule show 2>/dev/null; } |
        grep -F "oif ${_warp_iface} lookup ${_warp_table}" >/dev/null && _warp_has_rule=1
    if [ "$_warp_has_link" = 0 ] && [ "$_warp_has_route" = 0 ] && [ "$_warp_has_rule" = 0 ]; then
        return 0
    fi
    while ip -4 rule del oif "$_warp_iface" table "$_warp_table" 2>/dev/null; do :; done
    while ip -6 rule del oif "$_warp_iface" table "$_warp_table" 2>/dev/null; do :; done
    ip -4 route flush table "$_warp_table" 2>/dev/null || true
    ip -6 route flush table "$_warp_table" 2>/dev/null || true
    ip link del dev "$_warp_iface" 2>/dev/null || true
}

warp_cleanup_interfaces() {
    _warp_cleanup_slot=1
    while [ "$_warp_cleanup_slot" -le 3 ]; do
        warp_free_interface "$_warp_cleanup_slot"
        _warp_cleanup_slot=$((_warp_cleanup_slot + 1))
    done
}

warp_attach_all() {
    _warp_slot=1
    while [ "$_warp_slot" -le 3 ]; do
        _warp_endpoint=$(warp_account_value "$_warp_slot" '.endpoint // empty')
        [ -n "$_warp_endpoint" ] || _warp_endpoint=$(warp_initial_endpoint "$_warp_slot")
        warp_apply_interface "$_warp_slot" "$_warp_endpoint" || return 1
        _warp_slot=$((_warp_slot + 1))
    done
}

warp_diagnose_slot() {
    _warp_diag_iface="$1"
    _warp_diag_wg=$(wg show "$_warp_diag_iface" 2>/dev/null | grep -E 'endpoint:|latest handshake:|transfer:' | tr '\n' ';' || true)
    [ -n "$_warp_diag_wg" ] && warn "   诊断 [${_warp_diag_iface}] WireGuard: $_warp_diag_wg"
    _warp_diag_err=$(curl -fsS -4 --interface "$_warp_diag_iface" --connect-timeout 4 --max-time 6 "$WARP_CHECK_URL" 2>&1 || true)
    _warp_diag_err=$(printf '%s\n' "$_warp_diag_err" | tail -n 2 | tr '\n' ' ')
    [ -n "$_warp_diag_err" ] && warn "   诊断 [${_warp_diag_iface}] curl(-4): $_warp_diag_err"
}

warp_try_install_endpoints() {
    _warp_tie_slot="$1"
    _warp_tie_skip_ep="$2"
    _warp_tie_iface=$(warp_interface_name "$_warp_tie_slot")
    for _warp_tie_ep in $WARP_POOL; do
        [ "$_warp_tie_ep" = "$_warp_tie_skip_ep" ] && continue
        warn "⚠️ $_warp_tie_iface 当前端点验证未通过，尝试切换端点 $_warp_tie_ep"
        if warp_apply_interface "$_warp_tie_slot" "$_warp_tie_ep" && sleep 2 && warp_probe_interface "$_warp_tie_iface"; then
            warp_update_account_state "$_warp_tie_slot" "$_warp_tie_ep" 0 0 0 || return 1
            info "✅ $_warp_tie_iface 已切换端点 $_warp_tie_ep 并通过握手与 WARP 出口验证"
            return 0
        fi
    done
    return 1
}

warp_verify_install_slot() {
    _warp_vi_slot="$1"
    _warp_vi_iface=$(warp_interface_name "$_warp_vi_slot")
    _warp_vi_cur_ep=$(warp_account_value "$_warp_vi_slot" '.endpoint // empty' 2>/dev/null || true)
    [ -n "$_warp_vi_cur_ep" ] || _warp_vi_cur_ep=$(warp_initial_endpoint "$_warp_vi_slot")

    if warp_probe_interface "$_warp_vi_iface"; then
        info "✅ $_warp_vi_iface 内核握手和 WARP 出口验证通过"
        return 0
    fi

    sleep 2
    if warp_probe_interface "$_warp_vi_iface"; then
        info "✅ $_warp_vi_iface 内核握手和 WARP 出口验证通过"
        return 0
    fi

    if warp_try_install_endpoints "$_warp_vi_slot" "$_warp_vi_cur_ep"; then
        return 0
    fi

    warn "⚠️ $_warp_vi_iface 轮换全部端点均未通过，尝试为槽位 $_warp_vi_slot 重新注册 WARP 账号..."
    _warp_vi_new_acc=$(warp_register_account "$_warp_vi_slot" || true)
    if [ -n "$_warp_vi_new_acc" ]; then
        _warp_vi_new_ep=$(printf '%s\n' "$_warp_vi_new_acc" | jq -r '.endpoint // empty')
        if warp_save_account "$_warp_vi_slot" "$_warp_vi_new_acc"; then
            if warp_apply_interface "$_warp_vi_slot" "$_warp_vi_new_ep" && sleep 2 && warp_probe_interface "$_warp_vi_iface"; then
                info "✅ $_warp_vi_iface 已通过新账号和端点 $_warp_vi_new_ep 完成 WARP 出口验证"
                return 0
            fi
            if warp_try_install_endpoints "$_warp_vi_slot" "$_warp_vi_new_ep"; then
                return 0
            fi
        fi
    fi

    warp_diagnose_slot "$_warp_vi_iface"
    return 1
}

warp_install_body() {
    if command -v masque_remove_services >/dev/null 2>&1; then
        masque_remove_services >/dev/null 2>&1 || true
    fi
    if command -v warp_save_mode_env >/dev/null 2>&1; then
        WARP_MODE="wg"
        warp_save_mode_env || true
    fi
    ensure_warp_deps || return 1
    warp_prepare_store || { err "❌ WARP 账号数据不可用"; return 1; }
    warp_ensure_accounts || return 1
    _warp_tmp="${CONF_DIR}/config.warp.new.$$"
    if ! warp_build_install_config "$_warp_tmp"; then
        rm -f "$_warp_tmp"
        err "❌ 无法生成 sing-box WARP 配置"
        return 1
    fi
    if ! "$CORE_BIN" check -c "$_warp_tmp"; then
        rm -f "$_warp_tmp"
        err "❌ sing-box WARP 配置校验失败，原配置未更改"
        return 1
    fi
    if ! warp_attach_all; then
        rm -f "$_warp_tmp"
        warp_cleanup_interfaces
        err "❌ 创建 WARP 接口失败，已清理本次创建的接口与路由（账号缓存已保留）"
        return 1
    fi
    sleep 2
    _warp_install_slot=1
    while [ "$_warp_install_slot" -le 3 ]; do
        _warp_install_iface=$(warp_interface_name "$_warp_install_slot")
        if ! warp_verify_install_slot "$_warp_install_slot"; then
            rm -f "$_warp_tmp"
            warp_cleanup_interfaces
            err "❌ $_warp_install_iface 尚未通过 WARP 出口验证，已清理本次创建的接口与路由，sing-box 路由保持原样"
            warn "💡 若全部端点均 0 B received 握手失败，可能是宿主机屏蔽了 WireGuard UDP；"
            warn "   建议在 [10] WARP 管理菜单切换为「WARP MASQUE (usque)」模式（全 UDP 被封可选 --http2 或双路热备）。"
            return 1
        fi
        _warp_install_slot=$((_warp_install_slot + 1))
    done
    if ! warp_install_service; then
        rm -f "$_warp_tmp"
        return 1
    fi
    if ! warp_commit_config "$_warp_tmp"; then
        warp_stop_service >/dev/null 2>&1 || true
        warp_remove_service >/dev/null 2>&1 || true
        return 1
    fi
    if ! warp_service_action start; then
        err "❌ WARP 保活服务启动失败，正在恢复 sing-box 原路由"
        warp_stop_service >/dev/null 2>&1 || true
        warp_remove_service >/dev/null 2>&1 || true
        if warp_build_restore_config "$_warp_tmp" && "$CORE_BIN" check -c "$_warp_tmp" >/dev/null 2>&1 && warp_commit_config "$_warp_tmp"; then
            rm -f "$WARP_ROUTE_BACKUP" "$WARP_FALLBACK_STATE"
            warp_cleanup_interfaces
        else
            warn "原 sing-box 出站未能恢复，WARP 接口保留以免中断现有连接"
        fi
        return 1
    fi
    rm -f "$WARP_PAUSE_FLAG"
    warp_write_fallback_state "warp" 0 0 0 || true
    info "✅ 三路内核态 WARP 已接入 sing-box，节点流量现由 URLTest 自动择优"
    warn "旧 warp 接口及其系统策略路由保持原样，可在验证新出口后再单独退役。"
}

warp_install() (
    warp_lock || exit 1
    trap 'warp_unlock' EXIT
    trap 'warp_unlock; exit 1' HUP INT TERM
    warp_install_body
)

warp_repair_slot() {
    _warp_slot="$1"
    _warp_allow_register="${2:-1}"
    if [ -z "$(warp_account_json "$_warp_slot" 2>/dev/null)" ]; then
        warp_log "槽位 $_warp_slot 尚未注册账号，跳过修复"
        return 1
    fi
    _warp_iface=$(warp_interface_name "$_warp_slot")
    _warp_endpoint=$(warp_account_value "$_warp_slot" '.endpoint // empty')
    [ -n "$_warp_endpoint" ] || _warp_endpoint=$(warp_initial_endpoint "$_warp_slot")
    _warp_failures=$(warp_account_value "$_warp_slot" '.failures // 0')
    _warp_heals=$(warp_account_value "$_warp_slot" '.heal_count // 0')
    _warp_now=$(date +%s)

    _warp_topology_ok=1
    if ! warp_ensure_interface_topology "$_warp_slot" "$_warp_endpoint"; then
        _warp_topology_ok=0
        warp_log "槽位 $_warp_slot 的接口、地址或策略路由仍有缺项"
    fi

    if warp_probe_interface "$_warp_iface"; then
        if [ "$_warp_topology_changed" = "1" ] && [ "$_warp_topology_ok" = "1" ]; then
            _warp_heals=$((_warp_heals + 1))
            warp_update_account_state "$_warp_slot" "$_warp_endpoint" 0 "$_warp_heals" 0 || return 1
            warp_log "槽位 $_warp_slot 的接口拓扑已修复，WARP 出口正常"
        elif [ "$_warp_failures" != "0" ]; then
            warp_update_account_state "$_warp_slot" "$_warp_endpoint" 0 "$_warp_heals" 0 || return 1
        fi
        if [ "$_warp_topology_ok" != "1" ]; then
            warp_log "槽位 $_warp_slot 出口可通，但拓扑资料不完整，等待修复"
            return 1
        fi
        return 0
    fi

    if [ "$_warp_topology_ok" != "1" ]; then
        warp_log "槽位 $_warp_slot 拓扑资料不完整且出口探测失败，跳过端点轮换"
        return 1
    fi

    _warp_failures=$((_warp_failures + 1))
    if [ "$_warp_allow_register" != "1" ] || [ "$_warp_failures" -lt 3 ]; then
        _warp_next=$(warp_next_endpoint "$_warp_endpoint")
        warp_log "槽位 $_warp_slot 探测失败，轮换接入端点 $_warp_endpoint -> $_warp_next"
        if warp_apply_interface "$_warp_slot" "$_warp_next" && warp_probe_interface "$_warp_iface"; then
            _warp_heals=$((_warp_heals + 1))
            warp_update_account_state "$_warp_slot" "$_warp_next" 0 "$_warp_heals" 0
            warp_log "槽位 $_warp_slot 已通过新端点恢复"
            return 0
        fi
        warp_update_account_state "$_warp_slot" "$_warp_next" "$_warp_failures" "$_warp_heals" 0
        return 1
    fi

    _warp_retry=$(warp_account_value "$_warp_slot" '.next_retry // 0')
    if [ "$_warp_now" -lt "$_warp_retry" ]; then
        warp_log "槽位 $_warp_slot 仍不可用，按退避时间等待后再尝试换号"
        return 1
    fi

    warp_log "槽位 $_warp_slot 连续探测失败，尝试注册新 WARP 账号"
    _warp_old_account=$(warp_account_json "$_warp_slot") || return 1
    _warp_old_endpoint="$_warp_endpoint"
    _warp_next_retry=$((_warp_now + 900))
    warp_update_account_state "$_warp_slot" "$_warp_endpoint" "$_warp_failures" "$_warp_heals" "$_warp_next_retry" || return 1
    _warp_new_account=$(warp_register_account "$_warp_slot") || return 1
    _warp_new_endpoint=$(printf '%s\n' "$_warp_new_account" | jq -r '.endpoint')
    warp_save_account "$_warp_slot" "$_warp_new_account" || return 1
    if warp_apply_interface "$_warp_slot" "$_warp_new_endpoint" && warp_probe_interface "$_warp_iface"; then
        _warp_heals=$((_warp_heals + 1))
        warp_update_account_state "$_warp_slot" "$_warp_new_endpoint" 0 "$_warp_heals" 0
        warp_log "槽位 $_warp_slot 已通过新账号恢复"
        return 0
    fi
    warp_save_account "$_warp_slot" "$_warp_old_account"
    warp_update_account_state "$_warp_slot" "$_warp_old_endpoint" "$_warp_failures" "$_warp_heals" "$_warp_next_retry"
    warp_apply_interface "$_warp_slot" "$_warp_old_endpoint" || true
    warp_log "槽位 $_warp_slot 新账号验证失败，保留原账号并等待退避后重试"
    return 1
}

warp_repair_once() (
    if [ ! -f "$WARP_FILE" ]; then
        info "尚未配置 sing-box 内核态 WARP"
        exit 0
    fi
    warp_prepare_store || exit 1
    warp_lock || exit 1
    trap 'warp_unlock' EXIT
    trap 'warp_unlock; exit 1' HUP INT TERM

    warp_ensure_fallback_state || exit 1
    _warp_mode=$(warp_fallback_mode)
    _warp_allow_reg=1
    [ "$_warp_mode" = "direct" ] && _warp_allow_reg=0

    _warp_s1_ok=0
    _warp_s2_ok=0
    _warp_s3_ok=0
    _warp_slot=1
    while [ "$_warp_slot" -le 3 ]; do
        if warp_repair_slot "$_warp_slot" "$_warp_allow_reg"; then
            case "$_warp_slot" in
                1) _warp_s1_ok=1 ;;
                2) _warp_s2_ok=1 ;;
                3) _warp_s3_ok=1 ;;
            esac
        else
            warp_log "槽位 $_warp_slot 尚未恢复，其余出口继续巡检"
        fi
        _warp_slot=$((_warp_slot + 1))
    done

    if [ "$WARP_FALLBACK_DIRECT" = "1" ] && ! warp_is_paused; then
        if [ "$_warp_mode" = "warp" ]; then
            if [ "$_warp_s1_ok" = "0" ] && [ "$_warp_s2_ok" = "0" ] && [ "$_warp_s3_ok" = "0" ]; then
                _warp_target=$(warp_fallback_target)
                if warp_switch_route_final "$_warp_target"; then
                    warp_write_fallback_state "direct" 0 0 0 || true
                    warp_log "三路 WARP 出口全部探测失败，已切换至直连兜底模式 (route.final=${_warp_target})"
                else
                    warp_log "三路 WARP 出口全部探测失败，切换至直连兜底模式失败"
                fi
            fi
        elif [ "$_warp_mode" = "direct" ]; then
            _warp_st1=$(warp_fallback_streak 1)
            _warp_st2=$(warp_fallback_streak 2)
            _warp_st3=$(warp_fallback_streak 3)
            if [ "$_warp_s1_ok" = "1" ]; then _warp_st1=$((_warp_st1 + 1)); else _warp_st1=0; fi
            if [ "$_warp_s2_ok" = "1" ]; then _warp_st2=$((_warp_st2 + 1)); else _warp_st2=0; fi
            if [ "$_warp_s3_ok" = "1" ]; then _warp_st3=$((_warp_st3 + 1)); else _warp_st3=0; fi

            if [ "$_warp_st1" -ge 2 ] || [ "$_warp_st2" -ge 2 ] || [ "$_warp_st3" -ge 2 ]; then
                if jq -e '.outbounds[]? | select(.tag == "sbox-warp-auto")' "$CONF_FILE" >/dev/null 2>&1 &&
                    warp_switch_route_final "sbox-warp-auto"; then
                    warp_write_fallback_state "warp" 0 0 0 || true
                    warp_log "WARP 出口已连续 2 轮探测正常，已恢复 WARP 模式 (route.final=sbox-warp-auto)"
                else
                    warp_write_fallback_state "direct" "$_warp_st1" "$_warp_st2" "$_warp_st3" || true
                    warp_log "WARP 出口已满足恢复条件，但切回 sbox-warp-auto 失败"
                fi
            else
                warp_write_fallback_state "direct" "$_warp_st1" "$_warp_st2" "$_warp_st3" || true
            fi
        fi
    fi
)

warp_daemon() {
    warp_prepare_store || return 1
    warp_attach_all || warp_log "启动时部分 WARP 接口未能恢复，将继续后台重试"
    warp_log "启动三路 WARP 保活巡检，周期 ${WARP_INTERVAL} 秒"
    while :; do
        sleep "$WARP_INTERVAL"
        warp_is_paused || warp_repair_once || true
    done
}

warp_status() {
    if [ ! -f "$WARP_FILE" ]; then
        info "尚未配置 sing-box 内核态 WARP"
        return 0
    fi
    menu_title "WARP 通道状态"
    warp_show_channel_summary
    printf '\n%-12s %-20s %-18s %-10s %-10s\n' "槽位" "接口" "最近握手" "健康探测" "自愈次数"
    _warp_slot=1
    while [ "$_warp_slot" -le 3 ]; do
        _warp_iface=$(warp_interface_name "$_warp_slot")
        _warp_heals=$(warp_account_value "$_warp_slot" '.heal_count // 0' 2>/dev/null || printf '0')
        if wg show "$_warp_iface" >/dev/null 2>&1; then
            _warp_handshake=$(wg show "$_warp_iface" latest-handshakes 2>/dev/null | awk '{print $2; exit}')
            case "$_warp_handshake" in
                ''|0) _warp_handshake="尚无握手" ;;
                *) _warp_age=$(($(date +%s) - _warp_handshake)); _warp_handshake="${_warp_age}s 前" ;;
            esac
            if warp_probe_interface "$_warp_iface"; then _warp_health="正常"; else _warp_health="失败"; fi
        else
            _warp_handshake="接口未运行"
            _warp_health="失败"
        fi
        printf '%-12s %-20s %-18s %-10s %-10s\n' "$_warp_slot" "$_warp_iface" "$_warp_handshake" "$_warp_health" "$_warp_heals"
        _warp_slot=$((_warp_slot + 1))
    done
    case "$INIT" in
        systemd) systemctl is-active sbox-warp-keepalive.service 2>/dev/null || true ;;
        openrc) rc-service sbox-warp-keepalive status 2>/dev/null || true ;;
    esac
}

warp_disable_body() {
    if [ ! -f "$WARP_ROUTE_BACKUP" ]; then
        err "❌ 未找到 sing-box WARP 路由备份，拒绝猜测原始出站配置"
        return 1
    fi
    if ! warp_stop_service; then
        err "❌ 无法停止 WARP 保活服务，未更改 sing-box 配置或网卡"
        return 1
    fi
    if [ "$INIT" = "systemd" ]; then
        rm -f /etc/systemd/system/sing-box.service.d/10-sbox-warp.conf
        systemctl daemon-reload || { warp_restore_service_integration >/dev/null 2>&1 || true; return 1; }
    fi
    _warp_tmp="${CONF_DIR}/config.warp.disable.$$"
    if ! warp_build_restore_config "$_warp_tmp" || ! "$CORE_BIN" check -c "$_warp_tmp"; then
        rm -f "$_warp_tmp"
        warp_restore_service_integration >/dev/null 2>&1 || true
        err "❌ 还原配置校验失败，WARP 接口保持运行"
        return 1
    fi
    if ! warp_commit_config "$_warp_tmp"; then
        warp_restore_service_integration >/dev/null 2>&1 || true
        return 1
    fi
    if ! warp_remove_service; then
        err "❌ 无法移除 WARP 保活服务，保留网卡以免运行状态不一致"
        return 1
    fi
    warp_cleanup_interfaces
    rm -f "$WARP_ROUTE_BACKUP" "$WARP_FALLBACK_STATE" "$WARP_PAUSE_FLAG"
    info "✅ 已将 sing-box 路由恢复到启用 WARP 前的出站，并移除 sboxwg1/2/3"
    warn "旧 warp 接口和系统策略路由未更改。"
}

warp_remove_managed_resources() {
    if command -v masque_remove_services >/dev/null 2>&1; then
        masque_remove_services >/dev/null 2>&1 || true
    fi
    if [ ! -f "$WARP_FILE" ] && [ ! -f "$WARP_ROUTE_BACKUP" ] &&
        [ ! -f /etc/systemd/system/sbox-warp-keepalive.service ] &&
        [ ! -f /etc/init.d/sbox-warp-keepalive ]; then
        return 0
    fi
    warp_stop_service >/dev/null 2>&1 || true
    warp_remove_service >/dev/null 2>&1 || true
    _warp_slot=1
    while [ "$_warp_slot" -le 3 ]; do
        warp_free_interface "$_warp_slot"
        _warp_slot=$((_warp_slot + 1))
    done
}

warp_disable() (
    warp_lock || exit 1
    trap 'warp_unlock' EXIT
    trap 'warp_unlock; exit 1' HUP INT TERM
    warp_disable_body
)

warp_pause_body() {
    if [ ! -f "$WARP_FILE" ] || ! jq -e '.outbounds[]? | select(.tag == "sbox-warp-auto")' "$CONF_FILE" >/dev/null 2>&1; then
        err "❌ 尚未安装或启用三路 WARP"
        return 1
    fi
    _warp_cur_final=$(jq -r '.route.final // "direct"' "$CONF_FILE" 2>/dev/null || printf 'direct')
    if warp_is_paused && [ "$_warp_cur_final" != "sbox-warp-auto" ]; then
        info "ℹ️ WARP 当前已处于临时暂停状态（当前出站: $_warp_cur_final）"
        return 0
    fi
    if [ ! -f "$WARP_ROUTE_BACKUP" ]; then
        mkdir -p "$WARP_DIR" || return 1
        chmod 700 "$WARP_DIR" 2>/dev/null || true
        if [ "$_warp_cur_final" != "sbox-warp-auto" ] && [ -n "$_warp_cur_final" ]; then
            printf '%s\n' "$_warp_cur_final" > "$WARP_ROUTE_BACKUP" || return 1
        else
            printf 'direct\n' > "$WARP_ROUTE_BACKUP" || return 1
        fi
        chmod 600 "$WARP_ROUTE_BACKUP" 2>/dev/null || true
    fi
    _warp_target=$(warp_fallback_target)
    if [ "$_warp_cur_final" != "$_warp_target" ]; then
        if ! warp_switch_route_final "$_warp_target"; then
            err "❌ 切换出站至 $_warp_target 失败，未暂停 WARP"
            return 1
        fi
    fi
    mkdir -p "$WARP_DIR" || return 1
    chmod 700 "$WARP_DIR" 2>/dev/null || true
    date '+%Y-%m-%d %H:%M:%S' > "$WARP_PAUSE_FLAG" || return 1
    chmod 600 "$WARP_PAUSE_FLAG" 2>/dev/null || true
    warp_log "已临时暂停 WARP，默认出站切换为 ${_warp_target}"
    info "✅ 已临时暂停 WARP（当前出站: ${_warp_target}），sboxwg1/2/3 接口与配置已保留，可随时一键恢复"
}

warp_pause() (
    warp_lock || exit 1
    trap 'warp_unlock' EXIT
    trap 'warp_unlock; exit 1' HUP INT TERM
    warp_pause_body
)

warp_resume_body() {
    if [ ! -f "$WARP_FILE" ] || ! jq -e '.outbounds[]? | select(.tag == "sbox-warp-auto")' "$CONF_FILE" >/dev/null 2>&1; then
        err "❌ 未检测到 sbox-warp-auto 出站，请先安装 / 启用三路 WARP"
        return 1
    fi
    _warp_cur_final=$(jq -r '.route.final // "direct"' "$CONF_FILE" 2>/dev/null || printf 'direct')
    if ! warp_is_paused && [ "$_warp_cur_final" = "sbox-warp-auto" ]; then
        info "ℹ️ WARP 当前已处于启用状态"
        return 0
    fi
    if [ "$_warp_cur_final" != "sbox-warp-auto" ]; then
        if ! warp_switch_route_final "sbox-warp-auto"; then
            err "❌ 切回 sbox-warp-auto 失败，WARP 保持暂停状态"
            return 1
        fi
    fi
    rm -f "$WARP_PAUSE_FLAG"
    warp_write_fallback_state "warp" 0 0 0 || true
    warp_log "已恢复 WARP 自动出站 (route.final=sbox-warp-auto)"
    info "✅ 已恢复三路 WARP 自动出站 (sbox-warp-auto)"
}

warp_resume() (
    warp_lock || exit 1
    trap 'warp_unlock' EXIT
    trap 'warp_unlock; exit 1' HUP INT TERM
    warp_resume_body
)

warp_toggle_pause() {
    if warp_is_paused; then
        warp_resume
    else
        warp_pause
    fi
}

warp_refresh_slot_ip() {
    _warp_slot="$1"
    _warp_max_tries="$2"
    _warp_iface=$(warp_interface_name "$_warp_slot")
    _warp_old_account=$(warp_account_json "$_warp_slot" 2>/dev/null || true)
    if [ -z "$_warp_old_account" ]; then
        warn "⚠️ 通道 $_warp_slot 尚未注册账号，跳过"
        return 1
    fi
    _warp_old_endpoint=$(printf '%s\n' "$_warp_old_account" | jq -r '.endpoint // empty')
    [ -n "$_warp_old_endpoint" ] || _warp_old_endpoint=$(warp_initial_endpoint "$_warp_slot")
    _warp_init_v4=$(warp_read_exit_ip "$_warp_iface" 4 2>/dev/null || true)
    info "通道 $_warp_slot 当前 IPv4: ${_warp_init_v4:-未知}，最多尝试刷新 ${_warp_max_tries} 次"

    _warp_try=1
    while [ "$_warp_try" -le "$_warp_max_tries" ]; do
        [ "$_warp_try" -le 1 ] || sleep 2
        info "通道 $_warp_slot 正在进行第 ${_warp_try}/${_warp_max_tries} 次换号刷新..."
        _warp_new_account=$(warp_register_account "$_warp_slot" || true)
        if [ -z "$_warp_new_account" ]; then
            warn "⚠️ 通道 $_warp_slot 第 ${_warp_try} 次注册未成功"
            _warp_try=$((_warp_try + 1))
            continue
        fi
        _warp_new_endpoint=$(printf '%s\n' "$_warp_new_account" | jq -r '.endpoint // empty')
        [ -n "$_warp_new_endpoint" ] || _warp_new_endpoint="$_warp_old_endpoint"
        if ! warp_save_account "$_warp_slot" "$_warp_new_account" || ! warp_apply_interface "$_warp_slot" "$_warp_new_endpoint"; then
            warp_save_account "$_warp_slot" "$_warp_old_account" >/dev/null 2>&1 || true
            warp_apply_interface "$_warp_slot" "$_warp_old_endpoint" >/dev/null 2>&1 || true
            warn "⚠️ 通道 $_warp_slot 第 ${_warp_try} 次应用新账号失败，已保持原账号"
            _warp_try=$((_warp_try + 1))
            continue
        fi
        sleep 1
        _warp_new_v4=$(warp_read_exit_ip "$_warp_iface" 4 2>/dev/null || true)
        if [ -z "$_warp_new_v4" ]; then
            warp_save_account "$_warp_slot" "$_warp_old_account" >/dev/null 2>&1 || true
            warp_apply_interface "$_warp_slot" "$_warp_old_endpoint" >/dev/null 2>&1 || true
            warn "⚠️ 通道 $_warp_slot 第 ${_warp_try} 次新账号出口探测失败，已回退原账号"
            _warp_try=$((_warp_try + 1))
            continue
        fi
        _warp_old_account="$_warp_new_account"
        _warp_old_endpoint="$_warp_new_endpoint"
        if [ -z "$_warp_init_v4" ] || [ "$_warp_new_v4" != "$_warp_init_v4" ]; then
            warp_log "通道 $_warp_slot 刷新 IP 成功 (${_warp_init_v4:-未知} -> $_warp_new_v4，第 ${_warp_try}/${_warp_max_tries} 次)"
            info "✅ 通道 $_warp_slot 刷新 IP 成功: ${_warp_init_v4:-未知} -> $_warp_new_v4（第 ${_warp_try} 次）"
            return 0
        fi
        warn "⚠️ 通道 $_warp_slot 第 ${_warp_try}/${_warp_max_tries} 次分配到相同 IPv4: $_warp_new_v4"
        _warp_try=$((_warp_try + 1))
    done

    warn "⚠️ 通道 $_warp_slot 已尝试 ${_warp_max_tries} 次，IPv4 仍为 ${_warp_init_v4:-未知}"
    return 1
}

warp_refresh_ips() {
    if [ ! -f "$WARP_FILE" ]; then
        info "尚未配置 sing-box 内核态 WARP"
        return 0
    fi
    _warp_raw_slots="${1:-}"
    _warp_max_tries="${2:-}"
    if [ -z "$_warp_raw_slots" ]; then
        ask "请输入要刷新的通道号（点分割，如 1.3）: "
        _warp_raw_slots="$REPLY"
    fi
    if [ -z "$_warp_max_tries" ]; then
        ask "请输入最大尝试次数 [默认 3]: "
        _warp_max_tries="${REPLY:-3}"
    fi
    case "$_warp_max_tries" in
        ''|*[!0-9]*|0)
            err "❌ 尝试次数必须为正整数"
            return 1
            ;;
    esac
    if [ "$_warp_max_tries" -gt 10 ]; then
        warn "⚠️ 尝试次数上限为 10，已自动调整为 10"
        _warp_max_tries=10
    fi

    _warp_slots=""
    for _warp_token in $(printf '%s' "$_warp_raw_slots" | tr '.,' '  '); do
        case "$_warp_token" in
            1|2|3)
                case " $_warp_slots " in
                    *" $_warp_token "*) ;;
                    *) _warp_slots="${_warp_slots:+$_warp_slots }$_warp_token" ;;
                esac
                ;;
            "") ;;
            *)
                err "❌ 无效通道号: $_warp_token（仅支持 1、2、3）"
                return 1
                ;;
        esac
    done
    if [ -z "$_warp_slots" ]; then
        err "❌ 未输入有效通道号"
        return 1
    fi

    (
        warp_prepare_store || exit 1
        warp_lock || exit 1
        trap 'warp_unlock' EXIT
        trap 'warp_unlock; exit 1' HUP INT TERM
        for _warp_slot in $_warp_slots; do
            warp_refresh_slot_ip "$_warp_slot" "$_warp_max_tries" || true
        done
    )
    warp_invalidate_exit_ip_cache
}

run_warp_install_flow() {
    line
    warn "此操作会注册 3 个 WARP 账号、创建独立内核 WireGuard 接口，并让 sing-box 节点出站启用 WARP 自动容灾。"
    warn "现有 warp 接口、系统默认路由和 SSH 回程路由会保持原样。"
    confirm "继续配置三路内核态 WARP？" || return 0
    warp_install
}

run_warp_setup() {
    if [ "${1:-}" = "auto" ]; then
        warp_install
        return $?
    fi
    command -v warp_load_mode_env >/dev/null 2>&1 && warp_load_mode_env

    if [ "$WARP_MODE" = "masque" ]; then
        menu_title "WARP 管理中心 · 当前模式：MASQUE (usque)"
        warp_show_channel_summary
        echo "  注：dual 主路与 l4-socks 仅转发 TCP；需转发 UDP 时请选单路 socks。"
        menu_option 1 "安装 / 切换 MASQUE 子模式（双路热备默认 / 单路可选）"
        menu_option 2 "查看 MASQUE 状态与双栈出口 IP"
        menu_option 3 "重新注册 MASQUE 账号（带失败回滚保护）"
        if warp_is_paused; then
            menu_option 4 "恢复 MASQUE（启动 usque 并切回自动优选）"
        else
            menu_option 4 "暂停 MASQUE（停用 usque 切回直连，保留账号）"
        fi
        menu_option 5 "彻底卸载 MASQUE（先安全切回直连再清理）"
        menu_option 6 "切换回「三路内核态 WireGuard UDP（默认模式）」"
        menu_option 0 "返回"
        ask "请选择 [0-6]: "
        _warp_choice=$(printf '%s' "$REPLY" | tr -d ' \t\r')
        case "$_warp_choice" in
            1)
                _mq_arch_sel=$(masque_choose_arch_menu) || { info "已取消"; pause; return 0; }
                masque_install "$_mq_arch_sel"
                pause
                ;;
            2) masque_status; pause ;;
            3) masque_reregister; pause ;;
            4)
                if warp_is_paused; then masque_resume; else masque_pause; fi
                pause
                ;;
            5)
                if confirm "将先安全切回直连并彻底清理 usque 服务、配置与二进制。继续？"; then
                    masque_uninstall
                else
                    info "已取消卸载"
                fi
                pause
                ;;
            6)
                run_warp_install_flow
                pause
                ;;
            0|q|Q) return 0 ;;
            *) warn "无效输入: $_warp_choice"; pause ;;
        esac
        return 0
    fi

    menu_title "WARP 管理中心 · 当前模式：WireGuard UDP（默认）"
    warp_show_channel_summary
    menu_option 1 "安装 / 启用三路内核态 WARP"
    menu_option 2 "查看通道状态与出口 IP"
    menu_option 3 "立即执行一次保活修复"
    menu_option 4 "刷新指定通道出口 IP"
    if warp_is_paused; then
        menu_option 5 "恢复 WARP（切回自动优选）"
    else
        menu_option 5 "暂停 WARP（临时切回直连，保留接口）"
    fi
    menu_option 6 "停用自动出站并移除管理接口"
    menu_option 7 "切换为「WARP MASQUE (usque)」模式（UDP 被封推荐）"
    menu_option 0 "返回"
    ask "请选择 [0-7]: "
    _warp_choice=$(printf '%s' "$REPLY" | tr -d ' \t\r')
    case "$_warp_choice" in
        1) run_warp_install_flow; pause ;;
        2) warp_status; pause ;;
        3) warp_repair_once; pause ;;
        4) warp_refresh_ips; pause ;;
        5) warp_toggle_pause; pause ;;
        6)
            if confirm "将恢复 sing-box 原有出站并删除 sboxwg1/2/3。继续？"; then
                warp_disable
            else
                info "已取消停用操作"
            fi
            pause
            ;;
        7)
            _mq_arch_sel=$(masque_choose_arch_menu) || { info "已取消"; pause; return 0; }
            masque_install "$_mq_arch_sel"
            pause
            ;;
        0|q|Q) return 0 ;;
        *) warn "无效输入: $_warp_choice"; pause ;;
    esac
}

warp_command() {
    command -v warp_load_mode_env >/dev/null 2>&1 && warp_load_mode_env
    _warp_command="${1:-menu}"
    case "$_warp_command" in
        menu) run_warp_setup ;;
        install) run_warp_install_flow ;;
        status)
            if [ "$WARP_MODE" = "masque" ] && command -v masque_status >/dev/null 2>&1; then
                masque_status
            else
                warp_status
            fi
            ;;
        repair) warp_repair_once ;;
        refresh) shift; warp_refresh_ips "$@" ;;
        pause)
            if [ "$WARP_MODE" = "masque" ] && command -v masque_pause >/dev/null 2>&1; then
                masque_pause
            else
                warp_pause
            fi
            ;;
        resume)
            if [ "$WARP_MODE" = "masque" ] && command -v masque_resume >/dev/null 2>&1; then
                masque_resume
            else
                warp_resume
            fi
            ;;
        api) warp_enable_clash_api ;;
        disable)
            if [ "$WARP_MODE" = "masque" ] && command -v masque_uninstall >/dev/null 2>&1; then
                confirm "将恢复 sing-box 原有出站并卸载 MASQUE。继续？" && masque_uninstall
            else
                confirm "将恢复 sing-box 原有出站并删除 sboxwg1/2/3。继续？" && warp_disable
            fi
            ;;
        masque)
            _mq_sub="${2:-dual}"
            case "$_mq_sub" in
                dual|l4-socks|socks|socks-http2) masque_install "$_mq_sub" ;;
                status) masque_status ;;
                reregister) masque_reregister ;;
                pause) masque_pause ;;
                resume) masque_resume ;;
                uninstall) masque_uninstall ;;
                *) err "用法: sbox warp masque [dual|l4-socks|socks|socks-http2|status|reregister|pause|resume|uninstall]"; return 2 ;;
            esac
            ;;
        daemon) warp_daemon ;;
        log) tail -n 100 "$WARP_LOG" 2>/dev/null || warn "暂无 WARP 保活日志" ;;
        *)
            err "用法: sbox warp [menu|install|status|repair|refresh|pause|resume|api|disable|masque|daemon|log]"
            return 2
            ;;
    esac
}

# === [module: 56_warp_masque.sh] ===
# ------------------------------------------------------------------------------
# WARP MASQUE (usque) 双模支持：单路 / 双路异构热备、动态内存档位与生命周期管理
# ------------------------------------------------------------------------------

WARP_MODE_ENV="${WARP_DIR}/mode.env"
MASQUE_BIN="/usr/local/bin/usque"
MASQUE_CONF_MAIN="${WARP_DIR}/masque-primary.json"
MASQUE_CONF_BACKUP="${WARP_DIR}/masque-backup.json"
MASQUE_BASE_PORT="40000"
MASQUE_TRACE_V4="https://1.1.1.1/cdn-cgi/trace"
MASQUE_TRACE_V6="https://[2606:4700:4700::1111]/cdn-cgi/trace"

WARP_MODE="wg"
MASQUE_ARCH="dual"
MASQUE_PORT_MAIN="40000"
MASQUE_PORT_BACKUP="40001"

warp_load_mode_env() {
    WARP_MODE="wg"
    MASQUE_ARCH="dual"
    MASQUE_PORT_MAIN="40000"
    MASQUE_PORT_BACKUP="40001"
    if [ -f "$WARP_MODE_ENV" ]; then
        # shellcheck disable=SC1090
        . "$WARP_MODE_ENV" 2>/dev/null || true
    fi
    case "$WARP_MODE" in
        wg|masque) ;;
        *) WARP_MODE="wg" ;;
    esac
    case "$MASQUE_ARCH" in
        dual|l4-socks|socks|socks-http2) ;;
        *) MASQUE_ARCH="dual" ;;
    esac
    case "$MASQUE_PORT_MAIN" in ''|*[!0-9]*) MASQUE_PORT_MAIN="40000" ;; esac
    case "$MASQUE_PORT_BACKUP" in ''|*[!0-9]*) MASQUE_PORT_BACKUP="40001" ;; esac
}

warp_save_mode_env() {
    mkdir -p "$WARP_DIR" || return 1
    chmod 700 "$WARP_DIR" 2>/dev/null || true
    _mq_tmp="${WARP_MODE_ENV}.tmp.$$"
    cat > "$_mq_tmp" <<EOF
WARP_MODE="${WARP_MODE}"
MASQUE_ARCH="${MASQUE_ARCH}"
MASQUE_PORT_MAIN="${MASQUE_PORT_MAIN}"
MASQUE_PORT_BACKUP="${MASQUE_PORT_BACKUP}"
EOF
    chmod 600 "$_mq_tmp" 2>/dev/null || true
    mv -f "$_mq_tmp" "$WARP_MODE_ENV"
}

masque_arch_label() {
    case "$1" in
        dual)        printf '双路异构热备 (l4-socks主 + socks--http2备, 主路仅TCP)' ;;
        l4-socks)    printf '单路 l4-socks (UDP 443, 仅TCP, 最低开销)' ;;
        socks)       printf '单路 socks (UDP 443, 完整TCP+UDP)' ;;
        socks-http2) printf '单路 socks --http2 (TCP 443, 全UDP封禁兜底)' ;;
        *)           printf '%s' "$1" ;;
    esac
}

masque_ensure_deps() {
    _mq_need=""
    for _mq_cmd in curl unzip jq; do
        command -v "$_mq_cmd" >/dev/null 2>&1 || _mq_need="${_mq_need} $_mq_cmd"
    done
    [ -z "$_mq_need" ] && return 0
    info "📦 正在安装 MASQUE 所需依赖:${_mq_need}..."
    case "$OS_TYPE" in
        alpine|debian)
            install_pkg curl ca-certificates unzip jq || return 1
            ;;
        *)
            err "❌ MASQUE 模式仅支持 Alpine、Debian 与 Ubuntu"
            return 1
            ;;
    esac
}

masque_detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  printf 'amd64\n' ;;
        aarch64|arm64) printf 'arm64\n' ;;
        *)
            err "❌ 不支持的 CPU 架构: $(uname -m)（usque 仅提供 amd64 / arm64）"
            return 1
            ;;
    esac
}

masque_ensure_bin() {
    if [ -x "$MASQUE_BIN" ]; then
        return 0
    fi
    masque_ensure_deps || return 1
    _mq_arch=$(masque_detect_arch) || return 1
    _mq_api="https://api.github.com/repos/Diniboy1123/usque/releases/latest"
    _mq_dl_url=""

    info "⬇️  正在获取 usque 最新版本信息 (${_mq_arch})..."
    _mq_json=$(curl -fsSL --connect-timeout 8 --max-time 15 "$_mq_api" 2>/dev/null || true)
    if [ -n "$_mq_json" ]; then
        _mq_dl_url=$(printf '%s' "$_mq_json" | jq -r --arg a "$_mq_arch" '
            [.assets[]? | select(.name | test("linux.*" + $a + "\\.zip$"; "i")) | .browser_download_url][0] // empty
        ' 2>/dev/null || true)
    fi

    if [ -z "$_mq_dl_url" ]; then
        warn "⚠️ GitHub API 不可用或触发限流，改用 releases/latest 重定向解析版本号..."
        _mq_redir=$(curl -sIL -o /dev/null -w '%{url_effective}' --connect-timeout 8 --max-time 15 \
            "https://github.com/Diniboy1123/usque/releases/latest" 2>/dev/null || true)
        _mq_tag="${_mq_redir##*/}"
        _mq_ver="${_mq_tag#v}"
        if [ -z "$_mq_ver" ] || [ "$_mq_ver" = "latest" ]; then
            err "❌ 无法解析 usque 最新版本号，请检查网络连通性"
            return 1
        fi
        _mq_dl_url="https://github.com/Diniboy1123/usque/releases/download/${_mq_tag}/usque_${_mq_ver}_linux_${_mq_arch}.zip"
    fi

    _mq_dl_url="${GH_PROXY:-}${_mq_dl_url}"
    _mq_workdir="/tmp/usque_dl.$$"
    mkdir -p "$_mq_workdir" || return 1
    info "⬇️  正在下载 usque: $_mq_dl_url"
    if ! curl -fsSL --connect-timeout 10 --max-time 60 "$_mq_dl_url" -o "${_mq_workdir}/usque.zip"; then
        rm -rf "$_mq_workdir"
        err "❌ 下载 usque 压缩包失败"
        return 1
    fi
    if ! unzip -oq "${_mq_workdir}/usque.zip" -d "$_mq_workdir"; then
        rm -rf "$_mq_workdir"
        err "❌ 解压 usque 压缩包失败"
        return 1
    fi
    _mq_extracted=$(find "$_mq_workdir" -type f -name 'usque' 2>/dev/null | head -n 1 || true)
    if [ -z "$_mq_extracted" ] || [ ! -s "$_mq_extracted" ]; then
        rm -rf "$_mq_workdir"
        err "❌ 压缩包中未找到 usque 二进制文件"
        return 1
    fi
    mv -f "$_mq_extracted" "$MASQUE_BIN" && chmod 755 "$MASQUE_BIN"
    rm -rf "$_mq_workdir"
    info "✅ usque 已安装至 $MASQUE_BIN"
}

masque_port_in_use() {
    _mq_p="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -lnt 2>/dev/null | grep -Eq "[:.]${_mq_p}[[:space:]]" && return 0
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lnt 2>/dev/null | grep -Eq "[:.]${_mq_p}[[:space:]]" && return 0
    fi
    return 1
}

masque_pick_port() {
    _mq_start="${1:-$MASQUE_BASE_PORT}"
    _mq_skip="${2:-0}"
    _mq_p="$_mq_start"
    _mq_end=$((_mq_start + 200))
    while [ "$_mq_p" -le "$_mq_end" ]; do
        if [ "$_mq_p" != "$_mq_skip" ] && ! masque_port_in_use "$_mq_p"; then
            printf '%s\n' "$_mq_p"
            return 0
        fi
        _mq_p=$((_mq_p + 1))
    done
    printf '%s\n' "$_mq_start"
}

# 取 min(物理内存, cgroup 限额)，兼容 cgroup v1/v2 无上限占位值
masque_total_mem_mib() {
    _mq_phys_kb=$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)
    _mq_phys_mib=0
    case "$_mq_phys_kb" in ''|*[!0-9]*) _mq_phys_kb=0 ;; esac
    [ "$_mq_phys_kb" -gt 0 ] && _mq_phys_mib=$((_mq_phys_kb / 1024))

    _mq_cg_mib=0
    _mq_raw=""
    if [ -r /sys/fs/cgroup/memory.max ]; then
        _mq_raw=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || true)
    elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        _mq_raw=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || true)
    fi
    case "$_mq_raw" in
        ''|max|*[!0-9]*) ;;
        *)
            if [ "$_mq_raw" -gt 0 ] 2>/dev/null; then
                _mq_tmp_mib=$((_mq_raw / 1048576))
                # 忽略 Linux cgroup v1 常见无上限超大值 (如 9223372036854771712)
                if [ "$_mq_tmp_mib" -gt 0 ] && [ "$_mq_tmp_mib" -le 131072 ]; then
                    _mq_cg_mib="$_mq_tmp_mib"
                fi
            fi
            ;;
    esac

    if [ "$_mq_phys_mib" -gt 0 ] && [ "$_mq_cg_mib" -gt 0 ]; then
        if [ "$_mq_cg_mib" -lt "$_mq_phys_mib" ]; then
            printf '%s\n' "$_mq_cg_mib"
        else
            printf '%s\n' "$_mq_phys_mib"
        fi
    elif [ "$_mq_cg_mib" -gt 0 ]; then
        printf '%s\n' "$_mq_cg_mib"
    elif [ "$_mq_phys_mib" -gt 0 ]; then
        printf '%s\n' "$_mq_phys_mib"
    else
        printf '128\n'
    fi
}

# 输出格式: "<GOMEMLIMIT>|<MemoryHigh>|<MemoryMax>"
masque_calc_mem_tier() {
    _mq_role="${1:-single}"
    _mq_mem=$(masque_total_mem_mib)
    if [ "$_mq_mem" -le 192 ]; then
        case "$_mq_role" in
            dual-main)   printf '20MiB|28M|42M\n' ;;
            dual-backup) printf '16MiB|24M|36M\n' ;;
            *)           printf '24MiB|32M|48M\n' ;;
        esac
    elif [ "$_mq_mem" -le 384 ]; then
        printf '40MiB|48M|64M\n'
    else
        printf '64MiB|80M|112M\n'
    fi
}

masque_tune_udp_buf() {
    command -v sysctl >/dev/null 2>&1 || return 0
    _mq_rmem=$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)
    _mq_wmem=$(sysctl -n net.core.wmem_max 2>/dev/null || echo 0)
    case "$_mq_rmem" in ''|*[!0-9]*) _mq_rmem=0 ;; esac
    case "$_mq_wmem" in ''|*[!0-9]*) _mq_wmem=0 ;; esac
    if [ "$_mq_rmem" -lt 2621440 ]; then
        sysctl -w net.core.rmem_max=2621440 >/dev/null 2>&1 || true
    fi
    if [ "$_mq_wmem" -lt 2621440 ]; then
        sysctl -w net.core.wmem_max=2621440 >/dev/null 2>&1 || true
    fi
}

# 安全注册：先写入临时配置，成功且非空合法 JSON 后再原子替换，防止限流丢号
masque_register_config() {
    _mq_target="$1"
    mkdir -p "$WARP_DIR" || return 1
    chmod 700 "$WARP_DIR" 2>/dev/null || true
    _mq_tmp="${_mq_target}.reg.$$"
    rm -f "$_mq_tmp"
    info "📝 正在注册 Cloudflare WARP MASQUE 账号 ($(basename "$_mq_target"))..."
    if ! "$MASQUE_BIN" -c "$_mq_tmp" register --accept-tos >/dev/null 2>&1; then
        rm -f "$_mq_tmp"
        err "❌ MASQUE 账号注册失败（可能触发 Cloudflare 频率限制），保留原有配置"
        return 1
    fi
    if [ ! -s "$_mq_tmp" ] || ! jq -e 'type == "object"' "$_mq_tmp" >/dev/null 2>&1; then
        rm -f "$_mq_tmp"
        err "❌ 生成的 MASQUE 配置校验失败，已回滚"
        return 1
    fi
    chmod 600 "$_mq_tmp" 2>/dev/null || true
    mv -f "$_mq_tmp" "$_mq_target"
    info "✅ MASQUE 配置已就绪: $_mq_target"
}

masque_ensure_configs() {
    _mq_arch="${1:-$MASQUE_ARCH}"
    if [ ! -s "$MASQUE_CONF_MAIN" ]; then
        masque_register_config "$MASQUE_CONF_MAIN" || return 1
    fi
    if [ "$_mq_arch" = "dual" ] && [ ! -s "$MASQUE_CONF_BACKUP" ]; then
        masque_register_config "$MASQUE_CONF_BACKUP" || return 1
    fi
    return 0
}

masque_exec_args_for_role() {
    _mq_role="$1"
    _mq_arch="$2"
    _mq_port="$3"
    case "$_mq_role" in
        backup)
            printf '%s -c %s socks --http2 -b 127.0.0.1 -p %s\n' "$MASQUE_BIN" "$MASQUE_CONF_BACKUP" "$_mq_port"
            ;;
        *)
            case "$_mq_arch" in
                dual|l4-socks)
                    printf '%s -c %s l4-socks -b 127.0.0.1 -p %s\n' "$MASQUE_BIN" "$MASQUE_CONF_MAIN" "$_mq_port"
                    ;;
                socks)
                    printf '%s -c %s socks -b 127.0.0.1 -p %s\n' "$MASQUE_BIN" "$MASQUE_CONF_MAIN" "$_mq_port"
                    ;;
                socks-http2)
                    printf '%s -c %s socks --http2 -b 127.0.0.1 -p %s\n' "$MASQUE_BIN" "$MASQUE_CONF_MAIN" "$_mq_port"
                    ;;
            esac
            ;;
    esac
}

masque_write_one_systemd() {
    _mq_svc="$1"
    _mq_desc="$2"
    _mq_exec="$3"
    _mq_tier="$4"
    _mq_gomem=$(printf '%s' "$_mq_tier" | cut -d'|' -f1)
    _mq_mhigh=$(printf '%s' "$_mq_tier" | cut -d'|' -f2)
    _mq_mmax=$(printf '%s' "$_mq_tier" | cut -d'|' -f3)

    cat > "/etc/systemd/system/${_mq_svc}.service" <<EOF
[Unit]
Description=${_mq_desc}
After=network-online.target
Wants=network-online.target
Before=sing-box.service

[Service]
Type=simple
User=root
Environment="GOMEMLIMIT=${_mq_gomem}"
Environment="GOGC=50"
ExecStart=${_mq_exec}
Restart=always
RestartSec=3
TasksMax=64
Nice=5
OOMScoreAdjust=200
MemoryHigh=${_mq_mhigh}
MemoryMax=${_mq_mmax}
StandardOutput=null
StandardError=null
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
}

masque_write_one_openrc() {
    _mq_svc="$1"
    _mq_desc="$2"
    _mq_conf="$3"
    _mq_subargs="$4"
    _mq_gomem="$5"

    cat > "/etc/init.d/${_mq_svc}" <<EOF
#!/sbin/openrc-run
name="${_mq_svc}"
description="${_mq_desc}"
export GOMEMLIMIT="${_mq_gomem}"
export GOGC="50"
command="${MASQUE_BIN}"
command_args="-c ${_mq_conf} ${_mq_subargs}"
supervisor="supervise-daemon"
respawn_delay=3
respawn_max=0
pidfile="/run/${_mq_svc}.pid"
output_log="/dev/null"
error_log="/dev/null"

depend() {
    need net
    before sing-box
}
EOF
    chmod +x "/etc/init.d/${_mq_svc}"
}

masque_openrc_subargs() {
    _mq_role="$1"
    _mq_arch="$2"
    _mq_port="$3"
    case "$_mq_role" in
        backup)
            printf 'socks --http2 -b 127.0.0.1 -p %s\n' "$_mq_port"
            ;;
        *)
            case "$_mq_arch" in
                dual|l4-socks) printf 'l4-socks -b 127.0.0.1 -p %s\n' "$_mq_port" ;;
                socks)         printf 'socks -b 127.0.0.1 -p %s\n' "$_mq_port" ;;
                socks-http2)   printf 'socks --http2 -b 127.0.0.1 -p %s\n' "$_mq_port" ;;
            esac
            ;;
    esac
}

masque_install_services() {
    warp_load_mode_env
    if [ "$MASQUE_ARCH" = "dual" ]; then
        _mq_tier_main=$(masque_calc_mem_tier "dual-main")
        _mq_tier_bak=$(masque_calc_mem_tier "dual-backup")
    else
        _mq_tier_main=$(masque_calc_mem_tier "single")
        _mq_tier_bak=""
    fi

    _mq_exec_main=$(masque_exec_args_for_role "main" "$MASQUE_ARCH" "$MASQUE_PORT_MAIN")
    _mq_exec_bak=""
    [ "$MASQUE_ARCH" = "dual" ] && _mq_exec_bak=$(masque_exec_args_for_role "backup" "$MASQUE_ARCH" "$MASQUE_PORT_BACKUP")

    case "$INIT" in
        systemd)
            masque_write_one_systemd "sbox-usque" "sbox WARP MASQUE primary (usque)" "$_mq_exec_main" "$_mq_tier_main"
            if [ "$MASQUE_ARCH" = "dual" ]; then
                masque_write_one_systemd "sbox-usque-backup" "sbox WARP MASQUE backup http2 (usque)" "$_mq_exec_bak" "$_mq_tier_bak"
                _mq_wants="sbox-usque.service sbox-usque-backup.service"
            else
                if [ -f /etc/systemd/system/sbox-usque-backup.service ]; then
                    systemctl disable --now sbox-usque-backup.service >/dev/null 2>&1 || true
                    rm -f /etc/systemd/system/sbox-usque-backup.service
                fi
                _mq_wants="sbox-usque.service"
            fi
            mkdir -p /etc/systemd/system/sing-box.service.d || return 1
            cat > /etc/systemd/system/sing-box.service.d/10-sbox-warp.conf <<EOF
[Unit]
Wants=${_mq_wants}
After=${_mq_wants}
EOF
            systemctl daemon-reload
            systemctl enable sbox-usque.service >/dev/null 2>&1 || return 1
            [ "$MASQUE_ARCH" = "dual" ] && { systemctl enable sbox-usque-backup.service >/dev/null 2>&1 || return 1; }
            return 0
            ;;
        openrc)
            _mq_gomem_main=$(printf '%s' "$_mq_tier_main" | cut -d'|' -f1)
            _mq_sub_main=$(masque_openrc_subargs "main" "$MASQUE_ARCH" "$MASQUE_PORT_MAIN")
            masque_write_one_openrc "sbox-usque" "sbox WARP MASQUE primary (usque)" "$MASQUE_CONF_MAIN" "$_mq_sub_main" "$_mq_gomem_main"
            rc-update add sbox-usque default >/dev/null 2>&1 || true
            if [ "$MASQUE_ARCH" = "dual" ]; then
                _mq_gomem_bak=$(printf '%s' "$_mq_tier_bak" | cut -d'|' -f1)
                _mq_sub_bak=$(masque_openrc_subargs "backup" "$MASQUE_ARCH" "$MASQUE_PORT_BACKUP")
                masque_write_one_openrc "sbox-usque-backup" "sbox WARP MASQUE backup http2 (usque)" "$MASQUE_CONF_BACKUP" "$_mq_sub_bak" "$_mq_gomem_bak"
                rc-update add sbox-usque-backup default >/dev/null 2>&1 || true
            else
                if [ -f /etc/init.d/sbox-usque-backup ]; then
                    rc-service sbox-usque-backup stop >/dev/null 2>&1 || true
                    rc-update del sbox-usque-backup default >/dev/null 2>&1 || true
                    rm -f /etc/init.d/sbox-usque-backup
                fi
            fi
            return 0
            ;;
        *)
            err "❌ 未检测到 systemd 或 OpenRC，无法托管 MASQUE 后台服务"
            return 1
            ;;
    esac
}

masque_service_action() {
    _mq_act="$1"
    warp_load_mode_env
    case "$INIT" in
        systemd)
            if [ "$_mq_act" = "restart" ] || [ "$_mq_act" = "start" ]; then
                systemctl "$_mq_act" sbox-usque.service || return 1
                if [ "$MASQUE_ARCH" = "dual" ]; then
                    systemctl "$_mq_act" sbox-usque-backup.service || return 1
                fi
            else
                systemctl "$_mq_act" sbox-usque.service >/dev/null 2>&1 || true
                systemctl "$_mq_act" sbox-usque-backup.service >/dev/null 2>&1 || true
            fi
            ;;
        openrc)
            if [ "$_mq_act" = "restart" ] || [ "$_mq_act" = "start" ]; then
                rc-service sbox-usque "$_mq_act" || return 1
                if [ "$MASQUE_ARCH" = "dual" ]; then
                    rc-service sbox-usque-backup "$_mq_act" || return 1
                fi
            else
                rc-service sbox-usque "$_mq_act" >/dev/null 2>&1 || true
                [ -f /etc/init.d/sbox-usque-backup ] && rc-service sbox-usque-backup "$_mq_act" >/dev/null 2>&1 || true
            fi
            ;;
        *) return 1 ;;
    esac
}

masque_stop_services() {
    case "$INIT" in
        systemd)
            systemctl stop sbox-usque.service >/dev/null 2>&1 || true
            systemctl stop sbox-usque-backup.service >/dev/null 2>&1 || true
            ;;
        openrc)
            [ -f /etc/init.d/sbox-usque ] && rc-service sbox-usque stop >/dev/null 2>&1 || true
            [ -f /etc/init.d/sbox-usque-backup ] && rc-service sbox-usque-backup stop >/dev/null 2>&1 || true
            ;;
    esac
}

masque_remove_services() {
    masque_stop_services
    case "$INIT" in
        systemd)
            if [ -f /etc/systemd/system/sbox-usque.service ]; then
                systemctl disable sbox-usque.service >/dev/null 2>&1 || true
                rm -f /etc/systemd/system/sbox-usque.service
            fi
            if [ -f /etc/systemd/system/sbox-usque-backup.service ]; then
                systemctl disable sbox-usque-backup.service >/dev/null 2>&1 || true
                rm -f /etc/systemd/system/sbox-usque-backup.service
            fi
            rm -f /etc/systemd/system/sing-box.service.d/10-sbox-warp.conf
            rmdir /etc/systemd/system/sing-box.service.d 2>/dev/null || true
            systemctl daemon-reload >/dev/null 2>&1 || true
            ;;
        openrc)
            if [ -f /etc/init.d/sbox-usque ]; then
                rc-update del sbox-usque default >/dev/null 2>&1 || true
                rm -f /etc/init.d/sbox-usque
            fi
            if [ -f /etc/init.d/sbox-usque-backup ]; then
                rc-update del sbox-usque-backup default >/dev/null 2>&1 || true
                rm -f /etc/init.d/sbox-usque-backup
            fi
            ;;
    esac
}

masque_service_state() {
    _mq_svc="$1"
    case "$INIT" in
        systemd)
            if systemctl is-active --quiet "${_mq_svc}.service" 2>/dev/null; then
                printf '运行中'
            else
                printf '未运行'
            fi
            ;;
        openrc)
            if [ -f "/etc/init.d/${_mq_svc}" ] && rc-service "$_mq_svc" status >/dev/null 2>&1; then
                printf '运行中'
            else
                printf '未运行'
            fi
            ;;
        *) printf '未知' ;;
    esac
}

masque_build_singbox_config() {
    _mq_tmp="$1"
    warp_load_mode_env
    if [ ! -f "$WARP_ROUTE_BACKUP" ]; then
        _mq_prev=$(jq -r '.route.final // "direct"' "$CONF_FILE") || return 1
        [ "$_mq_prev" = "sbox-warp-auto" ] && _mq_prev="direct"
        printf '%s\n' "$_mq_prev" > "$WARP_ROUTE_BACKUP" || return 1
        chmod 600 "$WARP_ROUTE_BACKUP" 2>/dev/null || true
    fi
    _mq_ctrl=$(jq -r '.experimental.clash_api.external_controller // empty' "$CONF_FILE" 2>/dev/null || true)
    _mq_secret=$(jq -r '.experimental.clash_api.secret // empty' "$CONF_FILE" 2>/dev/null || true)
    if [ -z "$_mq_ctrl" ]; then
        _mq_ctrl="127.0.0.1:$(warp_pick_local_port)"
        [ -n "$_mq_secret" ] || _mq_secret=$(warp_gen_secret)
    fi

    if [ "$MASQUE_ARCH" = "dual" ]; then
        jq --argjson p1 "$MASQUE_PORT_MAIN" --argjson p2 "$MASQUE_PORT_BACKUP" \
           --arg ctrl "$_mq_ctrl" --arg secret "$_mq_secret" '
            .outbounds = ((.outbounds // []) | map(select(
                (.tag // "") != "sbox-warp-auto" and
                (.tag // "") != "sbox-warp-1" and
                (.tag // "") != "sbox-warp-2" and
                (.tag // "") != "sbox-warp-3"
            ))) + [
                {
                    type: "socks",
                    tag: "sbox-warp-1",
                    server: "127.0.0.1",
                    server_port: $p1,
                    version: "5"
                },
                {
                    type: "socks",
                    tag: "sbox-warp-2",
                    server: "127.0.0.1",
                    server_port: $p2,
                    version: "5"
                },
                {
                    type: "urltest",
                    tag: "sbox-warp-auto",
                    outbounds: ["sbox-warp-1", "sbox-warp-2"],
                    url: "https://www.cloudflare.com/cdn-cgi/trace",
                    interval: "2m",
                    tolerance: 80,
                    idle_timeout: "15m"
                }
            ]
            | .route = (.route // {})
            | .route.final = "sbox-warp-auto"
            | .experimental = (.experimental // {})
            | .experimental.clash_api = ((.experimental.clash_api // {}) + (
                if (.experimental.clash_api.external_controller // "") == "" then
                    { external_controller: $ctrl } + (if $secret != "" then { secret: $secret } else {} end)
                else {} end
            ))
        ' "$CONF_FILE" > "$_mq_tmp"
    else
        jq --argjson p1 "$MASQUE_PORT_MAIN" \
           --arg ctrl "$_mq_ctrl" --arg secret "$_mq_secret" '
            .outbounds = ((.outbounds // []) | map(select(
                (.tag // "") != "sbox-warp-auto" and
                (.tag // "") != "sbox-warp-1" and
                (.tag // "") != "sbox-warp-2" and
                (.tag // "") != "sbox-warp-3"
            ))) + [
                {
                    type: "socks",
                    tag: "sbox-warp-1",
                    server: "127.0.0.1",
                    server_port: $p1,
                    version: "5"
                },
                {
                    type: "urltest",
                    tag: "sbox-warp-auto",
                    outbounds: ["sbox-warp-1"],
                    url: "https://www.cloudflare.com/cdn-cgi/trace",
                    interval: "3m",
                    tolerance: 50,
                    idle_timeout: "30m"
                }
            ]
            | .route = (.route // {})
            | .route.final = "sbox-warp-auto"
            | .experimental = (.experimental // {})
            | .experimental.clash_api = ((.experimental.clash_api // {}) + (
                if (.experimental.clash_api.external_controller // "") == "" then
                    { external_controller: $ctrl } + (if $secret != "" then { secret: $secret } else {} end)
                else {} end
            ))
        ' "$CONF_FILE" > "$_mq_tmp"
    fi
}

# 输出格式: "<v4_ip>|<v6_ip>|<warp_state>"
masque_probe_port() {
    _mq_p="$1"
    _mq_t4=$(curl -fsS --socks5-hostname "127.0.0.1:${_mq_p}" --connect-timeout 4 --max-time 6 "$MASQUE_TRACE_V4" 2>/dev/null || true)
    _mq_v4=""
    _mq_w4=""
    if [ -n "$_mq_t4" ]; then
        _mq_v4=$(printf '%s\n' "$_mq_t4" | sed -n 's/^ip=//p' | head -n 1)
        _mq_w4=$(printf '%s\n' "$_mq_t4" | sed -n 's/^warp=//p' | head -n 1)
    fi

    _mq_t6=$(curl -fsS --socks5-hostname "127.0.0.1:${_mq_p}" --connect-timeout 4 --max-time 6 "$MASQUE_TRACE_V6" 2>/dev/null || true)
    _mq_v6=""
    _mq_w6=""
    if [ -n "$_mq_t6" ]; then
        _mq_v6=$(printf '%s\n' "$_mq_t6" | sed -n 's/^ip=//p' | head -n 1)
        _mq_w6=$(printf '%s\n' "$_mq_t6" | sed -n 's/^warp=//p' | head -n 1)
    fi

    _mq_wok="off"
    if [ "$_mq_w4" = "on" ] || [ "$_mq_w4" = "plus" ] || [ "$_mq_w6" = "on" ] || [ "$_mq_w6" = "plus" ]; then
        _mq_wok="on"
    fi
    printf '%s|%s|%s\n' "${_mq_v4:-未获取}" "${_mq_v6:-未获取}" "$_mq_wok"
}

masque_show_channel_summary() {
    warp_load_mode_env
    _mq_default=$(jq -r '.route.final // "direct"' "$CONF_FILE" 2>/dev/null || printf '未知')
    if [ "$_mq_default" = "sbox-warp-auto" ]; then
        printf '  WARP 模式  MASQUE (usque) · %s\n' "$(masque_arch_label "$MASQUE_ARCH")"
        _mq_active=$(warp_query_active_lane 2>/dev/null || true)
        if [ -n "$_mq_active" ]; then
            printf '  当前胜出  sbox-warp-%s\n' "$_mq_active"
        fi
    elif warp_is_paused; then
        printf '  WARP 模式  MASQUE (usque 已暂停，当前出站: %s)\n' "$_mq_default"
    else
        printf '  WARP 模式  MASQUE (usque，当前出站: %s)\n' "$_mq_default"
    fi

    _mq_st1=$(masque_service_state "sbox-usque")
    printf '  %b[主路]%b 127.0.0.1:%s (%s)\n' "$C_B" "$C_N" "$MASQUE_PORT_MAIN" "$_mq_st1"
    if [ "$MASQUE_ARCH" = "dual" ]; then
        _mq_st2=$(masque_service_state "sbox-usque-backup")
        printf '  %b[备路]%b 127.0.0.1:%s (%s, HTTP/2 兜底)\n' "$C_B" "$C_N" "$MASQUE_PORT_BACKUP" "$_mq_st2"
    fi
}

masque_verify_port_ready() {
    _mq_p="$1"
    _mq_try=0
    while [ "$_mq_try" -lt 4 ]; do
        _mq_res=$(masque_probe_port "$_mq_p")
        _mq_wok="${_mq_res##*|}"
        if [ "$_mq_wok" = "on" ]; then
            return 0
        fi
        sleep 2
        _mq_try=$((_mq_try + 1))
    done
    return 1
}

masque_stop_legacy_wg() {
    if [ -f /etc/systemd/system/sbox-warp-keepalive.service ] || [ -f /etc/init.d/sbox-warp-keepalive ]; then
        info "🔄 正在停用旧内核态 WireGuard WARP 服务与接口..."
        warp_stop_service >/dev/null 2>&1 || true
        warp_remove_service >/dev/null 2>&1 || true
        warp_cleanup_interfaces >/dev/null 2>&1 || true
    fi
}

masque_install_body() {
    _mq_target_arch="${1:-}"
    warp_load_mode_env
    [ -n "$_mq_target_arch" ] && MASQUE_ARCH="$_mq_target_arch"

    [ -f "$CONF_FILE" ] || { err "❌ 未找到 sing-box 配置文件: $CONF_FILE"; return 1; }
    masque_ensure_deps || return 1
    masque_ensure_bin || return 1
    masque_tune_udp_buf
    masque_ensure_configs "$MASQUE_ARCH" || return 1

    # 若原端口未被我方服务占用则复用，否则分配新端口
    if [ -z "$MASQUE_PORT_MAIN" ] || { [ "$(masque_service_state sbox-usque)" != "运行中" ] && masque_port_in_use "$MASQUE_PORT_MAIN"; }; then
        MASQUE_PORT_MAIN=$(masque_pick_port "$MASQUE_BASE_PORT" 0)
    fi
    if [ "$MASQUE_ARCH" = "dual" ]; then
        if [ -z "$MASQUE_PORT_BACKUP" ] || [ "$MASQUE_PORT_BACKUP" = "$MASQUE_PORT_MAIN" ] || \
           { [ "$(masque_service_state sbox-usque-backup)" != "运行中" ] && masque_port_in_use "$MASQUE_PORT_BACKUP"; }; then
            MASQUE_PORT_BACKUP=$(masque_pick_port $((MASQUE_PORT_MAIN + 1)) "$MASQUE_PORT_MAIN")
        fi
    fi

    WARP_MODE="masque"
    warp_save_mode_env || return 1

    masque_stop_legacy_wg
    masque_stop_services

    if ! masque_install_services; then
        err "❌ 安装 MASQUE 系统服务失败"
        return 1
    fi
    if ! masque_service_action start; then
        err "❌ 启动 usque 服务失败"
        masque_stop_services
        return 1
    fi

    info "🔍 正在验证 MASQUE 隧道出口连通性..."
    if ! masque_verify_port_ready "$MASQUE_PORT_MAIN"; then
        err "❌ 主路 (127.0.0.1:${MASQUE_PORT_MAIN}) 未能通过 WARP 出口验证"
        if [ "$MASQUE_ARCH" != "socks-http2" ]; then
            warn "💡 若宿主机同时封禁了 UDP 443，可尝试切换为「单路 socks --http2 (TCP 443)」"
        fi
        masque_stop_services
        return 1
    fi
    if [ "$MASQUE_ARCH" = "dual" ]; then
        if ! masque_verify_port_ready "$MASQUE_PORT_BACKUP"; then
            warn "⚠️ 备路 HTTP/2 (127.0.0.1:${MASQUE_PORT_BACKUP}) 暂未就绪，请稍后在状态面板复查"
        fi
    fi

    _mq_tmp="${CONF_DIR}/config.masque.new.$$"
    if ! masque_build_singbox_config "$_mq_tmp"; then
        rm -f "$_mq_tmp"
        err "❌ 生成 sing-box MASQUE 出站配置失败"
        return 1
    fi
    if ! "$CORE_BIN" check -c "$_mq_tmp"; then
        rm -f "$_mq_tmp"
        err "❌ sing-box 配置校验失败，原配置未更改"
        return 1
    fi
    if ! warp_commit_config "$_mq_tmp"; then
        err "❌ 应用 sing-box 配置失败，已回滚"
        return 1
    fi

    rm -f "$WARP_PAUSE_FLAG"
    info "✅ WARP MASQUE (${MASQUE_ARCH}) 已接入 sing-box (tag: sbox-warp-auto)"
}

masque_install() (
    _mq_arch_arg="${1:-}"
    warp_lock || exit 1
    trap 'warp_unlock' EXIT
    trap 'warp_unlock; exit 1' HUP INT TERM
    masque_install_body "$_mq_arch_arg"
)

masque_status() {
    warp_load_mode_env
    menu_title "WARP MASQUE (usque) 状态"
    printf '  运行架构  %s\n' "$(masque_arch_label "$MASQUE_ARCH")"
    _mq_mem=$(masque_total_mem_mib)
    printf '  内存检测  %s MiB (GOGC=50)\n' "$_mq_mem"

    _mq_st1=$(masque_service_state "sbox-usque")
    _mq_p1=$(masque_probe_port "$MASQUE_PORT_MAIN")
    _mq_v4_1=${_mq_p1%%|*}
    _mq_rest_1=${_mq_p1#*|}
    _mq_v6_1=${_mq_rest_1%%|*}
    _mq_w_1=${_mq_rest_1##*|}
    printf '  [主路]    127.0.0.1:%s | 服务: %s | warp=%s | IPv4: %s | IPv6: %s\n' \
        "$MASQUE_PORT_MAIN" "$_mq_st1" "$_mq_w_1" "$_mq_v4_1" "$_mq_v6_1"

    if [ "$MASQUE_ARCH" = "dual" ]; then
        _mq_st2=$(masque_service_state "sbox-usque-backup")
        _mq_p2=$(masque_probe_port "$MASQUE_PORT_BACKUP")
        _mq_v4_2=${_mq_p2%%|*}
        _mq_rest_2=${_mq_p2#*|}
        _mq_v6_2=${_mq_rest_2%%|*}
        _mq_w_2=${_mq_rest_2##*|}
        printf '  [备路]    127.0.0.1:%s | 服务: %s | warp=%s | IPv4: %s | IPv6: %s\n' \
            "$MASQUE_PORT_BACKUP" "$_mq_st2" "$_mq_w_2" "$_mq_v4_2" "$_mq_v6_2"
    fi
}

masque_reregister() (
    warp_lock || exit 1
    trap 'warp_unlock' EXIT
    trap 'warp_unlock; exit 1' HUP INT TERM
    warp_load_mode_env
    masque_ensure_bin || exit 1
    masque_register_config "$MASQUE_CONF_MAIN" || exit 1
    if [ "$MASQUE_ARCH" = "dual" ]; then
        masque_register_config "$MASQUE_CONF_BACKUP" || exit 1
    fi
    if ! warp_is_paused; then
        masque_service_action restart || exit 1
        sleep 2
        masque_verify_port_ready "$MASQUE_PORT_MAIN" && info "✅ 新账号已生效且通过 WARP 出口校验" || warn "⚠️ 服务已重启，请稍后检查状态面板"
    else
        info "✅ 新账号已保存（当前处于暂停状态，恢复后生效）"
    fi
)

masque_pause() (
    warp_lock || exit 1
    trap 'warp_unlock' EXIT
    trap 'warp_unlock; exit 1' HUP INT TERM
    [ -f "$CONF_FILE" ] || { err "❌ 未找到 sing-box 配置"; exit 1; }
    _mq_cur=$(jq -r '.route.final // "direct"' "$CONF_FILE" 2>/dev/null || printf 'direct')
    if [ ! -f "$WARP_ROUTE_BACKUP" ]; then
        mkdir -p "$WARP_DIR" || exit 1
        [ "$_mq_cur" != "sbox-warp-auto" ] && printf '%s\n' "$_mq_cur" > "$WARP_ROUTE_BACKUP" || printf 'direct\n' > "$WARP_ROUTE_BACKUP"
        chmod 600 "$WARP_ROUTE_BACKUP" 2>/dev/null || true
    fi
    _mq_target=$(warp_fallback_target)
    if [ "$_mq_cur" != "$_mq_target" ]; then
        warp_switch_route_final "$_mq_target" || { err "❌ 切换出站至 $_mq_target 失败"; exit 1; }
    fi
    masque_stop_services
    date '+%Y-%m-%d %H:%M:%S' > "$WARP_PAUSE_FLAG" || exit 1
    chmod 600 "$WARP_PAUSE_FLAG" 2>/dev/null || true
    info "✅ 已暂停 MASQUE（当前出站: ${_mq_target}），已停止 usque 进程并保留账号配置"
)

masque_resume() (
    warp_lock || exit 1
    trap 'warp_unlock' EXIT
    trap 'warp_unlock; exit 1' HUP INT TERM
    warp_load_mode_env
    masque_ensure_configs "$MASQUE_ARCH" || exit 1
    masque_install_services || exit 1
    masque_service_action start || { err "❌ 启动 usque 失败"; exit 1; }
    sleep 2
    if ! jq -e '.outbounds[]? | select(.tag == "sbox-warp-auto")' "$CONF_FILE" >/dev/null 2>&1; then
        _mq_tmp="${CONF_DIR}/config.masque.res.$$"
        masque_build_singbox_config "$_mq_tmp" && "$CORE_BIN" check -c "$_mq_tmp" >/dev/null 2>&1 && warp_commit_config "$_mq_tmp" || { rm -f "$_mq_tmp"; exit 1; }
    else
        warp_switch_route_final "sbox-warp-auto" || exit 1
    fi
    rm -f "$WARP_PAUSE_FLAG"
    info "✅ 已恢复 WARP MASQUE 自动出站 (sbox-warp-auto)"
)

masque_uninstall() (
    warp_lock || exit 1
    trap 'warp_unlock' EXIT
    trap 'warp_unlock; exit 1' HUP INT TERM
    if [ -f "$CONF_FILE" ] && jq -e '.outbounds[]? | select(.tag == "sbox-warp-auto")' "$CONF_FILE" >/dev/null 2>&1; then
        _mq_tmp="${CONF_DIR}/config.masque.uninst.$$"
        if warp_build_restore_config "$_mq_tmp" && "$CORE_BIN" check -c "$_mq_tmp" >/dev/null 2>&1; then
            warp_commit_config "$_mq_tmp" || warn "⚠️ 恢复 sing-box 直连出站失败，将继续清理 MASQUE 资源"
        else
            rm -f "$_mq_tmp"
        fi
    fi
    masque_remove_services
    rm -f "$MASQUE_CONF_MAIN" "$MASQUE_CONF_BACKUP" "$WARP_MODE_ENV" "$WARP_PAUSE_FLAG" "$WARP_ROUTE_BACKUP" "$MASQUE_BIN"
    info "✅ 已彻底卸载 WARP MASQUE（sing-box 本体与入站节点不受影响）"
)

masque_choose_arch_menu() {
    menu_title "选择 MASQUE 运行架构"
    echo "  提示：dual 主路与 l4-socks 仅转发 TCP（性能最高）；需转发 UDP 时请选单路 socks。"
    menu_option 1 "双路异构热备（推荐默认：l4-socks主 + socks--http2备，实测空载合计 ~19MB）"
    menu_option 2 "单路 l4-socks（UDP 443，仅转发 TCP，内存/CPU 最低）"
    menu_option 3 "单路 socks（UDP 443，完整 TCP + UDP 转发）"
    menu_option 4 "单路 socks --http2（TCP 443，全 UDP 被封兜底）"
    menu_option 0 "取消"
    ask "请选择 [0-4] (默认 1): "
    case "$(printf '%s' "$REPLY" | tr -d ' \t\r')" in
        ""|1) printf 'dual\n' ;;
        2)    printf 'l4-socks\n' ;;
        3)    printf 'socks\n' ;;
        4)    printf 'socks-http2\n' ;;
        *)    return 1 ;;
    esac
}

# === [module: 90_main.sh] ===
# ------------------------------------------------------------------------------
# sing-box 服务控制、更新/自启/卸载、主菜单与入口路由
# ------------------------------------------------------------------------------
menu_service() {
    menu_title "sing-box 服务"
    menu_option 1 "重启服务"
    menu_option 2 "停止服务"
    menu_option 3 "启动服务"
    menu_option 4 "查看最近 50 行日志"
    menu_option 5 "清空日志文件（仅 OpenRC / 无 init）"
    menu_option 0 "返回"
    ask "请选择 [0-5]: "
    case "$REPLY" in
        1) restart_and_check ;;
        2) svc stop >/dev/null 2>&1; sleep 1; core_pid >/dev/null && err "❌ 停止失败" || info "✅ 已停止" ;;
        3) restart_and_check ;;
        4) show_log 50 ;;
        5) : > "$LOG_FILE" 2>/dev/null; info "✅ 已清空 $LOG_FILE" ;;
        *) return 0 ;;
    esac
    pause
}

update_core() {
    OLDV=$(core_version)
    info "当前核心版本: $OLDV，正在检查最新版..."
    install_sbox_deps || return 1
    download_core || return 1
    NEWV=$(core_version)
    restart_and_check
    info "✅ 核心版本: $OLDV -> $NEWV"
}

repair_autostart() {
    write_service
    install_self
    case "$INIT" in
        systemd) info "systemd 自启状态: $(systemctl is-enabled sing-box 2>/dev/null)" ;;
        openrc)  rc-update show default 2>/dev/null | grep -E 'sing-box|local' ;;
    esac
    restart_and_check
}

uninstall_all() {
    warn "⚠️ 即将卸载 sing-box：停止服务并删除核心、管理脚本、服务文件与 /etc/sing-box"
    warn "   配置会先备份到 /root/singbox-config-backup.json"
    confirm "确认卸载？" || return 1
    cp -f "$CONF_FILE" /root/singbox-config-backup.json 2>/dev/null || true
    svc stop >/dev/null 2>&1 || true
    warp_remove_managed_resources
    case "$INIT" in
        systemd)
            systemctl disable --now sbox-warp-keepalive.service >/dev/null 2>&1 || true
            systemctl disable --now sbox-usque.service sbox-usque-backup.service >/dev/null 2>&1 || true
            rm -f /etc/systemd/system/sbox-warp-keepalive.service /etc/systemd/system/sbox-usque.service /etc/systemd/system/sbox-usque-backup.service
            rm -f /etc/systemd/system/sing-box.service.d/10-sbox-warp.conf
            rmdir /etc/systemd/system/sing-box.service.d 2>/dev/null || true
            systemctl disable sing-box >/dev/null 2>&1 || true
            rm -f /etc/systemd/system/sing-box.service
            systemctl daemon-reload
            ;;
        openrc)
            rc-update del sing-box default >/dev/null 2>&1 || true
            rc-update del sbox-warp-keepalive default >/dev/null 2>&1 || true
            rc-update del sbox-usque default >/dev/null 2>&1 || true
            rc-update del sbox-usque-backup default >/dev/null 2>&1 || true
            rm -f /etc/init.d/sing-box /etc/local.d/sing-box.start /etc/init.d/sbox-warp-keepalive /etc/init.d/sbox-usque /etc/init.d/sbox-usque-backup
            ;;
        *)
            pkill -x sing-box 2>/dev/null || killall sing-box 2>/dev/null || true
            ;;
    esac
    rm -rf "$CONF_DIR"
    rm -f "$CORE_BIN" "$SLINK_BIN" "$LOG_FILE" "$MENU_BIN"
    info "✅ 已卸载完成（配置备份: /root/singbox-config-backup.json）"
    return 0
}

update_self() {
    _url="${GH_PROXY:-}https://raw.githubusercontent.com/wangxiangg1/sboxwarpinone/main/sbox.sh"
    _tmp="/tmp/sbox.sh.new.$$"
    info "⬇️  正在拉取最新管理脚本: $_url"
    if ! curl -fsSL --connect-timeout 10 --max-time 30 "$_url" -o "$_tmp"; then
        err "❌ 拉取最新脚本失败"
        rm -f "$_tmp"
        return 1
    fi
    if ! head -n1 "$_tmp" | grep -q '^#!/bin/sh' || ! grep -q 'SCRIPT_VERSION=' "$_tmp" || ! sh -n "$_tmp" >/dev/null 2>&1; then
        err "❌ 下载的脚本校验失败，已放弃覆盖"
        rm -f "$_tmp"
        return 1
    fi
    _new_ver=$(sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/\1/p' "$_tmp" | head -n1)
    cp -f "$_tmp" /root/sbox.sh && cp -f "$_tmp" /usr/local/bin/sbox && chmod +x /root/sbox.sh /usr/local/bin/sbox
    rm -f "$_tmp"
    info "✅ 管理脚本已更新至 v${_new_ver:-latest}，即将重新加载..."
    exec /usr/local/bin/sbox
}

show_header() {
    [ -n "$JSON_ENGINE" ] || detect_json_tool >/dev/null 2>&1 || true
    load_strategy
    PID=$(core_pid || true)
    if [ -n "$PID" ]; then
        MEM=$(awk '/VmRSS/{printf "%.1f MB", $2/1024}' "/proc/$PID/status" 2>/dev/null)
        STATUS="${C_G}● 运行中${C_N} (PID: $PID, 内存: $MEM)"
    else
        STATUS="${C_R}● 未运行${C_N}"
    fi
    menu_title "SBOX 管理中心 · v${SCRIPT_VERSION}"
    printf '  %s / %s / 核心 %s / JSON %s\n' \
        "$(uname -m)" "$OS_TYPE/$INIT" "$(core_version)" "${JSON_ENGINE:-none}"
    printf '  sing-box %b  |  解析策略 %s\n' "$STATUS" "$(strategy_label "$STRATEGY")"
    menu_section "主机公网出口"
    printf '  IPv4 %s  |  IPv6 %s\n' "${IPV4:-无}" "${IPV6:-无}"
    menu_section "WARP 出口"
    warp_show_channel_summary
    menu_section "当前节点"
    list_nodes_brief || true
    line
}

main_menu() {
    detect_ip
    while true; do
        show_header
        menu_title "主菜单"
        menu_section "节点管理"
        menu_option 1 "查看 / 导出节点链接"
        menu_option 2 "新增节点  ·  Hysteria2 / VLESS+WS / VLESS+Reality"
        menu_option 3 "修改节点参数"
        menu_option 4 "删除节点"
        menu_option 5 "配置 WS 的 Cloudflare Origin TLS"
        menu_section "基础与服务"
        menu_option 6 "切换 DNS 解析策略"
        menu_option 7 "sing-box 服务控制与日志"
        menu_option 8 "更新 sing-box 核心"
        menu_option 9 "检查 / 修复开机自启"
        menu_section "网络与出口"
        menu_option 10 "管理 WARP 出口（WireGuard / MASQUE 双模）"
        menu_option 11 "Cloudflare 测速"
        menu_option 12 "重新探测主机 IP"
        menu_section "系统"
        menu_option 13 "卸载 sing-box"
        menu_option 14 "更新 sbox 管理脚本"
        menu_option 0 "退出"
        line
        ask "请输入数字 [0-14]: "
        case "$REPLY" in
            1) show_links_menu; pause ;;
            2) menu_add_node ;;
            3) menu_modify_node ;;
            4) menu_delete_node ;;
            5) menu_tls_setup ;;
            6) menu_strategy ;;
            7) menu_service ;;
            8) update_core; pause ;;
            9) repair_autostart; pause ;;
            10) run_warp_setup; warp_invalidate_exit_ip_cache ;;
            11) cf_speedtest; pause ;;
            12) detect_ip; warp_invalidate_exit_ip_cache ;;
            13) uninstall_all && exit 0; pause ;;
            14) update_self; pause ;;
            0|q|Q) exit 0 ;;
            *) warn "无效输入" ;;
        esac
    done
}

do_install() {
    line
    echo "     sing-box 多入站轻量节点 —— 全新安装模式"
    line
    echo "=== [1/6] 识别系统环境并安装轻量依赖 ($OS_TYPE / $INIT) ==="
    install_sbox_deps || exit 1
    ensure_json_tool || exit 1

    echo "=== [2/6] 下载或复用官方 sing-box 核心 ==="
    download_core || exit 1

    echo "=== [3/6] 初始化配置文件 ==="
    detect_ip
    mkdir -p "$CONF_DIR" "$CERT_DIR"
    if [ -f "$CONF_FILE" ]; then
        warn "⚠️ 检测到系统已存在配置文件 $CONF_FILE，已自动完整保留！"
        load_strategy
    else
        STRATEGY="AsIs"
        case "$1" in
            hy2)     [ -n "${6:-}" ] && STRATEGY="$6" ;;
            ws)      [ -n "${4:-}" ] && STRATEGY="$4" ;;
            reality) [ -n "${4:-}" ] && STRATEGY="$4" ;;
        esac
        _eff_v6="${WARP_IPV6:-$IPV6}"
        if [ -t 0 ] && [ -z "$1" ] && [ -n "$_eff_v6" ]; then
            ask "检测到 IPv6 ($_eff_v6)，是否开启 IPv6 优先解析？[Y/n]: "
            case "$REPLY" in n|N) STRATEGY="AsIs" ;; *) STRATEGY="UseIPv6v4" ;; esac
        fi
        valid_strategy "$STRATEGY" || { err "❌ 解析策略不合法: $STRATEGY"; exit 1; }
        _base_tmp="$CONF_DIR/config.new.json"
        json_init_base_config "$STRATEGY" "$_base_tmp"
        "$CORE_BIN" check -c "$_base_tmp" >/dev/null 2>&1 || {
            err "❌ 基础配置校验失败"
            "$CORE_BIN" check -c "$_base_tmp" 2>&1 || true
            rm -f "$_base_tmp"
            exit 1
        }
        mv -f "$_base_tmp" "$CONF_FILE"

        echo "=== [4/6] 创建首个业务节点 ==="
        if [ "$1" = "hy2" ] && [ -n "$2" ]; then
            add_hy2_node_flow 0 "$2" "${3:-}" "${4:-deb.debian.org}" "${5:-}" || exit 1
        elif [ "$1" = "ws" ] && [ -n "$2" ]; then
            add_ws_node_flow 0 "$2" "${3:-/ws?ed=2048}" || exit 1
        elif [ "$1" = "reality" ] && [ -n "$2" ]; then
            add_reality_node_flow 0 "$2" "${3:-}" || exit 1
        elif [ -t 0 ]; then
            menu_title "选择首个入站节点"
            menu_option 1 "Hysteria2  ·  UDP 传输，自签证书"
            menu_option 2 "VLESS + WS  ·  可配 Cloudflare CDN / Origin TLS"
            menu_option 3 "VLESS + Reality  ·  TCP Vision"
            menu_option 4 "稍后再添加"
            ask "请选择首个节点类型 [1-4] (回车默认 1): "
            case "${REPLY:-1}" in
                1) add_hy2_node_flow 1 || exit 1 ;;
                2) add_ws_node_flow 1 || exit 1 ;;
                3) add_reality_node_flow 1 || exit 1 ;;
                *) info "ℹ️ 已跳过节点创建，稍后可在菜单选 2 新增节点。" ;;
            esac
        else
            add_hy2_node_flow 0 "443" "" "deb.debian.org" "" || exit 1
        fi
    fi

    echo "=== [5/6] 配置守护进程与开机自启 ($INIT) ==="
    write_service
    install_self
    restart_and_check

    echo "=== [6/6] sing-box 安装完成 ==="
    free -m 2>/dev/null || true
    if [ -t 0 ] && [ -z "$1" ]; then
        echo ""
        if confirm "是否现在配置三路内核态 WARP（并由 sing-box 自动容灾）？"; then
            run_warp_setup "auto" || true
        fi
    fi

    show_links_menu || true
    info "🎉 以后随时输入 sbox 打开多入站管理菜单，sbox link（或 slink）导出全部链接。"
}

ENTRY_DIR=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")" 2>/dev/null)
need_root
detect_os

if is_installed; then
    case "$1" in
        link)  show_links_menu; exit 0 ;;
        list)  list_nodes_brief; exit 0 ;;
        speed) cf_speedtest; exit 0 ;;
        warp)  shift; warp_command "$@"; exit $? ;;
        *)     main_menu ;;
    esac
else
    if [ "$SELF_NAME" = "sbox" ]; then
        err "❌ 尚未安装 sing-box，请先运行安装脚本: /root/sbox.sh"
        exit 1
    fi
    do_install "$@"
fi
