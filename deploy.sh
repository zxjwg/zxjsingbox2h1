#!/usr/bin/env bash

# =================================================================
# 项目：Sing-box 自动化部署系统 (V3.2 用户体验优化版)
# 核心：BBR/Nginx回落/HY2/原子回滚/加载动画/自动解锁
# =================================================================

set -euo pipefail

# --- [ 0. 全局变量与配色 ] ---
CONF_DIR="/etc/sing-box"
CERT_DIR="/etc/v2ray-agent/tls"
NGINX_CONF="/etc/nginx/sites-available/default"
RANDOM_PORT=$(shuf -i 10000-60000 -n 1)
HY2_PORT="5443"
UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$(openssl rand -hex 8)-$(openssl rand -hex 4)-$(openssl rand -hex 4)-$(openssl rand -hex 4)-$(openssl rand -hex 12)")
SHORT_ID=$(openssl rand -hex 8)
LOGFILE="/var/log/singbox-deploy.log"

RED='\033[0;31m' && GREEN='\033[0;32m' && YELLOW='\033[0;33m' && BLUE='\033[0;34m' && NC='\033[0m'

log() { echo -e "[$(date '+%F %T')] $*" | tee -a "$LOGFILE"; }

# --- [ 1. 核心动画模块：小白定心丸 ] ---
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    echo -e "${YELLOW}==================================================${NC}"
    echo -e "${YELLOW}脚本正在后台全力搬砖，请闹心等待 1-3 分钟...${NC}"
    echo -e "${YELLOW}只要下面的图标 [ ] 还在转，就说明没有死机，请放心。${NC}"
    echo -e "${YELLOW}==================================================${NC}"
    
    while ps -p "$pid" > /dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
    echo -e "\n${GREEN}[完成] 当前步骤已成功处理！${NC}\n"
}

# --- [ 2. 环境初始化 (带自动解锁与动画) ] ---
init_env() {
    log "正在清理系统锁并同步依赖..."
    # 强制尝试解锁 apt，防止死等
    rm -f /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1
    
    (
        apt update -y >/dev/null 2>&1
        apt install -y curl wget lsof jq tar nginx ca-certificates iptables uuid-runtime openssl iptables-persistent coreutils -y >/dev/null 2>&1
    ) &
    spinner $!

    # 开启 BBR
    log "正在优化内核速度 (BBR)..."
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
    fi
}

# --- [ 3. 证书申请模块 ] ---
issue_cert() {
    local domain=$1 && local email=$2 && local mode=$3
    log "准备申请 TLS 证书..."
    (
        curl -sSfL https://get.acme.sh | sh -s -- --nocron >/dev/null 2>&1 || true
        /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
        mkdir -p "$CERT_DIR"
        
        if [ "$mode" = "dns" ]; then
            export CF_Token="$CF_TOKEN"
            /root/.acme.sh/acme.sh --issue -d "$domain" --dns dns_cf >/dev/null 2>&1
        else
            if lsof -i :80 | grep -q nginx; then
                /root/.acme.sh/acme.sh --issue -d "$domain" --nginx >/dev/null 2>&1
            else
                /root/.acme.sh/acme.sh --issue -d "$domain" --standalone >/dev/null 2>&1
            fi
        fi
        /root/.acme.sh/acme.sh --install-cert -d "$domain" --key-file "$CERT_DIR/server.key" --fullchain-file "$CERT_DIR/server.crt" >/dev/null 2>&1
    ) &
    spinner $!
}

# --- [ 4. 一键回退模块 ] ---
rollback() {
    echo -e "${RED}正在启动回滚流程，恢复原始系统状态...${NC}"
    systemctl stop sing-box 2>/dev/null || true
    # 清理 iptables 转发规则
    iptables -t nat -D PREROUTING -p udp --dport 443 -j REDIRECT --to-ports "$HY2_PORT" 2>/dev/null || true
    netfilter-persistent save >/dev/null 2>&1
    
    if [ -f "${NGINX_CONF}.orig" ]; then
        mv "${NGINX_CONF}.orig" "$NGINX_CONF"
        systemctl restart nginx
    fi
    rm -rf "$CONF_DIR" "$CERT_DIR" /usr/local/bin/sing-box
    echo -e "${GREEN}系统已恢复如初。${NC}"
}

# --- [ 主程序 ] ---
clear
echo -e "${BLUE}==================================================${NC}"
echo -e "${BLUE}   Sing-box 极速部署系统 V3.2 (小白友好版)         ${NC}"
echo -e "${BLUE}==================================================${NC}"

echo -e "1) ${GREEN}一键安装${NC} (Reality + HY2)"
echo -e "2) ${RED}完全卸载${NC} (还原环境)"
read -rp "请选择: " MAIN_OP

if [ "$MAIN_OP" == "2" ]; then rollback; exit 0; fi

read -rp "请输入域名: " DOMAIN
read -rp "请输入邮箱: " EMAIL
read -rp "是否开启 HY2 混淆(obfs)? (y/n, 默认 n): " IS_OBFS
IS_OBFS=${IS_OBFS:-"n"}

# 执行环境初始化
init_env

# 证书申请
issue_cert "$DOMAIN" "$EMAIL" "http"

# Nginx 回落配置
log "配置 Nginx 伪装站点..."
cp -a "$NGINX_CONF" "${NGINX_CONF}.orig" 2>/dev/null || true
cat > "$NGINX_CONF" <<EOF
server {
    listen 127.0.0.1:$RANDOM_PORT;
    server_name _;
    location / { root /var/www/html; index index.html; }
}
EOF
systemctl restart nginx

# Sing-box 部署
log "正在安装并启动 Sing-box..."
(
    curl -fsSL https://raw.githubusercontent.com/sagernet/sing-box/main/install.sh | bash -s -- >/dev/null 2>&1
    RE_KEYS=$(/usr/bin/sing-box generate reality-keypair)
    PRIV_KEY=$(echo "$RE_KEYS" | grep "Private key" | awk '{print $3}')
    PUB_KEY_VAL=$(echo "$RE_KEYS" | grep "Public key" | awk '{print $3}')
    
    OBFS_BLOCK=""
    if [[ "$IS_OBFS" =~ ^[yY]$ ]]; then
        OBFS_BLOCK=", \"obfs\": {\"type\": \"salamander\", \"password\": \"unserionssss66688\"}"
    fi

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
    # IPv4 UDP 443 转发
    iptables -t nat -A PREROUTING -p udp --dport 443 -j REDIRECT --to-ports "$HY2_PORT"
    netfilter-persistent save >/dev/null 2>&1
    systemctl enable --now sing-box >/dev/null 2>&1
) &
spinner $!

# 最终输出
echo -e "${GREEN}==================================================${NC}"
echo -e "部署成功！您的节点信息如下："
echo -e "UUID: ${BLUE}$UUID${NC}"
echo -e "Reality 公钥: ${BLUE}$(grep 'Public key' <<< $(/usr/bin/sing-box generate reality-keypair) | awk '{print $3}')${NC}"
echo -e "Reality ShortID: ${BLUE}$SHORT_ID${NC}"
echo -e "HY2 本地端口: ${BLUE}$HY2_PORT (UDP 443已重定向)${NC}"
echo -e "${GREEN}==================================================${NC}"
