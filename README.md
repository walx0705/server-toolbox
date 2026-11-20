# 服务器工具箱 toolbox.sh

菜单式服务器工具箱：系统维护 + sing-box 节点管理（HY2 / VLESS+WS+TLS）。
双模式托管：有 systemd 的普通 VPS 用 systemd；无 systemd 的沙盒（如 Altare）自动用 nohup。

## 一键运行

```bash
bash <(curl -sL https://raw.githubusercontent.com/walx0705/server-toolbox/main/toolbox.sh)
```

需要 root 或在 root 家目录下运行。脚本不内置任何密码：节点密码 / UUID 都在安装时于目标机器上现场生成，保存在该机器的 `~/sb-toolbox/nodes/<节点名>/` 里。

## 功能

**系统维护**
- 系统信息（系统、内核、CPU、内存、磁盘、公网 IP）
- 系统更新、安装常用工具、清理垃圾、设置时区、开启 BBR（仅普通 VPS）

**sing-box 节点管理**
- 一键安装 HY2 节点（自动生成密码、自签证书、端口自选）
- 一键安装 VLESS+WS+TLS 节点（自动生成 UUID 与 WS 路径、自签证书）
- 节点列表与状态、查看分享链接 / 终端二维码
- 修改密码 / UUID（自动重启并输出新链接）
- 重启 / 日志 / 卸载、更新 sing-box 到最新版

**服务管理**
- 一键拉起全部节点（沙盒或机器重启后恢复用）
- 停止全部节点

## 说明

- 节点文件目录：`~/sb-toolbox/`（可用环境变量 `SB_HOME` 覆盖）
- 每个节点的日志在各自目录下的 `sing-box.log`
- 自签证书部署的节点，客户端导入时需开启「允许不安全连接 / insecure」
