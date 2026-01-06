#!/usr/bin/env bash
# =================================================================
# 项目：Sing-box 自动化管理系统 (V9.8.1 修复版)
# 修复：补全 jq 路径 / 优化证书逻辑 / 移除不可见字符
# =================================================================

set -e
RED='\033[0;31m' && GREEN='\033[0;32m' && YELLOW='\033[0;33m' && BLUE='\033[0;34m' && NC='\033[0m'
CONF_DIR="/etc/sing-box"
CERT_DIR="/etc/v2ray-agent/tls"
ALIAS_PATH="/usr/bin/zxj2h1"
IP=$(curl -s http://checkip.amazonaws.com || echo "你的IP")

# --- [ 1. 系统级清障 ] ---
clear_all_firewalls() {
    echo -e "${BLUE}正在清理系统防火墙规则并释放端口...${NC}"
    apt-get update && apt-get install -y iptables psmisc tcpdump
    iptables -F && iptables -X
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    systemctl stop nginx 2>/dev/null || true
    fuser -k 80/tcp 443/tcp 2>/dev/null || true
}

# --- [ 2. 部署模块 ] ---
install_singbox() {
    clear_all_firewalls
    echo -e "${BLUE}[1/4] 安装依赖工具...${NC}"
    apt-get install -y jq uuid-runtime qrencode openssl socat tar wget curl lsof

    # 只有当变量为空时才询问，或者从现有配置中提取
    [ -z "$DOMAIN" ] && read -rp "请输入域名: " DOMAIN
    [ -z "$EMAIL" ] && read -rp "请输入邮箱: " EMAIL

    if [ ! -f "$CERT_DIR/server.crt" ]; then
        echo -e "${YELLOW}正在通过 80 端口申请证书...${NC}"
        iptables -I INPUT -p tcp --dport 80 -j ACCEPT
        [ ! -f "/root/.acme.sh/acme.sh" ] && curl https://get.acme.sh | sh -s email="$EMAIL" || true
        /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        if ! /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --force; then
            echo -e "${RED}申请失败！请检查云面板 80 入站(Ingress)规则。${NC}"
            exit 1
        fi
        mkdir -p "$CERT_DIR"
        /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --key-file "$CERT_DIR/server.key" --fullchain-file "$CERT_DIR/server.crt"
    fi

    echo -e "${BLUE}[2/4] 安装 Sing-box 核心...${NC}"
    ARCH=$(uname -m); [ "$ARCH" == "x86_64" ] && SB_ARCH="amd64" || SB_ARCH="arm64"
    VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//')
    wget -qO sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${SB_ARCH}.tar.gz"
    tar -zxf sing-box.tar.gz && find . -name sing-box -type f -exec mv -f {} /usr/bin/sing-box \;
    chmod +x /usr/bin/sing-box && rm -rf sing-box.tar.gz sing-box-*

    # 生成密钥对
    RE_OUT=$(/usr/bin/sing-box generate reality-keypair)
    PRIV_KEY=$(echo "$RE_OUT" | awk '/Private/ {print $NF}' | tr -d '\r\n ')
    PUB_KEY=$(echo "$RE_OUT" | awk '/Public/ {print $NF}' | tr -d '\r\n ')
    mkdir -p "$CONF_DIR" && echo "$PUB_KEY" > "$CONF_DIR/pub.key"
    UUID=$(uuidgen) && SID=$(openssl rand -hex 8)

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
    echo -e "${GREEN}部署完成！正在自动生成二维码...${NC}"
    sleep 2 && show_config
}

# --- [ 3. 展示与菜单 ] ---
show_config() {
    clear
    if [ ! -f "$CONF_DIR/config.json" ]; then echo -e "${RED}错误：配置文件不存在。${NC}"; sleep 2; main_menu; fi
    # 修复后的 jq 路径逻辑
    UUID=$(jq -r '.inbounds[0].users[0].uuid' "$CONF_DIR/config.json")
    PUB_KEY=$(cat "$CONF_DIR/pub.key")
    SID=$(jq -r '.inbounds[0].tls.reality.short_id[0]' "$CONF_DIR/config.json")
    DOMAIN=$(jq -r '.inbounds[1].tls.server_name' "$CONF_DIR/config.json")

    VLESS="vless://$UUID@$IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=$PUB_KEY&sid=$SID#Reality_Direct"
    HY2="hysteria2://$UUID@$IP:8443?sni=$DOMAIN&alpn=h3&insecure=0#HY2_$IP"
    
    echo -e "${YELLOW}Reality (TCP 443):${NC}\n$VLESS" && qrencode -t UTF8 "$VLESS"
    echo -e "\n${YELLOW}HY2 (UDP 8443):${NC}\n$HY2" && qrencode -t UTF8 "$HY2"
    echo -e "${BLUE}按回车键返回主菜单...${NC}"
    read
    main_menu
}

main_menu() {
    clear
    echo -e "${BLUE}==================================================${NC}"
    echo -e "      不正经的科学 - Sing-box 管理系统 V9.8.1     "
    echo -e "${BLUE}==================================================${NC}"
    echo -e "  ${GREEN}1.${NC} 开启 BBR 优化"
    echo -e "  ${GREEN}2.${NC} 一键部署节点 (自动生成二维码)"
    echo -e "  ${GREEN}3.${NC} 仅查看节点二维码"
    echo -e "  ${RED}0.${NC} 退出"
    read -rp "请选择 [0-3]: " num
    case "$num" in 1) optimize_system ;; 2) install_singbox ;; 3) show_config ;; 0) exit 0 ;; *) main_menu ;; esac
}

optimize_system() {
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p && echo -e "${GREEN}优化完成${NC}"; sleep 1; main_menu
}

# 快捷启动
main_menu
