# sboxwarpinone

Alpine / Debian / Ubuntu 通用轻量 `sing-box` 多入站管理脚本单文件仓库（内嵌 `warp-fix.sh` 与按需 `age` 加密 Cloudflare Origin TLS 证书）。

## 核心特性

- **单文件交付 (`sbox.sh`)**：支持 `Hysteria2`、`VLESS+WS`、`VLESS+Reality` 多入站共存管理。
- **零明文上库**：源码与产物均不含任何明文 Origin 证书、私钥、个人域名与密码。
- **GitHub Actions 云端 `age` 加密**：本机无需安装 `age`，在仓库 Secrets 填好证书与解锁口令后由 CI 自动在内存加密注入 `sbox.sh`。
- **VPS 按需解密**：日常安装 Hysteria2 / Reality 不触发 `age` 下载，不询问密码；仅当在 TLS 设置菜单选择「内置加密 Origin 证书」时，按需安装/拉取 `age` 并提示输入解锁口令。

---

## 一、GitHub 仓库配置（Secrets）

将本仓库推送至 GitHub 后，打开仓库 **Settings -> Secrets and variables -> Actions -> New repository secret**，添加以下 4 个机密变量：

| Secret 名称 | 说明 |
| :--- | :--- |
| `AGE_PASSPHRASE` | 证书解锁口令（部署开启内置 TLS 时由终端输入） |
| `ORIGIN_DOMAIN` | Origin 证书对应的主域名（例如 `example.com`） |
| `ORIGIN_CERT` | Cloudflare Origin TLS 证书 `.crt` 完整文本（含 `BEGIN/END CERTIFICATE`） |
| `ORIGIN_KEY` | Cloudflare Origin TLS 私钥 `.key` 完整文本（含 `BEGIN/END PRIVATE KEY`） |

配置完成后，进入仓库 **Actions -> Build Encrypted sbox.sh -> Run workflow** 手动触发一次，即可生成并提交含加密证书块的完整 `sbox.sh`。

---

## 二、VPS 一键安装与使用

```sh
curl -fsSL https://raw.githubusercontent.com/<你的用户名>/sboxwarpinone/main/sbox.sh -o /root/sbox.sh && chmod +x /root/sbox.sh && /root/sbox.sh
```

日常管理常用命令：
- `sbox`：打开交互管理菜单
- `sbox link` / `slink`：导出全部节点链接（HY2 自动计算并附带 `pinSHA256=`）
- `sbox list`：查看当前节点摘要
- `sbox speed`：运行 Cloudflare 测速（100MB 下载 + 50MB 上传）
