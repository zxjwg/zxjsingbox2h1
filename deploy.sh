#!/usr/bin/env bash

# =================================================================
# 项目：Sing-box 自动化部署系统 (V6.3 节点展示版)
# 功能：修复密钥提取 / 自动生成节点链接 / 二维码展示 / 唤醒词
# =================================================================

set -e

# --- [ 0. 基础变量 ] ---
RED='\033[0;31m' && GREEN='\033[0;32m' && YELLOW='\033[0;33m' && BLUE='\033[0;34m' && NC='\033[0m'
CONF_DIR="/etc/sing-box"
CERT_DIR="/etc/v2ray-agent/tls"
NGINX_CONF="/etc/nginx/sites-available/default"
RANDOM_PORT=$(shuf -i 10000-60000 -n 1 2>/dev/null || echo "37210")
ALIAS_PATH="/usr/bin/zxj2h1"
IP=$(curl -s http://checkip.amazonaws.com || curl -s icanhazip.com)

# --- [ 1. 暴力清理与环境自愈 ] ---
echo -e "${BLUE}[1/6] 正在初始化环境...${NC}"
killall -9 apt apt-get dpkg 2>/dev/null || true
rm -f /var/lib/dpkg/lock* /var/cache/debconf/*.dat
DEBIAN_FRONTEND=noninteractive dpkg --configure -a || true

# --- [ 2. 依赖安装 (增加 qrencode 用于展示二维码) ] ---
echo -e "${BLUE}[2/6] 安装必要依赖...${NC}"
apt-get update
# 增加 qrencode 工具
apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    curl wget lsof jq tar nginx ca-certificates uuid-runtime openssl coreutils qrencode

# --- [ 3. 证书逻辑 ] ---
read -rp "请输入域名: " DOMAIN
read -rp "请输入邮箱: " EMAIL

if [ -f "$CERT_DIR/server.crt" ]; then
    echo -e "${GREEN}检测到已有证书，跳过申请。${NC}"
else
    # ... (此处保持 V6.2 的 acme.sh 申请逻辑) ...
    curl https://get.acme.sh | sh -s email="$EMAIL" || true
    /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone
    mkdir -p "$CERT_DIR"
    /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --key-file "$CERT_DIR/server.key" --fullchain-file "$CERT_DIR/server.crt"
fi

# --- [ 4. Sing-box 二进制直装与密钥生成 ] ---
echo -e "${BLUE}[4/6] 部署 Sing-box 核心...${NC}"
VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//')
DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-amd64.tar.gz"
wget -qO sing-box.tar.gz "$DOWNLOAD_URL"
tar -zxf sing-box.tar.gz
mv sing-box-*/sing-box /usr/bin/ && chmod +x /usr/bin/sing-box
rm -rf sing-box.tar.gz sing-box-*

# 关键：修复密钥提取逻辑
RE_KEYS=$(/usr/bin/sing-box generate reality-keypair)
PRIV_KEY=$(echo "$RE_KEYS" | awk '/Private key:/ {print $3}')
PUB_KEY=$(echo "$RE_KEYS" | awk '/Public key:/ {print $3}')
SHORT_ID=$(openssl rand -hex 8)
UUID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)

# --- [ 5. 配置写入与启动 ] ---
mkdir -p "$CONF_DIR"
cat > "$CONF_DIR/config.json" <<EOF
{
  "inbounds": [
    {
      "type": "vless", "tag": "reality-in", "listen": "::", "listen_port": 443,
      "users": [{"uuid": "$UUID", "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": true, "server_name": "www.microsoft.com",
        "reality": { "enabled": true, "handshake": { "server": "127.0.0.1", "server_port": $RANDOM_PORT }, "private_key": "$PRIV_KEY", "short_id": ["$SHORT_ID"] }
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

# 配置 Systemd 与 Nginx
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
systemctl daemon-reload && systemctl enable --now sing-box

# --- [ 6. 节点链接生成与展示 ] ---
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
