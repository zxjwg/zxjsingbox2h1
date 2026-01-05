#!/usr/bin/env bash

# =================================================================
# 项目：Sing-box 自动化部署系统 (V5.1 证书修复版)
# 说明：修复 acme.sh 安装参数错误，直接监听 443 端口
# =================================================================

set -e

# --- [ 0. 配置与变量 ] ---
RED='\033[0;31m' && GREEN='\033[0;32m' && BLUE='\033[0;34m' && NC='\033[0m'
CONF_DIR="/etc/sing-box"
CERT_DIR="/etc/v2ray-agent/tls"
NGINX_CONF="/etc/nginx/sites-available/default"
RANDOM_PORT=$(shuf -i 10000-60000 -n 1 2>/dev/null || echo "37210")
UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$(openssl rand -hex 8)-$(openssl rand -hex 4)-$(openssl rand -hex 4)-$(openssl rand -hex 4)-$(openssl rand -hex 12)")
SHORT_ID=$(openssl rand -hex 8)

# --- [ 1. 暴力清理系统锁 ] ---
echo -e "${BLUE}[1/5] 正在解除系统锁定...${NC}"
systemctl stop unattended-upgrades apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
killall -9 apt apt-get dpkg 2>/dev/null || true
rm -f /var/lib/dpkg/lock* /var/cache/debconf/*.dat
DEBIAN_FRONTEND=noninteractive dpkg --configure -a || true

# --- [ 2. 核心依赖安装 ] ---
echo -e "${BLUE}[2/5] 正在安装必要依赖...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    curl wget lsof jq tar nginx ca-certificates uuid-runtime openssl coreutils

# --- [ 3. 交互式输入 ] ---
read -rp "请输入域名: " DOMAIN
read -rp "请输入邮箱: " EMAIL
read -rp "是否开启 HY2 混淆? (y/n, 默认 n): " IS_OBFS
IS_OBFS=${IS_OBFS:-"n"}

# --- [ 4. 证书申请 (修复参数逻辑) ] ---
echo -e "${BLUE}[3/5] 正在通过 acme.sh 申请证书...${NC}"
# 修复：使用更标准的安装命令，避免 --nocron 的连字符冲突
if [ ! -f "/root/.acme.sh/acme.sh" ]; then
    curl https://get.acme.sh | sh -s email="$EMAIL" || true
fi
# 定义 acme.sh 绝对路径
ACME="/root/.acme.sh/acme.sh"
[ ! -f "$ACME" ] && ACME="/.acme.sh/acme.sh" # 备选路径

$ACME --set-default-ca --server letsencrypt
mkdir -p "$CERT_DIR"
# 优先使用 Standalone 申请
$ACME --issue -d "$DOMAIN" --standalone || $ACME --issue -d "$DOMAIN" --nginx
$ACME --install-cert -d "$DOMAIN" --key-file "$CERT_DIR/server.key" --fullchain-file "$CERT_DIR/server.crt"

# --- [ 5. Sing-box 部署 ] ---
echo -e "${BLUE}[4/5] 正在安装 Sing-box 核心...${NC}"
curl -fsSL https://raw.githubusercontent.com/sagernet/sing-box/main/install.sh | bash -s --

RE_KEYS=$(/usr/bin/sing-box generate reality-keypair)
PRIV_KEY=$(echo "$RE_KEYS" | grep "Private key" | awk '{print $3}')
PUB_KEY=$(echo "$RE_KEYS" | grep "Public key" | awk '{print $3}')

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
      "type": "hysteria2", "tag": "hy2-in", "listen": "::", "listen_port": 443,
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

# --- [ 6. 伪装与启动 ] ---
echo -e "${BLUE}[5/5] 配置 Nginx 伪装并启动服务...${NC}"
cat > "$NGINX_CONF" <<EOF
server {
    listen 127.0.0.1:$RANDOM_PORT;
    server_name _;
    location / { root /var/www/html; index index.html; }
}
EOF
systemctl restart nginx
systemctl enable --now sing-box

echo -e "${GREEN}==================================================${NC}"
echo -e "部署成功！"
echo -e "UUID: ${BLUE}$UUID${NC}"
echo -e "Reality 公钥: ${BLUE}$PUB_KEY${NC}"
echo -e "==================================================${NC}"
