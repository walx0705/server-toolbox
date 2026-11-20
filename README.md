# server-toolbox

自用服务器工具箱 `toolbox.sh` v2：菜单式一键脚本，系统维护、网络工具、Docker 管理、sing-box 节点、哪吒探针、测试工具、备份恢复，一个脚本全包。

## 一键运行

```bash
bash <(curl -sL https://raw.githubusercontent.com/walx0705/server-toolbox/main/toolbox.sh)
```

也可以不进菜单直接执行：

```bash
bash <(curl -sL https://raw.githubusercontent.com/walx0705/server-toolbox/main/toolbox.sh) info
# 可用命令：info / nodes / start-all / stop-all / clean / update
```

## 主菜单（v2）

1. **系统维护**：系统信息、更新、常用工具、清理、时区、BBR、主机名、Swap、换源、DNS
2. **网络工具**：BBR、监听端口、开放端口、测速、IP 归属、Ping
3. **Docker 管理**：安装、状态、容器/镜像列表、清理、卸载
4. **sing-box 节点**：HY2 / VLESS+WS+TLS / VLESS-Reality / TUIC / AnyTLS 五种节点，列表、链接/二维码、改密码/UUID、日志、卸载、更新 sing-box
5. **哪吒探针**：v1 新版面板与 v0 旧版面板双支持，装/启/停/卸载
6. **测试工具**：IP 归属、ChatGPT 可达、Netflix 解锁、磁盘 IO、测速、Ping（自带简测，不跑第三方脚本）
7. **服务管理**：一键拉起/停止全部节点
8. **备份恢复**：整个工具箱目录打包/恢复（含节点配置与凭据，注意保管）

## 说明

- 节点数据在目标机 `~/sb-toolbox/`（可用环境变量 `SB_HOME` 改位置），每个节点一个目录：config.json、meta、证书、日志。
- 有 systemd 用 systemd 托管（单元名 `sb-toolbox-<节点名>`）；无 systemd 的沙盒（如 Altare）自动 nohup 托管，机器重启后跑「服务管理 → 一键拉起全部节点」恢复。
- 脚本不内置任何密码；节点密码、UUID、Reality 密钥、哪吒身份都在目标机生成。
- 与 singbox-panel 仓库是两套东西：那边是网页拼命令的参数化脚本，这边是 SSH 里用的交互菜单工具箱。
