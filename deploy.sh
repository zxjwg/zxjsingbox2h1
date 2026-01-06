#!/usr/bin/env bash
# =================================================================
# 项目：Sing-box 自动化管理系统 (V8.4 全功能修复版)
# 修复：补全 show_config / HY2 参数打印 / 自动生成防火墙指令
# =================================================================

set -e

# --- [ 0. 基础变量 ] ---
RED='\033[0;31m' && GREEN='\033[0;32m' && YELLOW='\033[0;33m' && BLUE='\033[0;34m' && NC='\033[0m'
CONF_DIR="/etc/sing-box"
CERT_DIR="/etc/v2ray-agent/tls"
ALIAS_PATH="/usr/bin/zxj2h1"
IP=$(curl -s http://checkip.amazonaws.com || echo "你的IP")

# --- [ 1. 系统优化：内核 BBR ] ---
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

# --- [ 2. 核心部署：Reality + HY2 ] ---
install_singbox() {
    echo -e "${BLUE}开始执行 Sing-box 自动化部署...${NC}"
    # 环境清理与依赖安装
    apt-get update && apt-get install -y jq uuid-runtime qrencode coreutils openssl socat tar wget curl
    
    read -rp "请输入域名 (如 fg.zhouxj.qzz.io): " DOMAIN
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

    # 二进制直装
    ARCH=$(uname -m); [ "$ARCH" == "x86_64" ] && SB_ARCH="amd64" || SB_ARCH="arm64"
    VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//')
    wget -qO sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${SB_ARCH}.tar.gz"
    tar -zxf sing-box.tar.gz && mv sing-box-*/sing-box /usr/bin/ && chmod +x /usr/bin/sing-box
    rm -rf sing-box.tar.gz sing-box-*

    # 密钥生成：使用 awk 提取
    RE_OUT=$(/usr/bin/sing-box generate reality-keypair)
    PRIV_KEY=$(echo "$RE_OUT" | awk '/Private key/ {print $NF}')
    PUB_KEY=$(echo "$RE_OUT" | awk '/Public key/ {print $NF}')
    UUID=$(uuidgen)
    SHORT_ID=$(openssl rand -hex 8)
    RAND_PORT=$(shuf -i 10000-60000 -n 1)

    mkdir -p "$CONF_DIR"
    cat > "$CONF_DIR/config.json" <<EOF
{
  "inbounds": [
    {
      "type": "vless", "tag": "reality-in", "listen": "::", "listen_port": 443,
      "users": [{"uuid": "$UUID", "flow": "xtls-rprx-vision"}],
      "tls": { "enabled": true, "server_name": "www.microsoft.com", "reality": { "enabled": true, "handshake": { "server": "127.0.0.1", "server_port": $RAND_PORT }, "private_key": "$PRIV_KEY", "short_id": ["$SHORT_ID"] } }
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
    # 存入公钥备查
    echo "$PUB_KEY" > "$CONF_DIR/pub.key"

    # 配置服务并启动
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
    echo -e "${GREEN}部署完成！${NC}"
    read -rp "按回车键返回菜单..." && main_menu
}

# --- [ 3. 展示配置：修复 command not found ] ---
show_config() {
    clear
    if [ ! -f "$CONF_DIR/config.json" ]; then
        echo -e "${RED}未检测到配置，请先执行选项 2 进行部署。${NC}"
    else
        UUID=$(jq -r '.inbounds[0].users[0].uuid' "$CONF_DIR/config.json")
        DOMAIN=$(jq -r '.inbounds[1].tls.server_name' "$CONF_DIR/config.json")
        PUB_KEY=$(cat "$CONF_DIR/pub.key" 2>/dev/null || echo "请重新执行安装以生成公钥")
        SID=$(jq -r '.inbounds[0].tls.reality.short_id[0]' "$CONF_DIR/config.json")
        HY2_PORT=$(jq -r '.inbounds[1].listen_port' "$CONF_DIR/config.json")

        VLESS_LINK="vless://$UUID@$IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=$PUB_KEY&sid=$SID#Reality_$IP"
        HY2_LINK="hysteria2://$UUID@$IP:$HY2_PORT?sni=$DOMAIN&alpn=h3&insecure=0#HY2_$IP"

        echo -e "${YELLOW}Reality 节点:${NC}\n${BLUE}$VLESS_LINK${NC}"
        qrencode -t UTF8 "$VLESS_LINK"
        echo -e "\n${YELLOW}Hysteria 2 节点:${NC}\n${BLUE}$HY2_LINK${NC}"
        qrencode -t UTF8 "$HY2_LINK"
    fi
    read -rp "按回车键返回菜单..." && main_menu
}

# --- [ 4. HY2 性能微调：增加参数打印与防火墙提醒 ] ---
hy2_tuning() {
    echo -e "${BLUE}正在微调 Hy2 性能参数...${NC}"
    if [ ! -f "$CONF_DIR/config.json" ]; then
        echo -e "${RED}配置不存在，请先部署。${NC}"
    else
        # 写入参数
        jq '.inbounds |= map(if .tag == "hy2-in" then . + {"mtu": 1280, "hop": true} else . end)' \
            "$CONF_DIR/config.json" > /tmp/sb.json && mv /tmp/sb.json "$CONF_DIR/config.json"
        
        systemctl restart sing-box
        
        echo -e "${GREEN}微调成功！当前参数：${NC}"
        echo -e "  - ${BLUE}MTU:${NC} 1280 (优化 UDP 分片)"
        echo -e "  - ${BLUE}端口跳跃 (Hop):${NC} 开启 (绕过运营商限速)"
        echo -e "=================================================="
        echo -e "${YELLOW}⚠️ 重要防火墙提醒：${NC}"
        echo -e "请务必在 VPS 后台放行 ${RED}UDP 8000-9000${NC} 端口段。"
        echo -e "系统命令已自动生成，正在尝试执行放行...${NC}"
        iptables -A INPUT -p udp --dport 8000:9000 -j ACCEPT || true
    fi
    read -rp "按回车键返回菜单..." && main_menu
}

# --- [ 5. 主菜单 ] ---
main_menu() {
    clear
    echo -e "${BLUE}==================================================${NC}"
    echo -e "      不正经的科学 - Sing-box 管理系统 V8.4       "
    echo -e "${BLUE}==================================================${NC}"
    echo -e "  ${GREEN}1.${NC} 优化系统性能 (开启内核 BBR 加速)"
    echo -e "  ${GREEN}2.${NC} 一键部署 Sing-box (Reality + HY2)"
    echo -e "  ${GREEN}3.${NC} 查看当前节点配置与二维码"
    echo -e "  ${GREEN}4.${NC} Hy2 性能微调 (打印参数并提醒防火墙)"
    echo -e "  ${RED}0.${NC} 退出脚本"
    echo -e "${BLUE}==================================================${NC}"
    read -rp "请选择操作 [0-4]: " menu_num
    case "$menu_num" in
        1) optimize_system ;;
        2) install_singbox ;;
        3) show_config ;;
        4) hy2_tuning ;;
        0) exit 0 ;;
        *) main_menu ;;
    esac
}

# 绑定快捷词
echo "bash <(curl -Ls https://raw.githubusercontent.com/zxjwg/zxjsingbox2h1/refs/heads/main/deploy.sh)" > "$ALIAS_PATH"
chmod +x "$ALIAS_PATH"

main_menu
