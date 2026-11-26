#!/bin/sh
# SBOX_MENU_SCRIPT_MARKER (请勿删除此行：用于识别 /usr/local/bin/sbox 是管理脚本而非二进制)
# ==============================================================================
# 脚本名称: sbox.sh  (Alpine / Debian / Ubuntu 通用轻量 sing-box 多入站安装 + 管理脚本)
# 仓库项目: sboxwarpinone (全合一单文件版，支持内核态 WARP 多出口容灾与 age 加密内置 Origin TLS 证书)
# 版本    : 1.1.7
# 核心特性:
#   - 多入站管理：同实例原生支持 Hysteria2 / VLESS+WS (CF CDN) / VLESS+Reality 共存
#   - 新版无警告配置：完全对齐 sing-box 1.12+ / 1.14+ DNS 与 default_domain_resolver 语法
#   - 轻量 JSON 引擎：优先复用系统已有 python3 或 jq，均无时自动安装极轻量 jq (~1MB)
#   - 小内存容器保护：OpenRC / systemd 自动按容器内存上限配置 GOMEMLIMIT
#   - 加密 Origin TLS：支持内嵌经 age 加密的 Cloudflare Origin 证书，选定启用时提示输入口令解锁
#   - 内核态 WARP：独立 WireGuard 网卡、sing-box URLTest 容灾、后台端点轮换与故障换号
#   - 配套完整生态：Reality SNI 探活优选池、CF 测速
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
# 源码构建: 由 src/*.sh 经 build.sh (及 GitHub Actions) 合并生成，请勿直接手改 sbox.sh
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
SCRIPT_VERSION="1.1.7"
GH_PROXY="${GH_PROXY:-}"

# 透明转发：以 sbox 名义被调用且带非保留参数时，直接交给官方 sing-box 核心
SELF_NAME=$(basename "$0" 2>/dev/null)
if [ "$SELF_NAME" = "sbox" ]; then
    case "$1" in
        ""|menu|link|list|speed|warp) ;;
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
