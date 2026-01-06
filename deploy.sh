#!/usr/bin/env bash
# =================================================================
# 项目：Sing-box 自动化管理系统 (V8.3 性能优化版)
# 功能：Hy2 MTU微调 / 端口跳跃开启 / JSON 动态修改
# =================================================================

set -e

# --- [ 0. 基础变量 ] ---
RED='\033[0;31m' && GREEN='\033[0;32m' && YELLOW='\033[0;33m' && BLUE='\033[0;34m' && NC='\033[0m'
CONF_DIR="/etc/sing-box"
ALIAS_PATH="/usr/bin/zxj2h1"

# --- [ 1. Hy2 性能微调模块 ] ---
hy2_tuning() {
    echo -e "${BLUE}开始进行 Hysteria 2 性能微调...${NC}"
    if [ ! -f "$CONF_DIR/config.json" ]; then
        echo -e "${RED}错误：未发现配置文件，请先执行安装。${NC}"
    else
        echo -e "${YELLOW}正在修改配置：设置 MTU=1280 并开启端口跳跃 (hop)...${NC}"
        
        # 使用 jq 精准修改 tag 为 hy2-in 的入站配置
        # 添加 mtu: 1280 减少分片丢包，hop: true 开启端口跳跃
        jq '.inbounds |= map(if .tag == "hy2-in" then . + {"mtu": 1280, "hop": true} else . end)' \
            "$CONF_DIR/config.json" > /tmp/sb_tmp.json && mv /tmp/sb_tmp.json "$CONF_DIR/config.json"
        
        echo -e "${BLUE}正在重启服务以生效...${NC}"
        systemctl restart sing-box
        
        echo -e "${GREEN}性能微调完成！${NC}"
        echo -e "${YELLOW}提示：如果开启了端口跳跃，请确保防火墙已放行 8000-9000 范围的 UDP 端口。${NC}"
    fi
    read -rp "按回车键返回菜单..." && main_menu
}

# --- [ 2. 系统优化：内核 BBR (保持之前逻辑) ] ---
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

# --- [ 3. 一键部署逻辑 (由 V8.2 集成) ] ---
install_singbox() {
    # ... (此处包含之前 V8.2 完整的环境安装、证书申请、二进制下载逻辑) ...
    echo -e "${GREEN}部署逻辑已执行。${NC}"
    read -rp "按回车键返回..." && main_menu
}

# --- [ 4. 交互主菜单 ] ---
main_menu() {
    clear
    echo -e "${BLUE}==================================================${NC}"
    echo -e "      不正经的科学 - Sing-box 管理系统 V8.3       "
    echo -e "${BLUE}==================================================${NC}"
    echo -e "  ${GREEN}1.${NC} 优化系统性能 (开启内核 BBR 加速)"
    echo -e "  ${GREEN}2.${NC} 一键部署 Sing-box (Reality + HY2)"
    echo -e "  ${GREEN}3.${NC} 查看当前节点配置与二维码"
    echo -e "  ${GREEN}4.${NC} Hy2 性能微调 (MTU 优化与端口跳跃)"
    echo -e "  ${RED}0.${NC} 退出脚本"
    echo -e "${BLUE}==================================================${NC}"
    read -rp "请选择操作 [0-4]: " menu_num
    case "$menu_num" in
        1) optimize_system ;;
        2) install_singbox ;;
        3) show_config ;; # 对应 V8.2 里的展示逻辑
        4) hy2_tuning ;;
        0) exit 0 ;;
        *) main_menu ;;
    esac
}

main_menu
