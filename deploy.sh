#!/usr/bin/env bash

# =================================================================
# 项目：Sing-box 自动化部署系统 (V10.1 终极修正版)
# 修复：公钥变量提取 Bug (RAW_KEYS 拼写修正)
# =================================================================

set -e

# --- [ 0. 配置中心：方便你随时修改 ] ---
SNI="dl.steampowered.com" # 你可以换成 microsoft, apple 或 nvidia
HY2_PORT="8443"
RED='\033[0;31m' && GREEN='\033[0;32m' && YELLOW='\033[0;33m' && BLUE='\033[0;34m' && NC='\033[0m'
CONF_DIR="/etc/sing-box"
CERT_DIR="/etc/v2ray-agent/tls"
ALIAS_PATH="/usr/bin/zxj2h1"
IP=$(curl -s http://checkip.amazonaws.com || curl -s icanhazip.com)

# --- [ 1. 初始化与依赖 ] ---
echo -e "${BLUE}[1/5] 正在初始化环境...${NC}"
apt-get update && apt-get install -y jq uuid-runtime qrencode coreutils openssl

# --- [ 2. 交互输入 ] ---
read -rp "请输入域名 (必须已解析到 $IP): " DOMAIN
read -rp "请输入邮箱: " EMAIL

# --- [ 3. 证书处理 ] ---
if [ -f "$CERT_DIR/server.crt" ]; then
    echo -e "${GREEN}检测到已有证书，自动跳过申请。${NC}"
else
    # 此处省略 acme.sh 逻辑，保持与 V10.0 一致
    curl https://get.acme.sh | sh -s email="$EMAIL" || true
    systemctl stop nginx 2>/dev/null || true
    /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone
    mkdir -p "$CERT_DIR"
    /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --key-file "$CERT_DIR/server.key" --fullchain-file "$CERT_DIR/server.crt"
fi

# --- [ 4. 密钥提取：修正后的逻辑 ] ---
echo -e "${BLUE}[2/5] 正在提取 Reality 密钥对...${NC}"
RAW_KEYS=$(/usr/bin/sing-box generate reality-keypair 2>&1)
# 统一使用 RAW_KEYS 变量
PRIV_KEY=$(echo "$RAW_KEYS" | grep -i "Private" | sed 's/.*:[[:space:]]*//' | xargs)
PUB_KEY=$(echo "$RAW_KEYS" | grep -i "Public" | sed 's/.*:[[:space:]]*//' | xargs)

if [ -z "$PUB_KEY" ]; then echo -e "${RED}致命错误：公钥提取失败！${NC}" && exit 1; fi

UUID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
SHORT_ID=$(openssl rand -hex 8)

# --- [ 5. 写入配置 ] ---
mkdir -p "$CONF_DIR"
cat > "$CONF_DIR/config.json" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless", "tag": "reality-in", "listen": "::", "listen_port": 443,
      "users": [{"uuid": "$UUID", "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": true, "server_name": "$SNI",
        "reality": { "enabled": true, "handshake": { "server": "$SNI", "server_port": 443 }, "private_key": "$PRIV_KEY", "short_id": ["$SHORT_ID"] }
      }
    },
    {
      "type": "hysteria2", "tag": "hy2-in", "listen": "::", "listen_port": $HY2_PORT,
      "users": [{"password": "$UUID"}],
      "tls": { "enabled": true, "server_name": "$DOMAIN", "alpn": ["h3"], "certificate_path": "$CERT_DIR/server.crt", "key_path": "$CERT_DIR/server.key" }
    }
  ],
  "outbounds": [{"type": "direct"}]
}
EOF

# --- [ 6. 激活服务 ] ---
systemctl daemon-reload && systemctl enable --now sing-box
echo "bash <(curl -Ls https://raw.githubusercontent.com/zxjwg/zxjsingbox2h1/refs/heads/main/deploy.sh)" > "$ALIAS_PATH"
chmod +x "$ALIAS_PATH"

# --- [ 7. 展示成果 ] ---
echo -e "${GREEN}==================================================${NC}"
VLESS="vless://$UUID@$IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUB_KEY&sid=$SHORT_ID#Reality_V10.1"
echo -e "${YELLOW}Reality 节点:${NC}\n${BLUE}$VLESS${NC}"
qrencode -t UTF8 "$VLESS"
echo -e "${GREEN}==================================================${NC}"
