#!/usr/bin/env bash
# =================================================================
# 项目：Sing-box 全能自动化部署系统（HY2 UDP-only，改进版 - 小修改）
# 说明：在之前提交的基础上做小且可回滚的改动：
#  - 创建日志文件并设置安全权限，所有输出追加到日志（同时保留终端输出）
#  - 在添加 iptables 规则时附加注释标签，便于精确清理
#  - 在中断/错误时触发 on_exit 清理函数，移除添加的 iptables 规则
#  - 读取 Cloudflare Token 时使用静默输入（read -s）避免回显
# 其它逻辑不变，变动极小，易回滚。
# =================================================================

set -euo pipefail
IFS=$'\n\t'

# ---------------- 全局配置 ----------------
CONF_DIR="${CONF_DIR:-/etc/sing-box}"
CERT_DIR="${CERT_DIR:-/etc/v2ray-agent/tls}"
NGINX_CONF="${NGINX_CONF:-/etc/nginx/sites-available/default}"
RANDOM_PORT="${RANDOM_PORT:-$(shuf -i 10000-60000 -n 1)}"   # Reality handshake 本地端口
HY2_PORT="${HY2_PORT:-5443}"                               # HY2 实际监听端口（非 443），脚本会把 UDP:443 转发到此端口
UUID="${UUID:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)}"
LOGFILE="${LOGFILE:-/var/log/singbox-deploy.log}"
REDIRECT_TAG="${REDIRECT_TAG:-zxjsingbox-redirect}"

RED='\033[0;31m' && GREEN='\033[0;32m' && YELLOW='\033[0;33m' && NC='\033[0m'

# Ensure logfile exists and has secure permissions (minimal change)
mkdir -p "$(dirname "$LOGFILE")"
touch "$LOGFILE"
chmod 0640 "$LOGFILE"

# Redirect all stdout/stderr to logfile as well as terminal
exec > >(tee -a "$LOGFILE") 2>&1

log() { echo -e "[$(date '+%F %T')] $*"; }

# on_exit handler: remove iptables redirect added by this script
on_exit() {
  rc=$?
  if [ $rc -ne 0 ]; then
    log "${RED}非正常退出 (code=$rc)，尝试清理并退出...${NC}"
  else
    log "退出，开始清理..."
  fi
  # Attempt to remove rules that contain our redirect tag
  if command -v iptables >/dev/null 2>&1; then
    iptables -t nat -S PREROUTING 2>/dev/null | grep -F -- "$REDIRECT_TAG" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
      iptables -t nat -S PREROUTING 2>/dev/null | grep -F -- "$REDIRECT_TAG" | while read -r line; do
        # convert -A to -D for deletion
        delline="${line/-A/-D}"
        # run delete command
        iptables -t nat $delline 2>/dev/null || true
      done
      log "已移除带标记的 iptables 规则 ($REDIRECT_TAG)"
    fi
  fi
  exit $rc
}

# trap INT, TERM and ERR to ensure cleanup on interruption or error
trap on_exit INT TERM ERR

# ---------------- 基础前置检查 ----------------
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}请以 root 或 sudo 运行此脚本${NC}"
  exit 1
fi

ensure_deps() {
  if ! command -v apt >/dev/null 2>&1; then
    log "${RED}仅支持 Debian/Ubuntu 系列自动安装。请手动安装依赖后重试：curl wget lsof jq tar shuf nginx iptables${NC}"
    exit 1
  fi
  log "apt 更新并安装常用依赖..."
  apt update -y
  apt install -y curl wget lsof jq tar shuf nginx ca-certificates iptables >/dev/null
}

backup_env() {
  log "备份 nginx 配置与已有 sing-box 配置（保守模式）"
  if [ -f "$NGINX_CONF" ] && [ ! -f "${NGINX_CONF}.orig" ]; then
    cp -a "$NGINX_CONF" "${NGINX_CONF}.orig"
    log "备份 $NGINX_CONF -> ${NGINX_CONF}.orig"
  fi
  if [ -d "$CONF_DIR" ] && [ ! -d "${CONF_DIR}.orig" ]; then
    cp -a "$CONF_DIR" "${CONF_DIR}.orig" || true
    log "备份 $CONF_DIR -> ${CONF_DIR}.orig"
  fi
}

# ---------------- acme.sh 与证书 ----------------
install_acme_sh_if_needed() {
  if [ -x "/root/.acme.sh/acme.sh" ] || [ -x "${HOME}/.acme.sh/acme.sh" ]; then
    return 0
  fi
  log "安装 acme.sh..."
  curl -sSfL https://get.acme.sh | sh -s -- --nocron || { log "${RED}acme.sh 安装失败${NC}"; exit 1; }
}

issue_certificate() {
  # mode: "http" 或 "dns"
  local domain="$1" email="$2" mode="$3"
  install_acme_sh_if_needed
  ACME_SH="/root/.acme.sh/acme.sh"
  [ ! -x "$ACME_SH" ] && ACME_SH="${HOME}/.acme.sh/acme.sh"
  if [ ! -x "$ACME_SH" ]; then log "${RED}找不到 acme.sh${NC}"; exit 1; fi

  mkdir -p "$CERT_DIR"
  "$ACME_SH" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true

  if [ "$mode" = "dns" ]; then
    # 支持 Cloudflare (dns_cf)。需提供 CF_Token（推荐）
    if [ -z "${CF_TOKEN:-}" ]; then
      log "使用 DNS 模式申请证书（Cloudflare）。请提供 Cloudflare API Token（拥有 Zone:Edit 权限）"
      # read silently to avoid echoing token
      read -rs -p "请输入 Cloudflare API Token（粘贴后回车）： " CF_TOKEN_INPUT
      echo
      CF_TOKEN="${CF_TOKEN_INPUT:-$CF_TOKEN}"
    fi
    if [ -z "${CF_TOKEN:-}" ]; then
      log "${RED}未提供 Cloudflare Token，无法使用 dns_cf 模式${NC}"
      exit 1
    fi
    export CF_Token="$CF_TOKEN"
    log "使用 acme.sh dns_cf 模式为 $domain 申请证书（Cloudflare）"
    "$ACME_SH" --issue -d "$domain" --dns dns_cf || { log "${RED}dns_cf 申请失败${NC}"; exit 1; }
  else
    # http 模式：若 80 被占用且 nginx 可用，使用 --nginx 插件；否则 standalone
    if lsof -i :80 >/dev/null 2>&1; then
      if command -v nginx >/dev/null 2>&1; then
        log "检测到端口 80 被占用，尝试使用 acme.sh --nginx 申请证书"
        "$ACME_SH" --issue -d "$domain" --nginx || { log "${RED}--nginx 申请失败，请检查 nginx 配置${NC}"; exit 1; }
      else
        log "${RED}80 被占用且未检测到 nginx，请确保 80 可用或改用 DNS 方式申请证书${NC}"
        exit 1
      fi
    else
      log "80 空闲，使用 standalone 模式申请证书"
      "$ACME_SH" --issue -d "$domain" --standalone || { log "${RED}standalone 申请失败${NC}"; exit 1; }
    fi
  fi

  # 安装证书到 CERT_DIR
  "$ACME_SH" --install-cert -d "$domain" \
    --key-file "$CERT_DIR/server.key" \
    --fullchain-file "$CERT_DIR/server.crt" || { log "${RED}证书写入失败${NC}"; exit 1; }

  chmod 600 "$CERT_DIR/server.key" || true
  chmod 644 "$CERT_DIR/server.crt" || true
  log "证书已写入 $CERT_DIR"
}

# ---------------- nginx 配置（回落 / 前置） ----------------
configure_nginx() {
  local mode="$1" # 1 回落(local listen), 2 CDN 前置
  mkdir -p /var/www/html
  if [ "$mode" = "1" ]; then
    cat > "$NGINX_CONF" <<EOF
server {
    listen 127.0.0.1:${RANDOM_PORT};
    server_name _;
    location / { root /var/www/html; index index.html; }
}
EOF
  else
    cat > "$NGINX_CONF" <<'EOF'
# CDN 前置占位配置，请按需替换
server {
    listen 80 default_server;
    server_name _;
    location / { return 404; }
}
EOF
  fi

  if nginx -t >/dev/null 2>&1; then
    systemctl restart nginx
    log "nginx 已应用并重启"
  else
    log "${RED}nginx 配置测试失败，请检查 $NGINX_CONF${NC}"
    exit 1
  fi
}

# ---------------- sing-box 部署 ----------------
gen_password() { head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 20 || echo "obfs$(date +%s)"; }

# SINGBOX_BIN detection
SINGBOX_BIN="$(command -v sing-box || echo /usr/bin/sing-box)"

setup_udp443_redirect() {
  # 把 IPv4 UDP 443 转发/重定向到本机 HY2_PORT
  if ! command -v iptables >/dev/null 2>&1; then
    log "${YELLOW}警告：iptables 未找到，无法添加 UDP 443 重定向规则。请手动配置或安装 iptables${NC}"
    return 0
  fi
  log "配置 iptables：将 UDP 443 重定向到本机 UDP ${HY2_PORT}（带标记: $REDIRECT_TAG）"
  # 先尝试删除旧规则（若存在），防止重复添加（忽略错误）
  iptables -t nat -D PREROUTING -p udp --dport 443 -j REDIRECT --to-ports "${HY2_PORT}" -m comment --comment "$REDIRECT_TAG" 2>/dev/null || true
  iptables -t nat -A PREROUTING -p udp --dport 443 -j REDIRECT --to-ports "${HY2_PORT}" -m comment --comment "$REDIRECT_TAG"
  log "iptables 规则已添加（IPv4 UDP 443 -> ${HY2_PORT}）"
  log "注意：iptables 规则不会自动持久化，重启后会失效。可安装 iptables-persistent 或将规则写入启动脚本以持久化。"
}

remove_udp443_redirect() {
  # Remove rules that contain our redirect tag
  if ! command -v iptables >/dev/null 2>&1; then
    return 0
  fi
  iptables -t nat -S PREROUTING 2>/dev/null | grep -F -- "$REDIRECT_TAG" >/dev/null 2>&1 || return 0
  iptables -t nat -S PREROUTING 2>/dev/null | grep -F -- "$REDIRECT_TAG" | while read -r line; do
    delline="${line/-A/-D}"
    iptables -t nat $delline 2>/dev/null || true
  done
  log "已尝试移除带标记的 iptables 规则 ($REDIRECT_TAG)"
}

deploy_singbox() {
  local domain="$1"
  local reality_sni="$2"
  local enable_obfs="$3"

  log "安装 sing-box（官方安装脚本）"
  curl -fsSL https://raw.githubusercontent.com/sagernet/sing-box/main/install.sh | bash -s -- || { log "${RED}sing-box 安装失败${NC}"; exit 1; }

  # 生成 Reality 密钥对（使用检测到的二进制）
  if [ -x "$SINGBOX_BIN" ]; then
    RE_KEYS=$("$SINGBOX_BIN" generate reality-keypair 2>/dev/null || true)
  else
    RE_KEYS=$(/usr/bin/sing-box generate reality-keypair 2>/dev/null || true)
  fi
  PUB_KEY=$(echo "$RE_KEYS" | sed -n 's/^[[:space:]]*Public key[: ]*//Ip' | tr -d '\r\n' || true)
  PRIV_KEY=$(echo "$RE_KEYS" | sed -n 's/^[[:space:]]*Private key[: ]*//Ip' | tr -d '\r\n' || true)
  if [ -z "$PUB_KEY" ] || [ -z "$PRIV_KEY" ]; then
    log "${RED}生成 Reality 密钥失败，输出如下：${NC}"
    echo "$RE_KEYS"
    exit 1
  fi

  mkdir -p "$CONF_DIR"
  local OBFS_BLOCK=""
  if [[ "$enable_obfs" =~ ^[yY]$ ]]; then
    OBFS_PWD="$(gen_password)"
    OBFS_BLOCK=", \"obfs\": {\"type\": \"salamander\", \"password\": \"${OBFS_PWD}\"}"
    log "HY2 混淆已启用（随机密码已生成）"
  else
    log "HY2 混淆保持关闭"
  fi

  # HY2 监听 HY2_PORT（非 443），然后将 IPv4 UDP 443 转发到 HY2_PORT，从而实现 UDP-only 的 443 行为
  cat > "$CONF_DIR/config.json" <<EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::",
      "listen_port": 443,
      "users": [{"uuid": "$UUID", "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": true,
        "server_name": "$reality_sni",
        "reality": {
          "enabled": true,
          "handshake": { "server": "127.0.0.1", "server_port": $RANDOM_PORT },
          "private_key": "$PRIV_KEY",
          "short_id": ["6ba85179e30d4fc2"]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${HY2_PORT},
      "up_mbps": 120,
      "down_mbps": 120,
      "users": [{"password": "$UUID"}]${OBFS_BLOCK},
      "tls": {
        "enabled": true,
        "server_name": "$domain",
        "alpn": ["h3"],
        "certificate_path": "$CERT_DIR/server.crt",
        "key_path": "$CERT_DIR/server.key"
      }
    }
  ],
  "outbounds": [{"type": "direct"}]
}
EOF

  # 使用检测到的 sing-box 二进制进行校验并启动
  if [ -x "$SINGBOX_BIN" ]; then
    "$SINGBOX_BIN" check -c "$CONF_DIR/config.json" || { log "${RED}sing-box 配置校验失败${NC}"; exit 1; }
  else
    /usr/bin/sing-box check -c "$CONF_DIR/config.json" || { log "${RED}sing-box 配置校验失败${NC}"; exit 1; }
  fi

  # 添加 UDP 443 -> HY2_PORT 的 iptables 规则（IPv4）
  setup_udp443_redirect

  systemctl enable --now sing-box
  log "sing-box 已启用并启动（HY2: UDP-only via redirect -> ${HY2_PORT}）"
}

# ---------------- 回滚（保守） ----------------
rollback() {
  log "一键回滚（保守）：停止 sing-box、移除 iptables 规则并恢复 nginx 配置"
  systemctl stop sing-box || true
  remove_udp443_redirect
  if [ -f "${NGINX_CONF}.orig" ]; then
    mv -f "${NGINX_CONF}.orig" "${NGINX_CONF}"
    systemctl restart nginx || true
    log "恢复 nginx 原配置"
  fi
  log "回滚完成（证书与配置备份保留以供人工审查）"
}

# ---------------- 主流程交互 ----------------
clear
echo -e "${GREEN}Sing-box 自动化部署（HY2 UDP-only 版，改进 - 小修改）${NC}"
echo "运行日志：$LOGFILE"
echo

ensure_deps
backup_env

echo "请选择部署模式："
echo " 1) 回落模式（Nginx -> Reality handshake）"
echo " 2) CDN 前置（Nginx 前置，按需自定义）"
echo " 3) 只做证书/网关（不输出节点）"
read -rp "请输入 1/2/3 (默认 1): " MODE
MODE="${MODE:-1}"

read -rp "请输入主域名 (用于 HY2 TLS)： " DOMAIN
if [ -z "$DOMAIN" ]; then
  echo -e "${RED}必须输入主域名（用于 HY2 TLS certificate）${NC}"
  exit 1
fi

read -rp "请输入邮箱（用于 Let's Encrypt）： " EMAIL

DEFAULT_REALITY_SNI="www.oracle.com"
echo
echo "Reality (VLESS Reality) 中用于 SNI/server_name（可与主域不同）。"
echo "按回车使用默认：${DEFAULT_REALITY_SNI}（建议使用自己的域名或子域）"
read -rp "请输入 Reality server_name (回车使用默认): " REALITY_SNI
REALITY_SNI="${REALITY_SNI:-$DEFAULT_REALITY_SNI}"

echo
echo "证书申请方式："
echo " 1) HTTP (standalone / nginx 插件，可能会占用 80/443 临时端口)"
echo " 2) DNS (Cloudflare - 推荐，当使用 CDN / Cloudflare 时无需占用 80/443)"
read -rp "请选择 1 或 2 (默认 2): " CERT_MODE
CERT_MODE="${CERT_MODE:-2}"

if [ "$CERT_MODE" = "2" ]; then
  if [ -z "${CF_TOKEN:-}" ]; then
    echo
    echo "使用 Cloudflare DNS 方式申请证书需要 API Token（拥有 Zone:Edit 权限）。"
    # read token silently to avoid echoing
    read -rs -p "请输入 Cloudflare API Token（粘贴后回��，或回车跳过并用 HTTP 模式）: " CF_TOKEN_INPUT
    echo
    if [ -n "$CF_TOKEN_INPUT" ]; then
      export CF_Token="$CF_TOKEN_INPUT"
      CF_TOKEN="$CF_TOKEN_INPUT"
    else
      echo "未提供 Cloudflare Token，改回 HTTP 模式。"
      CERT_MODE=1
    fi
  else
    export CF_Token="$CF_TOKEN"
  fi
fi

read -rp "是否启用 HY2 混淆 obfs? (y/N，默认 N): " ENABLE_OBFS
ENABLE_OBFS="${ENABLE_OBFS:-n}"

echo
echo "HY2 将监听本机端口: ${HY2_PORT} (本机)，并将外部 IPv4 UDP 443 重定向到该端口。"
echo "注意：若希望 HY2 直接监听 UDP 443（无需转发），请确保内核/应用层支持且端口未被占用。"
read -rp "确认并开始部署？输入 y 开始（其他键退出）: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[yY]$ ]]; then
  log "用户取消部署"
  exit 0
fi

# 执行证书申请
if [ "$CERT_MODE" = "2" ]; then
  issue_certificate "$DOMAIN" "$EMAIL" "dns"
else
  issue_certificate "$DOMAIN" "$EMAIL" "http"
fi

# nginx 配置
if [ "$MODE" = "1" ]; then
  configure_nginx "1"
else
  configure_nginx "2"
fi

# 部署 sing-box（HY2 将监听 HY2_PORT）
deploy_singbox "$DOMAIN" "$REALITY_SNI" "$ENABLE_OBFS"

# 输出关键信息
echo
log "部署完成，重要信息如下："
echo -e "${GREEN}======================================${NC}"
echo -e "UUID: $UUID"
echo -e "Reality 公钥: ${PUB_KEY:-<未解析>}"
echo -e "Reality server_name (SNI): $REALITY_SNI"
echo -e "HY2 TLS server_name: $DOMAIN"
echo -e "HY2 本地监听端口: ${HY2_PORT} (UDP only via iptables redirect from UDP 443)"
echo -e "配置文件: $CONF_DIR/config.json"
echo -e "证书路径: $CERT_DIR"
echo -e "日志: $LOGFILE"
echo -e "======================================${NC}"
