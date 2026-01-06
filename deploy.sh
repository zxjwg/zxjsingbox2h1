#!/usr/bin/env bash

# =================================================================
# 项目：Sing-box 自动化管理系统 (V8.1 模块化起步版)
# 功能：系统 BBR 优化 / 交互菜单框架 / 唤醒管理
# =================================================================

# --- [ 0. 配色与变量 ] ---
RED='\033[0;31m' && GREEN='\033[0;32m' && YELLOW='\033[0;33m' && BLUE='\033[0;34m' && NC='\033[0m'
ALIAS_PATH="/usr/bin/zxj2h1"

# --- [ 1. 性能优化模块：内核 BBR 加速 ] ---
# 开启 BBR 可以显著提升 UDP (Hy2) 在丢包环境下的表现
optimize_system() {
    echo -e "${BLUE}正在检查 BBR 状态...${NC}"
    if lsmod | grep -q bbr; then
        echo -e "${GREEN}系统已开启 BBR 加速。${NC}"
    else
        echo -e "${YELLOW}正在开启内核 BBR 拥塞控制算法...${NC}"
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
        echo -e "${GREEN}BBR 已成功开启！${NC}"
    fi
    read -rp "按回车键返回菜单..."
}

# --- [ 2. 服务管理模块 ] ---
# 快速查看 Sing-box 运行状态
check_status() {
    if systemctl is-active --quiet sing-box; then
        echo -e "Sing-box 状态: ${GREEN}正在运行${NC}"
    else
        echo -e "Sing-box 状态: ${RED}未运行${NC}"
    fi
    read -rp "按回车键返回菜单..."
}

# --- [ 3. 交互主菜单 ] ---
main_menu() {
    clear
    echo -e "${BLUE}==================================================${NC}"
    echo -e "      不正经的科学 - Sing-box 管理系统 V8.1       "
    echo -e "${BLUE}==================================================${NC}"
    echo -e "  ${GREEN}1.${NC} 优化系统性能 (开启内核 BBR 加速)"
    echo -e "  ${GREEN}2.${NC} 查看 Sing-box 运行状态"
    echo -e "  ${GREEN}3.${NC} 查看当前节点配置 (待开发)"
    echo -e "  ${RED}0.${NC} 退出脚本"
    echo -e "${BLUE}==================================================${NC}"
    read -rp "请选择操作 [0-3]: " menu_num

    case "$menu_num" in
        1) optimize_system ;;
        2) check_status ;;
        3) echo "节点展示功能正在模块化重构中..." && sleep 2 && main_menu ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入错误！${NC}" && sleep 1 && main_menu ;;
    esac
}

# 配置快捷唤醒词
echo "bash <(curl -Ls https://raw.githubusercontent.com/zxjwg/zxjsingbox2h1/refs/heads/main/deploy.sh)" > "$ALIAS_PATH"
chmod +x "$ALIAS_PATH"

main_menu
