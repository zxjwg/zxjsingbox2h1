#!/bin/bash

# ==========================================
# 自动化部署脚本：Hysteria 2 + VLESS Reality
# ==========================================

# 1. 环境准备与 BBR 开启
echo "正在优化内核参数 (BBR)..."
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p

# 2. 安装基础工具
apt update && apt install -y curl socat wget jq

# 3. 交互式输入 (让脚本更灵活)
read -p "请输入你的域名 (例如 fg.zhouxj.qzz.io): " DOMAIN
read -p "请输入你的邮箱 (用于证书提醒): " EMAIL
read -p "请输入 HY2 混淆密码 (回车默认使用 unserionssss66688): " HY2_PASS
HY2_PASS=${HY2_PASS:-"unserionssss66688"}
UUID=$(cat /proc/sys/kernel/random/uuid)

# 4. 申请 Let's Encrypt 证书
curl https://get.acme.sh | sh -s email=$EMAIL
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
~/.acme.sh/acme.sh --issue -d $DOMAIN --standalone
mkdir -p /etc/v2ray-agent/tls/
~/.acme.sh/acme.sh --install-cert -d $DOMAIN \
--key-file /etc/v2ray-agent/tls/server.key \
--fullchain-file /etc/v2ray-agent/tls/server.crt

# 5. 安装官方 Sing-box
bash <(curl -Ls https://raw.githubusercontent.com/sagernet/sing-box/main/install.sh)

# 6. 自动化生成 Reality 密钥对
RE_KEYS=$(/usr/bin/sing-box generate reality-keypair)
PRIVATE_KEY=$(echo "$RE_KEYS" | grep "Private key" | awk '{print $3}')
PUBLIC_KEY=$(echo "$RE_KEYS" | grep "Public key" | awk '{print $3}')

# 7. 写入配置文件
cat <<EOF > /etc/sing-box/config.json
{
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": 443,
      "up_mbps": 120,
      "down_mbps": 120,
      "users": [{"password": "$UUID"}],
      "obfs": {"type": "salamander", "password": "$HY2_PASS"},
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "alpn": ["h3"],
        "certificate_path": "/etc/v2ray-agent/tls/server.crt",
        "key_path": "/etc/v2ray-agent/tls/server.key"
      }
    },
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "::",
      "listen_port": 2053,
      "users": [{"uuid": "$UUID", "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": true,
        "server_name": "www.microsoft.com",
        "reality": {
          "enabled": true,
          "handshake": {"server": "www.microsoft.com", "server_port": 443},
          "private_key": "$PRIVATE_KEY",
          "short_id": ["6ba85179e30d4fc2"]
        }
      }
    }
  ],
  "outbounds": [{"type": "direct"}]
}
EOF

# 8. 启动并显示结果
systemctl enable --now sing-box
clear
echo "======================================"
echo "部署成功！请保存以下信息："
echo "UUID: $UUID"
echo "HY2 端口: 443 | 混淆密码: $HY2_PASS"
echo "Reality 端口: 2053 | 公钥 (PublicKey): $PUBLIC_KEY"
echo "======================================"
