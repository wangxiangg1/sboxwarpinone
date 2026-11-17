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
