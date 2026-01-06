#!/usr/bin/env bash

# =================================================================
# 项目：Sing-box 自动化部署系统 (V10.2 核心稳健版)
# 架构：VLESS Reality (443) + Hysteria 2 (8443)
# =================================================================

set -e

# --- [ 0. 核心配置中心 ] ---
SNI="www.microsoft.com"
HY2_PORT="8443"
RED='\033[0;31m' && GREEN='\033[0;32m' && YELLOW='\033[0;33m' && BLUE='\033[0;34m' && NC='\033[0m'
CONF_DIR="/etc/sing-box"
CERT_DIR="/etc/v2ray-agent/tls"
ALIAS_PATH="/usr/bin/zxj2h1"
IP=$(curl -s http://checkip.amazonaws.com || curl -s icanhazip.com)

# --- [ 1. 环境初始化 ] ---
echo -e "${BLUE}[1/5] 正在安装核心依赖...${NC}"
apt-get update && apt-get install -y jq uuid-runtime qrencode coreutils openssl socat

# --- [ 2. 二进制直装：1.12.14 稳定版 ] ---
echo -e "${BLUE}[2/5] 正在安装 Sing-box 1.12.14...${NC}"
ARCH=$(uname -m)
[ "$ARCH" == "x86_64" ] && SB_ARCH="amd64" || SB_ARCH="arm64"
wget -qO sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v1.12.14/sing-box-1.12.14-linux-${SB_ARCH}.tar.gz"
tar -zxf sing-box.tar.gz
mv sing-box-*/sing-box /usr/bin/ && chmod +x /usr/bin/sing-box
rm -rf sing-box.tar.gz sing-box-*

# --- [ 3. 密钥提取：暴力且稳健 ] ---
echo -e "${BLUE}[3/5] 正在生成并提取 Reality 密钥对...${NC}"
# 获取原始输出
RAW_KEYS=$(/usr/bin/sing-box generate reality-keypair 2>&1)
# 模糊匹配，不分大小写，截取冒号后的内容
PRIV_KEY=$(echo "$RAW_KEYS" | grep -i "Private" | sed 's/.*:[[:space:]]*//' | xargs)
PUB_KEY=$(echo "$RAW_KEYS" | grep -i "Public" | sed 's/.*:[[:space:]]*//' | xargs)

# 强制自检，失败就停止，不让错误蔓延
if [ -z "$PRIV_KEY" ] || [ -z "$PUB_KEY" ]; then
    echo -e "${RED}致命错误：密钥提取失败！请检查 Sing-box 是否运行正常。${NC}"
    exit 1
fi

UUID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
SHORT_ID=$(openssl rand -hex 8)

# --- [ 4. 证书处理 (HY2 专用) ] ---
echo -e "${BLUE}[4/5] 正在申请/读取 HY2 所需的域名证书...${NC}"
read -rp "请输入域名 (如 domain.com): " DOMAIN
read -rp "请输入邮箱: " EMAIL
if [ ! -f "$CERT_DIR/server.crt" ]; then
    curl https://get.acme.sh | sh -s email="$EMAIL" || true
    systemctl stop nginx 2>/dev/null || true
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone
    mkdir -p "$CERT_DIR"
    /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --key-file "$CERT_DIR/server.key" --fullchain-file "$CERT_DIR/server.crt"
fi

# --- [ 5. 写入核心配置 ] ---
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
systemctl stop sing-box 2>/dev/null || true
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

# --- [ 7. 展示节点 ] ---
echo -e "${GREEN}==================================================${NC}"
VLESS="vless://$UUID@$IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUB_KEY&sid=$SHORT_ID#Reality_V10.2"
echo -e "${YELLOW}Reality 节点 (TCP 443):${NC}\n${BLUE}$VLESS${NC}"
qrencode -t UTF8 "$VLESS"

HY2="hysteria2://$UUID@$IP:$HY2_PORT?sni=$DOMAIN&alpn=h3&insecure=0#HY2_V10.2"
echo -e "\n${YELLOW}Hysteria 2 节点 (UDP $HY2_PORT):${NC}\n${BLUE}$HY2${NC}"
qrencode -t UTF8 "$HY2"
echo -e "${GREEN}==================================================${NC}"
echo -e "唤醒词已设置：${BLUE}zxj2h1${NC}"
