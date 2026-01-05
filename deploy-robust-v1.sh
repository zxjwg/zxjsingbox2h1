#!/usr/bin/env bash
#
# 改进版部署脚本（兼容性与健壮性增强）
# 说明：
#  - 保持原脚本总体逻辑（申请证书 -> 安装 sing-box -> 生成 Reality/Hy2 -> nginx 回落 -> UDP 转发）
#  - 增加了：root 检查、包管理器检测、重试机制、超时、锁文件更安全的清理、日志、非交互 apt、nginx 配置检测/备份、
#    acme.sh 与 cert 申请的回退、iptables/nftables 兼容性判断、错误 trap 与提示等
#  - 默认跳过持久化 netfilter（适配外部/云平台管理的防火墙），通过 SKIP_NETFILTER_PERSISTENT 控制
#  - 修复 acme.sh 安装时报 Unknown parameter: ----nocron 的问题：不再直接传递 --nocron 给安装脚本，改为安装后移除自动任务（如 crontab/systemd）以禁用自动升级/定时任务
#
set -euo pipefail

# 日志
LOGFILE="/var/log/singbox-deploy.log"
mkdir -p "$(dirname "$LOGFILE")"
exec > >(tee -a "$LOGFILE") 2>&1

# 颜色
RED='\033[0;31m' && GREEN='\033[0;32m' && BLUE='\033[0;34m' && YELLOW='\033[0;33m' && NC='\033[0m'

# 可配置变量（保留原有默认）
CONF_DIR="/etc/sing-box"
CERT_DIR="/etc/v2ray-agent/tls"
NGINX_CONF_CANDIDATES=("/etc/nginx/sites-available/default" "/etc/nginx/conf.d/default.conf" "/etc/nginx/nginx.conf")
RANDOM_PORT=$(shuf -i 10000-60000 -n 1 2>/dev/null || echo "37210")
HY2_PORT="5443"
UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || (command -v uuidgen >/dev/null 2>&1 && uuidgen) || echo "$(openssl rand -hex 8)-$(openssl rand -hex 4)-$(openssl rand -hex 4)-$(openssl rand -hex 4)-$(openssl rand -hex 12)")"
SHORT_ID="$(openssl rand -hex 8 || echo "sid$(date +%s)")"

# 默认跳过持久化 netfilter（适配外部/云平台管理的防火墙）
SKIP_NETFILTER_PERSISTENT="${SKIP_NETFILTER_PERSISTENT:-true}"

# 超时/重试设置
RETRY_MAX=5
SLEEP_BETWEEN_RETRY=3
CURL_OPTS="--connect-timeout 10 --max-time 120 -fsSL"

# 工具选择占位
PKG_MANAGER=""
PKG_INSTALL=""
SYSTEMCTL_CMD="$(command -v systemctl || true)"

trap 'echo -e "${RED}发生错误，部署中止。请查看 $LOGFILE 以获取详细日志。${NC}"; exit 1' ERR

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}"; }
err() { echo -e "${RED}[ERROR] $*${NC}"; }

# ---------------- helpers ----------------
retry_cmd() {
    local n=1
    local max=${1:-$RETRY_MAX}
    shift || true
    while true; do
        if "$@"; then
            return 0
        else
            if [ "$n" -ge "$max" ]; then
                return 1
            fi
            warn "命令失败，重试 ${n}/${max}： $*"
            n=$((n + 1))
            sleep $SLEEP_BETWEEN_RETRY
        fi
    done
}

is_root() {
    [ "$(id -u)" -eq 0 ]
}

detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"
        PKG_INSTALL="apt-get install -y"
        export DEBIAN_FRONTEND=noninteractive
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
        PKG_INSTALL="dnf install -y"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
        PKG_INSTALL="yum install -y"
    else
        err "未检测到受支持的包管理器 (apt/dnf/yum)。请手动安装依赖后重试。"
        exit 1
    fi
    info "检测到包管理器：$PKG_MANAGER"
}

safe_kill_locking_processes() {
    # 尝试更温和的方式处理 apt/dpkg 锁（仍保留，但不强制杀掉大量进程）
    info "尝试修复被锁定的包管理器状态（温和模式）..."
    dpkg --configure -a || true
    for lock in /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock; do
        if [ -e "$lock" ]; then
            lpid=$(fuser "$lock" 2>/dev/null || true)
            if [ -n "$lpid" ]; then
                warn "检测到进程占用 $lock: $lpid，尝试温和终止..."
                kill "$lpid" 2>/dev/null || kill -9 "$lpid" 2>/dev/null || true
                sleep 1
            fi
            rm -f "$lock" || true
        fi
    done
    dpkg --configure -a || true
    info "锁文件处理完成。"
}

install_packages() {
    local pkgs=("$@")
    detect_pkg_manager
    case "$PKG_MANAGER" in
        apt)
            retry_cmd 5 apt-get update || warn "apt-get update 失败，继续..."
            # 如果用户选择跳过 netfilter 持久化，则从列表中移除 iptables-persistent
            if [ "$SKIP_NETFILTER_PERSISTENT" = "true" ]; then
                local filtered=()
                for p in "${pkgs[@]}"; do
                    if [ "$p" != "iptables-persistent" ]; then
                        filtered+=("$p")
                    fi
                done
                pkgs=("${filtered[@]}")
            fi
            retry_cmd 5 $PKG_INSTALL "${pkgs[@]}" || warn "安装部分包失败，继续（某些包可能已经安装或配置错误）。"
            ;;
        dnf|yum)
            retry_cmd 5 $PKG_INSTALL "${pkgs[@]}" || warn "安装部分包失败，继续（某些包可能已经安装或配置错误）。"
            ;;
    esac
}

choose_nginx_conf() {
    for p in "${NGINX_CONF_CANDIDATES[@]}"; do
        if [ -f "$p" ] || [ "${p##*/}" = "nginx.conf" ]; then
            echo "$p"
            return 0
        fi
    done
    # fallback
    echo "/etc/nginx/sites-available/default"
}

# 检测端口是否被占用（TCP/UDP 通用）
port_in_use() {
    local port=$1
    if command -v lsof >/dev/null 2>&1; then
        lsof -i :"$port" >/dev/null 2>&1 && return 0 || return 1
    elif command -v ss >/dev/null 2>&1; then
        ss -ltn | grep -q ":$port\b" && return 0 || return 1
    else
        return 1
    fi
}

# 移除 acme.sh 安装过程中可能注册的自动任务（crontab 或 systemd/cron）
disable_acmesh_auto() {
    # remove crontab entries for acme.sh (root)
    if command -v crontab >/dev/null 2>&1; then
        if crontab -l 2>/dev/null | grep -q "acme.sh"; then
            crontab -l 2>/dev/null | grep -v "acme.sh" | crontab - || true
            info "已从 crontab 中移除 acme.sh 条目。"
        fi
    fi
    # remove systemd user timer if present (unlikely for root)
    if [ -d /etc/systemd/system ] && systemctl list-timers --all 2>/dev/null | grep -q acme; then
        # try to disable any acme.sh timers
        systemctl list-units --all | grep -i acme | awk '{print $1}' | while read -r unit; do
            systemctl disable --now "$unit" 2>/dev/null || true
        done
        info "已尝试移除可能的 systemd acme 定时任务。"
    fi
}

install_acme_sh_and_issue() {
    info "[4/5] 正在通过 acme.sh 申请证书..."
    ACME_INSTALL_TMP="/tmp/acme_install.sh"
    ACME_HOME_CANDIDATES=("/root/.acme.sh" "$HOME/.acme.sh")

    # 下载安装脚本到临时文件（不直接 pipe），以避免参数解析异常
    if ! retry_cmd 3 curl $CURL_OPTS -o "$ACME_INSTALL_TMP" https://get.acme.sh; then
        warn "下载 acme.sh 安装脚本失败，跳过自动安装/申请证书。"
        return 1
    fi

    # 运行安装脚本 *不传递* --nocron，以避免安装器解析错误。安装完成后我们会主动移除自动任务以达到不使用 cron 的效果。
    bash "$ACME_INSTALL_TMP" || true

    # 尝试定位 acme.sh 可执行文件
    ACME_BIN=""
    for d in "${ACME_HOME_CANDIDATES[@]}"; do
        if [ -x "$d/acme.sh" ]; then
            ACME_BIN="$d/acme.sh"
            ACME_HOME="$d"
            break
        fi
    done
    # fallback: check common location
    if [ -z "$ACME_BIN" ] && [ -x "/root/.acme.sh/acme.sh" ]; then
        ACME_BIN="/root/.acme.sh/acme.sh"
        ACME_HOME="/root/.acme.sh"
    fi

    if [ -z "$ACME_BIN" ]; then
        warn "未找到 acme.sh 安装位置，跳过证书自动申请。"
        return 1
    fi

    # 禁用 acme.sh 安装时可能添加的定时任务/cron
    disable_acmesh_auto

    # 设置默认 CA
    "$ACME_BIN" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true

    # 选择申请模式：优先 standalone（需要 80/443 空闲），否则尝试 nginx 模式
    if ! port_in_use 80 || ! port_in_use 443; then
        # 如果任一端口空闲，尝试 standalone（会短暂监听）
        info "尝试使用 standalone 模式申请（80/443 端口检测为可用）..."
        # nginx 可能在运行，暂时停止以释放端口（只有在需要时）
        local nginx_was_running=false
        if command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx >/dev/null 2>&1; then
            nginx_was_running=true
            systemctl stop nginx >/dev/null 2>&1 || true
            info "暂时停止 nginx 以释放端口。"
        fi

        if "$ACME_BIN" --issue -d "$DOMAIN" --standalone --debug 2>/dev/null; then
            "$ACME_BIN" --install-cert -d "$DOMAIN" --key-file "$CERT_DIR/server.key" --fullchain-file "$CERT_DIR/server.crt" || true
            success "证书申请成功（standalone）。"
            # 恢复 nginx
            if [ "$nginx_was_running" = true ]; then
                systemctl start nginx >/dev/null 2>&1 || true
            fi
            return 0
        else
            warn "standalone 模式申请失败，尝试 nginx 模式（若可用）..."
            if [ "$nginx_was_running" = true ]; then
                systemctl start nginx >/dev/null 2>&1 || true
            fi
        fi
    else
        info "80/443 端口被占用，跳过 standalone 模式，使用 nginx 模式或 webroot 模式。"
    fi

    # nginx 模式（需要 nginx 可用且配置兼容 acme.sh nginx 插件）
    if command -v nginx >/dev/null 2>&1; then
        if "$ACME_BIN" --issue -d "$DOMAIN" --nginx --debug 2>/dev/null; then
            "$ACME_BIN" --install-cert -d "$DOMAIN" --key-file "$CERT_DIR/server.key" --fullchain-file "$CERT_DIR/server.crt" || true
            success "证书申请成功（nginx）。"
            return 0
        fi
    fi

    # webroot fallback: 如果 /var/www/html 存在且可写
    if [ -d "/var/www/html" ]; then
        if "$ACME_BIN" --issue -d "$DOMAIN" --webroot /var/www/html --debug 2>/dev/null; then
            "$ACME_BIN" --install-cert -d "$DOMAIN" --key-file "$CERT_DIR/server.key" --fullchain-file "$CERT_DIR/server.crt" || true
            success "证书申请成功（webroot）。"
            return 0
        fi
    fi

    warn "所有自动申请证书的方式均已尝试但未成功。你可手动将证书放到 $CERT_DIR 并重试。"
    return 1
}

# ---------------- start script ----------------
if ! is_root; then
    err "请以 root 或使用 sudo 执行此脚本。"
    exit 1
fi

info "开始部署 Sing-box（改进版）。详细日志记录到：$LOGFILE"

# 1) 尝试温和解除锁、修复状态（避免强杀导致的卡死）
info "[1/8] 处理可能的包管理器锁与中断状态..."
safe_kill_locking_processes

# 2) 安装基础依赖（带重试）
info "[2/8] 安装系统依赖（请观察输出）..."
BASE_PKGS=(curl wget lsof jq tar nginx ca-certificates iptables iproute2 openssl coreutils iptables-persistent)
# uuid 工具在不同系统名称不同
if command -v uuidgen >/dev/null 2>&1; then
    : # ok
else
    BASE_PKGS+=(uuid-runtime)
fi
install_packages "${BASE_PKGS[@]}"

# 3) 内核优化（BBR），只追加一次
info "[3/8] 配置内核网络优化(BBR)"
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf 2>/dev/null; then
    cat >>/etc/sysctl.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl -p >/dev/null 2>&1 || true
    success "已写入 sysctl 配置并尝试生效。"
else
    info "sysctl 中已存在 BBR 设置，跳过。"
fi

# 4) 交互式输入（加默认与校验）
echo -e "${YELLOW}--------------------------------------------------${NC}"
read -rp "请输入解析到此服务器的域名: " DOMAIN
if [ -z "$DOMAIN" ]; then
    err "域名不能为空，退出。"
    exit 1
fi
read -rp "请输入用于证书申请的邮箱 (可留空): " EMAIL
read -rp "是否开启 HY2 混淆(obfs)? (y/n, 默认 n): " IS_OBFS
IS_OBFS=${IS_OBFS:-"n"}
echo -e "${YELLOW}--------------------------------------------------${NC}"

# DNS 简单校验：检查域名是否指向当前服务器（若无法校验则仅提示）
info "校验域名解析（尽可能）..."
SERVER_IPV4="$(curl -4 -sS https://ifconfig.co || true)"
RESOLVED_IP="$(getent hosts "$DOMAIN" | awk '{print $1}' || true)"
if [ -n "$RESOLVED_IP" ] && [ -n "$SERVER_IPV4" ] && [ "$RESOLVED_IP" != "$SERVER_IPV4" ]; then
    warn "域名 $DOMAIN 解析到 $RESOLVED_IP，而当前服务器公网 IPv4 为 $SERVER_IPV4。请确认 DNS 配置是否正确（如果是 IPv6-only 或特殊情况可忽略）。"
else
    info "域名解析初步检查通过或无法确定（继续）。"
fi

# 5) 安装/申请证书（acme.sh），尽量容错
mkdir -p "$CERT_DIR"
install_acme_sh_and_issue || warn "证书申请阶段未成功完成，后续 TLS 可能无法启用。"

# 6) 安装 sing-box（官方脚本），用临时文件并加 timeout/重试
info "[6/8] 安装 sing-box 程序..."
SINGBOX_INSTALL_URL="https://raw.githubusercontent.com/sagernet/sing-box/main/install.sh"
TMP_INSTALL="/tmp/singbox_install.sh"
if retry_cmd 3 curl $CURL_OPTS "$SINGBOX_INSTALL_URL" -o "$TMP_INSTALL"; then
    bash "$TMP_INSTALL" || warn "运行 sing-box 安装脚本返回非零（继续）。"
else
    warn "下载 sing-box 安装脚本失败，跳过自动安装，请手动安装 sing-box 后再运行脚本。"
fi

SINGBOX_BIN="$(command -v sing-box || /usr/bin/sing-box || /usr/local/bin/sing-box || true)"
if [ -z "$SINGBOX_BIN" ] || [ ! -x "$SINGBOX_BIN" ]; then
    warn "未检测到 sing-box 可执行文件（$SINGBOX_BIN）。配置文件将写入 $CONF_DIR，但服务启动可能失败。"
fi

# 生成 Reality keypair（如果 sing-box 可用）
PRIV_KEY="" ; PUB_KEY=""
if [ -n "$SINGBOX_BIN" ] && [ -x "$SINGBOX_BIN" ]; then
    info "生成 Reality 密钥对..."
    RE_KEYS=$("$SINGBOX_BIN" generate reality-keypair 2>/dev/null || true)
    PRIV_KEY=$(echo "$RE_KEYS" | grep -i "Private key" | awk '{print $3}' || true)
    PUB_KEY=$(echo "$RE_KEYS" | grep -i "Public key" | awk '{print $3}' || true)
    if [ -z "$PRIV_KEY" ] || [ -z "$PUB_KEY" ]; then
        warn "未能通过 sing-box 生成 reality 密钥（输出：$RE_KEYS），将使用占位符（请手动替换）。"
        PRIV_KEY="REPLACEME_PRIVATE_KEY"
        PUB_KEY="REPLACEME_PUBLIC_KEY"
    fi
else
    warn "sing-box 未安装，跳过 reality 密钥生成。"
    PRIV_KEY="REPLACEME_PRIVATE_KEY"
    PUB_KEY="REPLACEME_PUBLIC_KEY"
fi

# 处理 HY2 混淆块
OBFS_BLOCK=""
if [[ "$IS_OBFS" =~ ^[yY]$ ]]; then
    OBFS_BLOCK=", \"obfs\": {\"type\": \"salamander\", \"password\": \"unserionssss66688\"}"
fi

# 确保目录存在并备份
mkdir -p "$CONF_DIR"
if [ -f "$CONF_DIR/config.json" ]; then
    cp -f "$CONF_DIR/config.json" "$CONF_DIR/config.json.bak-$(date +%s)" || true
fi

# 7) 写入 sing-box 配置（保持原格式与逻辑）
info "写入 sing-box 配置到 $CONF_DIR/config.json"
cat > "$CONF_DIR/config.json" <<EOF
{
  "inbounds": [
    {
      "type": "vless", "tag": "vless-reality", "listen": "::", "listen_port": 443,
      "users": [{"uuid": "$UUID", "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": true, "server_name": "www.microsoft.com",
        "reality": {
          "enabled": true, "handshake": { "server": "127.0.0.1", "server_port": $RANDOM_PORT },
          "private_key": "$PRIV_KEY", "short_id": ["$SHORT_ID"]
        }
      }
    },
    {
      "type": "hysteria2", "tag": "hy2-in", "listen": "::", "listen_port": $HY2_PORT,
      "up_mbps": 120, "down_mbps": 120, "users": [{"password": "$UUID"}]${OBFS_BLOCK},
      "tls": {
        "enabled": true, "server_name": "$DOMAIN", "alpn": ["h3"],
        "certificate_path": "$CERT_DIR/server.crt", "key_path": "$CERT_DIR/server.key"
      }
    }
  ],
  "outbounds": [{"type": "direct"}]
}
EOF

# 8) Nginx 回落配置（选择合适配置文件并备份）
NGINX_CONF="$(choose_nginx_conf)"
info "[7/8] 配置 Nginx 回落站点到 $NGINX_CONF（备份原文件）"
if [ -f "$NGINX_CONF" ]; then
    cp -f "$NGINX_CONF" "$NGINX_CONF.bak-$(date +%s)" || true
fi

# 确保回落目录存在
mkdir -p /var/www/html
cat > "$NGINX_CONF" <<EOF
server {
    listen 127.0.0.1:$RANDOM_PORT;
    server_name _;
    location / { root /var/www/html; index index.html; }
}
EOF

# 重启 nginx（如果存在 systemctl 与 nginx）
if command -v nginx >/dev/null 2>&1; then
    if [ -n "$SYSTEMCTL_CMD" ]; then
        systemctl restart nginx || warn "无法通过 systemctl 重启 nginx，请手动检查 nginx 配置后重启。"
    else
        nginx -s reload || nginx || warn "nginx 重启失败。"
    fi
fi

# 9) 端口转发（iptables / nftables 兼容）
info "[8/8] 配置 UDP 转发（443 -> $HY2_PORT）"
IPTABLES_CMD="$(command -v iptables || true)"
IP6TABLES_CMD="$(command -v ip6tables || true)"
NFT_CMD="$(command -v nft || true)"

if [ -n "$IPTABLES_CMD" ]; then
    if ! $IPTABLES_CMD -t nat -C PREROUTING -p udp --dport 443 -j REDIRECT --to-ports "$HY2_PORT" 2>/dev/null; then
        $IPTABLES_CMD -t nat -A PREROUTING -p udp --dport 443 -j REDIRECT --to-ports "$HY2_PORT"
        info "已添加 iptables IPv4 规则。"
    else
        info "iptables IPv4 规则已存在，跳过。"
    fi
elif [ -n "$NFT_CMD" ]; then
    if ! nft list table inet nat >/dev/null 2>&1; then
        nft add table ip nat 2>/dev/null || true
        nft 'add chain ip nat prerouting { type nat hook prerouting priority 0 ; }' 2>/dev/null || true
    fi
    if ! nft list chain ip nat prerouting 2>/dev/null | grep -q "udp dport 443 redirect to :$HY2_PORT"; then
        nft add rule ip nat prerouting udp dport 443 redirect to :$HY2_PORT 2>/dev/null || true
        info "已添加 nftables IPv4 转发规则（可能需调整以适配系统）。"
    else
        info "nftables 规则已存在，跳过。"
    fi
else
    warn "未检测到 iptables 或 nft 工具��无法自动添加 IPv4 转发规则，请手动配置 UDP 443 -> $HY2_PORT 的重定向。"
fi

if [ -n "$IP6TABLES_CMD" ]; then
    if $IP6TABLES_CMD -t nat -C PREROUTING -p udp --dport 443 -j REDIRECT --to-ports "$HY2_PORT" 2>/dev/null; then
        info "ip6tables IPv6 规则已存在，跳过。"
    else
        if $IP6TABLES_CMD -t nat -A PREROUTING -p udp --dport 443 -j REDIRECT --to-ports "$HY2_PORT" 2>/dev/null; then
            info "已添加 ip6tables IPv6 规则。"
        else
            warn "当前系统的 ip6tables 可能不支持 nat 表或添加规则失败（可忽略）。"
        fi
    fi
elif [ -n "$NFT_CMD" ]; then
    if ! nft list table ip6 nat >/dev/null 2>&1; then
        nft add table ip6 nat 2>/dev/null || true
        nft 'add chain ip6 nat prerouting { type nat hook prerouting priority 0 ; }' 2>/dev/null || true
    fi
    if ! nft list chain ip6 nat prerouting 2>/dev/null | grep -q "udp dport 443 redirect to :$HY2_PORT"; then
        nft add rule ip6 nat prerouting udp dport 443 redirect to :$HY2_PORT 2>/dev/null || true
        info "已尝试添加 nftables IPv6 转发规则（可能需调整以适配系统）。"
    fi
fi

# 保存 netfilter 规则（如果 SKIP_NETFILTER_PERSISTENT=false 才持久化）
if [ "$SKIP_NETFILTER_PERSISTENT" = "true" ]; then
    warn "已配置为跳过持久化 netfilter 规则（SKIP_NETFILTER_PERSISTENT=true）。重启后规则可能丢失。"
else
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save || warn "netfilter-persistent save 失败。"
    elif command -v iptables-save >/dev/null 2>&1; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || warn "iptables-save 写入失败。"
        if command -v ip6tables-save >/dev/null 2>&1; then
            ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || warn "ip6tables-save 写入失败。"
        fi
    else
        warn "未找到 netfilter 持久化工具，请手动持久化规则。"
    fi
fi

if [ -n "$SYSTEMCTL_CMD" ] && [ -f "/etc/systemd/system/sing-box.service" -o -f "/lib/systemd/system/sing-box.service" ] ; then
    systemctl enable --now sing-box || warn "尝试启动 sing-box 服务失败，请检查服务状态：systemctl status sing-box"
else
    if command -v sing-box >/dev/null 2>&1; then
        warn "sing-box 可执行文件存在但 systemd 单元未检测到，请手动创建/启动服务，或运行: sing-box run -c $CONF_DIR/config.json"
    else
        warn "sing-box 未安装或未正确安装，无法自动启动服务。"
    fi
fi

success "=================================================="
success "部署流程已完成（脚本执行结束）。请查看上方信息与日志：$LOGFILE"
echo ""
echo -e "UUID: ${BLUE}$UUID${NC}"
echo -e "Reality 公钥: ${BLUE}$PUB_KEY${NC}"
echo -e "Reality ShortID: ${BLUE}$SHORT_ID${NC}"
echo -e "HY2 本地端口: ${BLUE}$HY2_PORT (UDP 443 已尝试自动重定向)${NC}"
success "=================================================="

echo ""
echo -e "${YELLOW}提示：若证书申请失败，请确认 80/443 端口未被其他进程占用，或手动将证书放置到 $CERT_DIR 并重启 sing-box。${NC}"
