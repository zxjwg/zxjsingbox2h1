#!/usr/bin/env bash

# =================================================================
# 项目：Sing-box 全能通用自动化部署系统 (V4.0 透明版)
# 适用：Debian 11/12, Ubuntu 20.04/22.04+ (各家 VPS 通用)
# 功能：暴力解锁/BBR/Nginx回落/Reality/HY2 (UDP转发)
# =================================================================

set -e # 报错即刻停止

# --- [ 0. 配色与全局变量 ] ---
RED='\033[0;31m' && GREEN='\033[0;32m' && BLUE='\033[0;34m' && YELLOW='\033[0;33m' && NC='\033[0m'
CONF_DIR="/etc/sing-box"
CERT_DIR="/etc/v2ray-agent/tls"
NGINX_CONF="/etc/nginx/sites-available/default"
RANDOM_PORT=$(shuf -i 10000-60000 -n 1 2>/dev/null || echo "37210")
HY2_PORT="5443"
UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$(openssl rand -hex 8)-$(openssl rand -hex 4)-$(openssl rand -hex 4)-$(openssl rand -hex 4)-$(openssl rand -hex 12)")
SHORT_ID=$(openssl rand -hex 8)

# --- [ 1. 暴力清理：解决所有“卡死”源头 ] ---
echo -e "${BLUE}[1/6] 正在执行暴力解锁，确保环境绝对纯净...${NC}"
# 1.1 杀掉所有占用 apt/dpkg 的进程
systemctl stop unattended-upgrades 2>/dev/null || true
killall -9 apt apt-get dpkg 2>/dev/null || true
# 1.2 物理删除所有锁文件
rm -f /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock
# 1.3 修复可能中断的安装状态
dpkg --configure -a || true
echo -e "${GREEN}系统锁已强制解除。${NC}"

# --- [ 2. 透明化依赖安装：不再隐藏任何报错 ] ---
echo -e "${BLUE}[2/6] 正在安装系统必备依赖，请观察跑码输出...${NC}"
apt-get update
# 安装核心工具，确保包含 coreutils (shuf)
apt-get install -y curl wget lsof jq tar nginx ca-certificates iptables uuid-runtime openssl coreutils iptables-persistent

# --- [ 3. 内核网络优化 (BBR) ] ---
echo -e "${BLUE}[3/6] 正在开启内核 BBR 加速...${NC}"
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1 || true
fi

# --- [ 4. 交互式输入：获取关键配置 ] ---
echo -e "${YELLOW}--------------------------------------------------${NC}"
read -rp "请输入解析到此服务器的域名: " DOMAIN
read -rp "请输入用于证书申请的邮箱: " EMAIL
read -rp "是否开启 HY2 混淆(obfs)? (y/n, 默认 n): " IS_OBFS
IS_OBFS=${IS_OBFS:-"n"}
echo -e "${YELLOW}--------------------------------------------------${NC}"

# --- [ 5. 证书申请与核心部署 ] ---
echo -e "${BLUE}[4/6] 正在申请 TLS 证书 (使用 acme.sh)...${NC}"
# 强制安装 acme.sh
curl https://get.acme.sh | sh -s -- --nocron || true
/root/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
mkdir -p "$CERT_DIR"
# 自动选择模式：优先 Standalone，失败则尝试 Nginx
/root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone || /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --nginx
/root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --key-file "$CERT_DIR/server.key" --fullchain-file "$CERT_DIR/server.crt"

echo -e "${BLUE}[5/6] 正在部署 Sing-box 核心配置...${NC}"
# 使用官方安装脚本
curl -fsSL https://raw.githubusercontent.com/sagernet/sing-box/main/install.sh | bash -s --

# 生成 Reality 密钥
RE_KEYS=$(/usr/bin/sing-box generate reality-keypair)
PRIV_KEY=$(echo "$RE_KEYS" | grep "Private key" | awk '{print $3}')
PUB_KEY=$(echo "$RE_KEYS" | grep "Public key" | awk '{print $3}')

# 处理 HY2 混淆块
OBFS_BLOCK=""
if [[ "$IS_OBFS" =~ ^[yY]$ ]]; then
    OBFS_BLOCK=", \"obfs\": {\"type\": \"salamander\", \"password\": \"unserionssss66688\"}"
fi

# 写入配置文件
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
      "type": "hysteria2", "tag": "hy2-in", "listen": "::", "listen_port": $HY2_PORT,
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

# 配置 Nginx 伪装回落站点
cat > "$NGINX_CONF" <<EOF
server {
    listen 127.0.0.1:$RANDOM_PORT;
    server_name _;
    location / { root /var/www/html; index index.html; }
}
EOF
systemctl restart nginx

# --- [ 6. 端口转发与服务启动 ] ---
echo -e "${BLUE}[6/6] 正在配置端口重定向并启动服务...${NC}"
# IPv4 UDP 转发
iptables -t nat -A PREROUTING -p udp --dport 443 -j REDIRECT --to-ports "$HY2_PORT"
# IPv6 UDP 转发 (适配支持 IPv6 的服务器)
if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -t nat -A PREROUTING -p udp --dport 443 -j REDIRECT --to-ports "$HY2_PORT" 2>/dev/null || true
fi
netfilter-persistent save
systemctl enable --now sing-box

echo -e "${GREEN}==================================================${NC}"
echo -e "部署成功！您的 YouTube 演示数据如下："
echo -e "UUID: ${BLUE}$UUID${NC}"
echo -e "Reality 公钥: ${BLUE}$PUB_KEY${NC}"
echo -e "Reality ShortID: ${BLUE}$SHORT_ID${NC}"
echo -e "HY2 本地端口: ${BLUE}$HY2_PORT (UDP 443 已自动重定向)${NC}"
echo -e "${GREEN}==================================================${NC}"
