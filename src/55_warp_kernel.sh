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
