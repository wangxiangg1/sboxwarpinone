# sboxwarpinone (v1.2.0)

Alpine / Debian / Ubuntu 通用轻量 `sing-box` 多入站与双模 WARP 出口一键管理脚本（单文件合并产物：`sbox.sh`）。

## 主要特性
- **多入站共存**：同实例支持 `Hysteria2`、`VLESS+WS`（可注入 age 加密 Cloudflare Origin TLS）、`VLESS+Reality`。
- **双模 WARP 出口（菜单 `[10]`）**：
  - **WireGuard UDP（默认）**：三路内核态 `sboxwg1/2/3` + `sing-box` `urltest` 容灾。
  - **WARP MASQUE (`usque`)**：面向屏蔽 WireGuard UDP 环境的轻量用户态方案，支持 **双路异构热备**（推荐默认：`l4-socks` 主 + `socks --http2` 备）与单路子模式（`l4-socks` / `socks` / `socks-http2`）自由切换，按内存自动分级配置 `GOMEMLIMIT` 与 `GOGC=50`，兼容 OpenRC 与 systemd。
- **构建与校验**：修改 `src/*.sh` 后运行 `./build.sh` 生成 `sbox.sh` 并自动执行 `sh -n` 语法检查与明文私钥扫描。
