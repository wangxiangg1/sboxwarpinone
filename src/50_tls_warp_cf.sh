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
