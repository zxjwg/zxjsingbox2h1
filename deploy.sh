#!/usr/bin/env bash
# =================================================================
# 项目：Sing-box 自动化管理系统 (V8.8 终极兼容版)
# 修复：解决 PrivateKey 无空格提取失败 / 补全所有模块
# =================================================================

set -e

# --- [ 0. 基础变量 ] ---
RED='\033[0;31m' && GREEN='\033[0;32m' && YELLOW='\033[0;33m' && BLUE='\033[0;34m' && NC='\033[0m'
CONF_DIR="/etc/sing-box"
CERT_DIR="/etc/v2ray-agent/tls"
ALIAS_PATH="/usr/bin/zxj2h1"
IP=$(curl -s http://checkip.amazonaws.com || echo "你的IP")

# --- [ 1. 性能优化模块 ] ---
optimize_system() {
    echo -e "${BLUE}正在优化内核 BBR 加速...${NC}"
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
    fi
    echo -e "${GREEN}BBR 优化完成！${NC}"
    read -rp "按回车键返回..." && main_menu
}

# --- [ 2. 核心部署模块 ] ---
install_singbox() {
    echo -e "${BLUE}[1/4] 安装依赖...${NC}"
    apt-get update && apt-get install -y jq uuid-runtime qrencode coreutils openssl socat tar wget curl
    
    read -rp "请输入域名: " DOMAIN
    read -rp "请输入邮箱: " EMAIL

    # 证书申请
    if [ ! -f "$CERT_DIR/server.crt" ]; then
        curl https://get.acme.sh | sh -s email="$EMAIL" || true
        /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        systemctl stop nginx 2>/dev/null || true
        /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone
        mkdir -p "$CERT_DIR"
        /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --key-file "$CERT_DIR/server.key" --fullchain-file "$CERT_DIR/server.crt"
    fi

    echo -e "${BLUE}[2/4] 下载 Sing-box...${NC}"
    rm -f /usr/bin/sing-box
    ARCH=$(uname -m); [ "$ARCH" == "x86_64" ] && SB_ARCH="amd64" || SB_ARCH="arm64"
    VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//')
    wget -qO sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${SB_ARCH}.tar.gz"
    tar -zxf sing-box.tar.gz && find . -name sing-box -type f -exec mv -f {} /usr/bin/sing-box \;
    chmod +x /usr/bin/sing-box && rm -rf sing-box.tar.gz sing-box-*

    # --- 修复：兼容 PrivateKey 和 Private key 两种输出格式 ---
    echo -e "${BLUE}[3/4] 提取 Reality 密钥...${NC}"
    RE_OUT=$(/usr/bin/sing-box generate reality-keypair)
    # 使用 awk 直接打印每行最后一个字段，无视前面是否有空格或冒号
    PRIV_KEY=$(echo "$RE_OUT" | awk '/Private/ {print $NF}')
    PUB_KEY=$(echo "$RE_OUT" | awk '/Public/ {print $NF}')
    
    if [[ -z "$PUB_KEY" ]]; then echo -e "${RED}提取失败！输出为：$RE_OUT${NC}"; exit 1; fi
    mkdir -p "$CONF_DIR"
    echo "$PUB_KEY" > "$CONF_DIR/pub.key"

    UUID=$(uuidgen)
    SID=$(openssl rand -hex 8)
    RAND_PORT=$(shuf -i 10000-60000 -n 1)

    echo -e "${BLUE}[4/4] 写入配置...${NC}"
    cat > "$CONF_DIR/config.json" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless", "tag": "reality-in", "listen": "::", "listen_port": 443,
      "users": [{"uuid": "$UUID", "flow": "xtls-rprx-vision"}],
      "tls": { "enabled": true, "server_name": "www.microsoft.com", "reality": { "enabled": true, "handshake": { "server": "127.0.0.1", "server_port": $RAND_PORT }, "private_key": "$PRIV_KEY", "short_id": ["$SID"] } }
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
    # 启动服务
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
    echo -e "${GREEN}部署完成！请返回菜单选 3 查看。${NC}"
    read -p "按回车返回..." && main_menu
}

# --- [ 3. 查看配置 ] ---
show_config() {
    clear
    if [ ! -f "$CONF_DIR/config.json" ]; then echo -e "${RED}未安装。${NC}"; sleep 2; main_menu; fi
    UUID=$(jq -r '.inbounds[0].users[0].uuid' "$CONF_DIR/config.json")
    PUB_KEY=$(cat "$CONF_DIR/pub.key" 2>/dev/null || echo "MISSING")
    SID=$(jq -r '.inbounds[0].tls.reality.short_id[0]' "$CONF_DIR/config.json")
    DOMAIN=$(jq -r '.inbounds[1].tls.server_name' "$CONF_DIR/config.json")
    VLESS="vless://$UUID@$IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=$PUB_KEY&sid=$SID#Reality_$IP"
    HY2="hysteria2://$UUID@$IP:8443?sni=$DOMAIN&alpn=h3&insecure=0#HY2_$IP"
    echo -e "${YELLOW}Reality:${NC}\n${BLUE}$VLESS${NC}"
    qrencode -t UTF8 "$VLESS"
    echo -e "\n${YELLOW}Hy2:${NC}\n${BLUE}$HY2${NC}"
    qrencode -t UTF8 "$HY2"
    read -p "按回车返回..." && main_menu
}

# --- [ 4. Hy2 优化 ] ---
hy2_tuning() {
    echo -e "${BLUE}优化 Hy2...${NC}"
    jq '.inbounds |= map(if .tag == "hy2-in" then . + {"mtu": 1280, "hop": true} else . end)' \
        "$CONF_DIR/config.json" > /tmp/sb.json && mv /tmp/sb.json "$CONF_DIR/config.json"
    systemctl restart sing-box
    echo -e "${GREEN}完成！放行 UDP 8000-9000 端口。${NC}"
    read -p "按回车返回..." && main_menu
}

# --- [ 5. 诊断 ] ---
debug_network() {
    clear
    echo -e "${YELLOW}--- 网络状态 ---${NC}"
    lsof -i:443 && lsof -i:8443 || echo "未监听"
    read -p "按回车返回..." && main_menu
}

# --- [ 6. 主菜单 ] ---
main_menu() {
    clear
    echo -e "${BLUE}==================================================${NC}"
    echo -e "      不正经的科学 - Sing-box 管理系统 V8.8       "
    echo -e "${BLUE}==================================================${NC}"
    echo -e "  ${GREEN}1.${NC} 开启 BBR 加速"
    echo -e "  ${GREEN}2.${NC} 一键部署节点 (Reality + HY2)"
    echo -e "  ${GREEN}3.${NC} 查看节点信息/二维码"
    echo -e "  ${GREEN}4.${NC} HY2 性能调优"
    echo -e "  ${YELLOW}5.${NC} 深度网络诊断"
    echo -e "  ${RED}0.${NC} 退出"
    echo -e "${BLUE}==================================================${NC}"
    read -rp "选择 [0-5]: " num
    case "$num" in
        1) optimize_system ;; 2) install_singbox ;; 3) show_config ;;
        4) hy2_tuning ;; 5) debug_network ;; 0) exit 0 ;; *) main_menu ;;
    esac
}

echo "bash <(curl -Ls https://raw.githubusercontent.com/zxjwg/zxjsingbox2h1/refs/heads/main/deploy.sh)" > "$ALIAS_PATH"
chmod +x "$ALIAS_PATH"
main_menu
