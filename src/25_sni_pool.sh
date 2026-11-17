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
