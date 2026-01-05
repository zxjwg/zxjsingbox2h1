#!/usr/bin/env bash
set -euo pipefail

# ---------------- 1. 全局配置 ----------------
CONF_DIR="/etc/sing-box"
CERT_DIR="/etc/v2ray-agent/tls"
NGINX_CONF="/etc/nginx/sites-available/default"
# 自动生成随机端口与 ID
RANDOM_PORT=$(shuf -i 10000-60000 -n 1 2>/dev/null || echo "37210")
HY2_PORT="5443"
UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "550e8400-e29b-41d4-a716-446655440000")
SHORT_ID=$(openssl rand -hex 8 2>/dev/null || echo "6ba85179")
LOGFILE="/var/log/singbox-deploy.log"

RED='\033[0;31m' && GREEN='\033[0;32m' && BLUE='\033[0;34m' && NC='\033[0m'
log() { echo -e "[$(date '+%F %T')] $*" | tee -a "$LOGFILE"; }

# ---------------- 2. 基础依赖与 Nginx 自动安装 ----------------
ensure_deps() {
    log "正在检查并安装必要依赖 (curl, jq, nginx, coreutils...)"
    apt update -y
    # 修复：移除 shuf，改为安装 coreutils
    apt install -y curl wget lsof jq tar nginx ca-certificates iptables uuid-runtime openssl iptables-persistent coreutils -y >/dev/null
    
    if ! systemctl is-active --quiet nginx; then
        log "${BLUE}未检测到 Nginx 运行，正在启动并设置自启...${NC}"
        systemctl enable --now nginx
    fi
}

backup_env() {
    log "正在执行环境备份..."
    if [ -f "$NGINX_CONF" ] && [ ! -f "${NGINX_CONF}.orig" ]; then
        cp -a "$NGINX_CONF" "${NGINX_CONF}.orig"
        log "已备份原始 Nginx 配置：${NGINX_CONF}.orig"
    fi
}

# ---------------- 3. 证书管理 (HTTP/DNS) ----------------
issue_certificate() {
    local domain="$1" email="$2" mode="$3"
    log "正在通过 acme.sh 申请证书..."
    curl -sSfL https://get.acme.sh | sh -s -- --nocron || true
    local ACME_SH="/root/.acme.sh/acme.sh"
    
    mkdir -p "$CERT_DIR"
    "$ACME_SH" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true

    if [ "$mode" = "dns" ]; then
        export CF_Token="${CF_TOKEN:-}"
        "$ACME_SH" --issue -d "$domain" --dns dns_cf || { log "${RED}DNS 申请失败${NC}"; exit 1; }
    else
        # 自动识别是否通过 Nginx 插件申请
        if lsof -i :80 | grep -q nginx; then
            "$ACME_SH" --issue -d "$domain" --nginx || { log "${RED}Nginx 模式申请失败${NC}"; exit 1; }
        else
            "$ACME_SH" --issue -d "$domain" --standalone || { log "${RED}Standalone 模式申请失败${NC}"; exit 1; }
        fi
    fi
    "$ACME_SH" --install-cert -d "$domain" --key-file "$CERT_DIR/server.key" --fullchain-file "$CERT_DIR/server.crt"
}

# ---------------- 4. 端口转发配置 (IPv4 & IPv6) ----------------
setup_redirect() {
    log "配置 UDP 443 重定向到 ${HY2_PORT} (IPv4 & IPv6)..."
    # IPv4
    iptables -t nat -A PREROUTING -p udp --dport 443 -j REDIRECT --to-ports "${HY2_PORT}"
    # IPv6 兼容处理
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -t nat -A PREROUTING -p udp --dport 443 -j REDIRECT --to-ports "${HY2_PORT}" 2>/dev/null || true
    fi
    # 持久化规则
    netfilter-persistent save
}

# ---------------- 5. Sing-box 核心部署 ----------------
deploy_singbox() {
    local domain="$1" sni="$2" obfs="$3"
    log "下载并安装 Sing-box 官方最新内核..."
    curl -fsSL https://raw.githubusercontent.com/sagernet/sing-box/main/install.sh | bash -s --

    RE_KEYS=$(/usr/bin/sing-box generate reality-keypair)
    PRIV_KEY=$(echo "$RE_KEYS" | grep "Private key" | awk '{print $3}')
    PUB_KEY=$(echo "$RE_KEYS" | grep "Public key" | awk '{print $3}')

    HY2_OBFS=""
    if [[ "$obfs" =~ ^[yY]$ ]]; then
        HY2_OBFS=", \"obfs\": {\"type\": \"salamander\", \"password\": \"unserionssss66688\"}"
    fi

    # 写入双协议配置
    cat > "$CONF_DIR/config.json" <<EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::", "listen_port": 443,
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
    echo -e "${GREEN}Reality 公钥: $PUB_KEY${NC}"
}

# ---------------- 6. 主程序入口 ----------------
clear
echo -e "${GREEN}Sing-box 模块化部署系统 (支持自动安装 Nginx)${NC}"
ensure_deps
backup_env

# 开启 BBR 加速
log "正在开启 BBR 加速..."
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p > /dev/null

echo "1) 一键安装"
echo "2) 卸载回滚"
read -rp "请选择: " OP
if [ "$OP" == "2" ]; then
    log "正在回滚环境..."
    systemctl stop sing-box || true
    iptables -t nat -F && netfilter-persistent save
    [ -f "${NGINX_CONF}.orig" ] && mv "${NGINX_CONF}.orig" "$NGINX_CONF" && systemctl restart nginx
    log "环境已恢复。"; exit 0
fi

read -rp "输入域名: " DOMAIN
read -rp "输入邮箱: " EMAIL
read -rp "是否开启 HY2 混淆? (y/N): " IS_OBFS

issue_certificate "$DOMAIN" "$EMAIL" "http"

# 配置 Nginx 回落站点
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
echo -e "UUID: $UUID\nShortID: $SHORT_ID\nHY2 本地端口: $HY2_PORT"
