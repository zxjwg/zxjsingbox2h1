#!/usr/bin/env bash
# =================================================================
# 项目：Sing-box 全能通用部署系统 (V4.2 终极兼容透明版)
# 核心：暴力解锁 / 透明安装 / BBR / Reality + HY2 转发
# =================================================================

set -e

# --- [ 0. 环境感知与变量 ] ---
RED='\033[0;31m' && GREEN='\033[0;32m' && YELLOW='\033[0;33m' && BLUE='\033[0;34m' && NC='\033[0m'
CONF_DIR="/etc/sing-box"
CERT_DIR="/etc/v2ray-agent/tls"
NGINX_CONF="/etc/nginx/sites-available/default"
RANDOM_PORT=$(shuf -i 10000-60000 -n 1 2>/dev/null || echo "37210")
UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$(openssl rand -hex 8)-$(openssl rand -hex 4)-$(openssl rand -hex 4)-$(openssl rand -hex 4)-$(openssl rand -hex 12)")
SHORT_ID=$(openssl rand -hex 8)

# --- [ 1. 暴力解锁模块 ] ---
echo -e "${BLUE}[1/6] 正在执行系统深度解锁 (解决所有 apt/dpkg 冲突)...${NC}"
systemctl stop unattended-upgrades apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
killall -9 apt apt-get dpkg 2>/dev/null || true
rm -f /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/cache/debconf/config.dat
# 修复可能处于中断状态的安装包
DEBIAN_FRONTEND=noninteractive dpkg --configure -a || true
echo -e "${GREEN}系统锁已强制解除。${NC}"

# --- [ 2. 透明化依赖安装 ] ---
echo -e "${BLUE}[2/6] 正在安装系统依赖 (透明跑码模式)...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update
# 强制忽略所有配置交互，直接按默认走
apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    curl wget lsof jq tar nginx ca-certificates iptables uuid-runtime openssl coreutils iptables-persistent

# --- [ 3. 内核加速 BBR ] ---
echo -e "${BLUE}[3/6] 正在配置 BBR 内核加速...${NC}"
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1 || true
fi

# --- [ 4. 交互输入 ] ---
echo -e "${YELLOW}--------------------------------------------------${NC}"
read -rp "请输入域名 (解析到此 IP): " DOMAIN
read -rp "请输入邮箱 (用于申请证书): " EMAIL
read -rp "是否开启 HY2 混淆? (y/n, 默认 n): " IS_OBFS
IS_OBFS=${IS_OBFS:-"n"}
echo -e "${YELLOW}--------------------------------------------------${NC}"

# --- [ 5. 部署 Sing-box 与 证书 ] ---
echo -e "${BLUE}[4/6] 正在通过 acme.sh 申请 TLS 证书...${NC}"
curl https://get.acme.sh | sh -s -- --nocron || true
/root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
mkdir -p "$CERT_DIR"
/root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone || /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --nginx
/root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --key-file "$CERT_DIR/server.key" --fullchain-file "$CERT_DIR/server.crt"

echo -e "${BLUE}[5/6] 部署 Sing-box 核心配置...${NC}"
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
      "type": "hysteria2", "tag": "hy2-in", "listen": "::", "listen_port": 5443,
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

# Nginx 伪装站配置
cat > "$NGINX_CONF" <<EOF
server {
    listen 127.0.0.1:$RANDOM_PORT;
    server_name _;
    location / { root /var/www/html; index index.html; }
}
EOF
systemctl restart nginx

# --- [ 6. 端口转发与服务激活 ] ---
echo -e "${BLUE}[6/6] 配置重定向并启动服务...${NC}"
iptables -t nat -A PREROUTING -p udp --dport 443 -j REDIRECT --to-ports 5443
if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -t nat -A PREROUTING -p udp --dport 443 -j REDIRECT --to-ports 5443 2>/dev/null || true
fi
netfilter-persistent save
systemctl enable --now sing-box

echo -e "${GREEN}==================================================${NC}"
echo -e "部署成功！"
echo -e "UUID: ${BLUE}$UUID${NC}"
echo -e "Reality 公钥: ${BLUE}$PUB_KEY${NC}"
echo -e "==================================================${NC}"
