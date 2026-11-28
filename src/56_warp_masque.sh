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
