#!/usr/bin/env bash
#
# sing-box 一键安装与管理脚本
# 协议: VLESS + Reality + XTLS-Vision / Hysteria2
#
# 参考:
#   - sing-box 官方文档: https://sing-box.sagernet.org
#   - GitHub 一键脚本: 233boy/sing-box、irasutoya/sing-box、imengying/sing-box
#
set -euo pipefail

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
INFO_FILE="${CONFIG_DIR}/node.info"
BIN_PATH="/usr/local/bin/sing-box"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
HY2_CERT="${CONFIG_DIR}/hy2-cert.pem"
HY2_KEY="${CONFIG_DIR}/hy2-key.pem"

PORT="${PORT:-443}"
UUID="${UUID:-}"
SNI="${SNI:-www.apple.com}"
NAME="${NAME:-VLESS-REALITY}"
ENABLE_HY2="${ENABLE_HY2:-1}"
ENABLE_VLESS="${ENABLE_VLESS:-1}"
HY2_PORT="${HY2_PORT:-}"
HY2_PASSWORD="${HY2_PASSWORD:-}"
HY2_DOMAIN="${HY2_DOMAIN:-}"
SERVER_IP=""

MODE="menu"
AUTOSTART_ACTION=""
OPEN_FIREWALL=0

log()          { echo -e "[*] $*"; }
fail()         { echo -e "[!] $*" >&2; exit 1; }
need_root()    { [[ $EUID -eq 0 ]] || fail "请使用 root 运行本脚本"; }
need_singbox() { command -v sing-box >/dev/null 2>&1 || fail "sing-box 未安装，请先选择菜单 1 安装"; }

ask() {
  local ans
  if [[ "$MODE" == "menu" && -t 0 ]]; then
    read -r -p "$1 (默认 $2): " ans
    echo "${ans:-$2}"
  else
    echo "$2"
  fi
}

urlencode() {
  local LC_ALL=C s="$1" out="" c hex i
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9_.~-]) out+="$c" ;;
      *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
    esac
  done
  echo "$out"
}

addr_disp() {
  local a="$1"
  if [[ -n "$a" && "$a" =~ : && "$a" != "["* ]]; then
    echo "[$a]"
  else
    echo "$a"
  fi
}

usage() {
  cat <<'EOF'
sing-box 一键管理脚本 (VLESS + Reality + Vision / Hysteria2)

用法:
  bash <(curl -fsSL https://raw.githubusercontent.com/你的仓库/sing-box.sh)
      直接进入交互菜单

  bash <(curl -fsSL ...) install [-port 8443] [-no-hy2]
      直接安装（可带参数，不进入菜单）
  bash <(curl -fsSL ...) info | restart | status | update | uninstall
  bash <(curl -fsSL ...) autostart on|off|status
  bash <(curl -fsSL ...) change-port | change-sni
  bash <(curl -fsSL ...) bbr
      开启 BBR TCP 加速
  bash <(curl -fsSL ...) hy2
      单独安装 / 添加 Hysteria2 (HY2)

安装参数:
  -port <端口>          VLESS 监听端口 (默认 443)
  -sni <域名>           Reality 伪装域名 (默认 www.apple.com)
  -uuid <UUID>          指定 VLESS UUID (默认随机生成)
  -hy2-port <端口>      HY2 UDP 端口 (默认与 VLESS 相同)
  -hy2-domain <域名>    HY2 带域名模式 (免证书)
  -hy2-password <密码>  指定 HY2 密码 (默认随机生成)
  -no-hy2               不安装 Hysteria2
  -open-firewall        非交互安装时自动放行防火墙端口 (ufw/firewalld)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    install)           MODE="install"; shift ;;
    info)              MODE="info"; shift ;;
    restart)           MODE="restart"; shift ;;
    status)            MODE="status"; shift ;;
    autostart)         MODE="autostart"; AUTOSTART_ACTION="${2:-}"; shift $(( $# > 1 ? 2 : 1 )) ;;
    update)            MODE="update"; shift ;;
    bbr)               MODE="bbr"; shift ;;
    hy2)               MODE="hy2"; shift ;;
    change-port)       MODE="change-port"; shift ;;
    change-sni)        MODE="change-sni"; shift ;;
    uninstall|-uninstall) MODE="uninstall"; shift ;;
    -port|-p)          PORT="$2"; shift 2 ;;
    -uuid|-u)          UUID="$2"; shift 2 ;;
    -sni|-s)           SNI="$2"; shift 2 ;;
    -name|-n)          NAME="$2"; shift 2 ;;
    -hy2-port)         HY2_PORT="$2"; shift 2 ;;
    -hy2-password)     HY2_PASSWORD="$2"; shift 2 ;;
    -hy2-domain)       HY2_DOMAIN="$2"; shift 2 ;;
    -no-hy2)           ENABLE_HY2=0; shift ;;
    -open-firewall)    OPEN_FIREWALL=1; shift ;;
    -h|--help|-help)   usage; exit 0 ;;
    *) echo "未知参数: $1"; usage; exit 1 ;;
  esac
done

[[ -n "$HY2_PORT" ]] || HY2_PORT="$PORT"
if [[ -n "$HY2_DOMAIN" ]]; then
  ENABLE_HY2=1
  [[ "$HY2_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?\.[a-zA-Z]{2,}$ ]] || fail "域名格式无效: $HY2_DOMAIN"
fi
if [[ "$MODE" == "install" ]]; then
  [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || fail "端口无效: $PORT"
  [[ "$HY2_PORT" =~ ^[0-9]+$ ]] && (( HY2_PORT >= 1 && HY2_PORT <= 65535 )) || fail "HY2 端口无效: $HY2_PORT"
fi

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)   echo "amd64" ;;
    aarch64|arm64)  echo "arm64" ;;
    armv7l|armhf)   echo "armv7" ;;
    armv6l)         echo "armv6" ;;
    i386|i686)      echo "386" ;;
    riscv64)        echo "riscv64" ;;
    s390x)          echo "s390x" ;;
    ppc64le)        echo "ppc64le" ;;
    loongarch64)    echo "loong64" ;;
    *) fail "不支持的架构: $(uname -m)" ;;
  esac
}

get_latest_version() {
  local version
  version="$(curl -fsSL --max-time 15 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" \
    | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -1)"
  if [[ -z "$version" ]]; then
    version="$(curl -fsSL --max-time 15 -o /dev/null -w '%{redirect_url}' \
      "https://github.com/SagerNet/sing-box/releases/latest" \
      | sed -n 's#.*/tag/v\([^/]*\)$#\1#p')"
  fi
  [[ -z "$version" ]] && version="1.13.16"
  echo "$version"
}

fetch_singbox() {
  local arch version url tmpdir
  arch="$(detect_arch)"
  version="$(get_latest_version)"
  url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${arch}.tar.gz"
  log "下载 sing-box v${version} (linux-${arch})..."
  tmpdir="$(mktemp -d)"
  curl -fL --retry 3 -o "${tmpdir}/sing-box.tar.gz" "$url"
  tar -xzf "${tmpdir}/sing-box.tar.gz" -C "$tmpdir"
  install -m 755 "${tmpdir}/sing-box-${version}-linux-${arch}/sing-box" "$1"
  rm -rf "$tmpdir"
}

install_singbox() {
  if command -v sing-box >/dev/null 2>&1; then
    log "已检测到 sing-box: $(sing-box version | head -1)"
    return
  fi
  fetch_singbox "$BIN_PATH"
  log "安装完成: $(sing-box version | head -1)"
}

update_singbox() {
  need_root
  need_singbox
  log "当前版本: $(sing-box version | head -1)"
  fetch_singbox "$BIN_PATH"
  log "已更新: $(sing-box version | head -1)"
  restart_service
}

gen_uuid()       { [[ -n "$UUID" ]] || UUID="$(sing-box generate uuid)"; }
gen_short_id()   { SHORT_ID="$(openssl rand -hex 4 2>/dev/null || od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"; }
gen_hy2_password() { [[ -n "$HY2_PASSWORD" ]] || HY2_PASSWORD="$(openssl rand -hex 12)"; }

ask_hy2_password() {
  local pw=""
  if [[ "$MODE" == "menu" && -t 0 ]]; then
    read -r -p "HY2 密码 (留空自动生成): " pw
    [[ -n "$pw" ]] && HY2_PASSWORD="$pw"
  fi
}

gen_hy2_cert() {
  if [[ ! -f "$HY2_CERT" || ! -f "$HY2_KEY" ]]; then
    log "生成 Hysteria2 自签名证书 (CN=${HY2_DOMAIN:-$SNI})..."
    mkdir -p "$CONFIG_DIR"
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "$HY2_KEY" -out "$HY2_CERT" -days 3650 \
      -subj "/CN=${HY2_DOMAIN:-$SNI}" || fail "生成证书失败，请检查 openssl 与 ${CONFIG_DIR} 目录权限"
  fi
}

gen_reality_keys() {
  local output
  output="$(sing-box generate reality-keypair)"
  PRIVATE_KEY="$(echo "$output" | sed -n 's/^PrivateKey: *//p')"
  PUBLIC_KEY="$(echo "$output" | sed -n 's/^PublicKey: *//p')"
  [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || fail "生成 Reality 密钥失败"
}

save_info() {
  cat > "$INFO_FILE" <<EOF
PORT=${PORT}
UUID=${UUID}
SNI=${SNI}
NAME=${NAME}
PRIVATE_KEY=${PRIVATE_KEY}
PUBLIC_KEY=${PUBLIC_KEY}
SHORT_ID=${SHORT_ID}
ENABLE_HY2=${ENABLE_HY2}
ENABLE_VLESS=${ENABLE_VLESS}
HY2_PORT=${HY2_PORT}
HY2_PASSWORD=${HY2_PASSWORD}
HY2_DOMAIN=${HY2_DOMAIN}
SERVER_IP=${SERVER_IP}
EOF
  chmod 600 "$INFO_FILE"
}

load_info() {
  [[ -f "$INFO_FILE" ]] || fail "未找到节点信息 (${INFO_FILE})，请先选择菜单 1 安装"
  . "$INFO_FILE"
  PORT="${PORT:-443}"
  UUID="${UUID:-}"
  SNI="${SNI:-www.apple.com}"
  NAME="${NAME:-VLESS-REALITY}"
  PRIVATE_KEY="${PRIVATE_KEY:-}"
  PUBLIC_KEY="${PUBLIC_KEY:-}"
  SHORT_ID="${SHORT_ID:-}"
  ENABLE_HY2="${ENABLE_HY2:-1}"
  ENABLE_VLESS="${ENABLE_VLESS:-1}"
  HY2_PORT="${HY2_PORT:-$PORT}"
  HY2_PASSWORD="${HY2_PASSWORD:-}"
  HY2_DOMAIN="${HY2_DOMAIN:-}"
  SERVER_IP="${SERVER_IP:-}"
}

write_config() {
  mkdir -p "$CONFIG_DIR"
  if [[ -f "$CONFIG_FILE" ]]; then
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%s)"
    log "旧配置已备份到 ${CONFIG_DIR}/"
  fi
  local vless_inbound="" hy2_inbound="" inbounds=""
  if [[ "$ENABLE_VLESS" -eq 1 ]]; then
    vless_inbound="    {
      \"type\": \"vless\",
      \"tag\": \"vless-in\",
      \"listen\": \"::\",
      \"listen_port\": ${PORT},
      \"users\": [
        { \"uuid\": \"${UUID}\", \"flow\": \"xtls-rprx-vision\" }
      ],
      \"tls\": {
        \"enabled\": true,
        \"server_name\": \"${SNI}\",
        \"reality\": {
          \"enabled\": true,
          \"handshake\": { \"server\": \"${SNI}\", \"server_port\": 443 },
          \"private_key\": \"${PRIVATE_KEY}\",
          \"short_id\": [\"${SHORT_ID}\"]
        }
      }
    }"
  fi
  if [[ "$ENABLE_HY2" -eq 1 ]]; then
    hy2_inbound="    {
      \"type\": \"hysteria2\",
      \"tag\": \"hy2-in\",
      \"listen\": \"::\",
      \"listen_port\": ${HY2_PORT},
      \"users\": [
        { \"password\": \"${HY2_PASSWORD}\" }
      ],
      \"tls\": {
        \"enabled\": true,
        \"certificate_path\": \"${HY2_CERT}\",
        \"key_path\": \"${HY2_KEY}\"
      }
    }"
  fi
  if [[ -n "$vless_inbound" && -n "$hy2_inbound" ]]; then
    inbounds="${vless_inbound},
${hy2_inbound}"
  else
    inbounds="${vless_inbound}${hy2_inbound}"
  fi
  cat > "$CONFIG_FILE" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "ntp": {
    "enabled": true,
    "server": "time.apple.com",
    "server_port": 123,
    "interval": "30m"
  },
  "inbounds": [
${inbounds}
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF
  chmod 600 "$CONFIG_FILE"
  sing-box check -c "$CONFIG_FILE" || fail "配置校验失败，请检查 ${CONFIG_FILE}"
  save_info
}

setup_service() {
  cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable sing-box
  systemctl restart sing-box
  sleep 1
  systemctl is-active --quiet sing-box || fail "服务启动失败，请执行: journalctl -u sing-box -n 50 --no-pager"
}

restart_service() {
  need_root
  need_singbox
  systemctl restart sing-box
  sleep 1
  if systemctl is-active --quiet sing-box; then
    log "sing-box 已重启并正常运行"
  else
    fail "服务启动失败，请查看日志: journalctl -u sing-box -n 50 --no-pager"
  fi
}

get_public_ip() {
  local ip=""
  ip="$(curl -4 -fsSL --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(curl -4 -fsSL --max-time 10 https://ipinfo.io/ip 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(curl -fsSL --max-time 10 https://api6.ipify.org 2>/dev/null || true)"
  echo "$ip"
}

show_info() {
  need_root
  load_info
  [[ -n "$SERVER_IP" ]] || SERVER_IP="$(get_public_ip)"
  [[ -n "$SERVER_IP" ]] || SERVER_IP="<服务器IP>"
  echo "================================================================"
  echo "  节点信息 (保存于 ${INFO_FILE})"
  echo "================================================================"
  echo "  服务器:   ${SERVER_IP}"
  if [[ "$ENABLE_VLESS" -eq 1 ]]; then
    echo "  VLESS:    ${PORT} / UUID ${UUID}"
    echo "  SNI:      ${SNI} / 公钥 ${PUBLIC_KEY} / ShortId ${SHORT_ID}"
  fi
  if [[ "$ENABLE_HY2" -eq 1 ]]; then
    if [[ -n "$HY2_DOMAIN" ]]; then
      echo "  HY2:      带域名 ${HY2_DOMAIN} / ${HY2_PORT} (UDP)"
    else
      echo "  HY2:      无域名 / ${HY2_PORT} (UDP)"
    fi
    echo "  HY2 密码: ${HY2_PASSWORD}"
  fi
  echo "--------------------------------------------------------------"
  if [[ "$ENABLE_VLESS" -eq 1 ]]; then
    echo "  VLESS 分享链接 (复制下面整行):"
    echo "  vless://${UUID}@$(addr_disp "$SERVER_IP"):${PORT}?type=tcp&encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&spx=%2F#$(urlencode "$NAME")"
  fi
  if [[ "$ENABLE_HY2" -eq 1 ]]; then
    local hy2_server="$(addr_disp "$SERVER_IP")" hy2_suffix="?sni=${SNI}&insecure=1"
    [[ -n "$HY2_DOMAIN" ]] && { hy2_server="$HY2_DOMAIN"; hy2_suffix="?sni=${HY2_DOMAIN}&insecure=1"; }
    echo "  HY2 分享链接 (复制下面整行):"
    echo "  hy2://${HY2_PASSWORD}@${hy2_server}:${HY2_PORT}${hy2_suffix}#$(urlencode "${NAME}-hy2")"
  fi
  echo "================================================================"
}

check_ports() {
  local tool="" tcp_ok=0 udp_ok=0 ok=1
  if command -v ss >/dev/null 2>&1; then
    tool="ss"
  elif command -v netstat >/dev/null 2>&1; then
    tool="netstat"
  else
    log "未找到 ss/netstat，跳过端口监听检查"
    return 1
  fi
  if [[ "$tool" == "ss" ]]; then
    [[ "$ENABLE_VLESS" -eq 1 ]] && tcp_ok="$(ss -tln 2>/dev/null | grep -c ":$PORT " || true)"
    [[ "$ENABLE_HY2" -eq 1 ]] && udp_ok="$(ss -uln 2>/dev/null | grep -c ":$HY2_PORT " || true)"
  else
    [[ "$ENABLE_VLESS" -eq 1 ]] && tcp_ok="$(netstat -tln 2>/dev/null | grep -c ":$PORT " || true)"
    [[ "$ENABLE_HY2" -eq 1 ]] && udp_ok="$(netstat -uln 2>/dev/null | grep -c ":$HY2_PORT " || true)"
  fi
  if [[ "$ENABLE_VLESS" -eq 1 ]]; then
    if (( tcp_ok > 0 )); then
      log "VLESS TCP ${PORT}: 监听正常"
    else
      log "警告: VLESS TCP ${PORT} 未监听，请查看日志: journalctl -u sing-box -n 50 --no-pager"
      ok=0
    fi
  fi
  if [[ "$ENABLE_HY2" -eq 1 ]]; then
    if (( udp_ok > 0 )); then
      log "HY2 UDP ${HY2_PORT}: 监听正常"
    else
      log "警告: HY2 UDP ${HY2_PORT} 未监听"
      ok=0
    fi
  fi
  return $(( 1 - ok ))
}

check_sni_reachable() {
  local code=""
  code="$(curl -4 -sS -o /dev/null -w '%{http_code}' --max-time 8 "https://${SNI}" 2>/dev/null || true)"
  if [[ -z "$code" || "$code" == "000" ]]; then
    log "警告: 本机无法连通 https://${SNI}，Reality 握手可能失败（HY2 不受影响）。可在菜单 7 更换 SNI。"
    return 1
  fi
  log "Reality 伪装站点 ${SNI} 可连通 (HTTP ${code})"
}

open_firewall_ports() {
  local tcp="${PORT}/tcp" udp="" tool="" yn="n"
  [[ "$ENABLE_HY2" -eq 1 ]] && udp="${HY2_PORT}/udp"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    tool="ufw"
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    tool="firewalld"
  else
    log "未检测到启用的 ufw/firewalld，请确认云控制台安全组已放行 ${tcp}${udp:+和 ${udp}}"
    return
  fi
  if [[ "$OPEN_FIREWALL" -ne 1 ]]; then
    if [[ "$MODE" == "menu" && -t 0 ]]; then
      read -r -p "检测到 ${tool} 已启用，自动放行 ${tcp}${udp:+和 ${udp}}? [y/N] " yn
      [[ "$yn" =~ ^[yY]$ ]] || { log "未修改防火墙，请手动放行端口。"; return; }
    else
      return
    fi
  fi
  if [[ "$tool" == "ufw" ]]; then
    ufw allow "$tcp" >/dev/null 2>&1
    [[ -n "$udp" ]] && ufw allow "$udp" >/dev/null 2>&1
  else
    firewall-cmd --permanent --add-port="$tcp" >/dev/null 2>&1
    [[ -n "$udp" ]] && firewall-cmd --permanent --add-port="$udp" >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
  fi
  log "${tool} 已放行: ${tcp}${udp:+ / ${udp}}"
}

enable_bbr() {
  local cur=""
  cur="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  if [[ "$cur" == "bbr" ]]; then
    log "BBR 已开启 (tcp_congestion_control=bbr)"
    return 0
  fi
  log "开启 BBR TCP 加速..."
  modprobe tcp_bbr 2>/dev/null || true
  if ! sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1; then
    log "警告: 当前内核不支持 BBR，已跳过（不影响节点运行）"
    return 1
  fi
  grep -q '^net.core.default_qdisc=fq' /etc/sysctl.conf 2>/dev/null || echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf
  grep -q '^net.ipv4.tcp_congestion_control=bbr' /etc/sysctl.conf 2>/dev/null || echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf
  sysctl -p >/dev/null 2>&1 || true
  log "BBR 已开启（已写入 /etc/sysctl.conf，重启后保持）"
}

show_status() {
  need_singbox
  load_info
  systemctl status sing-box --no-pager -l || true
  echo ""
  if systemctl is-enabled --quiet sing-box 2>/dev/null; then
    log "开机自启: 已开启"
  else
    log "开机自启: 未开启"
  fi
  echo ""
  log "最近日志:"
  journalctl -u sing-box -n 10 --no-pager || true
  echo ""
  log "端口与连通性检查:"
  check_ports || true
  check_sni_reachable || true
  log "当前服务器时间: $(date '+%F %T %Z')（Reality 要求客户端与服务端时间误差在 2 分钟内）"
  if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)" == "bbr" ]]; then
    log "TCP 加速: BBR 已开启"
  else
    log "TCP 加速: 未开启（菜单 10 可开启 BBR）"
  fi
}

autostart_toggle() {
  need_root
  need_singbox
  local action="${1:-}"
  if [[ -z "$action" ]]; then
    if systemctl is-enabled --quiet sing-box 2>/dev/null; then
      echo "当前状态: 开机自启已开启"
      if [[ -t 0 ]]; then
        read -r -p "关闭开机自启? [y/N] " ans
        if [[ "$ans" =~ ^[yY]$ ]]; then
          systemctl disable sing-box
          log "已关闭开机自启（当前运行不受影响）"
        else
          echo "未更改。"
        fi
      fi
    else
      echo "当前状态: 开机自启未开启"
      if [[ -t 0 ]]; then
        read -r -p "开启开机自启? [y/N] " ans
        if [[ "$ans" =~ ^[yY]$ ]]; then
          systemctl enable sing-box
          log "已开启开机自启（开机自动运行）"
        else
          echo "未更改。"
        fi
      fi
    fi
  else
    case "$action" in
      on|enable)   systemctl enable sing-box; log "已开启开机自启" ;;
      off|disable) systemctl disable sing-box; log "已关闭开机自启" ;;
      status)      if systemctl is-enabled --quiet sing-box 2>/dev/null; then echo "已开启"; else echo "未开启"; fi ;;
      *) fail "用法: autostart on|off|status" ;;
    esac
  fi
}

change_port() {
  need_root
  need_singbox
  load_info
  local new_port new_hy2 sync
  if [[ "$ENABLE_VLESS" -eq 1 ]]; then
    new_port="$(ask "请输入新的 VLESS 端口" "$PORT")"
    [[ "$new_port" =~ ^[0-9]+$ ]] && (( new_port >= 1 && new_port <= 65535 )) || fail "端口无效: $new_port"
    PORT="$new_port"
    if [[ "$ENABLE_HY2" -eq 1 ]]; then
      if [[ -t 0 ]]; then
        read -r -p "是否同步修改 HY2 端口? [y/N] " sync
        if [[ "$sync" =~ ^[yY]$ ]]; then
          new_hy2="$(ask "请输入新的 HY2 端口" "$HY2_PORT")"
          [[ "$new_hy2" =~ ^[0-9]+$ ]] && (( new_hy2 >= 1 && new_hy2 <= 65535 )) || fail "HY2 端口无效: $new_hy2"
          HY2_PORT="$new_hy2"
        fi
      else
        HY2_PORT="$PORT"
      fi
    fi
  else
    new_hy2="$(ask "请输入新的 HY2 端口" "$HY2_PORT")"
    [[ "$new_hy2" =~ ^[0-9]+$ ]] && (( new_hy2 >= 1 && new_hy2 <= 65535 )) || fail "HY2 端口无效: $new_hy2"
    HY2_PORT="$new_hy2"
  fi
  write_config
  restart_service
  log "端口已更新，新分享链接:"
  show_info
}

change_sni() {
  need_root
  need_singbox
  load_info
  SNI="$(ask "请输入新的 Reality 伪装 SNI" "$SNI")"
  write_config
  restart_service
  check_sni_reachable || true
  log "SNI 已更新，新分享链接:"
  show_info
}

uninstall() {
  need_root
  echo -e "\n即将执行卸载，将删除:"
  echo "  - ${BIN_PATH}"
  echo "  - ${CONFIG_DIR} (配置、证书、节点信息)"
  echo "  - ${SERVICE_FILE}"
  read -r -p "确认卸载？请输入 yes 继续: " answer
  [[ "$answer" == "yes" ]] || { echo "已取消。"; return 0; }
  systemctl disable --now sing-box 2>/dev/null || true
  rm -f "${BIN_PATH}" "${SERVICE_FILE}"
  rm -rf "${CONFIG_DIR}"
  systemctl daemon-reload
  log "sing-box 已卸载，本机缓存与日志请手动清理。"
}

install_node() {
  need_root
  ENABLE_VLESS=1
  command -v curl >/dev/null 2>&1 || fail "缺少 curl，请先安装: apt install -y curl"
  command -v tar  >/dev/null 2>&1 || fail "缺少 tar，请先安装: apt install -y tar"
  command -v openssl >/dev/null 2>&1 || fail "缺少 openssl，请先安装: apt install -y openssl"

  if [[ -f "$CONFIG_FILE" ]]; then
    echo "检测到已有配置: ${CONFIG_FILE}"
    echo "重装将重新生成全部参数（UUID、Reality 密钥、HY2 密码），旧客户端链接会失效；旧配置会自动备份。"
    if [[ "$MODE" == "menu" && -t 0 ]]; then
      read -r -p "确认继续重装? [y/N] " ans
      [[ "$ans" =~ ^[yY]$ ]] || { echo "已取消。"; return 0; }
    else
      log "非交互模式，继续重装..."
    fi
  fi

  PORT="$(ask "请输入 VLESS 监听端口" "$PORT")"
  [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || fail "端口无效: $PORT"
  SNI="$(ask "请输入 Reality 伪装 SNI" "$SNI")"
  if [[ "$MODE" == "menu" && -t 0 ]]; then
    read -r -p "启用 Hysteria2? [Y/n] " hy2
    [[ "$hy2" =~ ^[nN]$ ]] && ENABLE_HY2=0
  fi
  if [[ "$ENABLE_HY2" -eq 1 ]]; then
    HY2_PORT="$(ask "HY2 UDP 端口 (可与 VLESS 相同)" "$HY2_PORT")"
    [[ "$HY2_PORT" =~ ^[0-9]+$ ]] && (( HY2_PORT >= 1 && HY2_PORT <= 65535 )) || fail "HY2 端口无效: $HY2_PORT"
    ask_hy2_password
    if [[ "$MODE" == "menu" && -t 0 ]]; then
      read -r -p "HY2 带域名模式? 输入域名，留空使用 IP 模式: " dom
      [[ -n "$dom" ]] && HY2_DOMAIN="$dom"
      [[ -n "$HY2_DOMAIN" ]] && [[ "$HY2_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?\.[a-zA-Z]{2,}$ ]] || fail "域名格式无效: $HY2_DOMAIN"
    fi
  fi

  install_singbox
  enable_bbr || true
  gen_uuid
  gen_reality_keys
  gen_short_id
  if [[ "$ENABLE_HY2" -eq 1 ]]; then
    gen_hy2_password
    gen_hy2_cert
  fi
  SERVER_IP="$(get_public_ip)"
  write_config
  setup_service
  open_firewall_ports
  check_ports || true
  check_sni_reachable || true
  echo ""
  show_info
  echo ""
  echo "防火墙提醒: 请确保以下端口已放行:"
  echo "  VLESS: ${PORT}/tcp"
  if [[ "$ENABLE_HY2" -eq 1 ]]; then
    echo "  HY2:   ${HY2_PORT}/udp"
  fi
  echo ""
  echo "例如 (UFW):"
  echo "  ufw allow ${PORT}/tcp"
  if [[ "$ENABLE_HY2" -eq 1 ]]; then
    echo "  ufw allow ${HY2_PORT}/udp"
  fi
}

install_hy2() {
  need_root
  command -v curl >/dev/null 2>&1 || fail "缺少 curl，请先安装: apt install -y curl"
  command -v tar  >/dev/null 2>&1 || fail "缺少 tar，请先安装: apt install -y tar"
  command -v openssl >/dev/null 2>&1 || fail "缺少 openssl，请先安装: apt install -y openssl"

  local old_domain=""
  if [[ -f "$INFO_FILE" ]]; then
    load_info
    old_domain="$HY2_DOMAIN"
    if [[ "$ENABLE_VLESS" -eq 1 && "$MODE" == "menu" && -t 0 ]]; then
      read -r -p "检测到已有 VLESS 节点，将保留其配置并单独添加/更新 HY2，继续? [y/N] " ans
      [[ "$ans" =~ ^[yY]$ ]] || { echo "已取消。"; return 0; }
    fi
    log "添加 / 更新 Hysteria2（VLESS 配置保持不变）..."
  else
    ENABLE_VLESS=0
    log "全新安装: 仅 Hysteria2（不含 VLESS）..."
  fi

  ENABLE_HY2=1
  HY2_PORT="$(ask "HY2 UDP 端口" "${HY2_PORT:-443}")"
  [[ "$HY2_PORT" =~ ^[0-9]+$ ]] && (( HY2_PORT >= 1 && HY2_PORT <= 65535 )) || fail "HY2 端口无效: $HY2_PORT"
  ask_hy2_password
  if [[ "$MODE" == "menu" && -t 0 ]]; then
    read -r -p "HY2 带域名模式? 输入域名，留空使用 IP 模式: " dom
    [[ -n "$dom" ]] && HY2_DOMAIN="$dom"
    [[ -n "$HY2_DOMAIN" ]] && [[ "$HY2_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?\.[a-zA-Z]{2,}$ ]] || fail "域名格式无效: $HY2_DOMAIN"
  fi
  if [[ "$HY2_DOMAIN" != "$old_domain" ]]; then
    rm -f "$HY2_CERT" "$HY2_KEY"
  fi

  install_singbox
  enable_bbr || true
  gen_hy2_password
  gen_hy2_cert
  write_config
  setup_service
  open_firewall_ports
  check_ports || true
  echo ""
  show_info
}

menu() {
  while true; do
    echo ""
    echo "================= sing-box 管理菜单 ================="
    echo "  1. 安装 / 重装节点 (VLESS+Reality+Vision / Hysteria2)"
    echo "  2. 单独安装 Hysteria2 (HY2)"
    echo "  3. 查看节点信息与分享链接"
    echo "  4. 重启服务"
    echo "  5. 开机自启设置"
    echo "  6. 更新 sing-box 内核"
    echo "  7. 更换端口"
    echo "  8. 更换 SNI"
    echo "  9. 查看状态与日志"
    echo "  10. 卸载 sing-box"
    echo "  11. 开启 BBR TCP 加速"
    echo "  0. 退出"
    echo "====================================================="
    read -r -p "请输入选项 [0-11]: " choice || break
    case "$choice" in
      1) install_node ;;
      2) install_hy2 ;;
      3) show_info ;;
      4) restart_service ;;
      5) autostart_toggle ;;
      6) update_singbox ;;
      7) change_port ;;
      8) change_sni ;;
      9) show_status ;;
      10) uninstall ;;
      11) enable_bbr ;;
      0) echo "再见。"; break ;;
      *) echo "无效选项: $choice" ;;
    esac
  done
}

case "$MODE" in
  install)      install_node ;;
  info)         show_info ;;
  restart)      restart_service ;;
  status)       show_status ;;
  autostart)    autostart_toggle "$AUTOSTART_ACTION" ;;
  update)       update_singbox ;;
  bbr)          enable_bbr ;;
  hy2)          install_hy2 ;;
  change-port)  change_port ;;
  change-sni)   change_sni ;;
  uninstall)    uninstall ;;
  menu)         menu ;;
esac
