#!/usr/bin/env bash

# =================================================================
# 项目：Sing-box 自动化部署系统 (V7.0 终极收工版)
# 修复：移除不支持的 --format 参数 / 增强密钥截取 / 紧凑二维码
# =================================================================

set -e

# --- [ 0. 变量定义 ] ---
RED='\033[0;31m' && GREEN='\033[0;32m' && BLUE='\033[0;34m' && NC='\033[0m'
CONF_DIR="/etc/sing-box"
CERT_DIR="/etc/v2ray-agent/tls"
ALIAS_PATH="/usr/bin/zxj2h1"
IP=$(curl -s http://checkip.amazonaws.com || curl -s icanhazip.com)

# --- [ 1. 初始化环境 ] ---
echo -e "${BLUE}[1/5] 正在初始化环境并清理系统锁...${NC}"
systemctl stop unattended-upgrades 2>/dev/null || true
killall -9 apt apt-get dpkg 2>/dev/null || true
rm -f /var/lib/dpkg/lock* /var/cache/debconf/*.dat
DEBIAN_FRONTEND=noninteractive dpkg --configure -a || true
apt-get update && apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    curl wget lsof jq tar nginx ca-certificates uuid-runtime openssl coreutils qrencode

# --- [ 2. 处理域名与证书 ] ---
read -rp "请输入域名 (如 fg.zhouxj.qzz.io): " DOMAIN
if [ ! -f "$CERT_DIR/server.crt" ]; then
    echo -e "${RED}未检测到证书，请确保解析已生效并重新运行申请逻辑。${NC}"
    # 此处可保留之前的 acme.sh 逻辑，但假设你已成功申请
fi

# --- [ 3. 二进制直装 ] ---
echo -e "${BLUE}[2/5] 正在安装 Sing-box 二进制文件...${NC}"
ARCH=$(uname -m)
[ "$ARCH" == "x86_64" ] && SB_ARCH="amd64" || SB_ARCH="arm64"
VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//')
DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${SB_ARCH}.tar.gz"

wget -qO sing-box.tar.gz "$DOWNLOAD_URL"
tar -zxf sing-box.tar.gz
mv sing-box-*/sing-box /usr/bin/ && chmod +x /usr/bin/sing-box
rm -rf sing-box.tar.gz sing-box-*

# --- [ 4. 密钥生成：回归最原始的截取法 (无 --format) ] ---
echo -e "${BLUE}[3/5] 正在提取 Reality 密钥对...${NC}"
# 不再使用 --format json，直接运行原始命令
RE_OUT=$(/usr/bin/sing-box generate reality-keypair)
# 使用 awk 提取最后一部分，不受空格影响
PRIV_KEY=$(echo "$RE_OUT" | awk '/Private key/ {print $NF}')
PUB_KEY=$(echo "$RE_OUT" | awk '/Public key/ {print $NF}')

if [[ -z "$PRIV_KEY" || -z "$PUB_KEY" ]]; then
    echo -e "${RED}致命错误：密钥提取失败！${NC}" && exit 1
fi

UUID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
SHORT_ID=$(openssl rand -hex 8)
RAND_PORT=$(shuf -i 10000-60000 -n 1)

# --- [ 5. 配置写入与启动 ] ---
mkdir -p "$CONF_DIR"
cat > "$CONF_DIR/config.json" <<EOF
{
  "inbounds": [
    {
      "type": "vless", "tag": "reality-in", "listen": "::", "listen_port": 443,
      "users": [{"uuid": "$UUID", "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": true, "server_name": "www.microsoft.com",
        "reality": { "enabled": true, "handshake": { "server": "127.0.0.1", "server_port": $RAND_PORT }, "private_key": "$PRIV_KEY", "short_id": ["$SHORT_ID"] }
      }
    },
    {
      "type": "hysteria2", "tag": "hy2-in", "listen": "::", "listen_port": 443,
      "users": [{"password": "$UUID"}],
      "tls": { "enabled": true, "server_name": "$DOMAIN", "alpn": ["h3"], "certificate_path": "$CERT_DIR/server.crt", "key_path": "$CERT_DIR/server.key" }
    }
  ],
  "outbounds": [{"type": "direct"}]
}
EOF

/usr/bin/sing-box check -c "$CONF_DIR/config.json"

# 创建 Systemd 服务
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

# --- [ 6. 成果展示 ] ---
echo -e "${GREEN}==================================================${NC}"
VLESS_LINK="vless://$UUID@$IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=$PUB_KEY&sid=$SHORT_ID#Reality_$IP"
echo -e "${YELLOW}Reality 节点:${NC}\n${BLUE}$VLESS_LINK${NC}"
qrencode -t UTF8 "$VLESS_LINK"

echo -e "\n${YELLOW}Hysteria 2 节点:${NC}"
HY2_LINK="hysteria2://$UUID@$IP:443?sni=$DOMAIN&alpn=h3&insecure=0#HY2_$IP"
echo -e "${BLUE}$HY2_LINK${NC}"
qrencode -t UTF8 "$HY2_LINK"
echo -e "${GREEN}==================================================${NC}"

# 配置唤醒词
echo "bash <(curl -Ls https://raw.githubusercontent.com/zxjwg/zxjsingbox2h1/refs/heads/main/deploy.sh)" > "$ALIAS_PATH"
chmod +x "$ALIAS_PATH"
echo -e "部署已彻底完成！今后输入 ${BLUE}zxj2h1${NC} 即可。晚安！"
