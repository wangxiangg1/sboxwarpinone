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
    _eff=$(curl -fsSLI -o /dev/null -w '%{url_effective}' --max-time 10 "${GH_PROXY}https://github.com/SagerNet/sing-box/releases/latest" 2>/dev/null || true)
    _ver=$(printf '%s' "$_eff" | sed -n 's|.*/tag/v\?\([^/?#]*\).*|\1|p')
    if [ -z "$_ver" ]; then
        _ver=$(curl -fsSL --max-time 10 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\?\([^"]*\)".*/\1/p' | head -n1)
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
    [ -n "$_ver" ] || { err "❌ 无法获取 sing-box 最新版本号（可设置 GH_PROXY 重试）"; return 1; }

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
    URL="${GH_PROXY}https://github.com/SagerNet/sing-box/releases/download/v${_ver}/${PKG}.tar.gz"
    info "⬇️  下载: $URL"
    if ! curl -fL --retry 2 -o "$TMPD/sbox.tar.gz" "$URL"; then
        err "❌ 下载失败（可设置 GH_PROXY 环境变量使用加速前缀后重试）"
        rm -rf "$TMPD"
        return 1
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
