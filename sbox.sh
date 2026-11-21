#!/bin/sh
# SBOX_MENU_SCRIPT_MARKER (请勿删除此行：用于识别 /usr/local/bin/sbox 是管理脚本而非二进制)
# ==============================================================================
# 脚本名称: sbox.sh  (Alpine / Debian / Ubuntu 通用轻量 sing-box 多入站安装 + 管理脚本)
# 仓库项目: sboxwarpinone (全合一单文件版，内置 warp-fix.sh，支持 age 加密内置 Origin TLS 证书)
# 版本    : 1.0.0
# 核心特性:
#   - 多入站管理：同实例原生支持 Hysteria2 / VLESS+WS (CF CDN) / VLESS+Reality 共存
#   - 新版无警告配置：完全对齐 sing-box 1.12+ / 1.14+ DNS 与 default_domain_resolver 语法
#   - 轻量 JSON 引擎：优先复用系统已有 python3 或 jq，均无时自动安装极轻量 jq (~1MB)
#   - 小内存容器保护：OpenRC / systemd 自动按容器内存上限配置 GOMEMLIMIT
#   - 加密 Origin TLS：支持内嵌经 age 加密的 Cloudflare Origin 证书，选定启用时提示输入口令解锁
#   - 配套完整生态：Reality SNI 探活优选池、WARP 安装 + 内嵌 LXC 内核态修复、CF 测速
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
# 源码构建: 由 src/*.sh + warp-fix.sh 经 build.sh (及 GitHub Actions) 合并生成，请勿直接手改 sbox.sh
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
SCRIPT_VERSION="1.0.0"
GH_PROXY="${GH_PROXY:-}"

# 透明转发：以 sbox 名义被调用且带非保留参数时，直接交给官方 sing-box 核心
SELF_NAME=$(basename "$0" 2>/dev/null)
if [ "$SELF_NAME" = "sbox" ]; then
    case "$1" in
        ""|menu|link|list|speed) ;;
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

    line
    echo " Reality SNI 选择（当前备选池共 ${_cnt} 个域名）"
    line
    echo " 1. 探测备选池中所有 SNI 的 TLS 1.3 / H2 连通性与延迟"
    echo " 2. 直接从备选池编号选择（跳过测速）"
    echo " 3. 手动输入自定义 SNI 域名"
    echo " 0. 取消"
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
                echo " ${_i}. ${_h}"
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
    line
    echo " 新增入站节点（可同机多协议共存）"
    line
    echo " 1. Hysteria2       (UDP 高速直连 / NAT 需通 UDP，默认关闭混淆)"
    echo " 2. VLESS + WS      (适合套 Cloudflare CDN / Origin TLS)"
    echo " 3. VLESS + Reality (TCP Vision，适合直连 / 中转机转发)"
    echo " 0. 返回"
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
    line
    echo " 选择要修改参数的节点："
    line
    pick_node all || { pause; return 0; }

    _idx="$SEL_IDX"
    _tag="$SEL_TAG"
    _proto="$SEL_PROTO"
    _net="$SEL_NET"
    _sec="$SEL_SEC"
    _clients="$SEL_CLIENTS"
    _crt_old="$SEL_WSPATH"

    line
    echo " 正在修改: ${_tag:-默认节点} (端口: $SEL_PORT | 协议: $_proto | 客户端数: $_clients)"
    line
    echo " 1. 修改监听端口"
    if [ "$_proto" = "hysteria2" ]; then
        echo " 2. 更换连接密码 (单用户安全模式)"
        echo " 3. 重签自签证书 / 换伪装域名"
        echo " 4. 开启或关闭 salamander 混淆"
    elif [ "$_sec" = "reality" ]; then
        echo " 2. 修改/重测 Reality SNI"
        echo " 3. 更换 UUID (单用户安全模式)"
        echo " 4. 重新生成 Reality 密钥对与 ShortId"
    else
        echo " 2. 修改 WS 路径"
        echo " 3. 更换 UUID (单用户安全模式)"
    fi
    echo " 0. 返回"
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
    line
    echo " 选择要删除的节点："
    line
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
# 解析策略、age 加密内置 Cloudflare Origin TLS 注入、WARP 修复与 Cloudflare 测速
# ------------------------------------------------------------------------------
menu_strategy() {
    load_strategy
    line
    echo " 当前全局解析策略: $(strategy_label "$STRATEGY")"
    echo " 可用 IPv6 出口  : ${WARP_IPV6:-${IPV6:-未检测到}}$([ -n "$WARP_IPV6" ] && [ -z "$IPV6" ] && echo " (WARP提供)")"
    line
    echo " 1. 系统默认 AsIs       (不强制偏好，按本地 DNS 解析)"
    echo " 2. IPv6 优先 UseIPv6v4 (prefer_ipv6：目标有 AAAA 记录走 IPv6)"
    echo " 3. IPv4 优先 UseIPv4v6 (prefer_ipv4)"
    echo " 4. 仅 IPv6   UseIPv6   (ipv6_only)"
    echo " 5. 仅 IPv4   UseIPv4   (ipv4_only)"
    echo " 0. 返回"
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
            [ -n "${IPV6}${WARP_IPV6}" ] || detect_ip
            if [ -z "${IPV6}${WARP_IPV6}" ]; then
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
    sys.exit(124)
if hasattr(os, "waitstatus_to_exitcode"):
    sys.exit(os.waitstatus_to_exitcode(st))
sys.exit(0 if st == 0 else (((st >> 8) & 0xff) or 1))
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
    line
    if has_embedded_origin_age; then
        echo " 1. 使用内置加密 Cloudflare Origin 证书（需输入密码解锁，配合 CF Full 模式）"
    else
        echo " 1. 使用内置加密 Cloudflare Origin 证书（当前副本未注入密文，需经 Actions 构建）"
    fi
    echo " 2. 指定自定义证书与私钥文件路径（配合自有域名开启 CF Full strict）"
    echo " 0. 取消"
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

run_warp_fix_only() {
    FIX_SCRIPT=$(find_helper_script "warp-fix.sh" || true)
    if [ -n "$FIX_SCRIPT" ]; then
        chmod +x "$FIX_SCRIPT" 2>/dev/null || true
        sh "$FIX_SCRIPT"
        return $?
    fi
    if command -v run_embedded_warp_fix >/dev/null 2>&1; then
        run_embedded_warp_fix
        return $?
    fi
    warn "⚠️ 未找到 warp-fix.sh（已查找 ${ENTRY_DIR:-/root}、/root、当前目录、/usr/local/bin）。"
    return 1
}

run_warp_install_flow() {
    line
    warn "⚠️ NAT 主机提示: 若需保持当前 SSH 端口回程稳定，请勿在 WARP 菜单中随意接管全局 IPv4 默认路由。"
    ensure_warp_deps || return 1
    WARP_MENU="/root/warp-menu.sh"
    WARP_URL="${GH_PROXY}https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh"
    info "⬇️  下载 fscarmen WARP 脚本: $WARP_URL"
    if ! curl -fsSL -o "$WARP_MENU" "$WARP_URL" && ! wget -qO "$WARP_MENU" "$WARP_URL"; then
        err "❌ WARP 脚本下载失败，请检查网络连通性"
        return 1
    fi
    chmod +x "$WARP_MENU"
    bash "$WARP_MENU"

    if [ -f /etc/wireguard/warp.conf ] || wg show warp >/dev/null 2>&1 || ps -ef | grep -v grep | grep -q wireguard-go; then
        echo ""
        info "🔍 检测到已配置 WARP，正在检查 LXC 内核态 WireGuard 状态..."
        run_warp_fix_only || true
    fi

    detect_ip
    load_strategy
    if [ -n "${IPV6}${WARP_IPV6}" ] && [ "$STRATEGY" = "AsIs" ]; then
        if confirm "检测到当前已有 IPv6 (${IPV6:-$WARP_IPV6})，是否将 sing-box 解析策略切换为 IPv6 优先 (UseIPv6v4)？"; then
            _tmp="$CONF_DIR/config.patch.json"
            rm -f "$_tmp"
            if json_exec patch_strategy "$CONF_FILE" "UseIPv6v4" "$_tmp" && safe_apply_patch "$_tmp"; then
                sync_compat_env
                restart_and_check
            fi
        fi
    fi
}

run_warp_setup() {
    if [ "$1" = "auto" ]; then
        run_warp_install_flow
        return $?
    fi
    line
    echo " 1. 安装 / 管理 WARP（拉起 fscarmen 脚本，完成后自动检查 LXC 内核态）"
    echo " 2. 仅执行 LXC 内核态 WireGuard 检查与修复（调用 warp-fix.sh）"
    echo " 0. 返回"
    ask "请选择 [0-2]: "
    case "$REPLY" in
        1) run_warp_install_flow ;;
        2) run_warp_fix_only ;;
        *) return 0 ;;
    esac
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
        echo " 1. 仅测 IPv4 (默认)"
        echo " 2. 仅测 IPv6"
        echo " 3. IPv4 + IPv6 都测"
        echo " 0. 返回"
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

# === [embedded: warp-fix.sh] ===
run_embedded_warp_fix() {
    _wf_tmp="/tmp/warp-fix.$$.sh"
    cat <<'__EMBEDDED_WARP_FIX_EOF__' > "$_wf_tmp"
#!/bin/sh
# ==============================================================================
# 脚本名称: warp-fix.sh (Alpine / Debian / Ubuntu LXC WARP 内核态无损修复脚本)
# 适用环境: Alpine Linux 及 Debian/Ubuntu LXC 小内存容器
# 核心作用: 纠正 fscarmen/warp 脚本在部分隐藏了 /sys/module/wireguard 的 LXC 容器中
#           误判安装用户态 wireguard-go 的问题，无损切回原生内核态 WireGuard。
# 设计原则:
#   1. 宿主机不支持原生内核态 WireGuard -> 直接原样退出 (0 修改)
#   2. 当前已经是内核态运行 -> 直接原样退出 (0 断流)
#   3. 100% 保留作者原有的 keepalive.sh (warp n) 防 WARP 假死自愈机制
#   4. 切换前备份原文件，异常时自动回滚，绝不断网失联
# 用法:
#   chmod +x /root/warp-fix.sh && /root/warp-fix.sh
# ==============================================================================

echo "==> [1/4] 探测当前容器宿主机是否支持原生内核态 WireGuard..."
if ! ip link add wg_probe0 type wireguard 2>/dev/null; then
    echo "⚠️ 当前宿主机不支持原生内核态 WireGuard，无需修复，保持原状退出。"
    exit 0
fi
ip link del wg_probe0 2>/dev/null
echo "✅ 探测通过：宿主机支持原生内核态 WireGuard！"

echo "==> [2/4] 检查当前是否被误装/启用了用户态 wireguard-go..."
if ! ps -ef | grep -v grep | grep -q wireguard-go && \
   [ ! -f /usr/bin/wireguard-go ] && \
   [ ! -f /usr/local/bin/wireguard-go ] && \
   grep -q "add_if" /usr/bin/wg-quick 2>/dev/null; then
    echo "✅ 当前 WARP 已经是纯内核态运行，无需任何修复！"
    exit 0
fi

echo "==> [3/4] 检测到 wireguard-go 用户态残留/篡改，正在切换回原生内核态..."
wg-quick down warp 2>/dev/null || true
killall -9 wireguard-go 2>/dev/null || true

# 备份以便异常时自动回滚
[ -f /usr/bin/wireguard-go ] && mv -f /usr/bin/wireguard-go /usr/bin/wireguard-go.bak
[ -f /usr/local/bin/wireguard-go ] && mv -f /usr/local/bin/wireguard-go /usr/local/bin/wireguard-go.bak
cp -f /usr/bin/wg-quick /usr/bin/wg-quick.bak 2>/dev/null || true

# 还原官方原版 wg-quick 脚本（自适应 Alpine apk 与 Debian/Ubuntu apt）
if command -v apk >/dev/null 2>&1; then
    apk fix --reinstall wireguard-tools-wg-quick >/dev/null 2>&1 || \
        sed -i 's/wireguard-go "$INTERFACE"/ip link add "$INTERFACE" type wireguard/g' /usr/bin/wg-quick
elif command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get install --reinstall -y --no-install-recommends wireguard-tools >/dev/null 2>&1 || \
        sed -i 's/wireguard-go "$INTERFACE"/ip link add "$INTERFACE" type wireguard/g' /usr/bin/wg-quick
else
    sed -i 's/wireguard-go "$INTERFACE"/ip link add "$INTERFACE" type wireguard/g' /usr/bin/wg-quick
fi

unset WG_QUICK_USERSPACE_IMPLEMENTATION
sed -i '/WG_QUICK_USERSPACE_IMPLEMENTATION/d' /etc/profile /etc/local.d/* /etc/init.d/* /lib/systemd/system/wg-quick@.service /etc/systemd/system/wg-quick@*.service.d/* 2>/dev/null || true
command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload 2>/dev/null || true

echo "==> [4/4] 重新以纯内核态拉起 WARP（保留原有 keepalive.sh 保活机制）..."
if wg-quick up warp; then
    rm -f /usr/bin/wireguard-go.bak /usr/local/bin/wireguard-go.bak /usr/bin/wg-quick.bak
    echo "--------------------------------------------------------"
    wg show warp
    echo "--------------------------------------------------------"
    echo "🎉 修复完成！当前 wireguard-go 进程数: $(ps -ef | grep -v grep | grep -c wireguard-go)"
else
    echo "❌ 内核态拉起异常，正在自动回滚至原状..."
    [ -f /usr/bin/wireguard-go.bak ] && mv -f /usr/bin/wireguard-go.bak /usr/bin/wireguard-go
    [ -f /usr/local/bin/wireguard-go.bak ] && mv -f /usr/local/bin/wireguard-go.bak /usr/local/bin/wireguard-go
    [ -f /usr/bin/wg-quick.bak ] && mv -f /usr/bin/wg-quick.bak /usr/bin/wg-quick
    wg-quick up warp
    exit 1
fi
__EMBEDDED_WARP_FIX_EOF__
    sh "$_wf_tmp"
    _wf_rc=$?
    rm -f "$_wf_tmp"
    return $_wf_rc
}

# === [embedded: origin.age] ===
write_embedded_origin_age() {
    cat <<'__EMBEDDED_ORIGIN_AGE_EOF__' > "$1"
-----BEGIN AGE ENCRYPTED FILE-----
YWdlLWVuY3J5cHRpb24ub3JnL3YxCi0+IHNjcnlwdCBiTkd0OXVDTDcyMXNnemdG
a3FzV1Z3IDE4CnFJMlIwMzFxbjdFMW5tektrZk0vYVRDMHg3UXZJMjZIeERJYjhp
VUZwQ0UKLS0tIGtEYjluSFdIQ0s4ZG8yMWNZZ3MyKzlWaCswdGsrZzFvRE8rclg2
eGFVa2sKAiMCfuYijLzElwpBWdmfMjJG4LfiilbgY43umxhER5sDj05T5/cm2Lqs
HKXEdN8R6HkxTqll3/npy6g7TacEJ4f1Wl649p5kwILTd0iilbeMJF3Y21W+mk7b
c/vQ/h8Q0qwvcXGfJ/dXyg3Qdtz+2TCvs6X5Z6FTFiF0qmXZSTM1SQvKGjIFfKEZ
PJYoKsBgzbNxmzebXZgBQsA/Vg68J5hgqkDGCU5bTAMjtLQ48tuihYxGInev0bfc
+nUtzM8F40DdbLNAEDyFcN1ecFScWtpjM7fJpDX/r1VBGA8kQlac3qfSyIP0EUsI
J+AQvU2ceLh4IUwZeyUCDROSst+FeuiwBdfebGcXkx7lvjWYe9719gErUOs99E5G
DSUojbMqiV+3BzPPOHXS1tU4kTYdsd8WViJIbRPDKI3+zAizco/XLyy0Prndv+uX
n5HTPbXRAB3aaY6ZbnQCrQ0vC38w/wjhBy9w7Lr0tc3VEneInMo+ubBEAkTVoECb
uaxcZrzmM8oPCMMYildVb/soVeSbHZoyd8agQpaQNMFe4pqqe+0oLcWmtH0dF+cu
n/PIpHpQHFRWc4/hcY9eR58ci+bInNQcvxtB4unIQT3x9cvEqL/p5oog5Ec0lVkH
yd7m8Yw8h9kn+C+W9iIPoBSJn4og6ZDax5X3ukV88kgIJXcq01o+q8i8vlOZ5B1h
glaZIwKsrLux2DoRM8GrFKGn2CwqH+rk+nSj3/+/93keClixoytQsUXwdoh2jUjy
uJbX7oiSwUQvYVTkAJhkM5uKOI0lCk3VYOxZR6VIpaU21zaNBTWrsrJZG3aJWh/t
ZLo1QWLCdE9dK6yOjXR2yezdLVLo9XNowDMdSQ3fEbmUV29hNTDqH2JxlIzd8H5s
4941Y0vp7CvIbCI7LgYDbQm3P74zmK8qMper5gW1H2y2UNK6jpHvTqeNy80y+5La
YW+hFoia1PEjldlLet/HpKPgliM6H/Dzf3d9rFGe61O+/z8POmSaS8+9JYRvrLXC
OeCcbkkw6zF4d44CySSP/WojscywNxkF4hek7c5JdMOtAZ8+U9sQtr4UnqBKpi9K
yIeDAipKAxKwioEB3mNbUM7Ns3eNdTUonZYGs2NQ+uROcIHPX4irBaFpQKY+AE8D
e/7mVWUPg5pZhNvtWct8LczohtD2ZZUKL8u+bQyW3Nl7I23tUEsLN/ODEJjvyVCd
2ZvCGqc/h4mYQrxOQ83cnwsJpKlPV7Z3xvKeaJKEzDm/VUtX94ao6Y7XFsT7cOdS
Vl1Im6RhPRSTOuYXH+AH6/8fTiH9GnDMixFO4IPLDsnq3b2Gh411Mi02whzAanLn
5Vuwx+hfEt7VnmAF/2lin/tB25b/ByNR0UF6gVe3z6NLBOT/uVMsfA8gCCj7I4yA
eb2+5txAusp3Cs5owhZMvRoZtD0y4UhPzQh7L1klAAhA6K/RMvbCyptsSqPtqsr6
+Cnd/N5kjjEjThIh4XtshNU8F24weBzxcvNlK+CnJ0oJF1kIwBVXRUYBY3T1xQ/K
v6tv1JeHF6T3a8yc5ajdkCHTfxjXFukaY/VLCkwAjbppBkGBZ0Va+1qfwyjSM3CP
DSoDpqR4C3zc4DmKJzLNfmLVq336HSJJT7G1m2ove2L9D5C+v+c/75AljfHoiUTo
dupd3Qwa1zTTUA56vTVa8qBp/s3ykJpinG0+RG3sb0tlLFkzN+6viWIyaUV9vxAi
vvl7uwydsaiMEVo5XEvifiBOWxd0jHdrHHXrfMHVnT9/oMpF2Enq6EYkACjCtcZk
Jwq9aiOCTukIUKBdsOfLC+LE056Mdb2aD9LTQpRqKA7igq0tFglO3WWIEB0yh/0Z
+Q2fZBVMJL69DLWos7Zn8aKFoYf5H2j2+0BVvzUvrfpcCox3yOtQ408+2hUgymM6
ar8v8bjcPp3XEk5DOCGhEhZL/0P3
-----END AGE ENCRYPTED FILE-----
__EMBEDDED_ORIGIN_AGE_EOF__
}

# === [module: 90_main.sh] ===
# ------------------------------------------------------------------------------
# sing-box 服务控制、更新/自启/卸载、主菜单与入口路由
# ------------------------------------------------------------------------------
menu_service() {
    line
    echo " 1. 重启 sing-box"
    echo " 2. 停止 sing-box"
    echo " 3. 启动 sing-box"
    echo " 4. 查看最近 50 行日志"
    echo " 5. 清空日志文件 (仅 OpenRC / 无 init 环境)"
    echo " 0. 返回"
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
    case "$INIT" in
        systemd)
            systemctl disable sing-box >/dev/null 2>&1 || true
            rm -f /etc/systemd/system/sing-box.service
            systemctl daemon-reload
            ;;
        openrc)
            rc-update del sing-box default >/dev/null 2>&1 || true
            rm -f /etc/init.d/sing-box /etc/local.d/sing-box.start
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
    [ -n "$JSON_ENGINE" ] || detect_json_engine >/dev/null 2>&1 || true
    load_strategy
    PID=$(core_pid || true)
    if [ -n "$PID" ]; then
        MEM=$(awk '/VmRSS/{printf "%.1f MB", $2/1024}' "/proc/$PID/status" 2>/dev/null)
        STATUS="${C_G}● 运行中${C_N} (PID: $PID, 内存: $MEM)"
    else
        STATUS="${C_R}● 未运行${C_N}"
    fi
    echo ""
    line
    printf "${C_B}   sing-box 多入站轻量管理脚本 v%s (Alpine/Debian 通用)${C_N}\n" "$SCRIPT_VERSION"
    line
    echo " 系统环境: $(uname -m) / $OS_TYPE ($INIT) | 核心: $(core_version) | JSON: ${JSON_ENGINE:-none}"
    printf " 运行状态: %b | 解析策略: ${C_Y}%s${C_N}\n" "$STATUS" "$(strategy_label "$STRATEGY")"
    echo " 真实 IP : IPv4=${IPV4:-无} | IPv6=${IPV6:-无}"
    if [ -n "$WARP_IPV4$WARP_IPV6" ]; then
        echo " WARP出口: IPv4=${WARP_IPV4:-未接管} | IPv6=${WARP_IPV6:-未接管}"
    fi
    echo "----------------------------------------------------------------"
    echo " 当前入站节点:"
    list_nodes_brief || true
    echo "----------------------------------------------------------------"
}

main_menu() {
    detect_ip
    while true; do
        show_header
        echo " 1. 查看 / 导出所有节点链接 (sbox link)"
        echo " 2. 新增节点 (Hysteria2 / VLESS+WS / VLESS+Reality)"
        echo " 3. 修改节点参数 (端口 / 密码 / 混淆 / 路径 / SNI / UUID)"
        echo " 4. 删除指定节点"
        echo " 5. 为 WS 节点配置 Cloudflare Origin TLS"
        echo " 6. 切换全局解析策略 (AsIs / IPv6优先 / IPv4优先)"
        echo " 7. 服务控制 (重启 / 停止 / 启动 / 日志)"
        echo " 8. 更新 sing-box 核心到最新版"
        echo " 9. 检查 / 修复开机自启"
        echo "10. 安装 WARP / LXC 内核态修复 (warp-fix.sh)"
        echo "11. Cloudflare 测速 (100MB 下载 + 50MB 上传)"
        echo "12. 重新探测本机 IP"
        echo "13. 卸载 sing-box"
        echo "14. 更新管理脚本 (sbox.sh)"
        echo " 0. 退出"
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
            10) run_warp_setup; pause ;;
            11) cf_speedtest; pause ;;
            12) detect_ip ;;
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
            echo " 1. Hysteria2       (UDP 高速直连 / 自动签证书，默认)"
            echo " 2. VLESS + WS      (适合套 Cloudflare CDN / Origin TLS)"
            echo " 3. VLESS + Reality (TCP Vision，适合直连 / 中转机转发)"
            echo " 4. 暂不添加节点，稍后在菜单中添加"
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
        if confirm "是否现在安装 WARP（并自动检查修复 LXC 内核态 WireGuard）？"; then
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
        *)     main_menu ;;
    esac
else
    if [ "$SELF_NAME" = "sbox" ]; then
        err "❌ 尚未安装 sing-box，请先运行安装脚本: /root/sbox.sh"
        exit 1
    fi
    do_install "$@"
fi
