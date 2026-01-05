#!/usr/bin/env bash

# =================================================================
# 项目：Sing-box 自动化部署系统 (V6.5 终极通关版)
# 修复：公钥提取 / 官方脚本 404 / 链接二维码展示 / 唤醒词
# =================================================================

set -e

# --- [ 0. 基础环境 ] ---
RED='\033[0;31m' && GREEN='\033[0;32m' && YELLOW='\033[0;33m' && BLUE='\033[0;34m' && NC='\033[0m'
CONF_DIR="/etc/sing-box"
CERT_DIR="/etc/v2ray-agent/tls"
NGINX_CONF="/etc/nginx/sites-available/default"
ALIAS_PATH="/usr/bin/zxj2h1"
IP=$(curl -s http://checkip.amazonaws.com || curl -s icanhazip.com)

# --- [ 1. 唤醒词设置 ] ---
echo "bash <(curl -Ls https://raw.githubusercontent.com/zxjwg/zxjsingbox2h1/refs/heads/main/deploy.sh)" > "$ALIAS_PATH"
chmod +x "$ALIAS_PATH"

# --- [ 2. 暴力自愈环境 ] ---
echo -e "${BLUE}[1/6] 正在初始化环境并清理锁...${NC}"
systemctl stop unattended-upgrades apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
killall -9 apt apt-get dpkg 2>/dev/null || true
rm -f /var/lib/dpkg/lock* /var/cache/debconf/*.dat
DEBIAN_FRONTEND=noninteractive dpkg --configure -a || true

# --- [ 3. 依赖安装 ] ---
echo -e "${BLUE}[2/6] 安装必要依赖 (含 qrencode)...${NC}"
apt-get update
apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    curl wget lsof jq tar nginx ca-certificates uuid-runtime openssl coreutils qrencode socat

# --- [ 4. 交互输入 ] ---
read -rp "请输入域名 (如 fg.zhouxj.qzz.io): " DOMAIN
read -rp "请输入邮箱: " EMAIL

# --- [ 5. 证书逻辑：检测并跳过 ] ---
echo -e "${BLUE}[3/6] 正在处理 TLS 证书...${NC}"
if [ -f "$CERT_DIR/server.crt" ] && [ -f "$CERT_DIR/server.key" ]; then
    echo -e "${GREEN}检测到已有证书，跳过申请。${NC}"
else
    if [ ! -f "/root/.acme.sh/acme.sh" ]; then
        curl https://get.acme.sh | sh -s email="$EMAIL" || true
    fi
    ACME="/root/.acme.sh/acme.sh"
    $ACME --set-default-ca --server letsencrypt
    systemctl stop nginx || true
    $ACME --issue -d "$DOMAIN" --standalone
    mkdir -p "$CERT_DIR"
    $ACME --install-cert -d "$DOMAIN" --key-file "$CERT_DIR/server.key" --fullchain-file "$CERT_DIR/server.crt"
fi

# --- [ 6. 二进制直装与密钥提取 ] ---
echo -e "${BLUE}[4/6] 正在通过二进制直装 Sing-box...${NC}"
ARCH=$(uname -m)
[ "$ARCH" == "x86_64" ] && SB_ARCH="amd64" || SB_ARCH="arm64"
VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//')
DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${SB_ARCH}.tar.gz"

wget -qO sing-box.tar.gz "$DOWNLOAD_URL"
tar -zxf sing-box.tar.gz
mv sing-box-*/sing-box /usr/bin/ && chmod +x /usr/bin/sing-box
rm -rf sing-box.tar.gz sing-box-*

# 核心：使用临时文件稳健提取密钥
/usr/bin/sing-box generate reality-keypair > keys.txt
PRIV_KEY=$(grep "Private key:" keys.txt | awk '{print $3}')
PUB_KEY=$(grep "Public key:" keys.txt | awk '{print $3}')
rm -f keys.txt

SHORT_ID=$(openssl rand -hex 8)
UUID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
RAND_PORT=$(shuf -i 10000-60000 -n 1)

# --- [ 7. 写入配置并启动 ] ---
mkdir -p "$CONF_DIR"
cat > "$CONF_DIR/config.json" <<EOF
{
  "inbounds": [
    {
      "type": "vless", "tag": "reality-in", "listen": "::", "listen_port": 443,
      "users": [{"uuid": "$UUID", "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": true, "server_name": "www.microsoft.com",
        "reality": { "enabled": true, "handshake": { "server": "127.0.0.1", "server_port": $RAND_PORT }, "private_key": "$PRIV_KEY", "short_id": ["$SHORT_ID"] }
      }
    },
    {
      "type": "hysteria2", "tag": "hy2-in", "listen": "::", "listen_port": 443,
      "users": [{"password": "$UUID"}],
      "tls": { "enabled": true, "server_name": "$DOMAIN", "alpn": ["h3"], "certificate_path": "$CERT_DIR/server.crt", "key_path": "$CERT_DIR/server.key" }
    }
  ],
  "outbounds": [{"type": "direct"}]
}
EOF

cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target
[Service]
ExecStart=/usr/bin/sing-box run -c $CONF_DIR/config.json
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

cat > "$NGINX_CONF" <<EOF
server { listen 127.0.0.1:$RAND_PORT; server_name _; location / { root /var/www/html; index index.html; } }
EOF

systemctl daemon-reload && systemctl restart nginx && systemctl enable --now sing-box

# --- [ 8. 成果展示 ] ---
echo -e "${GREEN}==================================================${NC}"
echo -e "${YELLOW}节点 1: VLESS Reality (TCP)${NC}"
VLESS_LINK="vless://$UUID@$IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=$PUB_KEY&sid=$SHORT_ID#Reality_$IP"
echo -e "${BLUE}$VLESS_LINK${NC}"
qrencode -t ansiutf8 "$VLESS_LINK"

echo -e "\n${YELLOW}节点 2: Hysteria 2 (UDP)${NC}"
HY2_LINK="hysteria2://$UUID@$IP:443?sni=$DOMAIN&alpn=h3&insecure=0#HY2_$IP"
echo -e "${BLUE}$HY2_LINK${NC}"
qrencode -t ansiutf8 "$HY2_LINK"
echo -e "${GREEN}==================================================${NC}"
echo -e "唤醒词：只需输入 ${BLUE}zxj2h1${NC} 即可管理脚本。"
