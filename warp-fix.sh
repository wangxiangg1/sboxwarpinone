#!/bin/sh
# ==============================================================================
# 脚本名称: warp-fix.sh (Alpine / Debian / Ubuntu LXC WARP 内核态无损修复脚本)
# 适用环境: Alpine Linux 及 Debian/Ubuntu LXC 小内存容器
# 核心作用: 纠正 fscarmen/warp 脚本在部分隐藏了 /sys/module/wireguard 的 LXC 容器中
#           误判安装用户态 wireguard-go 的问题，无损切回原生内核态 WireGuard。
# 设计原则:
#   1. 宿主机不支持原生内核态 WireGuard -> 直接原样退出 (0 修改)
#   2. 当前已经是内核态运行 -> 直接原样退出 (0 断流)
#   3. 100% 保留作者原有的 keepalive.sh (warp n) 防 WARP 假死自愈机制
#   4. 切换前备份原文件，异常时自动回滚，绝不断网失联
# 用法:
#   chmod +x /root/warp-fix.sh && /root/warp-fix.sh
# ==============================================================================

echo "==> [1/4] 探测当前容器宿主机是否支持原生内核态 WireGuard..."
if ! ip link add wg_probe0 type wireguard 2>/dev/null; then
    echo "⚠️ 当前宿主机不支持原生内核态 WireGuard，无需修复，保持原状退出。"
    exit 0
fi
ip link del wg_probe0 2>/dev/null
echo "✅ 探测通过：宿主机支持原生内核态 WireGuard！"

echo "==> [2/4] 检查当前是否被误装/启用了用户态 wireguard-go..."
if ! ps -ef | grep -v grep | grep -q wireguard-go && \
   [ ! -f /usr/bin/wireguard-go ] && \
   [ ! -f /usr/local/bin/wireguard-go ] && \
   grep -q "add_if" /usr/bin/wg-quick 2>/dev/null; then
    echo "✅ 当前 WARP 已经是纯内核态运行，无需任何修复！"
    exit 0
fi

echo "==> [3/4] 检测到 wireguard-go 用户态残留/篡改，正在切换回原生内核态..."
wg-quick down warp 2>/dev/null || true
killall -9 wireguard-go 2>/dev/null || true

# 备份以便异常时自动回滚
[ -f /usr/bin/wireguard-go ] && mv -f /usr/bin/wireguard-go /usr/bin/wireguard-go.bak
[ -f /usr/local/bin/wireguard-go ] && mv -f /usr/local/bin/wireguard-go /usr/local/bin/wireguard-go.bak
cp -f /usr/bin/wg-quick /usr/bin/wg-quick.bak 2>/dev/null || true

# 还原官方原版 wg-quick 脚本（自适应 Alpine apk 与 Debian/Ubuntu apt）
if command -v apk >/dev/null 2>&1; then
    apk fix --reinstall wireguard-tools-wg-quick >/dev/null 2>&1 || \
        sed -i 's/wireguard-go "$INTERFACE"/ip link add "$INTERFACE" type wireguard/g' /usr/bin/wg-quick
elif command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get install --reinstall -y --no-install-recommends wireguard-tools >/dev/null 2>&1 || \
        sed -i 's/wireguard-go "$INTERFACE"/ip link add "$INTERFACE" type wireguard/g' /usr/bin/wg-quick
else
    sed -i 's/wireguard-go "$INTERFACE"/ip link add "$INTERFACE" type wireguard/g' /usr/bin/wg-quick
fi

unset WG_QUICK_USERSPACE_IMPLEMENTATION
sed -i '/WG_QUICK_USERSPACE_IMPLEMENTATION/d' /etc/profile /etc/local.d/* /etc/init.d/* /lib/systemd/system/wg-quick@.service /etc/systemd/system/wg-quick@*.service.d/* 2>/dev/null || true
command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload 2>/dev/null || true

echo "==> [4/4] 重新以纯内核态拉起 WARP（保留原有 keepalive.sh 保活机制）..."
if wg-quick up warp; then
    rm -f /usr/bin/wireguard-go.bak /usr/local/bin/wireguard-go.bak /usr/bin/wg-quick.bak
    echo "--------------------------------------------------------"
    wg show warp
    echo "--------------------------------------------------------"
    echo "🎉 修复完成！当前 wireguard-go 进程数: $(ps -ef | grep -v grep | grep -c wireguard-go)"
else
    echo "❌ 内核态拉起异常，正在自动回滚至原状..."
    [ -f /usr/bin/wireguard-go.bak ] && mv -f /usr/bin/wireguard-go.bak /usr/bin/wireguard-go
    [ -f /usr/local/bin/wireguard-go.bak ] && mv -f /usr/local/bin/wireguard-go.bak /usr/local/bin/wireguard-go
    [ -f /usr/bin/wg-quick.bak ] && mv -f /usr/bin/wg-quick.bak /usr/bin/wg-quick
    wg-quick up warp
    exit 1
fi
