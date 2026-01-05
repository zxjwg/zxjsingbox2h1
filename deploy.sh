#!/usr/bin/env bash

# =================================================================
# 项目：Sing-box 自动化部署系统 (V6.2 终极通关版)
# 功能：二进制直装修复 404 / 证书检测跳过 / 唤醒词 zxj2h1
# =================================================================

set -e

# --- [ 0. 变量与路径 ] ---
RED='\033[0;31m' && GREEN='\033[0;32m' && YELLOW='\033[0;33m' && BLUE='\033[0;34m' && NC='\033[0m'
CONF_DIR="/etc/sing-box"
CERT_DIR="/etc/v2ray-agent/tls"
NGINX_CONF="/etc/nginx/sites-available/default"
RANDOM_PORT=$(shuf -i 10000-60000 -n 1 2>/dev/null || echo "37210")
# 唤醒词配置路径
ALIAS_PATH="/usr/bin/zxj2h1"
SCRIPT_URL="https://raw.githubusercontent.com/zxjwg/zxjsingbox2h1/refs/heads/main/deploy.sh"

# --- [ 1. 唤醒词设置 (zxj2h1) ] ---
echo -e "${BLUE}[1/6] 正在配置快捷唤醒词 zxj2h1...${NC}"
cat > "$ALIAS_PATH" <<EOF
#!/bin/bash
bash <(curl -Ls $SCRIPT_URL)
EOF
chmod +x "$ALIAS_PATH"

# --- [ 2. 暴力清理系统锁 ] ---
echo -e "${BLUE}[2/6] 正在解除系统锁定并自愈环境...${NC}"
systemctl stop unattended-upgrades apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
killall -9 apt apt-get dpkg 2>/dev/null || true
rm -f /var/lib/dpkg/lock* /var/cache/debconf/*.dat
DEBIAN_FRONTEND=noninteractive dpkg --configure -a || true

# --- [ 3. 安装依赖 (二进制安装必需品) ] ---
echo -e "${BLUE}[3/6] 安装核心依赖工具...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    curl wget lsof jq tar nginx ca-certificates uuid-runtime openssl coreutils

# --- [ 4. 证书逻辑：检测并跳过 ] ---
read -rp "请输入域名: " DOMAIN
read -rp "请输入邮箱: " EMAIL

echo -e "${BLUE}[4/6] 正在处理 TLS 证书...${NC}"
# 如果证书已存在，直接使用，不再申请
if [ -f "$CERT_DIR/server.crt" ] && [ -f "$CERT_DIR/server.key" ]; then
    echo -e "${GREEN}检测到已有证书，已自动跳过申请步骤。${NC}"
else
    echo -e "${YELLOW}未检测到证书，开始申请...${NC}"
    if [ ! -f "/root/.acme.sh/acme.sh" ]; then
        curl https://get.acme.sh | sh -s email="$EMAIL" || true
    fi
    ACME="/root/.acme.sh/acme.sh"
    $ACME --set-default-ca --server letsencrypt
    mkdir -p "$CERT_DIR"
    systemctl stop nginx || true
    $ACME --issue -d "$DOMAIN" --standalone
    $ACME --install-cert -d "$DOMAIN" --key-file "$CERT_DIR/server.key" --fullchain-file "$CERT_DIR/server.crt"
fi

# --- [ 5. Sing-box 核心部署 (修复官方 404 问题) ] ---
echo -e "${BLUE}[5/6] 正在执行二进制直装 (跳过官方安装脚本)...${NC}"
# 自动抓取 GitHub 最新版本
VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//')
DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-amd64.tar.gz"

echo -e "正在从 GitHub 下载 Sing-box v${VERSION}..."
wget -qO sing-box.tar.gz "$DOWNLOAD_URL"
tar -zxf sing-box.tar.gz
mv sing-box-*/sing-box /usr/bin/
chmod +x /usr/bin/sing-box
rm -rf sing-box.tar.gz sing-box-*

# 创建服务文件
mkdir -p "$CONF_DIR"
RE_KEYS=$(/usr/bin/sing-box generate reality-keypair)
PRIV_KEY=$(echo "$RE_KEYS" | grep "Private key" | awk '{print $3}')
PUB_KEY=$(echo "$RE_KEYS" | grep "Public key" | awk '{print $3}')
UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "11111111-2222-3333-4444-555555555555")

# 写入配置：443 端口 TCP/UDP 双监听
cat > "$CONF_DIR/config.json" <<EOF
{
  "inbounds": [
    {
      "type": "vless", "tag": "reality-in", "listen": "::", "listen_port": 443,
      "users": [{"uuid": "$UUID", "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": true, "server_name": "www.microsoft.com",
        "reality": { "enabled": true, "handshake": { "server": "127.0.0.1", "server_port": $RANDOM_PORT }, "private_key": "$PRIV_KEY", "short_id": ["$(openssl rand -hex 8)"] }
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

# --- [ 6. 激活与服务管理 ] ---
echo -e "${BLUE}[6/6] 配置 Nginx 伪装并激活服务...${NC}"
cat > "$NGINX_CONF" <<EOF
server { listen 127.0.0.1:$RANDOM_PORT; server_name _; location / { root /var/www/html; index index.html; } }
EOF
systemctl restart nginx

# 创建 Systemd 服务确保自启
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target nss-lookup.target
[Service]
ExecStart=/usr/bin/sing-box run -c $CONF_DIR/config.json
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now sing-box

echo -e "${GREEN}==================================================${NC}"
echo -e "部署成功！"
echo -e "唤醒词：只需输入 ${BLUE}zxj2h1${NC} 即可重新运行脚本。"
echo -e "UUID/密码：${BLUE}$UUID${NC}"
echo -e "Reality 公钥：${BLUE}$PUB_KEY${NC}"
echo -e "==================================================${NC}"
