#!/usr/bin/env bash
# =================================================================
# 项目：Sing-box 自动化管理系统 (V9.9.2 深度修复版)
# 修复：防火墙持久化 / 错误处理 / 证书续期 / 配置备份
# =================================================================

set -e
RED='\033[0;31m' && GREEN='\033[0;32m' && YELLOW='\033[0;33m' && BLUE='\033[0;34m' && NC='\033[0m'
CONF_DIR="/etc/sing-box"
CERT_DIR="/etc/v2ray-agent/tls"
BACKUP_DIR="$CONF_DIR/backups"

# --- [ 0. 前置检查 ] ---
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误：请使用 root 用户运行此脚本${NC}"
        exit 1
    fi
}

get_ip() {
    IP=$(curl -s --max-time 5 http://checkip.amazonaws.com || \
         curl -s --max-time 5 http://ipinfo.io/ip || \
         echo "获取失败")
    if [ "$IP" == "获取失败" ]; then
        read -rp "无法自动获取IP，请手动输入: " IP
    fi
}

# --- [ 1. 安全防火墙配置 ] ---
safe_firewall() {
    echo -e "${BLUE}正在优化防火墙规则...${NC}"
    
    # 安装依赖
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y iptables iptables-persistent jq uuid-runtime qrencode openssl socat wget curl lsof &>/dev/null || {
            echo -e "${RED}依赖安装失败${NC}"
            exit 1
        }
    elif command -v yum &>/dev/null; then
        yum install -y iptables iptables-services jq util-linux qrencode openssl socat wget curl lsof &>/dev/null || {
            echo -e "${RED}依赖安装失败${NC}"
            exit 1
        }
    else
        echo -e "${RED}不支持的系统${NC}"
        exit 1
    fi
    
    # 设置防火墙规则（保护SSH）
    iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 22 -j ACCEPT
    iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 443 -j ACCEPT
    iptables -C INPUT -p udp --dport 8443 -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport 8443 -j ACCEPT
    iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 80 -j ACCEPT
    
    # 持久化规则
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save
    elif command -v iptables-save &>/dev/null; then
        iptables-save > /etc/sysconfig/iptables 2>/dev/null || \
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
    
    echo -e "${GREEN}防火墙配置完成${NC}"
}

# --- [ 2. 配置备份 ] ---
backup_config() {
    if [ -f "$CONF_DIR/config.json" ]; then
        mkdir -p "$BACKUP_DIR"
        local backup_file="$BACKUP_DIR/config.$(date +%Y%m%d_%H%M%S).json"
        cp "$CONF_DIR/config.json" "$backup_file"
        echo -e "${GREEN}配置已备份到: $backup_file${NC}"
        
        # 只保留最近5个备份
        ls -t "$BACKUP_DIR"/config.*.json 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true
    fi
}

# --- [ 3. 版本检测优化 ] ---
get_current_version() {
    if [ ! -f /usr/bin/sing-box ]; then
        echo "未安装"
        return
    fi
    
    local ver=$(/usr/bin/sing-box version 2>/dev/null | grep -oP '(?<=version )\S+' || echo "未知")
    echo "$ver"
}

get_latest_version() {
    local latest=$(curl -s --max-time 10 https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name 2>/dev/null || echo "")
    if [ -z "$latest" ]; then
        echo -e "${RED}无法获取最新版本，请检查网络${NC}"
        return 1
    fi
    echo "${latest#v}"  # 移除 v 前缀
}

# --- [ 4. 核心更新模块（增强版）] ---
update_kernel_only() {
    echo -e "${BLUE}正在检查版本信息...${NC}"
    
    local current_ver=$(get_current_version)
    local latest_ver=$(get_latest_version) || return 1
    
    echo -e "${YELLOW}当前版本: $current_ver${NC}"
    echo -e "${YELLOW}最新版本: $latest_ver${NC}"
    
    if [ "$current_ver" == "$latest_ver" ] && [ "$current_ver" != "未安装" ]; then
        read -rp "版本已是最新，是否强制重新安装？(y/n): " force_reinstall
        [[ "$force_reinstall" != "y" ]] && main_menu && return
    fi
    
    # 备份现有配置
    backup_config
    
    # 检测架构
    local arch=$(uname -m)
    case "$arch" in
        x86_64) local sb_arch="amd64" ;;
        aarch64|arm64) local sb_arch="arm64" ;;
        armv7l) local sb_arch="armv7" ;;
        *) echo -e "${RED}不支持的架构: $arch${NC}"; return 1 ;;
    esac
    
    echo -e "${BLUE}正在下载 sing-box v${latest_ver} ($sb_arch)...${NC}"
    
    # 下载到临时目录
    local tmp_dir=$(mktemp -d)
    cd "$tmp_dir" || exit 1
    
    local download_url="https://github.com/SagerNet/sing-box/releases/download/v${latest_ver}/sing-box-${latest_ver}-linux-${sb_arch}.tar.gz"
    
    if ! wget -q --show-progress -O sing-box.tar.gz "$download_url"; then
        echo -e "${RED}下载失败，请检查网络或版本号${NC}"
        cd - > /dev/null && rm -rf "$tmp_dir"
        return 1
    fi
    
    # 解压并查找可执行文件
    tar -zxf sing-box.tar.gz || { echo -e "${RED}解压失败${NC}"; cd - > /dev/null; rm -rf "$tmp_dir"; return 1; }
    
    local binary=$(find . -name sing-box -type f -executable | head -1)
    if [ -z "$binary" ]; then
        echo -e "${RED}错误：未找到可执行文件${NC}"
        cd - > /dev/null && rm -rf "$tmp_dir"
        return 1
    fi
    
    # 停止服务
    echo -e "${BLUE}正在停止服务...${NC}"
    systemctl stop sing-box 2>/dev/null || echo -e "${YELLOW}服务未运行${NC}"
    
    # 替换二进制文件
    mv -f "$binary" /usr/bin/sing-box
    chmod +x /usr/bin/sing-box
    
    # 清理临时文件
    cd - > /dev/null && rm -rf "$tmp_dir"
    
    # 重启服务
    echo -e "${BLUE}正在启动服务...${NC}"
    if systemctl start sing-box; then
        echo -e "${GREEN}✓ 内核已成功升级至 v$latest_ver${NC}"
        echo -e "${GREEN}✓ 配置已保留，服务运行正常${NC}"
    else
        echo -e "${RED}✗ 服务启动失败，查看日志:${NC}"
        journalctl -u sing-box --no-pager -n 20
        return 1
    fi
    
    sleep 2 && main_menu
}

# --- [ 5. 证书申请（增强版）] ---
setup_certificate() {
    local domain=$1
    local email=$2
    
    echo -e "${BLUE}正在配置 SSL 证书...${NC}"
    
    # 检查证书是否已存在、有效且域名匹配
    if [ -f "$CERT_DIR/server.crt" ]; then
        local expire_date=$(openssl x509 -enddate -noout -in "$CERT_DIR/server.crt" | cut -d= -f2)
        local expire_epoch=$(date -d "$expire_date" +%s 2>/dev/null || echo 0)
        local now_epoch=$(date +%s)
        local days_left=$(( ($expire_epoch - $now_epoch) / 86400 ))

        # 使用全文匹配检查域名是否存在于当前证书（兼容由多域名造成的错判）
        if openssl x509 -noout -text -in "$CERT_DIR/server.crt" | grep -q "$domain"; then
            if [ $days_left -gt 30 ]; then
                echo -e "${GREEN}检测到证书域名匹配($domain) 且有效期剩余 $days_left 天，跳过申请${NC}"
                return 0
            else
                echo -e "${YELLOW}证书即将过期（剩余 $days_left 天），重新申请...${NC}"
            fi
        else
            echo -e "${YELLOW}检测到域名已更换（当前证书中未找到 $domain），强制重新申请...${NC}"
        fi
    fi
    
    # 安装 acme.sh
    if [ ! -f "/root/.acme.sh/acme.sh" ]; then
        echo -e "${BLUE}正在安装 acme.sh...${NC}"
        curl -s https://get.acme.sh | sh -s email="$email" || {
            echo -e "${RED}acme.sh 安装失败${NC}"
            return 1
        }
    fi
    
    # 设置默认 CA 并申请证书
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    
    echo -e "${BLUE}申请证书中 (遇到 Nginx/Apache 将自动临时挂起以释放 80 端口)...${NC}"
    
    # 使用 pre-hook 和 post-hook，保证申请时和未来自动续期时都能正确让出 80 端口
    if /root/.acme.sh/acme.sh --issue -d "$domain" --standalone --force \
        --pre-hook "systemctl stop nginx apache2 httpd sing-box 2>/dev/null || true" \
        --post-hook "systemctl start nginx apache2 httpd 2>/dev/null || true"; then
        mkdir -p "$CERT_DIR"
        /root/.acme.sh/acme.sh --install-cert -d "$domain" \
            --key-file "$CERT_DIR/server.key" \
            --fullchain-file "$CERT_DIR/server.crt" \
            --reloadcmd "systemctl restart sing-box"
        
        # 设置自动续期
        /root/.acme.sh/acme.sh --install-cronjob
        
        echo -e "${GREEN}证书申请成功${NC}"
    else
        echo -e "${RED}证书申请失败，请检查：${NC}"
        echo -e "  1. 域名 DNS 是否正确指向本机"
        echo -e "  2. 80 端口是否被占用"
        echo -e "  3. 防火墙是否放行 80 端口"
        return 1
    fi
}

# --- [ 6. 部署模块（优化版）] ---
install_singbox() {
    check_root
    get_ip
    safe_firewall
    
    echo -e "${BLUE}======================================${NC}"
    echo -e "${BLUE}    开始部署 Sing-box 节点    ${NC}"
    echo -e "${BLUE}======================================${NC}"
    
    # 输入域名和邮箱
    read -rp "请输入域名: " DOMAIN
    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}域名不能为空${NC}"
        main_menu
        return
    fi
    
    read -rp "请输入邮箱: " EMAIL
    EMAIL=${EMAIL:-admin@$DOMAIN}
    
    # 申请证书
    setup_certificate "$DOMAIN" "$EMAIL" || {
        echo -e "${RED}证书配置失败，无法继续${NC}"
        sleep 3
        main_menu
        return
    }
    
    # 安装 Sing-box
    echo -e "${BLUE}正在安装 Sing-box 核心...${NC}"
    
    local latest_ver=$(get_latest_version) || return 1
    local arch=$(uname -m)
    case "$arch" in
        x86_64) local sb_arch="amd64" ;;
        aarch64|arm64) local sb_arch="arm64" ;;
        armv7l) local sb_arch="armv7" ;;
        *) echo -e "${RED}不支持的架构: $arch${NC}"; return 1 ;;
    esac
    
    local tmp_dir=$(mktemp -d)
    cd "$tmp_dir" || exit 1
    
    wget -q --show-progress -O sing-box.tar.gz \
        "https://github.com/SagerNet/sing-box/releases/download/v${latest_ver}/sing-box-${latest_ver}-linux-${sb_arch}.tar.gz" || {
        echo -e "${RED}下载失败${NC}"
        cd - > /dev/null && rm -rf "$tmp_dir"
        return 1
    }
    
    tar -zxf sing-box.tar.gz
    local binary=$(find . -name sing-box -type f -executable | head -1)
    if [ -z "$binary" ]; then
        echo -e "${RED}未找到可执行文件${NC}"
        cd - > /dev/null && rm -rf "$tmp_dir"
        return 1
    fi
    
    mv -f "$binary" /usr/bin/sing-box
    chmod +x /usr/bin/sing-box
    cd - > /dev/null && rm -rf "$tmp_dir"
    
    # 生成配置
    echo -e "${BLUE}正在生成配置文件...${NC}"
    
    local re_out=$(/usr/bin/sing-box generate reality-keypair)
    local priv_key=$(echo "$re_out" | awk '/PrivateKey/ {print $NF}' | tr -d '\r\n ')
    local pub_key=$(echo "$re_out" | awk '/PublicKey/ {print $NF}' | tr -d '\r\n ')
    
    if [ -z "$priv_key" ] || [ -z "$pub_key" ]; then
        echo -e "${RED}Reality 密钥生成失败${NC}"
        return 1
    fi
    
    mkdir -p "$CONF_DIR"
    echo "$pub_key" > "$CONF_DIR/pub.key"
    
    local uuid_vless=$(uuidgen)
    local uuid_hy2=$(uuidgen)
    local sid=$(openssl rand -hex 8)
    
    # Reality 伪装域名选择
    echo -e "\n${BLUE}请选择 Reality 伪装域名 (SNI):${NC}"
    echo -e "  1. ${GREEN}www.bing.com${NC} (主选)"
    echo -e "  2. ${GREEN}app.com${NC}"
    echo -e "  3. ${GREEN}www.microsoft.com${NC}"
    echo -e "  4. 自定义"
    read -rp "请输入序号 [1-4, 默认1]: " sni_choice
    case "$sni_choice" in
        2) sni_domain="app.com" ;;
        3) sni_domain="www.microsoft.com" ;;
        4) read -rp "请输入自定义域名: " sni_domain ;;
        *) sni_domain="www.bing.com" ;;
    esac
    sni_domain=${sni_domain:-www.bing.com}
    
    # 生成配置文件
    cat > "$CONF_DIR/config.json" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": 443,
      "users": [
        {
          "uuid": "$uuid_vless",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$sni_domain",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$sni_domain",
            "server_port": 443
          },
          "private_key": "$priv_key",
          "short_id": ["$sid"]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": 8443,
      "users": [
        {
          "password": "$uuid_hy2"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "alpn": ["h3"],
        "certificate_path": "$CERT_DIR/server.crt",
        "key_path": "$CERT_DIR/server.key"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct"
    }
  ]
}
EOF
    
    # 保护配置文件权限
    chmod 600 "$CONF_DIR/config.json"
    
    # 创建 systemd 服务
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=/usr/bin/sing-box run -c $CONF_DIR/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable sing-box
    
    if systemctl start sing-box; then
        echo -e "${GREEN}部署完成！${NC}"
        sleep 2
        show_config
    else
        echo -e "${RED}服务启动失败，日志：${NC}"
        journalctl -u sing-box --no-pager -n 20
    fi
}

# --- [ 7. 服务状态检查 ] ---
check_service() {
    clear
    echo -e "${BLUE}======================================${NC}"
    echo -e "${BLUE}      Sing-box 服务状态      ${NC}"
    echo -e "${BLUE}======================================${NC}"
    
    if systemctl is-active --quiet sing-box; then
        echo -e "${GREEN}✓ 服务状态: 运行中${NC}"
        echo -e "\n${YELLOW}进程信息:${NC}"
        ps aux | grep sing-box | grep -v grep
        
        echo -e "\n${YELLOW}监听端口:${NC}"
        ss -tlnp | grep sing-box || echo "无TCP监听"
        ss -ulnp | grep sing-box || echo "无UDP监听"
        
        echo -e "\n${YELLOW}最近日志:${NC}"
        journalctl -u sing-box --no-pager -n 10
    else
        echo -e "${RED}✗ 服务状态: 未运行${NC}"
        echo -e "\n${YELLOW}错误日志:${NC}"
        journalctl -u sing-box --no-pager -n 20
    fi
    
    echo -e "\n${BLUE}按回车键返回主菜单...${NC}"
    read && main_menu
}

# --- [ 8. 展示配置 ] ---
show_config() {
    clear
    echo -e "${BLUE}======================================${NC}"
    echo -e "${BLUE}      节点配置与二维码      ${NC}"
    echo -e "${BLUE}======================================${NC}"
    
    if [ ! -f "$CONF_DIR/config.json" ]; then
        echo -e "${RED}错误：配置文件不存在${NC}"
        sleep 2
        main_menu
        return
    fi
    
    get_ip
    
    local uuid_vless=$(jq -r '.inbounds[0].users[0].uuid' "$CONF_DIR/config.json")
    local pub_key=$(cat "$CONF_DIR/pub.key" 2>/dev/null || echo "未找到")
    local sid=$(jq -r '.inbounds[0].tls.reality.short_id[0]' "$CONF_DIR/config.json")
    local sni=$(jq -r '.inbounds[0].tls.server_name' "$CONF_DIR/config.json")
    local domain=$(jq -r '.inbounds[1].tls.server_name' "$CONF_DIR/config.json")
    local uuid_hy2=$(jq -r '.inbounds[1].users[0].password' "$CONF_DIR/config.json")
    
    # VLESS Reality 链接
    local vless_link="vless://$uuid_vless@$IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$sni&fp=chrome&pbk=$pub_key&sid=$sid&type=tcp#Reality_${IP}"
    
    # Hysteria2 链接
    local hy2_link="hysteria2://$uuid_hy2@$IP:8443?sni=$domain&alpn=h3&insecure=0#HY2_${IP}"
    
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}VLESS Reality (TCP 443)${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "UUID: ${BLUE}$uuid_vless${NC}"
    echo -e "链接: $vless_link"
    echo ""
    qrencode -t UTF8 "$vless_link"
    
    echo -e "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}Hysteria2 (UDP 8443)${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "密码: ${BLUE}$uuid_hy2${NC}"
    echo -e "链接: $hy2_link"
    echo ""
    qrencode -t UTF8 "$hy2_link"
    
    echo -e "\n${BLUE}按回车键返回主菜单...${NC}"
    read && main_menu
}

# --- [ 9. BBR 优化 ] ---
optimize_system() {
    echo -e "${BLUE}正在优化系统参数...${NC}"
    
    if grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo -e "${YELLOW}BBR 已启用${NC}"
    else
        cat >> /etc/sysctl.conf <<EOF

# BBR 优化
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.core.rmem_max=134217728
net.core.wmem_max=134217728
EOF
        sysctl -p
        echo -e "${GREEN}BBR 优化完成${NC}"
    fi
    
    # 验证
    if sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
        echo -e "${GREEN}✓ BBR 已启用${NC}"
    else
        echo -e "${RED}✗ BBR 启用失败，可能需要内核支持${NC}"
    fi
    
    sleep 2
    main_menu
}

# --- [ 10. 卸载功能 ] ---
uninstall_singbox() {
    echo -e "${RED}警告：此操作将删除 Sing-box 及所有配置！${NC}"
    read -rp "确认卸载？(yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        main_menu
        return
    fi
    
    echo -e "${BLUE}正在卸载...${NC}"
    
    # 停止并禁用服务
    systemctl stop sing-box 2>/dev/null || true
    systemctl disable sing-box 2>/dev/null || true
    
    # 删除核心文件
    rm -f /etc/systemd/system/sing-box.service
    rm -f /usr/bin/sing-box
    rm -rf "$CONF_DIR"
    
    # 可选卸载 acme 和证书
    read -rp "是否一并彻底删除 Acme.sh 和已申请的域名证书？(yes/no): " remove_cert
    if [ "$remove_cert" == "yes" ]; then
        if [ -f "/root/.acme.sh/acme.sh" ]; then
            echo -e "${YELLOW}正在清理 acme.sh 和定时任务...${NC}"
            /root/.acme.sh/acme.sh --uninstall >/dev/null 2>&1
            rm -rf /root/.acme.sh
        fi
        echo -e "${YELLOW}清理旧证书文件...${NC}"
        rm -rf /etc/v2ray-agent
        echo -e "${GREEN}✓ 证书及 acme.sh 脚本已彻底清除！${NC}"
    fi
    
    systemctl daemon-reload
    
    echo -e "${GREEN}卸载完成${NC}"
    sleep 2
    main_menu
}

# --- [ 主菜单 ] ---
main_menu() {
    clear
    echo -e "${BLUE}==================================================${NC}"
    echo -e "      ${GREEN}Sing-box 管理系统${NC} ${YELLOW}(增强版 v9.9.2)${NC}      "
    echo -e "${BLUE}==================================================${NC}"
    echo -e "  ${GREEN}1.${NC} 开启 BBR 优化"
    echo -e "  ${GREEN}2.${NC} 一键部署节点 ${RED}(会覆盖现有配置)${NC}"
    echo -e "  ${GREEN}3.${NC} 查看节点配置/二维码"
    echo -e "  ${YELLOW}4.${NC} 仅更新内核 ${YELLOW}(保留配置/UUID)${NC}"
    echo -e "  ${GREEN}5.${NC} 查看服务状态"
    echo -e "  ${GREEN}6.${NC} 重启服务"
    echo -e "  ${GREEN}7.${NC} 查看实时日志"
    echo -e "  ${RED}8.${NC} 卸载 Sing-box"
    echo -e "  ${RED}0.${NC} 退出"
    echo -e "${BLUE}==================================================${NC}"
    
    read -rp "请选择 [0-8]: " num
    
    case "$num" in
        1) optimize_system ;;
        2) install_singbox ;;
        3) show_config ;;
        4) update_kernel_only ;;
        5) check_service ;;
        6) systemctl restart sing-box && echo -e "${GREEN}服务已重启${NC}" && sleep 1 && main_menu ;;
        7) journalctl -u sing-box -f ;;
        8) uninstall_singbox ;;
        0) echo -e "${GREEN}感谢使用！${NC}" && exit 0 ;;
        *) main_menu ;;
    esac
}

# --- [ 入口 ] ---
check_root
main_menu
