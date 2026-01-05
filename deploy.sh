#!/usr/bin/env bash

# =================================================================
# 项目：Sing-box 自动化部署系统 (V5.0 无防火墙/全透明版)
# 说明：移除 iptables 依赖，避开 debconf 锁死，协议直接监听 443
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

# --- [ 1. 暴力清理系统锁 (仅针对必要依赖) ] ---
echo -e "${BLUE}[1/5] 正在解除系统锁定...${NC}"
systemctl stop unattended-upgrades apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
killall -9 apt apt-get dpkg 2>/dev/null || true
rm -f /var/lib/dpkg/lock* /var/cache/debconf/*.dat
DEBIAN_FRONTEND=noninteractive dpkg --configure -a || true

# --- [ 2. 核心依赖安装 (剔除 iptables-persistent) ] ---
echo -e "${BLUE}[2/5] 正在安装必要依赖 (跳过防火墙组件)...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update
# 不再安装 iptables-persistent，彻底避开 passwords.dat 锁死问题
apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    curl wget lsof jq tar nginx ca-certificates uuid-runtime openssl coreutils

# --- [ 3. BBR 优化 ] ---
echo -e "${BLUE}[3/5] 开启 BBR 加速...${NC}"
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1 || true
fi

# --- [ 4. 交互式输入 ] ---
read -rp "请输入域名: " DOMAIN
read -rp "请输入邮箱: " EMAIL
read -rp "是否开启 HY2 混淆? (y/n, 默认 n): " IS_OBFS
IS_OBFS=${IS_OBFS:-"n"}

# --- [ 5. 核心部署 ] ---
echo -e "${BLUE}[4/5] 正在通过 acme.sh 申请证书...${NC}"
curl https://get.acme.sh | sh -s -- --nocron || true
/root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
mkdir -p "$CERT_DIR"
# 优先 standalone 申请
/root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone || /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --nginx
/root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --key-file "$CERT_DIR/server.key" --fullchain-file "$CERT_DIR/server.crt"

echo -e "${BLUE}[5/5] 部署 Sing-box (Reality TCP + HY2 UDP 直接监听 443)...${NC}"
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

# Nginx 伪装配置
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
echo -e "部署成功！(无防火墙依赖模式)"
echo -e "UUID: ${BLUE}$UUID${NC}"
echo -e "Reality 公钥: ${BLUE}$PUB_KEY${NC}"
echo -e "提示：请确保在 VPS 外部防火墙(Security Group)开启 TCP 443 和 UDP 443 端口${NC}"
echo -e "==================================================${NC}"
