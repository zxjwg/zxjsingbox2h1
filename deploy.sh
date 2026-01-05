#!/usr/bin/env bash

# =================================================================
# 项目：Sing-box 自动化部署系统 (V6.9 终极全能版)
# 修复：JSON 密钥提取 / 404 绕过 / 紧凑二维码 / 快捷唤醒词
# =================================================================

set -e

# --- [ 0. 基础环境定义 ] ---
RED='\033[0;31m' && GREEN='\033[0;32m' && YELLOW='\033[0;33m' && BLUE='\033[0;34m' && NC='\033[0m'
CONF_DIR="/etc/sing-box"
CERT_DIR="/etc/v2ray-agent/tls"
ALIAS_PATH="/usr/bin/zxj2h1"
IP=$(curl -s http://checkip.amazonaws.com || curl -s icanhazip.com)

# --- [ 1. 暴力解锁与环境初始化 ] ---
echo -e "${BLUE}[1/6] 正在暴力解除系统锁定并初始化环境...${NC}"
systemctl stop unattended-upgrades apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
killall -9 apt apt-get dpkg 2>/dev/null || true
rm -f /var/lib/dpkg/lock* /var/cache/debconf/*.dat
DEBIAN_FRONTEND=noninteractive dpkg --configure -a || true

# 安装所有必需工具 (一次性安装，减少报错概率)
apt-get update && apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    curl wget lsof jq tar nginx ca-certificates uuid-runtime openssl coreutils qrencode socat

# --- [ 2. 交互输入 ] ---
read -rp "请输入域名 (必须解析到 $IP): " DOMAIN
read -rp "请输入邮箱 (用于申请证书): " EMAIL

# --- [ 3. 证书逻辑：自愈与检测 ] ---
echo -e "${BLUE}[2/6] 正在处理 TLS 证书 (自动跳过已存在证书)...${NC}"
if [ -f "$CERT_DIR/server.crt" ] && [ -f "$CERT_DIR/server.key" ]; then
    echo -e "${GREEN}检测到已有证书，已自动跳过。${NC}"
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

# --- [ 4. 二进制直装：彻底绕过 404 脚本 ] ---
echo -e "${BLUE}[3/6] 正在从 GitHub 下载并安装 Sing-box 二进制程序...${NC}"
ARCH=$(uname -m)
[ "$ARCH" == "x86_64" ] && SB_ARCH="amd64" || SB_ARCH="arm64"
VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//')
DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${SB_ARCH}.tar.gz"

wget -qO sing-box.tar.gz "$DOWNLOAD_URL"
tar -zxf sing-box.tar.gz
mv sing-box-*/sing-box /usr/bin/ && chmod +x /usr/bin/sing-box
rm -rf sing-box.tar.gz sing-box-*

# --- [ 5. 密钥提取与配置生成 (JSON 核心修复) ] ---
echo -e "${BLUE}[4/6] 正在提取 Reality 密钥并生成配置...${NC}"
# 使用 JSON 格式提取，杜绝 private_key 为空
RE_JSON=$(/usr/bin/sing-box generate reality-keypair --format json)
PRIV_KEY=$(echo "$RE_JSON" | jq -r '.private_key')
PUB_KEY=$(echo "$RE_JSON" | jq -r '.public_key')

if [[ "$PRIV_KEY" == "null" || -z "$PRIV_KEY" ]]; then
    echo -e "${RED}致命错误：密钥提取失败，请检查二进制文件。${NC}" && exit 1
fi

UUID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
SHORT_ID=$(openssl rand -hex 8)
RAND_PORT=$(shuf -i 10000-60000 -n 1)

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

# --- [ 6. 激活服务与展示成果 ] ---
echo -e "${BLUE}[5/6] 正在校验并激活服务...${NC}"
/usr/bin/sing-box check -c "$CONF_DIR/config.json"

# 创建 Systemd 服务
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

# 配置快捷唤醒词
echo "bash <(curl -Ls https://raw.githubusercontent.com/zxjwg/zxjsingbox2h1/refs/heads/main/deploy.sh)" > "$ALIAS_PATH"
chmod +x "$ALIAS_PATH"

echo -e "${GREEN}==================================================${NC}"
echo -e "${YELLOW}节点 1: VLESS Reality (TCP)${NC}"
VLESS_LINK="vless://$UUID@$IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=$PUB_KEY&sid=$SHORT_ID#Reality_$IP"
echo -e "${BLUE}$VLESS_LINK${NC}"
qrencode -t UTF8 "$VLESS_LINK"

echo -e "\n${YELLOW}节点 2: Hysteria 2 (UDP)${NC}"
HY2_LINK="hysteria2://$UUID@$IP:443?sni=$DOMAIN&alpn=h3&insecure=0#HY2_$IP"
echo -e "${BLUE}$HY2_LINK${NC}"
qrencode -t UTF8 "$HY2_LINK"
echo -e "${GREEN}==================================================${NC}"
echo -e "部署已完成！今后只需输入 ${BLUE}zxj2h1${NC} 即可重新运行脚本。"
