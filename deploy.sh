#!/usr/bin/env bash
# =================================================================
# 项目：Sing-box 自动化管理系统 (V9.8 证书自愈版)
# 修复：自动放行 80 端口 / 强制重置 iptables / 修正证书验证
# =================================================================

set -e
RED='\033[0;31m' && GREEN='\033[0;32m' && YELLOW='\033[0;33m' && BLUE='\033[0;34m' && NC='\033[0m'
CONF_DIR="/etc/sing-box"
CERT_DIR="/etc/v2ray-agent/tls"
ALIAS_PATH="/usr/bin/zxj2h1"
IP=$(curl -s http://checkip.amazonaws.com || echo "你的IP")

# --- [ 1. 核心：系统级清障 ] ---
clear_all_firewalls() {
    echo -e "${BLUE}正在暴力清理系统内部防火墙拦截 (iptables)...${NC}"
    # 安装并确保 iptables 处于开放状态
    apt-get update && apt-get install -y iptables psmisc
    iptables -F && iptables -X
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    
    # 强制释放 80 和 443 端口占用
    systemctl stop nginx 2>/dev/null || true
    fuser -k 80/tcp 443/tcp 2>/dev/null || true
    echo -e "${GREEN}系统内部防火墙已全部放开。${NC}"
}

# --- [ 2. 部署模块：增加 80 端口验证逻辑 ] ---
install_singbox() {
    clear_all_firewalls
    echo -e "${BLUE}[1/4] 正在安装依赖...${NC}"
    apt-get install -y jq uuid-runtime qrencode openssl socat tar wget curl lsof

    read -rp "请输入域名: " DOMAIN
    read -rp "请输入邮箱: " EMAIL

    # 证书申请专用通道
    if [ ! -f "$CERT_DIR/server.crt" ]; then
        echo -e "${YELLOW}正在通过 80 端口验证申请证书...${NC}"
        # 再次确保 80 端口内部放行
        iptables -I INPUT -p tcp --dport 80 -j ACCEPT
        
        if [ ! -f "/root/.acme.sh/acme.sh" ]; then
            curl https://get.acme.sh | sh -s email="$EMAIL" || true
        fi
        /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        
        # 执行申请
        if ! /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --force; then
            echo -e "${RED}证书申请失败！通常是因为云面板未放行 TCP 80 端口。${NC}"
            exit 1
        fi
        
        mkdir -p "$CERT_DIR"
        /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --key-file "$CERT_DIR/server.key" --fullchain-file "$CERT_DIR/server.crt"
    fi

    echo -e "${BLUE}[2/4] 下载并安装二进制核心...${NC}"
    ARCH=$(uname -m); [ "$ARCH" == "x86_64" ] && SB_ARCH="amd64" || SB_ARCH="arm64"
    VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//')
    wget -qO sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${SB_ARCH}.tar.gz"
    tar -zxf sing-box.tar.gz && find . -name sing-box -type f -exec mv -f {} /usr/bin/sing-box \;
    chmod +x /usr/bin/sing-box && rm -rf sing-box.tar.gz sing-box-*

    # 密钥与 UUID 生成
    RE_OUT=$(/usr/bin/sing-box generate reality-keypair)
    PRIV_KEY=$(echo "$RE_OUT" | awk '/Private/ {print $NF}' | tr -d '\r\n ')
    PUB_KEY=$(echo "$RE_OUT" | awk '/Public/ {print $NF}' | tr -d '\r\n ')
    mkdir -p "$CONF_DIR" && echo "$PUB_KEY" > "$CONF_DIR/pub.key"
    UUID=$(uuidgen) && SID=$(openssl rand -hex 8) && RAND_PORT=$(shuf -i 10000-60000 -n 1)

    # 写入配置
    cat > "$CONF_DIR/config.json" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless", "tag": "vless-in", "listen": "::", "listen_port": 443,
      "users": [{"uuid": "$UUID", "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": true, "server_name": "www.microsoft.com",
        "reality": {
          "enabled": true,
          "handshake": { "server": "www.microsoft.com", "server_port": 443 },
          "private_key": "$PRIV_KEY", "short_id": ["$SID"]
        }
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
    systemctl stop sing-box 2>/dev/null || true
    systemctl restart sing-box || {
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
    }
    echo -e "${GREEN}部署完成！请检查选项 3 获取新二维码。${NC}"
    read -p "按回车返回..." && main_menu
}

# (其余 show_config, debug_network, optimize_system 保持不变)
