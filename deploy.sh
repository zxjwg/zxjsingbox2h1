#!/usr/bin/env bash

# =================================================================
# 项目：Sing-box 自动化部署系统 (V10.0 终极完美版)
# 架构：VLESS Reality (443) + Hysteria 2 (8443)
# 特点：免 Nginx 维护 / 微软官网伪装 / 兼容性密钥提取 / 自动唤醒词
# =================================================================

set -e

# --- [ 0. 基础环境定义 ] ---
RED='\033[0;31m' && GREEN='\033[0;32m' && YELLOW='\033[0;33m' && BLUE='\033[0;34m' && NC='\033[0m'
CONF_DIR="/etc/sing-box"
CERT_DIR="/etc/v2ray-agent/tls"
ALIAS_PATH="/usr/bin/zxj2h1"
IP=$(curl -s http://checkip.amazonaws.com || curl -s icanhazip.com)

# --- [ 1. 暴力初始化：解除所有系统锁定 ] ---
echo -e "${BLUE}[1/6] 正在初始化环境并解除系统锁...${NC}"
systemctl stop unattended-upgrades apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
killall -9 apt apt-get dpkg 2>/dev/null || true
rm -f /var/lib/dpkg/lock* /var/cache/debconf/*.dat
DEBIAN_FRONTEND=noninteractive dpkg --configure -a || true
apt-get update && apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    curl wget jq tar ca-certificates uuid-runtime openssl qrencode coreutils socat

# --- [ 2. 交互输入 ] ---
read -rp "请输入域名 (必须已解析到 $IP): " DOMAIN
read -rp "请输入邮箱 (用于申请证书): " EMAIL

# --- [ 3. 证书自愈：检测并申请 ] ---
echo -e "${BLUE}[2/6] 正在处理 TLS 证书...${NC}"
if [ -f "$CERT_DIR/server.crt" ] && [ -f "$CERT_DIR/server.key" ]; then
    echo -e "${GREEN}检测到已有证书，自动跳过申请。${NC}"
else
    if [ ! -f "/root/.acme.sh/acme.sh" ]; then
        curl https://get.acme.sh | sh -s email="$EMAIL" || true
    fi
    ACME="/root/.acme.sh/acme.sh"
    $ACME --set-default-ca --server letsencrypt
    systemctl stop nginx 2>/dev/null || true
    $ACME --issue -d "$DOMAIN" --standalone
    mkdir -p "$CERT_DIR"
    $ACME --install-cert -d "$DOMAIN" --key-file "$CERT_DIR/server.key" --fullchain-file "$CERT_DIR/server.crt"
fi

# --- [ 4. 二进制直装：强行安装 1.12.14 稳定版 ] ---
echo -e "${BLUE}[3/6] 正在通过二进制直装 Sing-box 1.12.14...${NC}"
ARCH=$(uname -m)
[ "$ARCH" == "x86_64" ] && SB_ARCH="amd64" || SB_ARCH="arm64"
wget -qO sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v1.12.14/sing-box-1.12.14-linux-${SB_ARCH}.tar.gz"
tar -zxf sing-box.tar.gz
mv sing-box-*/sing-box /usr/bin/ && chmod +x /usr/bin/sing-box
rm -rf sing-box.tar.gz sing-box-*

# --- [ 5. 密钥提取：V9.0 兼容性模糊匹配逻辑 ] ---
echo -e "${BLUE}[4/6] 正在提取 Reality 密钥对...${NC}"
RAW_KEYS=$(/usr/bin/sing-box generate reality-keypair 2>&1)
PRIV_KEY=$(echo "$RAW_KEYS" | grep -i "Private" | sed 's/.*:[[:space:]]*//' | xargs)
PUB_KEY=$(echo "$RE_JSON" | grep -i "Public" | sed 's/.*:[[:space:]]*//' | xargs)

# 兜底：如果变量还是空，输出原始信息报错
if [ -z "$PRIV_KEY" ]; then echo -e "${RED}密钥提取失败！${NC}" && exit 1; fi

UUID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
SHORT_ID=$(openssl rand -hex 8)

# --- [ 6. 写入“免维护”配置 (Reality 转微软) ] ---
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
        "reality": { "enabled": true, "handshake": { "server": "www.microsoft.com", "server_port": 443 }, "private_key": "$PRIV_KEY", "short_id": ["$SHORT_ID"] }
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

# --- [ 7. 启动服务与激活唤醒词 ] ---
/usr/bin/sing-box check -c "$CONF_DIR/config.json"
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
echo "bash <(curl -Ls https://raw.githubusercontent.com/zxjwg/zxjsingbox2h1/refs/heads/main/deploy.sh)" > "$ALIAS_PATH"
chmod +x "$ALIAS_PATH"

# --- [ 8. 节点展示 ] ---
echo -e "${GREEN}==================================================${NC}"
VLESS="vless://$UUID@$IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=$PUB_KEY&sid=$SHORT_ID#Reality_V10"
echo -e "${YELLOW}Reality 节点 (TCP 443):${NC}\n${BLUE}$VLESS${NC}"
qrencode -t UTF8 "$VLESS"

HY2="hysteria2://$UUID@$IP:8443?sni=$DOMAIN&alpn=h3&insecure=0#HY2_V10"
echo -e "\n${YELLOW}Hysteria 2 节点 (UDP 8443):${NC}\n${BLUE}$HY2${NC}"
qrencode -t UTF8 "$HY2"
echo -e "${GREEN}==================================================${NC}"
echo -e "部署成功！输入 ${BLUE}zxj2h1${NC} 即可管理脚本。晚安！"
