#!/usr/bin/env bash
# 项目：Sing-box 自动化部署系统 (V9.0 终极全能版)
# 特点：兼容性密钥提取、二进制直装、紧凑二维码

set -e

# --- [ 0. 变量定义 ] ---
RED='\033[0;31m' && GREEN='\033[0;32m' && BLUE='\033[0;34m' && NC='\033[0m'
CONF_DIR="/etc/sing-box"
CERT_DIR="/etc/v2ray-agent/tls"
ALIAS_PATH="/usr/bin/zxj2h1"
IP=$(curl -s http://checkip.amazonaws.com || echo "31.57.47.96")

# --- [ 1. 初始化环境 ] ---
echo -e "${BLUE}[1/5] 正在快速自愈环境...${NC}"
apt-get update && apt-get install -y jq uuid-runtime qrencode coreutils openssl

# --- [ 2. 证书检测 ] ---
read -rp "请输入域名 (如 fg.zhouxj.qzz.io): " DOMAIN
if [ ! -f "$CERT_DIR/server.crt" ]; then
    echo -e "${RED}未检测到证书文件，请确保之前步骤已成功。${NC}"
fi

# --- [ 3. 密钥提取：使用你刚刚测试成功的逻辑 ] ---
echo -e "${BLUE}[2/5] 正在提取 Reality 密钥对...${NC}"
RAW_KEYS=$(/usr/bin/sing-box generate reality-keypair 2>&1)
PRIV_KEY=$(echo "$RAW_KEYS" | grep -i "Private" | sed 's/.*:[[:space:]]*//' | xargs)
PUB_KEY=$(echo "$RAW_KEYS" | grep -i "Public" | sed 's/.*:[[:space:]]*//' | xargs)

UUID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
SHORT_ID=$(openssl rand -hex 8)
RAND_PORT=$(shuf -i 10000-60000 -n 1)

# --- [ 4. 写入配置 ] ---
mkdir -p "$CONF_DIR"
cat > "$CONF_DIR/config.json" <<EOF
{
  "log": { "level": "info", "timestamp": true },
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
      "type": "hysteria2", "tag": "hy2-in", "listen": "::", "listen_port": 8443,
      "users": [{"password": "$UUID"}],
      "tls": { "enabled": true, "server_name": "$DOMAIN", "alpn": ["h3"], "certificate_path": "$CERT_DIR/server.crt", "key_path": "$CERT_DIR/server.key" }
    }
  ],
  "outbounds": [{"type": "direct"}]
}
EOF

# --- [ 5. 重启并展示 ] ---
/usr/bin/sing-box check -c "$CONF_DIR/config.json"
systemctl restart sing-box

echo -e "${GREEN}==================================================${NC}"
VLESS="vless://$UUID@$IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=$PUB_KEY&sid=$SHORT_ID#Reality_Final"
echo -e "${YELLOW}Reality 节点:${NC}\n${BLUE}$VLESS${NC}"
qrencode -t UTF8 "$VLESS"

echo -e "\n${YELLOW}Hysteria 2 节点:${NC}"
HY2="hysteria2://$UUID@$IP:8443?sni=$DOMAIN&alpn=h3&insecure=0#HY2_Final"
echo -e "${BLUE}$HY2${NC}"
qrencode -t UTF8 "$HY2"
echo -e "${GREEN}==================================================${NC}"

# 唤醒词设置
echo "bash <(curl -Ls https://raw.githubusercontent.com/zxjwg/zxjsingbox2h1/refs/heads/main/deploy.sh)" > "$ALIAS_PATH"
chmod +x "$ALIAS_PATH"
