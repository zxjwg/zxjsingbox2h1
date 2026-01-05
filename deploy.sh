#!/usr/bin/env bash
# 项目：Sing-box 自动化部署（极致性能与安全版）
# 更新：支持 IPv6 转发、随机 ShortID、HTTP 优先证书申请、防火墙持久化

set -euo pipefail
IFS=$'\n\t'

# ---------------- 1. 全局配置 ----------------
CONF_DIR="/etc/sing-box"
CERT_DIR="/etc/v2ray-agent/tls"
NGINX_CONF="/etc/nginx/sites-available/default"
RANDOM_PORT=$(shuf -i 10000-60000 -n 1)
HY2_PORT="5443"
UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "550e8400-e29b-41d4-a716-446655440000")
SHORT_ID=$(openssl rand -hex 8) # 增加随机 Short ID 提升安全性
LOGFILE="/var/log/singbox-deploy.log"

RED='\033[0;31m' && GREEN='\033[0;32m' && BLUE='\033[0;34m' && NC='\033[0m'
log() { echo -e "[$(date '+%F %T')] $*" | tee -a "$LOGFILE"; }

# ---------------- 2. 基础环境准备 ----------------
ensure_deps() {
    log "安装必要依赖：curl, wget, jq, nginx, iptables, uuid-runtime, openssl..."
    apt update -y && apt install -y curl wget lsof jq tar shuf nginx ca-certificates iptables uuid-runtime openssl iptables-persistent -y >/dev/null
}

backup_env() {
    # 仅在第一次运行时备份，防止被脚本产生的配置覆盖
    if [ -f "$NGINX_CONF" ] && [ ! -f "${NGINX_CONF}.orig" ]; then
        cp -a "$NGINX_CONF" "${NGINX_CONF}.orig"
        log "已备份原始 Nginx 配置。"
    fi
}

# ---------------- 3. 证书申请（HTTP 优先） ----------------
issue_certificate() {
    local domain="$1" email="$2" mode="$3"
    log "开始申请证书 (模式: $mode)..."
    curl -sSfL https://get.acme.sh | sh -s -- --nocron || true
    local ACME_SH="/root/.acme.sh/acme.sh"
    
    mkdir -p "$CERT_DIR"
    "$ACME_SH" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true

    if [ "$mode" = "dns" ]; then
        # DNS 模式 (Cloudflare)
        export CF_Token="${CF_TOKEN:-}"
        "$ACME_SH" --issue -d "$domain" --dns dns_cf || { log "${RED}DNS 申请失败${NC}"; exit 1; }
    else
        # HTTP 模式 (Standalone 或 Nginx)
        if lsof -i :80 >/dev/null 2>&1; then
            "$ACME_SH" --issue -d "$domain" --nginx || { log "${RED}Nginx 插件申请失败${NC}"; exit 1; }
        else
            "$ACME_SH" --issue -d "$domain" --standalone || { log "${RED}Standalone 申请失败${NC}"; exit 1; }
        fi
    fi

    "$ACME_SH" --install-cert -d "$domain" --key-file "$CERT_DIR/server.key" --fullchain-file "$CERT_DIR/server.crt"
}

# ---------------- 4. 端口重定向与持久化 ----------------
setup_redirect() {
    log "配置 UDP 443 重定向到 ${HY2_PORT} (支持 IPv4 & IPv6)..."
    # IPv4 重定向
    iptables -t nat -A PREROUTING -p udp --dport 443 -j REDIRECT --to-ports "${HY2_PORT}"
    # IPv6 重定向
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -t nat -A PREROUTING -p udp --dport 443 -j REDIRECT --to-ports "${HY2_PORT}" 2>/dev/null || true
    fi
    # 持久化保存
    netfilter-persistent save
}

# ---------------- 5. 核心部署逻辑 ----------------
deploy_singbox() {
    local domain="$1" sni="$2" obfs="$3"
    log "安装 Sing-box 官方内核..."
    curl -fsSL https://raw.githubusercontent.com/sagernet/sing-box/main/install.sh | bash -s --

    RE_KEYS=$(/usr/bin/sing-box generate reality-keypair)
    PRIV_KEY=$(echo "$RE_KEYS" | grep "Private key" | awk '{print $3}')

    HY2_OBFS=""
    if [[ "$obfs" =~ ^[yY]$ ]]; then
        HY2_OBFS=", \"obfs\": {\"type\": \"salamander\", \"password\": \"unserionssss66688\"}"
    fi

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
        "enabled": true, "server_name": "$sni",
        "reality": {
          "enabled": true,
          "handshake": { "server": "127.0.0.1", "server_port": $RANDOM_PORT },
          "private_key": "$PRIV_KEY", "short_id": ["$SHORT_ID"]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::", "listen_port": ${HY2_PORT},
      "up_mbps": 120, "down_mbps": 120,
      "users": [{"password": "$UUID"}]${HY2_OBFS},
      "tls": {
        "enabled": true, "server_name": "$domain", "alpn": ["h3"],
        "certificate_path": "$CERT_DIR/server.crt", "key_path": "$CERT_DIR/server.key"
      }
    }
  ],
  "outbounds": [{"type": "direct"}]
}
EOF
    setup_redirect
    systemctl enable --now sing-box
}

# ---------------- 主程序 ----------------
clear
echo -e "${GREEN}Sing-box 模块化部署（生产环境优化版）${NC}"
ensure_deps && backup_env

# 模式选择 (1: 回落, 2: 卸载回滚)
echo "1) 一键安装 (HTTP 证书优先)"
echo "2) 一键回滚 (还原环境)"
read -rp "请选择: " MAIN_CHOICE
if [ "$MAIN_CHOICE" == "2" ]; then
    log "正在回退环境..."
    systemctl stop sing-box || true
    [ -f "${NGINX_CONF}.orig" ] && mv "${NGINX_CONF}.orig" "$NGINX_CONF" && systemctl restart nginx
    log "环境已恢复。"; exit 0
fi

read -rp "输入主域名: " DOMAIN
read -rp "输入邮箱: " EMAIL
read -rp "是否使用 DNS 模式申请证书? (y/N, 默认 N): " IS_DNS
read -rp "是否开启 HY2 混淆? (y/N, 默认 N): " IS_OBFS

if [[ "$IS_DNS" =~ ^[yY]$ ]]; then
    read -rp "输入 Cloudflare API Token: " CF_TOKEN
    export CF_Token="$CF_TOKEN"
    issue_certificate "$DOMAIN" "$EMAIL" "dns"
else
    issue_certificate "$DOMAIN" "$EMAIL" "http"
fi

# 写入 Nginx 本地回落配置
cat > "$NGINX_CONF" <<EOF
server {
    listen 127.0.0.1:$RANDOM_PORT;
    server_name _;
    location / { root /var/www/html; index index.html; }
}
EOF
systemctl restart nginx

deploy_singbox "$DOMAIN" "www.microsoft.com" "$IS_OBFS"

log "${GREEN}部署完成！${NC}"
echo -e "UUID: $UUID\nReality ShortID: $SHORT_ID\nHY2 本地端口: $HY2_PORT (UDP 443 已自动重定向)"
