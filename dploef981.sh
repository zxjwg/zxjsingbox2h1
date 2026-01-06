#!/usr/bin/env bash
# =================================================================
# 项目：Sing-box 自动化管理系统 (V9.8.1 黄金全通版)
# 特点：暴力清障 / 证书自愈 / 修复 JQ 挂起 / 微软直连
# =================================================================

set -e
RED='\033[0;31m' && GREEN='\033[0;32m' && YELLOW='\033[0;33m' && BLUE='\033[0;34m' && NC='\033[0m'
CONF_DIR="/etc/sing-box"
CERT_DIR="/etc/v2ray-agent/tls"
ALIAS_PATH="/usr/bin/zxj2h1"
IP=$(curl -s http://checkip.amazonaws.com || echo "你的IP")

# --- [ 1. 系统加固：清空拦截规则 ] ---
clear_all_firewalls() {
    echo -e "${BLUE}正在初始化系统环境：释放端口并重置内部防火墙...${NC}"
    apt-get update && apt-get install -y iptables psmisc jq uuid-runtime qrencode openssl socat tar wget curl lsof
    
    # 暴力重置内部防火墙为全放通模式
    iptables -P INPUT ACCEPT && iptables -P FORWARD ACCEPT && iptables -P OUTPUT ACCEPT
    iptables -F && iptables -X
    
    # 强制杀死抢占 80/443 的残留进程
    systemctl stop nginx 2>/dev/null || true
    fuser -k 80/tcp 443/tcp 2>/dev/null || true
}

# --- [ 2. 部署模块：证书与核心安装 ] ---
install_singbox() {
    clear_all_firewalls
    echo -e "${BLUE}[1/4] 验证域名信息...${NC}"
    
    # 智能提取域名：优先读取现有配置，没有再询问
    if [ -f "$CONF_DIR/config.json" ]; then
        DOMAIN=$(jq -r '.inbounds[1].tls.server_name' "$CONF_DIR/config.json")
    fi
    [ -z "$DOMAIN" ] || [ "$DOMAIN" == "null" ] && read -rp "请输入域名: " DOMAIN
    read -rp "请输入邮箱: " EMAIL

    # 证书申请逻辑 (验证 80 端口)
    if [ ! -f "$CERT_DIR/server.crt" ]; then
        echo -e "${YELLOW}证书未就绪，正在通过 80 端口申请...${NC}"
        iptables -I INPUT -p tcp --dport 80 -j ACCEPT
        [ ! -f "/root/.acme.sh/acme.sh" ] && curl https://get.acme.sh | sh -s email="$EMAIL" || true
        /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        if ! /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --force; then
            echo -e "${RED}致命错误：证书申请超时。请检查云面板 80 端口 Ingress (入站) 规则！${NC}"
            exit 1
        fi
        mkdir -p "$CERT_DIR"
        /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --key-file "$CERT_DIR/server.key" --fullchain-file "$CERT_DIR/server.crt"
    else
        echo -e "${GREEN}检测到现有证书，跳过申请环节。${NC}"
    fi

    echo -e "${BLUE}[2/4] 安装 Sing-box 二进制核心...${NC}"
    ARCH=$(uname -m); [ "$ARCH" == "x86_64" ] && SB_ARCH="amd64" || SB_ARCH="arm64"
    VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//')
    wget -qO sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${SB_ARCH}.tar.gz"
    tar -zxf sing-box.tar.gz && find . -name sing-box -type f -exec mv -f {} /usr/bin/sing-box \;
    chmod +x /usr/bin/sing-box && rm -rf sing-box.tar.gz sing-box-*

    # 生成 Reality 密钥与 UUID
    RE_OUT=$(/usr/bin/sing-box generate reality-keypair)
    PRIV_KEY=$(echo "$RE_OUT" | awk '/Private/ {print $NF}' | tr -d '\r\n ')
    PUB_KEY=$(echo "$RE_OUT" | awk '/Public/ {print $NF}' | tr -d '\r\n ')
    mkdir -p "$CONF_DIR" && echo "$PUB_KEY" > "$CONF_DIR/pub.key"
    UUID=$(uuidgen) && SID=$(openssl rand -hex 8)

    # 写入配置：VLESS Reality (443) + HY2 (8443)
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
    # 注册并启动系统服务
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
    echo -e "${GREEN}部署完成！即将生成配置信息...${NC}"
    sleep 2 && show_config
}

# --- [ 3. 展示模块：修复 JQ 路径 BUG ] ---
show_config() {
    clear
    if [ ! -f "$CONF_DIR/config.json" ]; then echo -e "${RED}未发现配置文件。${NC}"; sleep 2; main_menu; fi
    
    # 【核心修复】为 jq 增加具体的路径参数，防止挂起
    UUID=$(jq -r '.inbounds[0].users[0].uuid' "$CONF_DIR/config.json")
    PUB_KEY=$(cat "$CONF_DIR/pub.key")
    SID=$(jq -r '.inbounds[0].tls.reality.short_id[0]' "$CONF_DIR/config.json")
    DOMAIN=$(jq -r '.inbounds[1].tls.server_name' "$CONF_DIR/config.json")

    VLESS="vless://$UUID@$IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=$PUB_KEY&sid=$SID#Reality_Direct"
    HY2="hysteria2://$UUID@$IP:8443?sni=$DOMAIN&alpn=h3&insecure=0#HY2_$IP"
    
    echo -e "${YELLOW}Reality (TCP 443 - 微软直连):${NC}\n$VLESS" && qrencode -t UTF8 "$VLESS"
    echo -e "\n${YELLOW}Hysteria 2 (UDP 8443 - 域名加速):${NC}\n$HY2" && qrencode -t UTF8 "$HY2"
    echo -e "${BLUE}按回车键返回菜单...${NC}"
    read
    main_menu
}

# --- [ 4. 诊断与主控 ] ---
main_menu() {
    clear
    echo -e "${BLUE}==================================================${NC}"
    echo -e "      不正经的科学 - Sing-box 黄金稳定版 V9.8.1   "
    echo -e "${BLUE}==================================================${NC}"
    echo -e "  ${GREEN}1.${NC} 内核优化 (BBR + UDP 调优)"
    echo -e "  ${GREEN}2.${NC} 一键全新安装 (Reality + HY2)"
    echo -e "  ${GREEN}3.${NC} 查看节点配置与二维码"
    echo -e "  ${YELLOW}4.${NC} 查看实时运行日志"
    echo -e "  ${RED}0.${NC} 退出脚本"
    read -rp "请选择: " num
    case "$num" in
        1) optimize_system ;; 
        2) install_singbox ;; 
        3) show_config ;; 
        4) journalctl -u sing-box --no-pager -n 20 && read -p "按回车继续..." && main_menu ;;
        0) exit 0 ;; *) main_menu ;;
    esac
}

optimize_system() {
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
    fi
    echo -e "${GREEN}BBR 加速已开启。${NC}"; sleep 1; main_menu
}

# 快捷词
echo "bash <(curl -Ls https://raw.githubusercontent.com/zxjwg/zxjsingbox2h1/refs/heads/main/deploy.sh)" > "$ALIAS_PATH"
chmod +x "$ALIAS_PATH" && main_menu
