#!/bin/sh
# ------------------------------------------------------------------------------
# sboxwarpinone 单文件合并构建脚本：
#   1) 合并 src/*.sh 为单文件 sbox.sh（锁定 LF 行尾 + sh -n 语法检查）
#   2) 自动内嵌 warp-fix.sh 为 run_embedded_warp_fix()
#   3) 当指定 AGE_ARMOR_FILE 且包含有效 age 密文块时，自动内嵌 write_embedded_origin_age()
#   4) 强制执行明文私钥泄漏阻断扫描
# ------------------------------------------------------------------------------
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_DIR="${SCRIPT_DIR}/src"
OUT_FILE="${SCRIPT_DIR}/sbox.sh"
TMP_FILE="${OUT_FILE}.tmp.$$"
AGE_ARMOR_FILE="${AGE_ARMOR_FILE:-}"

[ -d "$SRC_DIR" ] || { echo "❌ 未找到源码目录: $SRC_DIR" >&2; exit 1; }
: > "$TMP_FILE"
_first=1

for _part in \
    "${SRC_DIR}/00_header.sh" \
    "${SRC_DIR}/10_common.sh" \
    "${SRC_DIR}/20_json_engine.sh" \
    "${SRC_DIR}/25_sni_pool.sh" \
    "${SRC_DIR}/30_service.sh" \
    "${SRC_DIR}/40_nodes.sh" \
    "${SRC_DIR}/50_tls_warp_cf.sh" \
    "${SRC_DIR}/90_main.sh"
do
    [ -f "$_part" ] || { echo "❌ 缺少源码模块: $_part" >&2; rm -f "$TMP_FILE"; exit 1; }
    _name=$(basename "$_part")

    if [ "$_name" = "90_main.sh" ]; then
        if [ -f "${SCRIPT_DIR}/warp-fix.sh" ]; then
            printf '\n# === [embedded: warp-fix.sh] ===\n' >> "$TMP_FILE"
            cat <<'EOF' >> "$TMP_FILE"
run_embedded_warp_fix() {
    _wf_tmp="/tmp/warp-fix.$$.sh"
    cat <<'__EMBEDDED_WARP_FIX_EOF__' > "$_wf_tmp"
EOF
            tr -d '\r' < "${SCRIPT_DIR}/warp-fix.sh" >> "$TMP_FILE"
            cat <<'EOF' >> "$TMP_FILE"
__EMBEDDED_WARP_FIX_EOF__
    sh "$_wf_tmp"
    _wf_rc=$?
    rm -f "$_wf_tmp"
    return $_wf_rc
}
EOF
        fi

        if [ -n "$AGE_ARMOR_FILE" ] && [ -f "$AGE_ARMOR_FILE" ]; then
            if ! grep -q "BEGIN AGE ENCRYPTED FILE" "$AGE_ARMOR_FILE"; then
                echo "❌ AGE_ARMOR_FILE 不是有效的 ASCII age 密文文件: $AGE_ARMOR_FILE" >&2
                rm -f "$TMP_FILE"
                exit 1
            fi
            printf '\n# === [embedded: origin.age] ===\n' >> "$TMP_FILE"
            cat <<'EOF' >> "$TMP_FILE"
write_embedded_origin_age() {
    cat <<'__EMBEDDED_ORIGIN_AGE_EOF__' > "$1"
EOF
            tr -d '\r' < "$AGE_ARMOR_FILE" >> "$TMP_FILE"
            cat <<'EOF' >> "$TMP_FILE"
__EMBEDDED_ORIGIN_AGE_EOF__
}
EOF
        fi
    fi

    if [ "$_first" = "1" ]; then
        tr -d '\r' < "$_part" >> "$TMP_FILE"
        _first=0
    else
        printf '\n# === [module: %s] ===\n' "$_name" >> "$TMP_FILE"
        sed '1{/^#!/d;}' "$_part" | tr -d '\r' >> "$TMP_FILE"
    fi
done

if grep -Eq -- '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|-----BEGIN CERTIFICATE-----' "$TMP_FILE"; then
    echo "❌ 安全拦截：检测到产物中包含明文证书或私钥，已中止构建！" >&2
    rm -f "$TMP_FILE"
    exit 1
fi

sh -n "$TMP_FILE"
mv -f "$TMP_FILE" "$OUT_FILE"
chmod +x "$OUT_FILE" 2>/dev/null || true
_lines=$(wc -l < "$OUT_FILE" | tr -d ' ')
_age_flag="无内置证书密文"
[ -n "$AGE_ARMOR_FILE" ] && [ -f "$AGE_ARMOR_FILE" ] && _age_flag="已注入 age 加密证书"
echo "✅ 已合并构建: $OUT_FILE ($_lines 行，LF 行尾，sh -n 校验通过，$_age_flag)"
