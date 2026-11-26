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
