#!/usr/bin/env bash
# =================================================================
# 项目：Sing-box 自动化管理系统 (V9.2 架构修复版)
# 修复：移除 JSON 无效字段 mtu/hop / 修复服务崩溃 / 补全所有函数
# =================================================================

set -e

# --- [ 0. 基础变量 ] ---
RED='\033[0;31m' && GREEN='\033[0;32m' && YELLOW='\033[0;33m' && BLUE='\033[0;34m' && NC='\033[0m'
CONF_DIR="/etc/sing-box"
CERT_DIR="/etc/v2ray-agent/tls"
ALIAS_PATH="/usr/bin/zxj2h1"
IP=$(curl -s http://checkip.amazonaws.com || echo "你的IP")

# --- [ 1. 性能优化：内核 BBR ] ---
optimize_system() {
    echo -e "${BLUE}正在优化内核网络性能...${NC}"
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        # 针对 UDP (Hy2) 调优：增加缓冲区限制
        echo "net.core.rmem_max=67108864" >> /etc/sysctl.conf
        echo "net.core.wmem_max=67108864" >> /etc/sysctl.conf
        sysctl -p
    fi
    echo -e "${GREEN}内核 BBR 与 UDP 缓冲区已优化。${NC}"
    read -rp "按回车键返回..." && main_menu
}

# --- [ 2. 核心部署：修复 JSON 结构 ] ---
install_singbox() {
    echo -e "${BLUE}[1/4] 安装依赖...${NC}"
    apt-get update && apt-get install -y jq uuid-runtime qrencode openssl socat tar wget curl lsof
    
    read -rp "请输入域名: " DOMAIN
    read -rp "请输入邮箱: " EMAIL

    # 证书处理 (逻辑保持稳定)
    if [ ! -f "$CERT_DIR/server.crt" ]; then
        curl https://get.acme.sh | sh -s email="$EMAIL" || true
        /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        systemctl stop nginx 2>/dev/null || true
        /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone
        mkdir -p "$CERT_DIR"
        /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --key-file "$CERT_DIR/server.key" --fullchain-file "$CERT_DIR/server.crt"
    fi

    echo -e "${BLUE}[2/4] 安装核心程序...${NC}"
    ARCH=$(uname -m); [ "$ARCH" == "x86_64" ] && SB_ARCH="amd64" || SB_ARCH="arm64"
    VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//')
    wget -qO sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${SB_ARCH}.tar.gz"
    tar -zxf sing-box.tar.gz && find . -name sing-box -type f -exec mv -f {} /usr/bin/sing-box \;
    chmod +x /usr/bin/sing-box && rm -rf sing-box.tar.gz sing-box-*

    # 密钥提取 (模糊匹配版)
    RE_OUT=$(/usr/bin/sing-box generate reality-keypair)
    PRIV_KEY=$(echo "$RE_OUT" | awk '/Private/ {print $NF}')
    PUB_KEY=$(echo "$RE_OUT" | awk '/Public/ {print $NF}')
    mkdir -p "$CONF_DIR" && echo "$PUB_KEY" > "$CONF_DIR/pub.key"

    UUID=$(uuidgen) && SID=$(openssl rand -hex 8) && RAND_PORT=$(shuf -i 10000-60000 -n 1)

    # 写入配置：移除了会导致报错的 mtu 和 hop 字段
    echo -e "${BLUE}[3/4] 正在写入合规 JSON 配置...${NC}"
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

    # 启动服务并清理冲突
    systemctl stop nginx 2>/dev/null || true
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
    echo -e "${GREEN}部署成功！[选项 3] 查看链接，[选项 5] 验证状态。${NC}"
    read -p "按回车继续..." && main_menu
}

# --- [ 3. 展示配置 ] ---
show_config() {
    clear
    if [ ! -f "$CONF_DIR/config.json" ]; then echo "未安装"; sleep 1; main_menu; fi
    UUID=$(jq -r '.inbounds[0].users[0].uuid' "$CONF_DIR/config.json")
    PUB_KEY=$(cat "$CONF_DIR/pub.key" 2>/dev/null)
    SID=$(jq -r '.inbounds[0].tls.reality.short_id[0]' "$CONF_DIR/config.json")
    DOMAIN=$(jq -r '.inbounds[1].tls.server_name' "$CONF_DIR/config.json")
    
    echo -e "${YELLOW}Reality:${NC}"
    VLESS="vless://$UUID@$IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=$PUB_KEY&sid=$SID#Reality_$IP"
    echo "$VLESS" && qrencode -t UTF8 "$VLESS"
    
    echo -e "\n${YELLOW}Hy2:${NC}"
    HY2="hysteria2://$UUID@$IP:8443?sni=$DOMAIN&alpn=h3&insecure=0#HY2_$IP"
    echo "$HY2" && qrencode -t UTF8 "$HY2"
    read -p "按回车返回..." && main_menu
}

# --- [ 4. 诊断工具 ] ---
debug_network() {
    clear
    echo -e "${YELLOW}--- 网络状态自检 ---${NC}"
    echo -e "443 (Reality) 监听状态:" && lsof -i:443 || echo "未监听到 443 端口"
    echo -e "\n8443 (Hy2) 监听状态:" && lsof -i:8443 || echo "未监听到 8443 端口"
    echo -e "\n服务运行日志 (最近10条):" && journalctl -u sing-box --no-pager -n 10
    read -p "按回车返回..." && main_menu
}

# --- [ 5. 主菜单 ] ---
main_menu() {
    clear
    echo -e "${BLUE}==================================================${NC}"
    echo -e "      不正经的科学 - Sing-box 管理系统 V9.2       "
    echo -e "${BLUE}==================================================${NC}"
    echo -e "  ${GREEN}1.${NC} 优化系统性能 (BBR + UDP 缓存)"
    echo -e "  ${GREEN}2.${NC} 一键部署节点 (修复 JSON 崩溃问题)"
    echo -e "  ${GREEN}3.${NC} 查看当前节点信息/二维码"
    echo -e "  ${YELLOW}4.${NC} 深度网络诊断与日志查看"
    echo -e "  ${RED}0.${NC} 退出"
    read -rp "请选择: " num
    case "$num" in 1) optimize_system ;; 2) install_singbox ;; 3) show_config ;; 4) debug_network ;; 0) exit 0 ;; *) main_menu ;; esac
}

echo "bash <(curl -Ls https://raw.githubusercontent.com/zxjwg/zxjsingbox2h1/refs/heads/main/deploy.sh)" > "$ALIAS_PATH"
chmod +x "$ALIAS_PATH" && main_menu
