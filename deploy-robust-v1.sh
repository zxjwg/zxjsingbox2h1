#!/usr/bin/env bash
#
# 改进版部署脚本（兼容性与健壮性增强）
# 说明：
#  - 保持原脚本总体逻辑（申请证书 -> 安装 sing-box -> 生成 Reality/Hy2 -> nginx 回落 -> UDP 转发）
#  - 增加了：root 检查、包管理器检测、重试机制、超时、锁文件更安全的清理、日志、非交互 apt、nginx 配置检测/备份、
#    acme.sh 与 cert 申请的回退、iptables/nftables 兼容性判断、错误 trap 与提示等
#  - 默认跳过持久化 netfilter（适配外部/云平台管理的防火墙），通过 SKIP_NETFILTER_PERSISTENT 控制
#  - 修复 acme.sh 安装时报 Unknown parameter: ----nocron 的问题：不再直接传递 --nocron 给安装脚本，改为安装后移除自动任务（如 crontab/systemd）以禁用自动升级/定时任务
#  - 改进 acme.sh webroot 流程：当尝试 webroot 模式时临时为指定域名创建并启用 nginx server block 在 80 端口指向 /var/www/html，以确保挑战文件可被验证；发布后会恢复 nginx 配置
#  - sing-box 官方安装脚本路径增加备选（尝试 main -> master），若仍不可用会提示手动从 Releases 安装
#
set -euo pipefail

LOGFILE="/var/log/singbox-deploy.log"
mkdir -p "$(dirname "$LOGFILE")"
exec > >(tee -a "$LOGFILE") 2>&1

RED='\033[0;31m' && GREEN='\033[0;32m' && BLUE='\033[0;34m' && YELLOW='\033[0;33m' && NC='\033[0m'

CONF_DIR="/etc/sing-box"
CERT_DIR="/etc/v2ray-agent/tls"
NGINX_CONF_CANDIDATES=("/etc/nginx/sites-available/default" "/etc/nginx/conf.d/default.conf" "/etc/nginx/nginx.conf")
RANDOM_PORT=$(shuf -i 10000-60000 -n 1 2>/dev/null || echo "37210")
HY2_PORT="5443"
UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || (command -v uuidgen >/dev/null 2>&1 && uuidgen) || echo "$(openssl rand -hex 8)-$(openssl rand -hex 4)-$(openssl rand -hex 4)-$(openssl rand -hex 4)-$(openssl rand -hex 12)")"
SHORT_ID="$(openssl rand -hex 8 || echo "sid$(date +%s)")"

SKIP_NETFILTER_PERSISTENT="${SKIP_NETFILTER_PERSISTENT:-true}"
RETRY_MAX=5
SLEEP_BETWEEN_RETRY=3
CURL_OPTS="--connect-timeout 10 --max-time 120 -fsSL"
PKG_MANAGER=""
PKG_INSTALL=""
SYSTEMCTL_CMD="$(command -v systemctl || true)"

trap 'echo -e "${RED}发生错误，部署中止。请查看 $LOGFILE 以获取详细日志。${NC}"; exit 1' ERR

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}"; }
err() { echo -e "${RED}[ERROR] $*${NC}"; }

retry_cmd() { local n=1; local max=${1:-$RETRY_MAX}; shift || true; while true; do if "$@"; then return 0; else if [ "$n" -ge "$max" ]; then return 1; fi; warn "命令失败，重试 ${n}/${max}： $*"; n=$((n+1)); sleep $SLEEP_BETWEEN_RETRY; fi; done }
is_root() { [ "$(id -u)" -eq 0 ]; }

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then PKG_MANAGER="apt"; PKG_INSTALL="apt-get install -y"; export DEBIAN_FRONTEND=noninteractive
  elif command -v dnf >/dev/null 2>&1; then PKG_MANAGER="dnf"; PKG_INSTALL="dnf install -y"
  elif command -v yum >/dev/null 2>&1; then PKG_MANAGER="yum"; PKG_INSTALL="yum install -y"
  else err "未检测到受支持的包管理器 (apt/dnf/yum)。请手动安装依赖后重试。"; exit 1; fi
  info "检测到包管理器：$PKG_MANAGER"
}

safe_kill_locking_processes() {
  info "尝试温和修复被锁定的包管理器状态..."
  dpkg --configure -a 2>/dev/null || true
  for lock in /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock; do
    if [ -e "$lock" ]; then lpid=$(fuser "$lock" 2>/dev/null || true); if [ -n "$lpid" ]; then warn "检测到进程占用 $lock: $lpid，尝试温和终止..."; kill "$lpid" 2>/dev/null || kill -9 "$lpid" 2>/dev/null || true; sleep 1; fi; rm -f "$lock" || true; fi
  done
  dpkg --configure -a 2>/dev/null || true
  info "锁文件处理完成。"
}

install_packages() {
  local pkgs=("$@"); detect_pkg_manager
  case "$PKG_MANAGER" in
    apt)
      retry_cmd 5 apt-get update || warn "apt-get update 失败，继续..."
      if [ "$SKIP_NETFILTER_PERSISTENT" = "true" ]; then
        local filtered=(); for p in "$@"; do [ "$p" != "iptables-persistent" ] && filtered+=("$p"); done; set -- "${filtered[@]}"
      fi
      retry_cmd 5 $PKG_INSTALL "$@" || warn "安装部分包��败，继续。"
      ;;
    dnf|yum)
      retry_cmd 5 $PKG_INSTALL "$@" || warn "安装部分包失败，继续。"
      ;;
  esac
}

choose_nginx_conf() { for p in "${NGINX_CONF_CANDIDATES[@]}"; do if [ -f "$p" ] || [ "${p##*/}" = "nginx.conf" ]; then echo "$p"; return 0; fi; done; echo "/etc/nginx/sites-available/default"; }

# 更可靠地检测端口占用：优先 lsof/ss/netstat，再 fallback 到 /dev/tcp 连接尝试
port_in_use() {
  local port=$1
  if command -v lsof >/dev/null 2>&1; then lsof -i :"$port" >/dev/null 2>&1 && return 0 || return 1
  elif command -v ss >/dev/null 2>&1; then ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE ":$port$|\.$port$" && return 0 || return 1
  elif command -v netstat >/dev/null 2>&1; then netstat -ltn 2>/dev/null | grep -qE ":$port\b|\.$port\b" && return 0 || return 1
  else
    # 尝试通过连接本地回环端口判断
    if bash -c "</dev/tcp/127.0.0.1/$port" >/dev/null 2>&1; then return 0; else return 1; fi
  fi
}

disable_acmesh_auto() { if command -v crontab >/dev/null 2>&1; then if crontab -l 2>/dev/null | grep -q "acme.sh"; then crontab -l 2>/dev/null | grep -v "acme.sh" | crontab - || true; info "已从 crontab 中移除 acme.sh 条目。"; fi; fi; if [ -d /etc/systemd/system ] && [ -n "$SYSTEMCTL_CMD" ] && systemctl list-timers --all 2>/dev/null | grep -q acme; then systemctl list-units --all | grep -i acme | awk '{print $1}' | while read -r unit; do systemctl disable --now "$unit" 2>/dev/null || true; done; info "已尝试移除可能的 systemd acme 定时任务。"; fi }

# 临时为域名创建 nginx server block（用于 webroot 验证），并在结束后恢复
create_temp_nginx_for_domain() {
  local domain=$1
  local tmp_conf="/etc/nginx/sites-available/_acme_tmp_${domain}"
  local enabled_link="/etc/nginx/sites-enabled/_acme_tmp_${domain}"
  mkdir -p /var/www/html
  cat > "$tmp_conf" <<EOF
server {
  listen 80;
  server_name ${domain};
  root /var/www/html;
  location /.well-known/acme-challenge/ { allow all; }
}
EOF
  # enable
  mkdir -p /etc/nginx/sites-enabled
  ln -sf "$tmp_conf" "$enabled_link"
  nginx -t >/dev/null 2>&1 || true
  if [ -n "$SYSTEMCTL_CMD" ]; then systemctl restart nginx >/dev/null 2>&1 || nginx -s reload >/dev/null 2>&1 || true; else nginx -s reload >/dev/null 2>&1 || true; fi
  echo "$tmp_conf|$enabled_link"
}

remove_temp_nginx() {
  local tmp_conf=$1; local enabled_link=$2
  [ -L "$enabled_link" ] && rm -f "$enabled_link" || true
  [ -f "$tmp_conf" ] && rm -f "$tmp_conf" || true
  if [ -n "$SYSTEMCTL_CMD" ]; then systemctl restart nginx >/dev/null 2>&1 || nginx -s reload >/dev/null 2>&1 || true; else nginx -s reload >/dev/null 2>&1 || true; fi
}

install_acme_sh_and_issue() {
  info "[4/5] 正在通过 acme.sh 申请证书..."
  ACME_INSTALL_TMP="/tmp/acme_install.sh"
  ACME_HOME_CANDIDATES=("/root/.acme.sh" "$HOME/.acme.sh")
  if ! retry_cmd 3 curl $CURL_OPTS -o "$ACME_INSTALL_TMP" https://get.acme.sh; then warn "下载 acme.sh 安装脚本失败，跳过自动安装/申请证书。"; return 1; fi
  bash "$ACME_INSTALL_TMP" || true
  ACME_BIN=""
  for d in "${ACME_HOME_CANDIDATES[@]}"; do [ -x "$d/acme.sh" ] && { ACME_BIN="$d/acme.sh"; ACME_HOME="$d"; break; }; done
  # 最后再尝试在 PATH 中查找
  if [ -z "$ACME_BIN" ]; then ACME_BIN="$(command -v acme.sh || true)"; fi
  if [ -z "$ACME_BIN" ]; then warn "未找到 acme.sh 安装位置，跳过证书自动��请。"; return 1; fi
  disable_acmesh_auto
  "$ACME_BIN" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true

  # 优先 standalone（仅当 80 端口空闲）
  if port_in_use 80; then
    info "检测到 80 端口被占用，standalone 模式不可用，跳过该方式。"
  else
    info "80 端口可用，尝试 standalone 模式申请（短暂监听）..."
    if retry_cmd 3 "$ACME_BIN" --issue -d "$DOMAIN" --standalone --debug 2>/dev/null; then
      "$ACME_BIN" --install-cert -d "$DOMAIN" --key-file "$CERT_DIR/server.key" --fullchain-file "$CERT_DIR/server.crt" || true
      success "证书申请成功（standalone）。"
      return 0
    else
      warn "standalone 模式申请失败，继续尝试其他模式。"
    fi
  fi

  # 尝试 nginx 插件（默认 nginx 配置可用）
  if command -v nginx >/dev/null 2>&1; then
    info "尝试使用 acme.sh 的 nginx 插件（如果可用）..."
    if retry_cmd 2 "$ACME_BIN" --issue -d "$DOMAIN" --nginx --debug 2>/dev/null; then
      "$ACME_BIN" --install-cert -d "$DOMAIN" --key-file "$CERT_DIR/server.key" --fullchain-file "$CERT_DIR/server.crt" || true
      success "证书申请成功（nginx 插件）。"
      return 0
    else
      warn "nginx 插件申请失败，继续尝试 webroot。"
    fi
  fi

  # webroot 模式（确保 webroot 被域名服务），我们临时创建一个 nginx server block 指向 /var/www/html
  mkdir -p /var/www/html
  tmp_info=""
  if command -v nginx >/dev/null 2>&1; then
    info "创建临时 nginx server block 以支持 webroot 验证..."
    tmp_info=$(create_temp_nginx_for_domain "$DOMAIN") || true
    tmp_conf=$(echo "$tmp_info" | cut -d'|' -f1)
    tmp_link=$(echo "$tmp_info" | cut -d'|' -f2)
  else
    info "未检测到 nginx，webroot 模式仅在现有 web 服务上可用。"
  fi
  if retry_cmd 3 "$ACME_BIN" --issue -d "$DOMAIN" --webroot /var/www/html --debug 2>/dev/null; then
    "$ACME_BIN" --install-cert -d "$DOMAIN" --key-file "$CERT_DIR/server.key" --fullchain-file "$CERT_DIR/server.crt" || true
    success "证书申请成功（webroot）。"
    [ -n "$tmp_info" ] && remove_temp_nginx "$tmp_conf" "$tmp_link"
    return 0
  else
    warn "webroot 模式申请失败。"
    [ -n "$tmp_info" ] && remove_temp_nginx "$tmp_conf" "$tmp_link"
  fi

  warn "所有自动申请证书的方式均已尝试但未成功。请手动将证书放到 $CERT_DIR 并重试。"
  return 1
}

# start
if ! is_root; then err "请以 root 或使用 sudo 执行此脚本。"; exit 1; fi
info "开始部署 Sing-box（改进版）。详细日志记录到：$LOGFILE"
info "[1/8] 处理可能的包管理器锁与中断状态..."
safe_kill_locking_processes
info "[2/8] 安装系统依赖（请观察输出）..."
BASE_PKGS=(curl wget lsof jq tar nginx ca-certificates iptables iproute2 openssl coreutils iptables-persistent)
if command -v uuidgen >/dev/null 2>&1; then :; else BASE_PKGS+=(uuid-runtime); fi
install_packages "${BASE_PKGS[@]}"
info "[3/8] 配置内核网络优化(BBR)"
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf 2>/dev/null; then cat >>/etc/sysctl.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl -p >/dev/null 2>&1 || true; success "已写入 sysctl 配置并尝试生效。"; else info "sysctl 中已存在 BBR 设置，跳过。"; fi

echo -e "${YELLOW}--------------------------------------------------${NC}"
read -rp "请输入解析到此服务器的域名: " DOMAIN
if [ -z "$DOMAIN" ]; then err "域名不能为空，退出。"; exit 1; fi
read -rp "请输入用于证书申请的邮箱 (可留空): " EMAIL
read -rp "是否开启 HY2 混淆(obfs)? (y/n, 默认 n): " IS_OBFS
IS_OBFS=${IS_OBFS:-"n"}
echo -e "${YELLOW}--------------------------------------------------${NC}"

info "校验域名解析（尽可能）..."
SERVER_IPV4="$(curl -4 -sS https://ifconfig.co || true)"
RESOLVED_IP="$(getent hosts "$DOMAIN" | awk '{print $1}' || true)"
if [ -n "$RESOLVED_IP" ] && [ -n "$SERVER_IPV4" ] && [ "$RESOLVED_IP" != "$SERVER_IPV4" ]; then warn "域名 $DOMAIN 解析到 $RESOLVED_IP，而当前服务器公网 IPv4 为 $SERVER_IPV4。"; else info "域名解析初步检查通过或无法确定（继续）。"; fi

mkdir -p "$CERT_DIR"
install_acme_sh_and_issue || warn "证书申请阶段未成功完成，后续 TLS 可能无法启用。"

# Install sing-box: try multiple candidate URLs
info "[6/8] 安装 sing-box 程序..."
SINGBOX_INSTALL_URLS=("https://raw.githubusercontent.com/sagernet/sing-box/main/install.sh" "https://raw.githubusercontent.com/sagernet/sing-box/master/install.sh")
TMP_INSTALL="/tmp/singbox_install.sh"
installed=false
for url in "${SINGBOX_INSTALL_URLS[@]}"; do
  info "尝试下载 sing-box 安装脚本： $url"
  if retry_cmd 3 curl $CURL_OPTS -o "$TMP_INSTALL" "$url"; then
    if bash "$TMP_INSTALL"; then installed=true; info "sing-box 安装脚本执行成功（来自 $url）。"; break; else warn "运行 install.sh 返回非零（来自 $url），尝试下一个 URL..."; fi
  else
    warn "从 $url 下载 install.sh 失败，尝试下一个 URL..."
  fi
done
if [ "$installed" != true ]; then
  warn "无法从已知路径下载 sing-box install.sh。请手动从 https://github.com/sagernet/sing-box/releases 下载并安装 sing-box。"
fi

SINGBOX_BIN="$(command -v sing-box || /usr/bin/sing-box || /usr/local/bin/sing-box || true)"
if [ -z "$SINGBOX_BIN" ] || [ ! -x "$SINGBOX_BIN" ]; then warn "未检测到 sing-box 可执行文件（$SINGBOX_BIN）。配置文件将写入 $CONF_DIR，但服务启动可能失败。"; fi

PRIV_KEY=""; PUB_KEY=""
if [ -n "$SINGBOX_BIN" ] && [ -x "$SINGBOX_BIN" ]; then info "生成 Reality 密钥对..."; RE_KEYS=$("$SINGBOX_BIN" generate reality-keypair 2>/dev/null || true); PRIV_KEY=$(echo "$RE_KEYS" | grep -i "Private key" | awk '{print $3}' || true); PUB_KEY=$(echo "$RE_KEYS" | grep -i "Public key" | awk '{print $3}' || true); if [ -z "$PRIV_KEY" ] || [ -z "$PUB_KEY" ]; then warn "未能通过 sing-box 生成 reality 密钥（输出：$RE_KEYS），将使用占位符。"; PRIV_KEY="REPLACEME_PRIVATE_KEY"; PUB_KEY="REPLACEME_PUBLIC_KEY"; fi; else warn "sing-box 未安装，跳过 reality 密钥生成。"; PRIV_KEY="REPLACEME_PRIVATE_KEY"; PUB_KEY="REPLACEME_PUBLIC_KEY"; fi

OBFS_BLOCK=""; if [[ "$IS_OBFS" =~ ^[yY]$ ]]; then OBFS_BLOCK=", \"obfs\": {\"type\": \"salamander\", \"password\": \"unserionssss66688\"}"; fi

mkdir -p "$CONF_DIR"
[ -f "$CONF_DIR/config.json" ] && cp -f "$CONF_DIR/config.json" "$CONF_DIR/config.json.bak-$(date +%s)" || true

info "写入 sing-box 配置到 $CONF_DIR/config.json"
cat > "$CONF_DIR/config.json" <<EOF
{
  "inbounds": [
    {
      "type": "vless", "tag": "vless-reality", "listen": "::", "listen_port": 443,
      "users": [{"uuid": "$UUID", "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": true, "server_name": "www.microsoft.com",
        "reality": {
          "enabled": true, "handshake": { "server": "127.0.0.1", "server_port": $RANDOM_PORT },
          "private_key": "$PRIV_KEY", "short_id": ["$SHORT_ID"]
        }
      }
    },
    {
      "type": "hysteria2", "tag": "hy2-in", "listen": "::", "listen_port": $HY2_PORT,
      "up_mbps": 120, "down_mbps": 120, "users": [{"password": "$UUID"}]${OBFS_BLOCK},
      "tls": {
        "enabled": true, "server_name": "$DOMAIN", "alpn": ["h3"],
        "certificate_path": "$CERT_DIR/server.crt", "key_path": "$CERT_DIR/server.key"
      }
    }
  ],
  "outbounds": [{"type": "direct"}]
}
EOF

NGINX_CONF="$(choose_nginx_conf)"
info "[7/8] 配置 Nginx 回落站点到 $NGINX_CONF（备份原文件）"
[ -f "$NGINX_CONF" ] && cp -f "$NGINX_CONF" "$NGINX_CONF.bak-$(date +%s)" || true
mkdir -p /var/www/html
cat > "$NGINX_CONF" <<EOF
server {
    listen 127.0.0.1:$RANDOM_PORT;
    server_name _;
    location / { root /var/www/html; index index.html; }
}
EOF
if command -v nginx >/dev/null 2>&1; then if [ -n "$SYSTEMCTL_CMD" ]; then systemctl restart nginx || warn "无法通过 systemctl 重启 nginx，请手动检查 nginx 配置后重启。"; else nginx -s reload || nginx || warn "nginx 重启失败。"; fi; fi

info "[8/8] 配置 UDP 转发（443 -> $HY2_PORT）"
IPTABLES_CMD="$(command -v iptables || true)"
IP6TABLES_CMD="$(command -v ip6tables || true)"
NFT_CMD="$(command -v nft || true)"
if [ -n "$IPTABLES_CMD" ]; then if ! $IPTABLES_CMD -t nat -C PREROUTING -p udp --dport 443 -j REDIRECT --to-ports "$HY2_PORT" 2>/dev/null; then $IPTABLES_CMD -t nat -A PREROUTING -p udp --dport 443 -j REDIRECT --to-ports "$HY2_PORT"; info "已添加 iptables IPv4 规则。"; else info "iptables IPv4 规则已存在，跳过。"; fi
elif [ -n "$NFT_CMD" ]; then if ! nft list table inet nat >/dev/null 2>&1; then nft add table ip nat 2>/dev/null || true; nft 'add chain ip nat prerouting { type nat hook prerouting priority 0 ; }' 2>/dev/null || true; fi; if ! nft list chain ip nat prerouting 2>/dev/null | grep -q "udp dport 443 redirect to :$HY2_PORT"; then nft add rule ip nat prerouting udp dport 443 redirect to :$HY2_PORT 2>/dev/null || true; info "已添加 nftables IPv4 转发规则（可能需调整以适配系统）。"; else info "nftables 规则已存在，跳过。"; fi; else warn "未检测到 iptables 或 nft 工具，无法自动添加 IPv4 转发规则，请手动配置 UDP 443 -> $HY2_PORT 的重定向。"; fi

if [ -n "$IP6TABLES_CMD" ]; then if $IP6TABLES_CMD -t nat -C PREROUTING -p udp --dport 443 -j REDIRECT --to-ports "$HY2_PORT" 2>/dev/null; then info "ip6tables IPv6 规则已存在，跳过。"; else if $IP6TABLES_CMD -t nat -A PREROUTING -p udp --dport 443 -j REDIRECT --to-ports "$HY2_PORT" 2>/dev/null; then info "已添加 ip6tables IPv6 规则。"; else warn "当前系统的 ip6tables 可能不支持 nat 表或添加规则失败（可忽略）。"; fi; fi
elif [ -n "$NFT_CMD" ]; then if ! nft list table ip6 nat >/dev/null 2>&1; then nft add table ip6 nat 2>/dev/null || true; nft 'add chain ip6 nat prerouting { type nat hook prerouting priority 0 ; }' 2>/dev/null || true; fi; if ! nft list chain ip6 nat prerouting 2>/dev/null | grep -q "udp dport 443 redirect to :$HY2_PORT"; then nft add rule ip6 nat prerouting udp dport 443 redirect to :$HY2_PORT 2>/dev/null || true; info "已尝试添加 nftables IPv6 转发规则（可能需调整以适配系统）。"; fi; fi

if [ "$SKIP_NETFILTER_PERSISTENT" = "true" ]; then warn "已配置为跳过持久化 netfilter 规则（SKIP_NETFILTER_PERSISTENT=true）。重启后规则可能丢失。"; else if command -v netfilter-persistent >/dev/null 2>&1; then netfilter-persistent save || warn "netfilter-persistent save 失败。"; elif command -v iptables-save >/dev/null 2>&1; then iptables-save > /etc/iptables/rules.v4 2>/dev/null || warn "iptables-save 写入失败。"; if command -v ip6tables-save >/dev/null 2>&1; then ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || warn "ip6tables-save 写入失败。"; fi; else warn "未找到 netfilter 持久化工具，请手动持久化规则。"; fi; fi

if [ -n "$SYSTEMCTL_CMD" ] && [ -f "/etc/systemd/system/sing-box.service" -o -f "/lib/systemd/system/sing-box.service" ] ; then systemctl enable --now sing-box || warn "尝试启动 sing-box 服务失败，请检查服务状态：systemctl status sing-box"; else if command -v sing-box >/dev/null 2>&1; then warn "sing-box 可执行文件存在但 systemd 单元未检测到，请手动创建/启动服务，或运行: sing-box run -c $CONF_DIR/config.json"; else warn "sing-box 未安装或未正确安装，无法自动启动服务。"; fi; fi

success "=================================================="
success "部署流程已完成（脚本执行结束）。请查看上方信息与日志：$LOGFILE"
echo ""; echo -e "UUID: ${BLUE}$UUID${NC}"; echo -e "Reality 公钥: ${BLUE}$PUB_KEY${NC}"; echo -e "Reality ShortID: ${BLUE}$SHORT_ID${NC}"; echo -e "HY2 本地端口: ${BLUE}$HY2_PORT (UDP 443 已尝试自动重定向)${NC}"; success "=================================================="

echo ""; echo -e "${YELLOW}提示：若证书申请失败，请确认 80/443 端口未被其他进程占用，或手动将证书放置到 $CERT_DIR 并重启 sing-box。${NC}"
