#!/usr/bin/env bash

# =================================================================
# 项目：Sing-box 自动化部署系统 (V1.1 透明重构版)
# 特点：取消后台静默模式，全流程跑码可见，确保安装不挂起
# =================================================================

set -e # 遇到错误立即停止

# --- [ 0. 全局变量 ] ---
CONF_DIR="/etc/sing-box"
CERT_DIR="/etc/v2ray-agent/tls"
NGINX_CONF="/etc/nginx/sites-available/default"
RANDOM_PORT=$(shuf -i 10000-60000 -n 1)
HY2_PORT="5443"
UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$(openssl rand -hex 8)-$(openssl rand -hex 4)-$(openssl rand -hex 4)-$(openssl rand -hex 4)-$(openssl rand -hex 12)")
SHORT_ID=$(openssl rand -hex 8)

RED='\033[0;31m' && GREEN='\033[0;32m' && BLUE='\033[0;34m' && NC='\033[0m'

# --- [ 1. 暴力清理环境 ] ---
echo -e "${BLUE}[1/5] 正在清理系统锁，确保安装环境纯净...${NC}"
systemctl stop unattended-upgrades 2>/dev/null || true
rm -f /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock 2>/dev/null
dpkg --configure -a || true

# --- [ 2. 实时安装依赖 ] ---
echo -e "${BLUE}[2/5] 正在安装系统依赖，请观察输出信息...${NC}"
# 不再隐藏输出，确保你能看到进度，防止 debconf 挂起
apt-get update
apt-get install -y curl wget lsof jq tar nginx ca-certificates iptables uuid-runtime openssl coreutils iptables-persistent

# --- [ 3. 网络内核优化 ] ---
echo -e "${BLUE}[3/5] 正在开启内核 BBR 加速...${NC}"
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p
fi

# --- [ 4. 关键信息输入 ] ---
echo -e "${GREEN}--------------------------------------------------${NC}"
read -rp "请输入域名 (用于 HY2): " DOMAIN
read -rp "请输入邮箱 (用于 证书申请): " EMAIL
read -rp "是否开启 HY2 混淆(obfs)? (y/n, 默认 n): " IS_OBFS
IS_OBFS=${IS_OBFS:-"n"}
echo -e "${GREEN}--------------------------------------------------${NC}"

# --- [ 5. 核心部署 ] ---
echo -e "${BLUE}[4/5] 正在通过 acme.sh 申请 TLS 证书 (透明过程)...${NC}"
curl https://get.acme.sh | sh -s -- --nocron
/root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
mkdir -p "$CERT_DIR"
# 自动尝试申请模式
/root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone || /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --nginx
/root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --key-file "$CERT_DIR/server.key" --fullchain-file "$CERT_DIR/server.crt"

echo -e "${BLUE}[5/5] 正在部署 Sing-box 核心...${NC}"
curl -fsSL https://raw.githubusercontent.com/sagernet/sing-box/main/install.sh | bash -s --

RE_KEYS=$(/usr/bin/sing-box generate reality-keypair)
PRIV_KEY=$(echo "$RE_KEYS" | grep "Private key" | awk '{print $3}')
PUB_KEY_VAL=$(echo "$RE_KEYS" | grep "Public key" | awk '{print $3}')

OBFS_BLOCK=""
if [[ "$IS_OBFS" =~ ^[yY]$ ]]; then
    OBFS_BLOCK=", \"obfs\": {\"type\": \"salamander\", \"password\": \"unserionssss66688\"}"
fi

# 写入最终配置文件
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

# Nginx 伪装配置
cat > "$NGINX_CONF" <<EOF
server {
    listen 127.0.0.1:$RANDOM_PORT;
    server_name _;
    location / { root /var/www/html; index index.html; }
}
EOF
systemctl restart nginx

# 开启转发与服务
iptables -t nat -A PREROUTING -p udp --dport 443 -j REDIRECT --to-ports "$HY2_PORT"
netfilter-persistent save
systemctl enable --now sing-box

echo -e "${GREEN}==================================================${NC}"
echo -e "部署成功！您的 UUID: ${BLUE}$UUID${NC}"
echo -e "Reality 公钥: ${BLUE}$PUB_KEY_VAL${NC}"
echo -e "==================================================${NC}"
