#!/usr/bin/env bash
# ============================================================
# 服务器工具箱 toolbox.sh v2
# 系统维护 / 网络工具 / Docker / sing-box 节点 / 哪吒探针
# 节点：HY2 / VLESS+WS+TLS / VLESS-Reality / TUIC / AnyTLS
# 双模式：有 systemd 的普通 VPS 用 systemd 托管；
#         无 systemd 的沙盒（如 Altare）自动用 nohup 托管。
# 用法：bash <(curl -sL <脚本地址>)          进菜单
#       bash <(curl -sL <脚本地址>) info    直接执行命令
#       （info / nodes / start-all / stop-all / clean / update）
# 说明：脚本不内置任何密码，节点密码/UUID 均在安装时于本机生成。
# ============================================================

# 通过管道运行时把输入切回终端，保证菜单可交互；切不过去就沿用当前输入
shopt -s execfail 2>/dev/null
if [ ! -t 0 ] && ( : < /dev/tty ) 2>/dev/null; then
  exec < /dev/tty
fi

VERSION="2.0.0"
SB_HOME="${SB_HOME:-$HOME/sb-toolbox}"
SB_BIN_DIR="$SB_HOME/bin"
SB_NODES_DIR="$SB_HOME/nodes"
SB_BIN="$SB_BIN_DIR/sing-box"
SB_VERSION_PIN="1.14.4"

# ---------- 基础工具 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

info()  { echo -e "${BLUE}[信息]${NC} $*"; }
ok()    { echo -e "${GREEN}[成功]${NC} $*"; }
warn()  { echo -e "${YELLOW}[注意]${NC} $*"; }
err()   { echo -e "${RED}[错误]${NC} $*"; }

pause() { echo; read -rp "按回车键返回菜单..." _tmp; }

need_root() {
  if [ "$(id -u)" != "0" ]; then
    warn "当前不是 root 用户，部分功能（装包、绑端口、写系统服务）可能失败"
  fi
}

has_systemd() {
  [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1
}

pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then echo apt
  elif command -v dnf >/dev/null 2>&1; then echo dnf
  elif command -v yum >/dev/null 2>&1; then echo yum
  elif command -v apk >/dev/null 2>&1; then echo apk
  else echo none; fi
}

pkg_install() {
  local mgr; mgr=$(pkg_mgr)
  case "$mgr" in
    apt) apt-get update -y && apt-get install -y "$@" ;;
    dnf) dnf install -y "$@" ;;
    yum) yum install -y "$@" ;;
    apk) apk add --no-cache "$@" ;;
    *) err "未识别的包管理器，请手动安装：$*"; return 1 ;;
  esac
}

ensure_cmd() {
  # ensure_cmd 命令 包名
  if ! command -v "$1" >/dev/null 2>&1; then
    info "正在安装 $1 ..."
    pkg_install "${2:-$1}" >/dev/null 2>&1
  fi
  command -v "$1" >/dev/null 2>&1
}

public_ip() {
  local ip
  ip=$(curl -s --max-time 6 https://api.ipify.org 2>/dev/null)
  [ -z "$ip" ] && ip=$(curl -s --max-time 6 https://ip.sb 2>/dev/null)
  echo "$ip" | tr -d ' \n'
}

urlencode() {
  # 只处理 base64 可能出现的 + / = 三个字符，足够拼分享链接
  echo -n "$1" | sed -e 's/+/%2B/g' -e 's/\//%2F/g' -e 's/=/%3D/g'
}

rand_port() { shuf -i 10000-60000 -n 1 2>/dev/null || echo $(( (RANDOM % 40000) + 10000 )); }

gen_password() { openssl rand -base64 16 2>/dev/null || head -c 32 /dev/urandom | base64; }

gen_uuid() {
  if [ -x "$SB_BIN" ]; then "$SB_BIN" generate uuid 2>/dev/null && return
  fi
  cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null
}

# ---------- 系统类 ----------
sys_info() {
  echo -e "${CYAN}===== 系统信息 =====${NC}"
  [ -f /etc/os-release ] && . /etc/os-release && echo "系统      : $PRETTY_NAME"
  echo "内核      : $(uname -r)"
  echo "架构      : $(uname -m)"
  echo "CPU 核心  : $(nproc 2>/dev/null || echo '?')"
  if command -v free >/dev/null 2>&1; then
    echo "内存      : $(free -h | awk 'NR==2{print $3" / "$2}')"
  fi
  echo "磁盘(/)   : $(df -h / | awk 'NR==2{print $3" / "$2" (已用 "$5")"}')"
  echo "运行时间  : $(uptime -p 2>/dev/null || uptime)"
  echo "公网 IP   : $(public_ip)"
  echo "systemd   : $(has_systemd && echo 有 || echo 无（节点用 nohup 托管）)"
  echo "工具箱目录: $SB_HOME"
  pause
}

sys_update() {
  local mgr; mgr=$(pkg_mgr)
  info "开始系统更新（包管理器：$mgr）..."
  case "$mgr" in
    apt) apt-get update -y && apt-get upgrade -y ;;
    dnf) dnf upgrade -y ;;
    yum) yum update -y ;;
    apk) apk update && apk upgrade ;;
    *) err "未识别的包管理器，无法自动更新" ;;
  esac
  ok "系统更新流程结束"
  pause
}

sys_tools() {
  info "安装常用工具：curl wget git vim unzip tar openssl ca-certificates qrencode"
  case "$(pkg_mgr)" in
    apt) pkg_install curl wget git vim unzip tar openssl ca-certificates qrencode ;;
    apk) pkg_install curl wget git vim unzip tar openssl ca-certificates qrencode ;;
    *)   pkg_install curl wget git vim unzip tar openssl qrencode ;;
  esac
  ok "常用工具安装完成"
  pause
}

sys_clean() {
  info "清理包缓存与临时文件..."
  case "$(pkg_mgr)" in
    apt) apt-get autoremove -y; apt-get clean ;;
    dnf) dnf autoremove -y; dnf clean all ;;
    yum) yum autoremove -y; yum clean all ;;
    apk) apk cache clean 2>/dev/null ;;
  esac
  command -v journalctl >/dev/null 2>&1 && journalctl --vacuum-time=3d >/dev/null 2>&1
  find /tmp -type f -atime +3 -delete 2>/dev/null
  ok "清理完成，当前磁盘："
  df -h /
  pause
}

sys_timezone() {
  echo "常用时区："
  echo "  1) Asia/Shanghai   2) Asia/Tokyo   3) Asia/Singapore"
  echo "  4) Europe/London   5) America/New_York   6) UTC"
  read -rp "选择 [1-6，直接回车=1]: " tzc
  local tz="Asia/Shanghai"
  case "$tzc" in
    2) tz="Asia/Tokyo" ;; 3) tz="Asia/Singapore" ;; 4) tz="Europe/London" ;;
    5) tz="America/New_York" ;; 6) tz="UTC" ;; *) tz="Asia/Shanghai" ;;
  esac
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-timezone "$tz" 2>/dev/null
  fi
  if [ -f "/usr/share/zoneinfo/$tz" ]; then
    ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime 2>/dev/null
    echo "$tz" > /etc/timezone 2>/dev/null
  fi
  ok "时区已设为 $tz，当前时间：$(date)"
  pause
}

sys_bbr() {
  if ! has_systemd; then
    warn "无 systemd 或沙盒环境通常无权改内核参数，跳过 BBR"
    pause; return
  fi
  if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    ok "BBR 已经开启"; pause; return
  fi
  echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
  sysctl -p >/dev/null 2>&1
  if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    ok "BBR 开启成功"
  else
    warn "BBR 开启未生效（内核可能不支持）"
  fi
  pause
}

sys_hostname() {
  echo "当前主机名：$(hostname)"
  read -rp "新主机名（直接回车不改）: " hn
  [ -z "$hn" ] && { pause; return; }
  if command -v hostnamectl >/dev/null 2>&1; then hostnamectl set-hostname "$hn" 2>/dev/null; fi
  hostname "$hn" 2>/dev/null
  echo "$hn" > /etc/hostname 2>/dev/null
  ok "主机名已改为 $hn（重新登录后提示符生效）"
  pause
}

sys_swap() {
  echo "当前内存/交换："
  free -h
  if swapon --show 2>/dev/null | grep -q .; then
    echo "已有 swap：$(swapon --show | tail -n +2)"
    read -rp "要删除现有 /swapfile 并重设吗？[y/N]: " yn
    case "$yn" in y|Y) swapoff /swapfile 2>/dev/null; rm -f /swapfile ;; *) pause; return ;; esac
  fi
  read -rp "Swap 大小 MB [默认 1024]: " sz; sz="${sz:-1024}"
  if ! fallocate -l "${sz}M" /swapfile 2>/dev/null; then
    dd if=/dev/zero of=/swapfile bs=1M count="$sz" status=none 2>/dev/null
  fi
  chmod 600 /swapfile
  if mkswap /swapfile >/dev/null 2>&1 && swapon /swapfile 2>/dev/null; then
    grep -q '^/swapfile' /etc/fstab 2>/dev/null || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    ok "Swap 已开启（${sz}MB）"
    free -h
  else
    err "Swap 开启失败（沙盒/容器环境通常无此权限）"
    rm -f /swapfile
  fi
  pause
}

sys_source() {
  if [ "$(pkg_mgr)" != "apt" ]; then warn "换源目前只支持 Debian/Ubuntu（apt）"; pause; return; fi
  echo "  1) 国内源（清华 TUNA）"
  echo "  2) 官方源"
  read -rp "请选择 [1-2]: " c
  local files="/etc/apt/sources.list /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list.d/ubuntu.sources"
  local f
  for f in $files; do
    [ -f "$f" ] || continue
    cp "$f" "$f.bak" 2>/dev/null
    case "$c" in
      1) sed -i -e 's|deb.debian.org|mirrors.tuna.tsinghua.edu.cn|g' \
                -e 's|security.debian.org|mirrors.tuna.tsinghua.edu.cn|g' \
                -e 's|archive.ubuntu.com|mirrors.tuna.tsinghua.edu.cn|g' \
                -e 's|security.ubuntu.com|mirrors.tuna.tsinghua.edu.cn|g' "$f" ;;
      2) sed -i -e 's|mirrors.tuna.tsinghua.edu.cn|deb.debian.org|g' "$f"
         grep -q ubuntu "$f" 2>/dev/null && sed -i -e 's|deb.debian.org|archive.ubuntu.com|g' "$f" ;;
    esac
  done
  apt-get update -y
  ok "换源完成（原文件已备份为 .bak）"
  pause
}

sys_dns() {
  echo "当前 DNS："
  grep -E '^nameserver' /etc/resolv.conf 2>/dev/null || echo "（无）"
  echo "  1) 国内：223.5.5.5 + 119.29.29.29"
  echo "  2) 国外：8.8.8.8 + 1.1.1.1"
  echo "  3) 自定义输入"
  read -rp "请选择 [1-3]: " c
  local d1 d2
  case "$c" in
    1) d1=223.5.5.5; d2=119.29.29.29 ;;
    2) d1=8.8.8.8; d2=1.1.1.1 ;;
    3) read -rp "主 DNS: " d1; read -rp "备 DNS（可空）: " d2 ;;
    *) pause; return ;;
  esac
  [ -z "$d1" ] && { err "DNS 不能为空"; pause; return; }
  cp /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null
  { echo "nameserver $d1"; [ -n "$d2" ] && echo "nameserver $d2"; } > /etc/resolv.conf
  ok "DNS 已设置（若系统用 systemd-resolved 管理，重启后可能被覆盖）"
  pause
}

sys_menu() {
  while true; do
    echo -e "${CYAN}===== 系统维护 =====${NC}"
    echo "  1) 系统信息"
    echo "  2) 系统更新"
    echo "  3) 安装常用工具"
    echo "  4) 清理垃圾"
    echo "  5) 设置时区"
    echo "  6) 开启 BBR（仅普通 VPS）"
    echo "  7) 修改主机名"
    echo "  8) Swap 管理"
    echo "  9) 更换软件源（Debian/Ubuntu）"
    echo " 10) DNS 设置"
    echo "  0) 返回主菜单"
    read -rp "请选择: " c
    case "$c" in
      1) sys_info ;; 2) sys_update ;; 3) sys_tools ;;
      4) sys_clean ;; 5) sys_timezone ;; 6) sys_bbr ;;
      7) sys_hostname ;; 8) sys_swap ;; 9) sys_source ;; 10) sys_dns ;;
      0) return ;; *) warn "无效选择" ;;
    esac
  done
}

# ---------- 网络工具 ----------
net_ports() {
  echo -e "${CYAN}===== 当前监听端口 =====${NC}"
  if command -v ss >/dev/null 2>&1; then ss -tulnp 2>/dev/null | head -40
  elif command -v netstat >/dev/null 2>&1; then netstat -tulnp 2>/dev/null | head -40
  else warn "没有 ss/netstat，先在系统维护里装常用工具（iproute2）"; fi
  pause
}

net_open_port() {
  read -rp "要开放的端口: " p
  [ -z "$p" ] && { pause; return; }
  read -rp "协议 [tcp/udp/both，默认 both]: " pr; pr="${pr:-both}"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then
    case "$pr" in
      tcp) ufw allow "$p/tcp" ;; udp) ufw allow "$p/udp" ;; *) ufw allow "$p" ;;
    esac
    ok "ufw 已放行 $p（$pr）"
  elif command -v iptables >/dev/null 2>&1; then
    case "$pr" in
      tcp) iptables -I INPUT -p tcp --dport "$p" -j ACCEPT ;;
      udp) iptables -I INPUT -p udp --dport "$p" -j ACCEPT ;;
      *) iptables -I INPUT -p tcp --dport "$p" -j ACCEPT; iptables -I INPUT -p udp --dport "$p" -j ACCEPT ;;
    esac
    ok "iptables 已放行 $p（$pr，未做持久化，重启可能失效）"
  else
    warn "没有 ufw/iptables（沙盒环境端口由平台管，这里放行不了）"
  fi
  warn "别忘了云厂商安全组/平台面板那边也要放行同一个端口"
  pause
}

net_speed() {
  if command -v speedtest >/dev/null 2>&1; then speedtest
  elif command -v speedtest-cli >/dev/null 2>&1; then speedtest-cli
  else
    info "未装测速工具，正在安装 speedtest-cli ..."
    pkg_install speedtest-cli >/dev/null 2>&1 || pip3 install speedtest-cli >/dev/null 2>&1 || pkg_install python3-pip >/dev/null 2>&1
    command -v speedtest-cli >/dev/null 2>&1 && speedtest-cli || err "测速工具安装失败"
  fi
  pause
}

ip_info() {
  local ip; ip=$(public_ip)
  echo "公网 IP：${ip:-获取失败}"
  if [ -n "$ip" ]; then
    curl -s --max-time 8 "http://ip-api.com/json/${ip}?lang=zh-CN" | tr ',' '\n' | \
      grep -E '"(country|regionName|city|isp|org|as|query)"' | sed 's/"//g;s/:/：/'
  fi
  pause
}

net_ping() {
  read -rp "目标（域名或 IP）[默认 8.8.8.8]: " t; t="${t:-8.8.8.8}"
  ping -c 4 -W 3 "$t" 2>/dev/null || ping -c 4 "$t"
  pause
}

net_menu() {
  while true; do
    echo -e "${CYAN}===== 网络工具 =====${NC}"
    echo "  1) 开启 BBR（仅普通 VPS）"
    echo "  2) 查看监听端口"
    echo "  3) 开放端口（ufw/iptables）"
    echo "  4) 一键测速（speedtest）"
    echo "  5) 本机 IP 信息与归属"
    echo "  6) Ping 测试"
    echo "  0) 返回主菜单"
    read -rp "请选择: " c
    case "$c" in
      1) sys_bbr ;; 2) net_ports ;; 3) net_open_port ;;
      4) net_speed ;; 5) ip_info ;; 6) net_ping ;;
      0) return ;; *) warn "无效选择" ;;
    esac
  done
}

# ---------- Docker 管理 ----------
docker_ok() { command -v docker >/dev/null 2>&1; }

dk_install() {
  if docker_ok; then ok "Docker 已安装：$(docker --version)"; pause; return; fi
  info "安装 Docker（官方脚本）..."
  if curl -fsSL --max-time 30 https://get.docker.com -o /tmp/get-docker.sh 2>/dev/null; then
    sh /tmp/get-docker.sh >/dev/null 2>&1; rm -f /tmp/get-docker.sh
  fi
  if ! docker_ok; then
    info "官方脚本未成功，改用包管理器安装 docker.io ..."
    pkg_install docker.io >/dev/null 2>&1 || pkg_install docker >/dev/null 2>&1
  fi
  if docker_ok; then
    has_systemd && systemctl enable --now docker >/dev/null 2>&1
    ok "Docker 安装完成：$(docker --version)"
  else
    err "Docker 安装失败（沙盒/容器环境通常跑不了 Docker）"
  fi
  pause
}

dk_menu() {
  while true; do
    echo -e "${CYAN}===== Docker 管理 =====${NC}"
    echo "  1) 安装 Docker"
    echo "  2) 状态总览（版本/容器数/镜像数）"
    echo "  3) 容器列表"
    echo "  4) 镜像列表"
    echo "  5) 清理无用资源（停掉的容器/悬空镜像/缓存）"
    echo "  6) 卸载 Docker"
    echo "  0) 返回主菜单"
    read -rp "请选择: " c
    case "$c" in
      1) dk_install ;;
      2) if docker_ok; then docker --version; docker ps -a --format 'table {{.Names}}\t{{.Status}}' | head -20; docker system df; else warn "未安装 Docker"; fi; pause ;;
      3) docker_ok && docker ps -a || warn "未安装 Docker"; pause ;;
      4) docker_ok && docker images || warn "未安装 Docker"; pause ;;
      5) if docker_ok; then read -rp "确认清理？[y/N]: " yn; case "$yn" in y|Y) docker system prune -f ;; esac; else warn "未安装 Docker"; fi; pause ;;
      6) if docker_ok; then read -rp "确认卸载 Docker？容器与镜像会保留在磁盘上 [y/N]: " yn; case "$yn" in y|Y) has_systemd && systemctl stop docker 2>/dev/null; case "$(pkg_mgr)" in apt) apt-get remove -y docker-ce docker-ce-cli containerd.io docker.io docker 2>/dev/null ;; dnf|yum) $(pkg_mgr) remove -y docker-ce docker 2>/dev/null ;; esac; ok "卸载流程结束" ;; esac; else warn "未安装 Docker"; fi; pause ;;
      0) return ;; *) warn "无效选择" ;;
    esac
  done
}

# ---------- sing-box 本体 ----------
sb_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) echo amd64 ;;
  esac
}

sb_install_binary() {
  # $1 可选：指定版本，默认取官方最新
  local ver="$1" arch url tmp
  arch=$(sb_arch)
  if [ -z "$ver" ]; then
    ver=$(curl -s --max-time 10 https://api.github.com/repos/SagerNet/sing-box/releases/latest \
      | grep -o '"tag_name": *"v[^"]*"' | head -1 | sed 's/.*"v//;s/"//')
    [ -z "$ver" ] && ver="$SB_VERSION_PIN"
  fi
  url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-${arch}.tar.gz"
  info "下载 sing-box v${ver} (linux-${arch}) ..."
  tmp=$(mktemp -d)
  if ! curl -sL --max-time 300 -o "$tmp/sb.tar.gz" "$url"; then
    err "下载失败：$url"; rm -rf "$tmp"; return 1
  fi
  mkdir -p "$SB_BIN_DIR"
  tar xzf "$tmp/sb.tar.gz" -C "$tmp" || { err "解压失败"; rm -rf "$tmp"; return 1; }
  cp "$tmp/sing-box-${ver}-linux-${arch}/sing-box" "$SB_BIN"
  chmod +x "$SB_BIN"
  rm -rf "$tmp"
  ok "sing-box 已安装：$("$SB_BIN" version | head -1)"
}

sb_ensure_binary() {
  [ -x "$SB_BIN" ] || sb_install_binary
}

# ---------- 节点元数据 ----------
node_dir() { echo "$SB_NODES_DIR/$1"; }

meta_set() { # meta_set 节点名 key value
  local f; f="$(node_dir "$1")/meta"
  touch "$f"
  grep -v "^$2=" "$f" > "$f.tmp" 2>/dev/null; mv "$f.tmp" "$f"
  echo "$2=$3" >> "$f"
}

meta_get() { # meta_get 节点名 key
  local f; f="$(node_dir "$1")/meta"
  [ -f "$f" ] && grep "^$2=" "$f" | head -1 | cut -d= -f2-
}

list_nodes() {
  [ -d "$SB_NODES_DIR" ] || return 0
  ls -1 "$SB_NODES_DIR" 2>/dev/null
}

node_exists() { [ -d "$(node_dir "$1")" ]; }

# ---------- 证书 ----------
gen_cert() {
  # gen_cert 目录 SNI
  local d="$1" sni="$2"
  if [ -f "$d/cert.pem" ] && [ -f "$d/key.pem" ]; then return 0; fi
  if openssl ecparam -genkey -name prime256v1 -out "$d/key.pem" 2>/dev/null; then
    openssl req -new -x509 -days 3650 -key "$d/key.pem" -out "$d/cert.pem" \
      -subj "/CN=$sni" 2>/dev/null
  else
    openssl req -new -x509 -days 3650 -nodes -newkey rsa:2048 \
      -keyout "$d/key.pem" -out "$d/cert.pem" -subj "/CN=$sni" 2>/dev/null
  fi
  [ -f "$d/cert.pem" ] && [ -f "$d/key.pem" ]
}

# ---------- 服务托管（systemd / nohup 双模式） ----------
svc_start() { # svc_start 节点名
  local name="$1" d; d=$(node_dir "$name")
  [ -f "$d/config.json" ] || { err "节点 $name 配置不存在"; return 1; }
  if has_systemd; then
    local unit="sb-toolbox-$name"
    cat > "/etc/systemd/system/$unit.service" <<EOF
[Unit]
Description=sing-box node $name (toolbox)
After=network.target

[Service]
Type=simple
ExecStart=$SB_BIN run -c $d/config.json
Restart=on-failure
StandardOutput=append:$d/sing-box.log
StandardError=append:$d/sing-box.log

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$unit" >/dev/null 2>&1
    systemctl restart "$unit"
    sleep 1
    systemctl is-active --quiet "$unit" && ok "节点 $name 已启动（systemd）" || { err "节点 $name 启动失败，看日志"; return 1; }
  else
    if [ -f "$d/pid" ] && kill -0 "$(cat "$d/pid")" 2>/dev/null; then
      warn "节点 $name 已经在运行（PID $(cat "$d/pid")）"; return 0
    fi
    cat > "$d/start.sh" <<EOF
#!/bin/sh
cd $d || exit 1
nohup $SB_BIN run -c config.json >> sing-box.log 2>&1 &
echo \$! > $d/pid
EOF
    chmod +x "$d/start.sh"
    sh "$d/start.sh"
    sleep 1
    if [ -f "$d/pid" ] && kill -0 "$(cat "$d/pid")" 2>/dev/null; then
      ok "节点 $name 已启动（nohup，PID $(cat "$d/pid")）"
    else
      err "节点 $name 启动失败，看日志：$d/sing-box.log"; return 1
    fi
  fi
}

svc_stop() { # svc_stop 节点名
  local name="$1" d; d=$(node_dir "$name")
  if has_systemd; then
    systemctl stop "sb-toolbox-$name" 2>/dev/null
    systemctl disable "sb-toolbox-$name" >/dev/null 2>&1
  fi
  if [ -f "$d/pid" ]; then
    kill "$(cat "$d/pid")" 2>/dev/null
    rm -f "$d/pid"
  fi
  # 兜底：按配置路径找进程
  local p
  p=$(pgrep -f "sing-box run -c $d/config.json" 2>/dev/null)
  [ -n "$p" ] && kill $p 2>/dev/null
  ok "节点 $name 已停止"
}

svc_running() { # 返回 0 表示在跑
  local name="$1" d; d=$(node_dir "$name")
  if has_systemd && systemctl is-active --quiet "sb-toolbox-$name" 2>/dev/null; then
    return 0
  fi
  if [ -f "$d/pid" ] && kill -0 "$(cat "$d/pid")" 2>/dev/null; then
    return 0
  fi
  pgrep -f "sing-box run -c $d/config.json" >/dev/null 2>&1
}

svc_status_text() {
  if svc_running "$1"; then echo "运行中"; else echo "已停止"; fi
}

# ---------- 分享链接 ----------
node_link() { # node_link 节点名
  local name="$1" type addr port sni secret
  type=$(meta_get "$name" type)
  addr=$(meta_get "$name" addr)
  port=$(meta_get "$name" port)
  sni=$(meta_get "$name" sni)
  if [ "$type" = "hysteria2" ]; then
    secret=$(urlencode "$(meta_get "$name" password)")
    echo "hysteria2://${secret}@${addr}:${port}?sni=${sni}&insecure=1#${name}"
  elif [ "$type" = "vless" ]; then
    secret=$(meta_get "$name" uuid)
    local path; path=$(meta_get "$name" path)
    echo "vless://${secret}@${addr}:${port}?encryption=none&security=tls&sni=${sni}&type=ws&path=$(urlencode "$path")&allowInsecure=1#${name}"
  elif [ "$type" = "reality" ]; then
    secret=$(meta_get "$name" uuid)
    local pbk sid; pbk=$(meta_get "$name" pbk); sid=$(meta_get "$name" sid)
    echo "vless://${secret}@${addr}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pbk}&sid=${sid}&type=tcp#${name}"
  elif [ "$type" = "tuic" ]; then
    local tuuid; tuuid=$(meta_get "$name" uuid)
    secret=$(urlencode "$(meta_get "$name" password)")
    echo "tuic://${tuuid}:${secret}@${addr}:${port}?sni=${sni}&insecure=1&alpn=h3#${name}"
  elif [ "$type" = "anytls" ]; then
    secret=$(urlencode "$(meta_get "$name" password)")
    echo "anytls://${secret}@${addr}:${port}?sni=${sni}&insecure=1#${name}"
  fi
}

show_link() { # show_link 节点名
  local link; link=$(node_link "$1")
  echo -e "${CYAN}----- 节点 $1 分享链接 -----${NC}"
  echo "$link"
  if command -v qrencode >/dev/null 2>&1; then
    echo; qrencode -t ANSIUTF8 "$link"
  else
    warn "（未装 qrencode，只能显示链接；主菜单-系统维护-安装常用工具 可装）"
  fi
}

# ---------- 安装 HY2 ----------
install_hy2() {
  need_root
  sb_ensure_binary || { pause; return; }
  ensure_cmd openssl openssl >/dev/null
  local name port addr sni password d
  read -rp "节点名 [默认 hy2-1]: " name; name="${name:-hy2-1}"
  if node_exists "$name"; then err "节点 $name 已存在，先卸载或换个名字"; pause; return; fi
  read -rp "监听端口 [默认随机，Altare 填 25697]: " port; port="${port:-$(rand_port)}"
  local ip; ip=$(public_ip)
  read -rp "服务器地址（客户端连接用）[默认公网 IP ${ip:-未知}]: " addr; addr="${addr:-$ip}"
  [ -z "$addr" ] && { err "地址不能为空"; pause; return; }
  read -rp "SNI / 证书名 [默认同服务器地址]: " sni; sni="${sni:-$addr}"
  read -rp "节点密码 [直接回车=自动生成]: " password; password="${password:-$(gen_password)}"
  d=$(node_dir "$name"); mkdir -p "$d"
  gen_cert "$d" "$sni" || { err "证书生成失败"; pause; return; }
  cat > "$d/config.json" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": $port,
      "users": [ { "password": "$password" } ],
      "tls": {
        "enabled": true,
        "server_name": "$sni",
        "certificate_path": "$d/cert.pem",
        "key_path": "$d/key.pem"
      }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF
  if ! "$SB_BIN" check -c "$d/config.json"; then
    err "配置校验未通过，已保留在 $d/config.json 待排查"; pause; return
  fi
  meta_set "$name" type hysteria2
  meta_set "$name" addr "$addr"
  meta_set "$name" port "$port"
  meta_set "$name" sni "$sni"
  meta_set "$name" password "$password"
  meta_set "$name" autostart 1
  svc_start "$name"
  echo
  show_link "$name"
  pause
}

# ---------- 安装 VLESS+WS+TLS ----------
install_vless() {
  need_root
  sb_ensure_binary || { pause; return; }
  ensure_cmd openssl openssl >/dev/null
  local name port addr sni uuid path d
  read -rp "节点名 [默认 vless-1]: " name; name="${name:-vless-1}"
  if node_exists "$name"; then err "节点 $name 已存在，先卸载或换个名字"; pause; return; fi
  read -rp "监听端口 [默认随机]: " port; port="${port:-$(rand_port)}"
  local ip; ip=$(public_ip)
  read -rp "服务器地址（客户端连接用）[默认公网 IP ${ip:-未知}]: " addr; addr="${addr:-$ip}"
  [ -z "$addr" ] && { err "地址不能为空"; pause; return; }
  read -rp "SNI / 证书名 [默认同服务器地址]: " sni; sni="${sni:-$addr}"
  uuid=$(gen_uuid)
  path="/$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  d=$(node_dir "$name"); mkdir -p "$d"
  gen_cert "$d" "$sni" || { err "证书生成失败"; pause; return; }
  cat > "$d/config.json" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": $port,
      "users": [ { "uuid": "$uuid" } ],
      "transport": { "type": "ws", "path": "$path" },
      "tls": {
        "enabled": true,
        "server_name": "$sni",
        "certificate_path": "$d/cert.pem",
        "key_path": "$d/key.pem"
      }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF
  if ! "$SB_BIN" check -c "$d/config.json"; then
    err "配置校验未通过，已保留在 $d/config.json 待排查"; pause; return
  fi
  meta_set "$name" type vless
  meta_set "$name" addr "$addr"
  meta_set "$name" port "$port"
  meta_set "$name" sni "$sni"
  meta_set "$name" uuid "$uuid"
  meta_set "$name" path "$path"
  meta_set "$name" autostart 1
  svc_start "$name"
  echo
  show_link "$name"
  pause
}

# ---------- 安装 VLESS-Reality ----------
install_reality() {
  need_root
  sb_ensure_binary || { pause; return; }
  ensure_cmd openssl openssl >/dev/null
  local name port addr rsni uuid priv pub sid d out ip
  read -rp "节点名 [默认 reality-1]: " name; name="${name:-reality-1}"
  if node_exists "$name"; then err "节点 $name 已存在，先卸载或换个名字"; pause; return; fi
  read -rp "监听端口 [默认随机]: " port; port="${port:-$(rand_port)}"
  ip=$(public_ip)
  read -rp "服务器地址（客户端连接用）[默认公网 IP ${ip:-未知}]: " addr; addr="${addr:-$ip}"
  [ -z "$addr" ] && { err "地址不能为空"; pause; return; }
  read -rp "Reality 目标站 [默认 www.microsoft.com]: " rsni; rsni="${rsni:-www.microsoft.com}"
  uuid=$(gen_uuid)
  out=$("$SB_BIN" generate reality-keypair 2>/dev/null)
  priv=$(echo "$out" | grep -i private | awk '{print $2}')
  pub=$(echo "$out" | grep -i public | awk '{print $2}')
  sid=$(openssl rand -hex 4 2>/dev/null)
  [ -z "$priv" ] && { err "Reality 密钥生成失败"; pause; return; }
  d=$(node_dir "$name"); mkdir -p "$d"
  cat > "$d/config.json" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vless",
      "tag": "reality-in",
      "listen": "::",
      "listen_port": $port,
      "users": [ { "uuid": "$uuid", "flow": "xtls-rprx-vision" } ],
      "tls": {
        "enabled": true,
        "server_name": "$rsni",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$rsni", "server_port": 443 },
          "private_key": "$priv",
          "short_id": [ "$sid" ]
        }
      }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF
  if ! "$SB_BIN" check -c "$d/config.json"; then
    err "配置校验未通过，已保留在 $d/config.json 待排查"; pause; return
  fi
  meta_set "$name" type reality
  meta_set "$name" addr "$addr"
  meta_set "$name" port "$port"
  meta_set "$name" sni "$rsni"
  meta_set "$name" uuid "$uuid"
  meta_set "$name" pbk "$pub"
  meta_set "$name" sid "$sid"
  meta_set "$name" autostart 1
  svc_start "$name"
  echo
  show_link "$name"
  pause
}

# ---------- 安装 TUIC ----------
install_tuic() {
  need_root
  sb_ensure_binary || { pause; return; }
  ensure_cmd openssl openssl >/dev/null
  local name port addr sni uuid password d ip
  read -rp "节点名 [默认 tuic-1]: " name; name="${name:-tuic-1}"
  if node_exists "$name"; then err "节点 $name 已存在，先卸载或换个名字"; pause; return; fi
  read -rp "监听端口 [默认随机]: " port; port="${port:-$(rand_port)}"
  ip=$(public_ip)
  read -rp "服务器地址（客户端连接用）[默认公网 IP ${ip:-未知}]: " addr; addr="${addr:-$ip}"
  [ -z "$addr" ] && { err "地址不能为空"; pause; return; }
  read -rp "SNI / 证书名 [默认 www.bing.com]: " sni; sni="${sni:-www.bing.com}"
  uuid=$(gen_uuid)
  read -rp "节点密码 [直接回车=自动生成]: " password; password="${password:-$(gen_password)}"
  d=$(node_dir "$name"); mkdir -p "$d"
  gen_cert "$d" "$sni" || { err "证书生成失败"; pause; return; }
  cat > "$d/config.json" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": $port,
      "users": [ { "uuid": "$uuid", "password": "$password" } ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "server_name": "$sni",
        "alpn": [ "h3" ],
        "certificate_path": "$d/cert.pem",
        "key_path": "$d/key.pem"
      }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF
  if ! "$SB_BIN" check -c "$d/config.json"; then
    err "配置校验未通过，已保留在 $d/config.json 待排查"; pause; return
  fi
  meta_set "$name" type tuic
  meta_set "$name" addr "$addr"
  meta_set "$name" port "$port"
  meta_set "$name" sni "$sni"
  meta_set "$name" uuid "$uuid"
  meta_set "$name" password "$password"
  meta_set "$name" autostart 1
  svc_start "$name"
  echo
  show_link "$name"
  pause
}

# ---------- 安装 AnyTLS ----------
install_anytls() {
  need_root
  sb_ensure_binary || { pause; return; }
  ensure_cmd openssl openssl >/dev/null
  local name port addr sni password d ip
  read -rp "节点名 [默认 anytls-1]: " name; name="${name:-anytls-1}"
  if node_exists "$name"; then err "节点 $name 已存在，先卸载或换个名字"; pause; return; fi
  read -rp "监听端口 [默认随机]: " port; port="${port:-$(rand_port)}"
  ip=$(public_ip)
  read -rp "服务器地址（客户端连接用）[默认公网 IP ${ip:-未知}]: " addr; addr="${addr:-$ip}"
  [ -z "$addr" ] && { err "地址不能为空"; pause; return; }
  read -rp "SNI / 证书名 [默认 www.bing.com]: " sni; sni="${sni:-www.bing.com}"
  read -rp "节点密码 [直接回车=自动生成]: " password; password="${password:-$(gen_password)}"
  d=$(node_dir "$name"); mkdir -p "$d"
  gen_cert "$d" "$sni" || { err "证书生成失败"; pause; return; }
  cat > "$d/config.json" <<EOF
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": $port,
      "users": [ { "password": "$password" } ],
      "tls": {
        "enabled": true,
        "server_name": "$sni",
        "certificate_path": "$d/cert.pem",
        "key_path": "$d/key.pem"
      }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF
  if ! "$SB_BIN" check -c "$d/config.json"; then
    err "配置校验未通过，已保留在 $d/config.json 待排查"; pause; return
  fi
  meta_set "$name" type anytls
  meta_set "$name" addr "$addr"
  meta_set "$name" port "$port"
  meta_set "$name" sni "$sni"
  meta_set "$name" password "$password"
  meta_set "$name" autostart 1
  svc_start "$name"
  echo
  show_link "$name"
  pause
}

# ---------- 节点管理 ----------
pick_node() {
  # 把选择的节点名放进全局 PICKED；无节点返回 1
  local nodes i c
  nodes=$(list_nodes)
  if [ -z "$nodes" ]; then warn "还没有任何节点，先安装一个"; return 1; fi
  echo "已有节点："
  i=1
  echo "$nodes" | while read -r n; do
    echo "  $i) $n（$(meta_get "$n" type)，端口 $(meta_get "$n" port)，$(svc_status_text "$n")）"
    i=$((i+1))
  done
  read -rp "输入序号: " c
  PICKED=$(echo "$nodes" | sed -n "${c}p")
  [ -n "$PICKED" ]
}

nodes_status() {
  local nodes; nodes=$(list_nodes)
  if [ -z "$nodes" ]; then warn "还没有任何节点"; pause; return; fi
  echo -e "${CYAN}===== 节点列表 =====${NC}"
  echo "$nodes" | while read -r n; do
    printf "%-16s 类型:%-10s 端口:%-6s 地址:%-28s 状态:%s\n" \
      "$n" "$(meta_get "$n" type)" "$(meta_get "$n" port)" "$(meta_get "$n" addr)" "$(svc_status_text "$n")"
  done
  pause
}

node_logs() {
  pick_node || { pause; return; }
  local d; d=$(node_dir "$PICKED")
  echo -e "${CYAN}----- $PICKED 最近 50 行日志（$d/sing-box.log）-----${NC}"
  tail -50 "$d/sing-box.log" 2>/dev/null || warn "暂无日志文件"
  pause
}

node_change_secret() {
  pick_node || { pause; return; }
  local name="$PICKED" type d new
  type=$(meta_get "$name" type); d=$(node_dir "$name")
  if [ "$type" = "hysteria2" ] || [ "$type" = "tuic" ] || [ "$type" = "anytls" ]; then
    read -rp "新密码 [直接回车=自动生成]: " new; new="${new:-$(gen_password)}"
    if command -v python3 >/dev/null 2>&1; then
      python3 - "$d/config.json" "$new" <<'PYEOF'
import json, sys
p, v = sys.argv[1], sys.argv[2]
c = json.load(open(p))
c["inbounds"][0]["users"][0]["password"] = v
json.dump(c, open(p, "w"), indent=2)
PYEOF
    else
      local old; old=$(meta_get "$name" password)
      sed -i "s|\"password\": \"$old\"|\"password\": \"$new\"|" "$d/config.json"
    fi
    meta_set "$name" password "$new"
  else
    new=$(gen_uuid)
    if command -v python3 >/dev/null 2>&1; then
      python3 - "$d/config.json" "$new" <<'PYEOF'
import json, sys
p, v = sys.argv[1], sys.argv[2]
c = json.load(open(p))
c["inbounds"][0]["users"][0]["uuid"] = v
json.dump(c, open(p, "w"), indent=2)
PYEOF
    else
      local old; old=$(meta_get "$name" uuid)
      sed -i "s|$old|$new|g" "$d/config.json"
    fi
    meta_set "$name" uuid "$new"
    info "新 UUID：$new"
  fi
  "$SB_BIN" check -c "$d/config.json" && svc_stop "$name" && svc_start "$name"
  echo; show_link "$name"
  pause
}

node_uninstall() {
  pick_node || { pause; return; }
  local name="$PICKED"
  read -rp "确认卸载节点 $name ？配置文件与证书将删除 [y/N]: " yn
  case "$yn" in
    y|Y)
      svc_stop "$name"
      if has_systemd; then
        rm -f "/etc/systemd/system/sb-toolbox-$name.service"
        systemctl daemon-reload 2>/dev/null
      fi
      rm -rf "$(node_dir "$name")"
      ok "节点 $name 已卸载"
      ;;
    *) info "已取消" ;;
  esac
  pause
}

sb_update() {
  info "更新 sing-box 到官方最新版..."
  local nodes; nodes=$(list_nodes)
  # 先停所有节点再换二进制
  echo "$nodes" | while read -r n; do [ -n "$n" ] && svc_stop "$n"; done
  if sb_install_binary; then
    echo "$nodes" | while read -r n; do
      [ -n "$n" ] && [ "$(meta_get "$n" autostart)" = "1" ] && svc_start "$n"
    done
    ok "更新完成"
  else
    err "更新失败，节点保持停止状态，可在服务管理里手动拉起"
  fi
  pause
}

start_all_nodes() {
  local nodes; nodes=$(list_nodes)
  if [ -z "$nodes" ]; then warn "还没有任何节点"; pause; return; fi
  echo "$nodes" | while read -r n; do
    [ -n "$n" ] && svc_start "$n"
  done
  ok "全部节点拉起流程结束（沙盒重启后跑这一项即可恢复）"
  pause
}

stop_all_nodes() {
  local nodes; nodes=$(list_nodes)
  [ -z "$nodes" ] && { warn "还没有任何节点"; pause; return; }
  echo "$nodes" | while read -r n; do [ -n "$n" ] && svc_stop "$n"; done
  pause
}

node_menu() {
  while true; do
    echo -e "${CYAN}===== sing-box 节点管理 =====${NC}"
    echo "  1) 安装 HY2 节点"
    echo "  2) 安装 VLESS+WS+TLS 节点"
    echo "  3) 安装 VLESS-Reality 节点"
    echo "  4) 安装 TUIC 节点"
    echo "  5) 安装 AnyTLS 节点"
    echo "  6) 节点列表与状态"
    echo "  7) 查看节点链接 / 二维码"
    echo "  8) 修改密码 / UUID（自动重启并出新链接）"
    echo "  9) 重启某个节点"
    echo " 10) 查看某个节点日志"
    echo " 11) 卸载某个节点"
    echo " 12) 更新 sing-box 到最新版"
    echo "  0) 返回主菜单"
    read -rp "请选择: " c
    case "$c" in
      1) install_hy2 ;;
      2) install_vless ;;
      3) install_reality ;;
      4) install_tuic ;;
      5) install_anytls ;;
      6) nodes_status ;;
      7) pick_node && { show_link "$PICKED"; pause; } ;;
      8) node_change_secret ;;
      9) pick_node && { svc_stop "$PICKED"; svc_start "$PICKED"; pause; } ;;
      10) node_logs ;;
      11) node_uninstall ;;
      12) sb_update ;;
      0) return ;;
      *) warn "无效选择" ;;
    esac
  done
}

service_menu() {
  while true; do
    echo -e "${CYAN}===== 服务管理 =====${NC}"
    echo "  1) 一键拉起全部节点（沙盒/机器重启后用）"
    echo "  2) 停止全部节点"
    echo "  3) 节点列表与状态"
    echo "  0) 返回主菜单"
    read -rp "请选择: " c
    case "$c" in
      1) start_all_nodes ;;
      2) stop_all_nodes ;;
      3) nodes_status ;;
      0) return ;;
      *) warn "无效选择" ;;
    esac
  done
}

# ---------- 哪吒探针（v0 / v1 双版本） ----------
NZ_DIR="$SB_HOME/nezha"
NZ_V0_PIN="v0.20.5"

nz_meta_set() {
  touch "$NZ_DIR/meta"
  grep -v "^$1=" "$NZ_DIR/meta" > "$NZ_DIR/meta.tmp" 2>/dev/null; mv "$NZ_DIR/meta.tmp" "$NZ_DIR/meta"
  echo "$1=$2" >> "$NZ_DIR/meta"
}
nz_meta_get() { [ -f "$NZ_DIR/meta" ] && grep "^$1=" "$NZ_DIR/meta" | head -1 | cut -d= -f2-; }

nz_download() { # $1=版本 v0|v1
  local arch url tag tmp
  case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) arch=amd64 ;; esac
  if [ "$1" = "v0" ]; then
    tag=$(curl -s --max-time 10 "https://api.github.com/repos/nezhahq/agent/releases?per_page=100" \
      | grep -o '"tag_name": *"v0\.[^"]*"' | head -1 | sed 's/.*"//;s/"//')
    [ -z "$tag" ] && tag="$NZ_V0_PIN"
    url="https://github.com/nezhahq/agent/releases/download/${tag}/nezha-agent_linux_${arch}.zip"
    info "下载哪吒探针 v0 版 $tag ..."
  else
    url="https://github.com/nezhahq/agent/releases/latest/download/nezha-agent_linux_${arch}.zip"
    info "下载哪吒探针 v1 版（官方最新）..."
  fi
  tmp=$(mktemp -d)
  curl -sL --max-time 300 -o "$tmp/nz.zip" "$url" || { err "下载失败"; rm -rf "$tmp"; return 1; }
  if command -v unzip >/dev/null 2>&1; then
    unzip -o -q "$tmp/nz.zip" -d "$tmp" || { err "解压失败"; rm -rf "$tmp"; return 1; }
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$tmp/nz.zip" "$tmp" \
      || { err "解压失败"; rm -rf "$tmp"; return 1; }
  else
    err "没有 unzip 也没有 python3，解压不了"; rm -rf "$tmp"; return 1
  fi
  mkdir -p "$NZ_DIR"
  cp "$tmp/nezha-agent" "$NZ_DIR/nezha-agent"
  chmod +x "$NZ_DIR/nezha-agent"
  rm -rf "$tmp"
  ok "哪吒探针已下载（$1 版）"
}

nz_cmdline() {
  local ver server key tls uuid
  ver=$(nz_meta_get ver); server=$(nz_meta_get server); key=$(nz_meta_get key)
  tls=$(nz_meta_get tls); uuid=$(nz_meta_get uuid)
  if [ "$ver" = "v0" ]; then
    echo "$NZ_DIR/nezha-agent -s $server -p $key"
  else
    local tlsv=false; [ "$tls" = "1" ] && tlsv=true
    cat > "$NZ_DIR/nezha.yml" <<EOF
debug: false
server: $server
client_secret: $key
tls: $tlsv
uuid: $uuid
report_delay: 3
EOF
    chmod 600 "$NZ_DIR/nezha.yml" 2>/dev/null
    echo "$NZ_DIR/nezha-agent -c $NZ_DIR/nezha.yml"
  fi
}

nz_start() {
  [ -f "$NZ_DIR/meta" ] || { warn "哪吒探针还没安装"; return 1; }
  local cmd; cmd=$(nz_cmdline)
  if has_systemd; then
    cat > /etc/systemd/system/sb-toolbox-nezha.service <<EOF
[Unit]
Description=nezha agent (toolbox)
After=network.target

[Service]
Type=simple
ExecStart=$cmd
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sb-toolbox-nezha >/dev/null 2>&1
    systemctl restart sb-toolbox-nezha
    sleep 1
    systemctl is-active --quiet sb-toolbox-nezha && ok "哪吒探针已启动" || err "哪吒探针启动失败，查 journalctl -u sb-toolbox-nezha"
  else
    if [ -f "$NZ_DIR/pid" ] && kill -0 "$(cat "$NZ_DIR/pid")" 2>/dev/null; then
      warn "哪吒探针已在运行"; return 0
    fi
    cat > "$NZ_DIR/start.sh" <<EOF
#!/bin/sh
cd $NZ_DIR || exit 1
nohup $cmd >> nezha.log 2>&1 &
echo \$! > $NZ_DIR/pid
EOF
    chmod +x "$NZ_DIR/start.sh"
    sh "$NZ_DIR/start.sh"
    sleep 1
    [ -f "$NZ_DIR/pid" ] && kill -0 "$(cat "$NZ_DIR/pid")" 2>/dev/null \
      && ok "哪吒探针已启动（nohup）" || err "哪吒探针启动失败，看 $NZ_DIR/nezha.log"
  fi
}

nz_stop() {
  if has_systemd; then
    systemctl stop sb-toolbox-nezha 2>/dev/null
    systemctl disable sb-toolbox-nezha >/dev/null 2>&1
  fi
  if [ -f "$NZ_DIR/pid" ]; then kill "$(cat "$NZ_DIR/pid")" 2>/dev/null; rm -f "$NZ_DIR/pid"; fi
  local p; p=$(pgrep -f "$NZ_DIR/nezha-agent" 2>/dev/null); [ -n "$p" ] && kill $p 2>/dev/null
  ok "哪吒探针已停止"
}

nz_running() {
  if has_systemd && systemctl is-active --quiet sb-toolbox-nezha 2>/dev/null; then return 0; fi
  if [ -f "$NZ_DIR/pid" ] && kill -0 "$(cat "$NZ_DIR/pid")" 2>/dev/null; then return 0; fi
  pgrep -f "$NZ_DIR/nezha-agent" >/dev/null 2>&1
}

nz_install() {
  need_root
  local server key ver tls
  read -rp "哪吒面板地址（地址:端口，如 nezha.example.com:8008）: " server
  [ -z "$server" ] && { err "地址不能为空"; pause; return; }
  read -rp "探针密钥: " key
  [ -z "$key" ] && { err "密钥不能为空"; pause; return; }
  read -rp "面板版本 [v1 新版（默认）/ v0 旧版]: " ver; ver="${ver:-v1}"
  [ "$ver" != "v0" ] && ver="v1"
  tls=""
  if [ "$ver" = "v1" ]; then
    read -rp "连接走 TLS？[y/N]: " yn; case "$yn" in y|Y) tls="1" ;; esac
  fi
  nz_stop >/dev/null 2>&1
  nz_download "$ver" || { pause; return; }
  mkdir -p "$NZ_DIR"
  nz_meta_set server "$server"
  nz_meta_set key "$key"
  nz_meta_set ver "$ver"
  nz_meta_set tls "$tls"
  local uuid; uuid=$(nz_meta_get uuid)
  [ -z "$uuid" ] && nz_meta_set uuid "$(cat /proc/sys/kernel/random/uuid)"
  nz_start
  pause
}

nz_menu() {
  while true; do
    echo -e "${CYAN}===== 哪吒探针 =====${NC}"
    if [ -f "$NZ_DIR/meta" ]; then
      echo "已配置：$(nz_meta_get ver) 版 → $(nz_meta_get server)，状态：$(nz_running && echo 运行中 || echo 已停止)"
    else
      echo "尚未安装"
    fi
    echo "  1) 安装 / 重装探针（可选 v0 或 v1）"
    echo "  2) 启动探针"
    echo "  3) 停止探针"
    echo "  4) 重启探针"
    echo "  5) 卸载探针"
    echo "  0) 返回主菜单"
    read -rp "请选择: " c
    case "$c" in
      1) nz_install ;;
      2) nz_start; pause ;;
      3) nz_stop; pause ;;
      4) nz_stop >/dev/null; nz_start; pause ;;
      5) read -rp "确认卸载哪吒探针？[y/N]: " yn; case "$yn" in y|Y) nz_stop; has_systemd && rm -f /etc/systemd/system/sb-toolbox-nezha.service && systemctl daemon-reload 2>/dev/null; rm -rf "$NZ_DIR"; ok "哪吒探针已卸载" ;; esac; pause ;;
      0) return ;; *) warn "无效选择" ;;
    esac
  done
}

# ---------- 测试工具（自带简测，不跑第三方脚本） ----------
test_chatgpt() {
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 12 https://chatgpt.com 2>/dev/null)
  case "$code" in
    200|301|302|307|308) echo "ChatGPT：可达（HTTP $code）" ;;
    403) echo "ChatGPT：连得上但被挡（HTTP 403，多为地区/IP 风控）" ;;
    000) echo "ChatGPT：连不上（网络不通或被墙）" ;;
    *) echo "ChatGPT：HTTP $code" ;;
  esac
  pause
}

test_netflix() {
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 12 https://www.netflix.com/title/81280792 2>/dev/null)
  case "$code" in
    200|301|302) echo "Netflix：自制剧页面可开（大概率解锁当地片库）" ;;
    404) echo "Netflix：只能看基础片库或未解锁（404）" ;;
    403) echo "Netflix：被挡（403）" ;;
    000) echo "Netflix：连不上" ;;
    *) echo "Netflix：HTTP $code" ;;
  esac
  pause
}

test_io() {
  local f=/tmp/.toolbox-iotest
  echo "写入 256MB 测速中..."
  dd if=/dev/zero of="$f" bs=64k count=4096 oflag=dsync 2>&1 | tail -1
  rm -f "$f"
  pause
}

test_menu() {
  while true; do
    echo -e "${CYAN}===== 测试工具 =====${NC}"
    echo "  1) 本机 IP 信息与归属"
    echo "  2) ChatGPT 可达简测"
    echo "  3) Netflix 解锁简测"
    echo "  4) 磁盘 IO 简测"
    echo "  5) 一键测速（speedtest）"
    echo "  6) Ping 测试"
    echo "  0) 返回主菜单"
    read -rp "请选择: " c
    case "$c" in
      1) ip_info ;; 2) test_chatgpt ;; 3) test_netflix ;;
      4) test_io ;; 5) net_speed ;; 6) net_ping ;;
      0) return ;; *) warn "无效选择" ;;
    esac
  done
}

# ---------- 备份恢复 ----------
bk_backup() {
  local out="$HOME/sb-toolbox-backup-$(date +%F-%H%M).tar.gz"
  tar -czf "$out" -C "$(dirname "$SB_HOME")" "$(basename "$SB_HOME")" 2>/dev/null
  if [ -f "$out" ]; then
    ok "备份完成：$out（$(du -h "$out" | cut -f1)）"
    warn "备份包含节点密码/哪吒密钥，请妥善保管，不要外传"
  else
    err "备份失败"
  fi
  pause
}

bk_restore() {
  local files n i c f
  files=$(ls -1 "$HOME"/sb-toolbox-backup-*.tar.gz 2>/dev/null)
  [ -z "$files" ] && { warn "在 $HOME 没找到备份包"; pause; return; }
  echo "已有备份："
  i=1
  echo "$files" | while read -r x; do echo "  $i) $x"; i=$((i+1)); done
  read -rp "选择要恢复的序号: " c
  f=$(echo "$files" | sed -n "${c}p")
  [ -z "$f" ] && { err "选择无效"; pause; return; }
  read -rp "恢复将覆盖当前工具箱数据（节点先停），确认？[y/N]: " yn
  case "$yn" in
    y|Y) ;;
    *) info "已取消"; pause; return ;;
  esac
  local nodes; nodes=$(list_nodes)
  echo "$nodes" | while read -r x; do [ -n "$x" ] && svc_stop "$x"; done
  nz_stop >/dev/null 2>&1
  mv "$SB_HOME" "${SB_HOME}.old-$(date +%s)" 2>/dev/null
  tar -xzf "$f" -C "$(dirname "$SB_HOME")"
  ok "恢复完成，正在拉起节点..."
  nodes=$(list_nodes)
  echo "$nodes" | while read -r x; do
    [ -n "$x" ] && [ "$(meta_get "$x" autostart)" = "1" ] && svc_start "$x"
  done
  [ -f "$NZ_DIR/meta" ] && nz_start
  pause
}

bk_menu() {
  while true; do
    echo -e "${CYAN}===== 备份恢复 =====${NC}"
    echo "  1) 备份工具箱（节点+哪吒配置打包到家目录）"
    echo "  2) 从备份恢复"
    echo "  0) 返回主菜单"
    read -rp "请选择: " c
    case "$c" in
      1) bk_backup ;;
      2) bk_restore ;;
      0) return ;; *) warn "无效选择" ;;
    esac
  done
}

# ---------- 主菜单 ----------
banner() {
  echo -e "${GREEN}========================================${NC}"
  echo -e "${GREEN}        服务器工具箱  v$VERSION${NC}"
  echo -e "${GREEN}  系统/网络/Docker/节点/哪吒/测试/备份${NC}"
  echo -e "${GREEN}========================================${NC}"
  if has_systemd; then echo "托管模式：systemd"; else echo "托管模式：nohup（无 systemd 环境）"; fi
  echo "工具箱目录：$SB_HOME"
  echo
}

main() {
  need_root
  mkdir -p "$SB_BIN_DIR" "$SB_NODES_DIR"
  banner
  while true; do
    echo -e "${CYAN}===== 主菜单 =====${NC}"
    echo "  1) 系统维护"
    echo "  2) 网络工具"
    echo "  3) Docker 管理"
    echo "  4) sing-box 节点管理"
    echo "  5) 哪吒探针"
    echo "  6) 测试工具"
    echo "  7) 服务管理"
    echo "  8) 备份恢复"
    echo "  9) 系统信息"
    echo "  0) 退出"
    read -rp "请选择: " c
    case "$c" in
      1) sys_menu ;;
      2) net_menu ;;
      3) dk_menu ;;
      4) node_menu ;;
      5) nz_menu ;;
      6) test_menu ;;
      7) service_menu ;;
      8) bk_menu ;;
      9) sys_info ;;
      0) echo "拜拜，节点还在后台跑着呢。"; exit 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

# 直接命令（不用进菜单）：info / nodes / start-all / stop-all / clean / update
case "${1:-}" in
  info) sys_info; exit 0 ;;
  nodes) nodes_status; exit 0 ;;
  start-all) start_all_nodes; exit 0 ;;
  stop-all) stop_all_nodes; exit 0 ;;
  clean) sys_clean; exit 0 ;;
  update) sys_update; exit 0 ;;
esac

main "$@"
