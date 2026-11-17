# sboxwarpinone

适用于 **Alpine / Debian / Ubuntu**（含 180 MiB 级小内存 LXC / NAT 容器）的轻量化 `sing-box` 多入站管理脚本，单文件全合一，开箱即用。

## 核心特性

- **单文件多入站共存**：同一 `sing-box` 实例原生支持并独立管理 `Hysteria2`、`VLESS+WS`、`VLESS+Reality`，增删改互不干扰。
- **对齐新版无警告 Schema**：原生适配 `sing-box 1.12+ / 1.14+`（`dns.strategy`、`route.default_domain_resolver`、`sniff` 规则及 WS `max_early_data` 拆分）。
- **轻量环境自适应**：
  - 自动识别 Alpine / `musl` libc 并拉取官方 `-musl` 核心；
  - OpenRC (`supervise-daemon`) / systemd 自动按容器 cgroup 内存上限计算 `GOMEMLIMIT`（最小 `48MiB`）；
  - 优先复用系统 `python3` / `jq`，均无时按需安装轻量 `jq`。
- **完整配套工具链**：
  - `Hysteria2` 自动签发自签证书并在 `sbox link` 时自动计算 `pinSHA256=` 锁指纹；
  - `VLESS+Reality` 内置 TLS 1.3 + H2 SNI 探活优选池；
  - 集成 Cloudflare 测速（100MB 下载 + 50MB 上传）与真实公网 IP / WARP 双栈出口探测；
  - 内嵌 `warp-fix.sh`，支持 LXC 容器内核态 WireGuard 检查与修复。
- **零明文上库设计**：支持经 GitHub Actions 在 CI 内存使用 `age` 加密内嵌 Origin TLS 证书，公开代码库与脚本产物均不含任何明文私钥或口令。

---

## 一、快速安装与升级

### 1. 全新安装

```sh
curl -fsSL https://raw.githubusercontent.com/wangxiangg1/sboxwarpinone/main/sbox.sh -o /root/sbox.sh && chmod +x /root/sbox.sh && /root/sbox.sh
```

> 若网络访问 GitHub 较慢，可前置加速代理变量后运行：
> ```sh
> export GH_PROXY="https://ghfast.top/"
> curl -fsSL "${GH_PROXY}https://raw.githubusercontent.com/wangxiangg1/sboxwarpinone/main/sbox.sh" -o /root/sbox.sh && chmod +x /root/sbox.sh && /root/sbox.sh
> ```

### 2. 已有机器更新管理脚本（不影响现有节点配置）

```sh
curl -fsSL https://raw.githubusercontent.com/wangxiangg1/sboxwarpinone/main/sbox.sh -o /root/sbox.sh && cp -f /root/sbox.sh /usr/local/bin/sbox && chmod +x /root/sbox.sh /usr/local/bin/sbox && sbox
```

### 3. 日常常用命令与非交互传参

- `sbox`：打开交互管理菜单
- `sbox link` / `slink`：导出全部入站链接
- `sbox list`：命令行查看入站摘要
- `sbox speed`：运行 Cloudflare 测速（100MB 下载 + 50MB 上传）
- 透明转发：除上述保留词外，其他参数（如 `sbox version`、`sbox check ...`）直接透传给 `/usr/local/bin/sing-box`
- 非交互首次安装示例：
  - `/root/sbox.sh hy2 35565`
  - `/root/sbox.sh ws 8080 '/ws?ed=2048' AsIs`
  - `/root/sbox.sh reality 443`

---

## 二、关于内置 TLS 证书（面向外部用户与 Fork 自建）

1. **直接使用本仓库脚本的用户**：
   - `Hysteria2`（自签证书）、`VLESS+Reality` 与明文 `VLESS+WS` 均**不需要任何密码**，直接开箱即用；
   - 在为 `VLESS+WS` 配置 Origin TLS 时，菜单第 `1` 项「内置加密 Origin 证书」受仓库所有者 `age` 口令保护，外部用户请直接选择第 `2` 项「**指定自定义证书与私钥文件路径**」。
2. **Fork 后部署属于你自己的加密版本**：
   - Fork 本仓库后，打开你仓库的 **Settings -> Secrets and variables -> Actions -> New repository secret**，添加以下 4 个 Secrets：

| Secret 名称 | 说明 |
| :--- | :--- |
| `AGE_PASSPHRASE` | 证书解锁口令（部署启用内置 TLS 时由终端通过 `age` 交互输入） |
| `ORIGIN_DOMAIN` | Origin 证书对应的主域名（未填时 CI 会自动从证书 SAN 提取） |
| `ORIGIN_CERT` | Cloudflare Origin TLS 证书 `.crt` 完整文本（含 `BEGIN/END CERTIFICATE`） |
| `ORIGIN_KEY` | Cloudflare Origin TLS 私钥 `.key` 完整文本（含 `BEGIN/END PRIVATE KEY`） |

   - 配置完成后运行一次 **Actions -> Build Encrypted sbox.sh -> Run workflow**，CI 会在 Runner 内存完成证书私钥匹配校验、`age -p -a` 加密与反向回解校验，并扫描确认无明文残留后自动更新 `sbox.sh`。

---

## 三、仓库文件布局

| 路径 | 用途 |
| :--- | :--- |
| `sbox.sh` | 由 CI / `build.sh` 自动合并生成的单文件成品（内嵌 `warp-fix.sh` 与密文块） |
| `src/` | 模块化 POSIX `sh` 源码 |
| `warp-fix.sh` | LXC 内核态 WireGuard 检查与修复脚本 |
| `build.sh` | 本地/CI 合并构建脚本（含 LF 检查、`sh -n` 校验与防泄密阻断） |
| `.github/workflows/build.yml` | GitHub Actions 云端 `age` 加密构建流水线 |
