#!/usr/bin/env bash
# =================================================================
# 项目：Sing-box 自动化管理系统 (V8.5 自检纠错版)
# 修复：公钥强制提取 / 配置文件自愈 / 深度诊断工具
# =================================================================

set -e

# --- [ 0. 变量定义 ] ---
RED='\033[0;31m' && GREEN='\033[0;32m' && YELLOW='\033[0;33m' && BLUE='\033[0;34m' && NC='\033[0m'
CONF_DIR="/etc/sing-box"
CERT_DIR="/etc/v2ray-agent/tls"
ALIAS_PATH="/usr/bin/zxj2h1"
IP=$(curl -s http://checkip.amazonaws.com || echo "你的IP")

# --- [ 1. 核心安装逻辑：增加强制校验 ] ---
install_singbox() {
    echo -e "${BLUE}[2/6] 正在执行一键部署...${NC}"
    # 环境清理与依赖
    apt-get update && apt-get install -y jq uuid-runtime qrencode coreutils openssl socat tar wget curl
    
    read -rp "请输入域名: " DOMAIN
    read -rp "请输入邮箱: " EMAIL

    # 证书处理 (逻辑同前，保持稳定)
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

    # --- 关键修复：强制公钥提取逻辑 ---
    echo -e "${BLUE}正在生成并强制提取 Reality 密钥...${NC}"
    /usr/bin/sing-box generate reality-keypair > /tmp/keys.txt
    PRIV_KEY=$(grep "Private key:" /tmp/keys.txt | awk '{print $NF}')
    PUB_KEY=$(grep "Public key:" /tmp/keys.txt | awk '{print $NF}')
    rm -f /tmp/keys.txt

    # 强制校验：如果公钥为空则立即终止，防止生成空配置
    if [[ -z "$PRIV_KEY" || -z "$PUB_KEY" ]]; then
        echo -e "${RED}致命错误：密钥提取失败！请检查 /usr/bin/sing-box 是否能正常运行。${NC}"
        exit 1
    fi
    echo "$PUB_KEY" > "$CONF_DIR/pub.key"

    UUID=$(uuidgen)
    SID=$(openssl rand -hex 8)
    RAND_PORT=$(shuf -i 10000-60000 -n 1)

    # 写入配置
    mkdir -p "$CONF_DIR"
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

    # 自检并启动
    /usr/bin/sing-box check -c "$CONF_DIR/config.json"
    systemctl restart sing-box || { echo -e "${RED}启动失败，请检查配置。${NC}"; exit 1; }
    echo -e "${GREEN}部署成功！请点选项 3 查看链接。${NC}"
    read -p "按回车返回..." && main_menu
}

# --- [ 2. 诊断工具：解决 HY2 不通的问题 ] ---
debug_network() {
    clear
    echo -e "${YELLOW}--- 网络连通性深度诊断 ---${NC}"
    echo -e "1. 检查 443 端口监听 (Reality):"
    lsof -i:443
    echo -e "\n2. 检查 8443 端口监听 (HY2):"
    lsof -i:8443
    echo -e "\n3. 检查系统 UDP 限制:"
    sysctl net.core.rmem_max
    echo -e "\n${BLUE}提示：如果端口正常但连不上，请务必去 VPS 后台开启 UDP 8443 端口！${NC}"
    read -p "按回车返回..." && main_menu
}

# --- [ 3. 展示配置 (补全逻辑) ] ---
show_config() {
    clear
    if [ ! -f "$CONF_DIR/config.json" ]; then
        echo -e "${RED}未安装服务。${NC}"; sleep 2; main_menu
    fi
    UUID=$(jq -r '.inbounds[0].users[0].uuid' "$CONF_DIR/config.json")
    PUB_KEY=$(cat "$CONF_DIR/pub.key" 2>/dev/null || echo "MISSING")
    SID=$(jq -r '.inbounds[0].tls.reality.short_id[0]' "$CONF_DIR/config.json")
    DOMAIN=$(jq -r '.inbounds[1].tls.server_name' "$CONF_DIR/config.json")
    
    echo -e "${YELLOW}VLESS Reality 链接:${NC}"
    LINK1="vless://$UUID@$IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=$PUB_KEY&sid=$SID#Reality_$IP"
    echo -e "${BLUE}$LINK1${NC}"
    qrencode -t UTF8 "$LINK1"
    
    echo -e "\n${YELLOW}Hysteria 2 链接:${NC}"
    LINK2="hysteria2://$UUID@$IP:8443?sni=$DOMAIN&alpn=h3&insecure=0#HY2_$IP"
    echo -e "${BLUE}$LINK2${NC}"
    qrencode -t UTF8 "$LINK2"
    read -p "按回车返回..." && main_menu
}

# --- [ 4. 主菜单 ] ---
main_menu() {
    clear
    echo -e "${BLUE}==================================================${NC}"
    echo -e "      不正经的科学 - Sing-box 管理系统 V8.5       "
    echo -e "${BLUE}==================================================${NC}"
    echo -e "  ${GREEN}1.${NC} 开启 BBR 加速"
    echo -e "  ${GREEN}2.${NC} 一键部署节点 (Reality + HY2)"
    echo -e "  ${GREEN}3.${NC} 查看节点信息/二维码"
    echo -e "  ${GREEN}4.${NC} HY2 性能调优 (MTU与端口跳跃)"
    echo -e "  ${YELLOW}5.${NC} 深度网络诊断 (排查不通原因)"
    echo -e "  ${RED}0.${NC} 退出"
    echo -e "${BLUE}==================================================${NC}"
    read -rp "请选择 [0-5]: " num
    case "$num" in
        1) optimize_system ;;
        2) install_singbox ;;
        3) show_config ;;
        4) hy2_tuning ;; # 逻辑同前
        5) debug_network ;;
        0) exit 0 ;;
        *) main_menu ;;
    esac
}

main_menu
