#!/bin/bash

# =================================================================
# 项目：Sing-box 自动化运维系统 (YouTube 演示专用)
# 功能：BBR/证书/Nginx回落/HY2(可选混淆)/一键回滚
# =================================================================

# --- [ 0. 全局变量与配色 ] ---
CONF_DIR="/etc/sing-box"
CERT_DIR="/etc/v2ray-agent/tls"
NGINX_CONF="/etc/nginx/sites-available/default"
RAND_PORT=$(shuf -i 10000-60000 -n 1) 
UUID=$(cat /proc/sys/kernel/random/uuid)
RED='\033[0;31m' && GREEN='\033[0;32m' && BLUE='\033[0;34m' && NC='\033[0m'

# --- [ 1. 基础引擎模块 ] ---
function init_engine() {
    echo -e "${BLUE}[1/6] 开启内核加速 (BBR) 并同步系统工具...${NC}"
    # 写入并生效 BBR 优化
    sed -i '/net.core/d' /etc/sysctl.conf && sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p > /dev/null
    apt update && apt install -y curl socat wget jq lsof tar nginx
}

# --- [ 2. 原子化备份模块 ] ---
function backup_environment() {
    echo -e "${BLUE}[2/6] 正在执行系统环境原子备份...${NC}"
    if [ -f "$NGINX_CONF" ] && [ ! -f "${NGINX_CONF}.orig" ]; then
        cp "$NGINX_CONF" "${NGINX_CONF}.orig"
    fi
}

# --- [ 3. 证书管理中心 ] ---
function cert_manager() {
    local domain=$1 && local email=$2
    echo -e "${BLUE}[3/6] 正在申请 Let's Encrypt 证书...${NC}"
    curl https://get.acme.sh | sh -s email="$email"
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    mkdir -p "$CERT_DIR"
    # 智能选择申请模式
    if lsof -i :80 > /dev/null; then
        ~/.acme.sh/acme.sh --issue -d "$domain" --nginx
    else
        ~/.acme.sh/acme.sh --issue -d "$domain" --standalone
    fi
    ~/.acme.sh/acme.sh --install-cert -d "$domain" \
        --key-file "$CERT_DIR/server.key" \
        --fullchain-file "$CERT_DIR/server.crt"
}

# --- [ 4. Nginx 变阵模块 ] ---
function nginx_adapter() {
    echo -e "${BLUE}[4/6] 正在配置 Nginx 前端回落监听...${NC}"
    cat <<EOF > "$NGINX_CONF"
server {
    listen 127.0.0.1:$RAND_PORT;
    server_name _;
    location / { root /var/www/html; index index.html; }
}
EOF
    systemctl restart nginx
}

# --- [ 5. Sing-box 部署模块 ] ---
function singbox_deploy() {
    echo -e "${BLUE}[5/6] 正在安装 Sing-box 核心并生成配置...${NC}"
    bash <(curl -Ls https://raw.githubusercontent.com/sagernet/sing-box/main/install.sh)
    
    RE_KEYS=$(/usr/bin/sing-box generate reality-keypair)
    PUB_KEY=$(echo "$RE_KEYS" | grep "Public key" | awk '{print $3}')
    PRIV_KEY=$(echo "$RE_KEYS" | grep "Private key" | awk '{print $3}')

    # 处理 HY2 混淆逻辑：默认不开启
    HY2_OBFS=""
    if [[ "$ENABLE_OBFS" == "y" || "$ENABLE_OBFS" == "Y" ]]; then
        HY2_OBFS=', "obfs": {"type": "salamander", "password": "unserionssss66688"}'
    fi

    cat <<EOF > "$CONF_DIR/config.json"
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::",
      "listen_port": 443,
      "users": [{"uuid": "$UUID", "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": true,
        "server_name": "www.microsoft.com",
        "reality": {
          "enabled": true,
          "handshake": { "server": "127.0.0.1", "server_port": $RAND_PORT },
          "private_key": "$PRIV_KEY",
          "short_id": ["6ba85179e30d4fc2"]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": 443 ${HY2_OBFS},
      "up_mbps": 120,
      "down_mbps": 120,
      "users": [{"password": "$UUID"}],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "alpn": ["h3"],
        "certificate_path": "$CERT_DIR/server.crt",
        "key_path": "$CERT_DIR/server.key"
      }
    }
  ],
  "outbounds": [{"type": "direct"}]
}
EOF
    /usr/bin/sing-box check -c "$CONF_DIR/config.json" && systemctl enable --now sing-box
}

# --- [ 6. 深度回滚模块 ] ---
function rollback() {
    echo -e "${RED}正在启动一键回滚，移除所有修改...${NC}"
    systemctl stop sing-box 2>/dev/null
    rm -rf "$CONF_DIR" "$CERT_DIR" /usr/local/bin/sing-box /etc/systemd/system/sing-box.service
    if [ -f "${NGINX_CONF}.orig" ]; then
        mv "${NGINX_CONF}.orig" "$NGINX_CONF"
        systemctl restart nginx
    fi
    echo -e "${GREEN}系统已恢复至执行前的纯净状态。${NC}"
}

# --- [ 主入口 ] ---
clear
echo -e "${GREEN}Sing-box 自动化运维系统 v2.0${NC}"
echo "---------------------------"
echo "1. 快速安装 (Reality + HY2)"
echo "2. 一键回滚 (卸载并恢复原样)"
echo "3. 退出"
read -p "选择: " MAIN_OP

if [ "$MAIN_OP" == "2" ]; then rollback; exit 0; fi
if [ "$MAIN_OP" != "1" ]; then exit 0; fi

read -p "请输入域名: " DOMAIN
read -p "请输入邮箱: " EMAIL
read -p "是否开启 HY2 混淆(obfs)? 可能会导致卡顿 (y/n, 默认 n): " ENABLE_OBFS
ENABLE_OBFS=${ENABLE_OBFS:-"n"}

init_engine && backup_environment
cert_manager "$DOMAIN" "$EMAIL"
nginx_adapter
singbox_deploy

echo -e "${GREEN}======================================"
echo -e "部署成功！您的专属节点信息："
echo -e "UUID: $UUID"
echo -e "Reality 公钥: $PUB_KEY"
echo -e "HY2 端口: 443 (UDP) | 混淆: ${ENABLE_OBFS}"
echo -e "======================================${NC}"
