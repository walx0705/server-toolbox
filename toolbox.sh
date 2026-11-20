#!/usr/bin/env bash
# ============================================================
# 服务器工具箱 toolbox.sh
# 系统维护 + sing-box 节点管理（HY2 / VLESS+WS+TLS）
# 双模式：有 systemd 的普通 VPS 用 systemd 托管；
#         无 systemd 的沙盒（如 Altare）自动用 nohup 托管。
# 用法：bash <(curl -sL <脚本地址>)
# 说明：脚本不内置任何密码，节点密码/UUID 均在安装时于本机生成。
# ============================================================

# 通过管道运行时把输入切回终端，保证菜单可交互；切不过去就沿用当前输入
shopt -s execfail 2>/dev/null
if [ ! -t 0 ] && ( : < /dev/tty ) 2>/dev/null; then
  exec < /dev/tty
fi

VERSION="1.0.0"
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

sys_menu() {
  while true; do
    echo -e "${CYAN}===== 系统维护 =====${NC}"
    echo "  1) 系统信息"
    echo "  2) 系统更新"
    echo "  3) 安装常用工具"
    echo "  4) 清理垃圾"
    echo "  5) 设置时区"
    echo "  6) 开启 BBR（仅普通 VPS）"
    echo "  0) 返回主菜单"
    read -rp "请选择: " c
    case "$c" in
      1) sys_info ;; 2) sys_update ;; 3) sys_tools ;;
      4) sys_clean ;; 5) sys_timezone ;; 6) sys_bbr ;;
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
  if [ "$type" = "hysteria2" ]; then
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
    echo "  3) 节点列表与状态"
    echo "  4) 查看节点链接 / 二维码"
    echo "  5) 修改密码 / UUID（自动重启并出新链接）"
    echo "  6) 重启某个节点"
    echo "  7) 查看某个节点日志"
    echo "  8) 卸载某个节点"
    echo "  9) 更新 sing-box 到最新版"
    echo "  0) 返回主菜单"
    read -rp "请选择: " c
    case "$c" in
      1) install_hy2 ;;
      2) install_vless ;;
      3) nodes_status ;;
      4) pick_node && { show_link "$PICKED"; pause; } ;;
      5) node_change_secret ;;
      6) pick_node && { svc_stop "$PICKED"; svc_start "$PICKED"; pause; } ;;
      7) node_logs ;;
      8) node_uninstall ;;
      9) sb_update ;;
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

# ---------- 主菜单 ----------
banner() {
  echo -e "${GREEN}========================================${NC}"
  echo -e "${GREEN}        服务器工具箱  v$VERSION${NC}"
  echo -e "${GREEN}   系统维护 + sing-box 节点（HY2/VLESS）${NC}"
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
    echo "  2) sing-box 节点管理"
    echo "  3) 服务管理"
    echo "  4) 系统信息"
    echo "  0) 退出"
    read -rp "请选择: " c
    case "$c" in
      1) sys_menu ;;
      2) node_menu ;;
      3) service_menu ;;
      4) sys_info ;;
      0) echo "拜拜，节点还在后台跑着呢。"; exit 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

main "$@"
