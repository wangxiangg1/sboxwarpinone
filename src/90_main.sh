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
