#!/usr/bin/env bash
# =================================================================
# 项目：Sing-box 自动化管理系统 (V9.7 终极通关版)
# 目标：彻底解决端口冲突、密钥提取与协议握手问题
# =================================================================

set -e

# --- [ 0. 基础变量 ] ---
RED='\033[0;31m' && GREEN='\033[0;32m' && YELLOW='\033[0;33m' && BLUE='\033[0;34m' && NC='\033[0m'
CONF_DIR="/etc/sing-box"
CERT_DIR="/etc/v2ray-agent/tls"
ALIAS_PATH="/usr/bin/zxj2h1"
IP=$(curl -s http://checkip.amazonaws.com || echo "你的IP")

# --- [ 1. 系统优化模块 ] ---
optimize_system() {
    echo -e "${BLUE}正在优化内核网络性能 (BBR + UDP 缓存)...${NC}"
    # 开启 BBR
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        # 针对 UDP 调优
        echo "net.core.rmem_max=67108864" >> /etc/sysctl.conf
        echo "net.core.wmem_max=67108864" >> /etc/sysctl.conf
        sysctl -p
    fi
    echo -e "${GREEN}系统优化完成！${NC}"
    read -rp "按回车键返回菜单..." && main_menu
}

# --- [ 2. 核心部署：暴力清障 + 微软直连 ] ---
install_singbox() {
    echo -e "${BLUE}正在执行暴力清障逻辑...${NC}"
    # 彻底封印 Nginx 并释放 443 端口
    systemctl disable --now nginx 2>/dev/null || true
    apt-get update && apt-get install -y psmisc jq uuid-runtime qrencode openssl socat tar wget curl lsof
    fuser -k 443/tcp 2>/dev/null || true
    
    # 放行系统防火墙
    iptables -I INPUT -p tcp --dport 443 -j ACCEPT
    iptables -I INPUT -p udp --dport 8443 -j ACCEPT

    read -rp "请输入解析到本机的域名: " DOMAIN
    read -rp "请输入邮箱: " EMAIL

    # 证书申请 (HY2 使用)
    if [ ! -f "$CERT_DIR/server.crt" ]; then
        curl https://get.acme.sh | sh -s email="$EMAIL" || true
        /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone
        mkdir -p "$CERT_DIR"
        /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --key-file "$CERT_DIR/server.key" --fullchain-file "$CERT_DIR/server.crt"
    fi

    # 安装二进制
    ARCH=$(uname -m); [ "$ARCH" == "x86_64" ] && SB_ARCH="amd64" || SB_ARCH="arm64"
    VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//')
    wget -qO sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${SB_ARCH}.tar.gz"
    tar -zxf sing-box.tar.gz && find . -name sing-box -type f -exec mv -f {} /usr/bin/sing-box \;
    chmod +x /usr/bin/sing-box && rm -rf sing-box.tar.gz sing-box-*

    # 密钥提取 (兼容版)
    RE_OUT=$(/usr/bin/sing-box generate reality-keypair)
    PRIV_KEY=$(echo "$RE_OUT" | awk '/Private/ {print $NF}' | tr -d '\r\n ')
    PUB_KEY=$(echo "$RE_OUT" | awk '/Public/ {print $NF}' | tr -d '\r\n ')
    mkdir -p "$CONF_DIR" && echo "$PUB_KEY" > "$CONF_DIR/pub.key"

    UUID=$(uuidgen) && SID=$(openssl rand -hex 8) && RAND_PORT=$(shuf -i 10000-60000 -n 1)

    # 写入配置：微软直连方案
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
    # 启动服务
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
    echo -e "${GREEN}部署完成！请重新扫码以对齐密钥。${NC}"
    read -p "按回车返回..." && main_menu
}

# --- [ 3. 展示配置：从 JSON 实时提取 ] ---
show_config() {
    clear
    if [ ! -f "$CONF_DIR/config.json" ]; then echo -e "${RED}未安装服务。${NC}"; sleep 1; main_menu; fi
    UUID=$(jq -r '.inbounds[0].users[0].uuid' "$CONF_DIR/config.json")
    PUB_KEY=$(cat "$CONF_DIR/pub.key" 2>/dev/null)
    SID=$(jq -r '.inbounds[0].tls.reality.short_id[0]' "$CONF_DIR/config.json")
    DOMAIN=$(jq -r '.inbounds[1].tls.server_name' "$CONF_DIR/config.json")
    
    echo -e "${YELLOW}Reality (TCP 443):${NC}"
    VLESS="vless://$UUID@$IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=$PUB_KEY&sid=$SID#Reality_Direct"
    echo -e "${BLUE}$VLESS${NC}"
    qrencode -t UTF8 "$VLESS"
    
    echo -e "\n${YELLOW}Hysteria 2 (UDP 8443):${NC}"
    HY2="hysteria2://$UUID@$IP:8443?sni=$DOMAIN&alpn=h3&insecure=0#HY2_$IP"
    echo -e "${BLUE}$HY2${NC}"
    qrencode -t UTF8 "$HY2"
    read -p "按回车键返回..." && main_menu
}

# --- [ 4. 诊断工具：实时日志 ] ---
debug_network() {
    clear
    echo -e "${YELLOW}--- 实时运行日志 (最后 15 条) ---${NC}"
    journalctl -u sing-box --no-pager -n 15
    echo -e "\n${YELLOW}--- 端口监听状态 ---${NC}"
    lsof -i:443 && lsof -i:8443 || echo "未监听到指定端口"
    read -p "按回车键返回..." && main_menu
}

# --- [ 5. 交互主菜单 ] ---
main_menu() {
    clear
    echo -e "${BLUE}==================================================${NC}"
    echo -e "      不正经的科学 - Sing-box 终极管理系统 V9.7       "
    echo -e "${BLUE}==================================================${NC}"
    echo -e "  ${GREEN}1.${NC} 优化系统性能 (BBR + UDP 调优)"
    echo -e "  ${GREEN}2.${NC} 彻底清障并一键部署 (Reality 直连)"
    echo -e "  ${GREEN}3.${NC} 查看最新节点配置/二维码"
    echo -e "  ${YELLOW}4.${NC} 深度网络诊断与实时日志"
    echo -e "  ${RED}0.${NC} 退出脚本"
    echo -e "${BLUE}==================================================${NC}"
    read -rp "请选择 [0-4]: " num
    case "$num" in
        1) optimize_system ;; 2) install_singbox ;; 3) show_config ;;
        4) debug_network ;; 0) exit 0 ;; *) main_menu ;;
    esac
}

# 配置快捷唤醒词
echo "bash <(curl -Ls https://raw.githubusercontent.com/zxjwg/zxjsingbox2h1/refs/heads/main/deploy.sh)" > "$ALIAS_PATH"
chmod +x "$ALIAS_PATH" && main_menu
