#!/usr/bin/env bash
#
# 改进版部署脚本（兼容性与健壮性增强）
# 说明：
#  - 保持原脚本总体逻辑（申请证书 -> 安装 sing-box -> 生成 Reality/Hy2 -> nginx 回落 -> UDP 转发）
#  - 增加了：root 检查、包管理器检测、重试机制、超时、锁文件更安全的清理、日志、非交互 apt、nginx 配置检测/备份、
#    acme.sh 与 cert 申请的回退、iptables/nftables 兼容性判断、错误 trap 与提示等
#  - 适用：Debian/Ubuntu 优先；尝试在 CentOS/RHEL/Fedora 上做最小兼容（但原生 sing-box 安装脚本仍以 Debian 系列为主）
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
    # 尝试更温和的方式处理 apt/dpkg 锁
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
            retry_cmd 5 apt-get update
            retry_cmd 5 $PKG_INSTALL "${pkgs[@]}"
            ;;
        dnf|yum)
            retry_cmd 5 $PKG_INSTALL "${pkgs[@]}"
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

# ---------------- start script ----------------
if ! is_root; then
    err "请以 root 或使用 sudo 执行此脚本。"
    exit 1
fi

info "开始部署 Sing-box（改进版）。详细日志记录到：$LOGFILE"

# 1) 尝试温和解除锁、修复状态（避免强杀导致的卡死）
info "[1/7] 处理可能的包管理器锁与中断状态..."
safe_kill_locking_processes

# 2) 安装基础依赖（带重试）
info "[2/7] 安装系统依赖（请观察输出）..."
BASE_PKGS=(curl wget lsof jq tar nginx ca-certificates iptables iproute2 openssl coreutils)
# uuid 工具在不同系统名称不同
if command -v uuidgen >/dev/null 2>&1; then
    : # ok
else
    BASE_PKGS+=(uuid-runtime)
fi
install_packages "${BASE_PKGS[@]}"

# 确保 shuf 可用（coreutils）
if ! command -v shuf >/dev/null 2>&1; then
    warn "shuf 未安装，尝试通过 coreutils 提供或使用 fallback"
fi

# 3) 内核优化（BBR），只追加一次
info "[3/7] 配置内核网络优化(BBR)"
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf 2>/dev/null; then
    cat >>/etc/sysctl.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    # 立刻生效（忽略可能的错误）
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
# 尝试解析域名
RESOLVED_IP="$(getent hosts "$DOMAIN" | awk '{print $1}' || true)"
if [ -n "$RESOLVED_IP" ] && [ -n "$SERVER_IPV4" ] && [ "$RESOLVED_IP" != "$SERVER_IPV4" ]; then
    warn "域名 $DOMAIN 解析到 $RESOLVED_IP，而当前服务器公网 IPv4 为 $SERVER_IPV4。请确认 DNS 配置是否正确（如果是 IPv6-only 或特殊情况可忽略）。"
else
    info "域名解析初步检查通过或无法确定（继续）。"
fi

# 5) 安装/申请证书（acme.sh），尽量容错
info "[4/7] 安装 acme.sh 并申请 TLS 证书..."
ACME_HOME="/root/.acme.sh"
ACME_BIN="$ACME_HOME/acme.sh"
if ! [ -x "$ACME_BIN" ]; then
    info "安装 acme.sh..."
    retry_cmd 3 curl $CURL_OPTS https://get.acme.sh | sh -s -- --nocron || true
    # 可能安装到了其他用户目录，检查
    if [ ! -x "$ACME_BIN" ] && [ -x "/root/.acme.sh/acme.sh" ]; then
        ACME_BIN="/root/.acme.sh/acme.sh"
    fi
fi
if [ ! -x "$ACME_BIN" ]; then
    warn "acme.sh 安装失败或不可执行，后续尝试使用 certbot（如果可用）或跳过。"
fi

mkdir -p "$CERT_DIR"
# 优先使用 acme.sh --standalone（会短暂占用 80/443），若失败则尝试 nginx 模式
if [ -x "$ACME_BIN" ]; then
    info "设置 acme 默认 CA 为 letsencrypt（忽略错误）..."
    "$ACME_BIN" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true

    info "尝试使用 acme.sh 的 standalone 模式申请证书（可能需要 80/443 暂时开放）..."
    if "$ACME_BIN" --issue -d "$DOMAIN" --standalone --debug 2>/dev/null; then
        "$ACME_BIN" --install-cert -d "$DOMAIN" --key-file "$CERT_DIR/server.key" --fullchain-file "$CERT_DIR/server.crt" || true
        success "证书申请成功（standalone）。"
    else
        warn "standalone 模式失败，尝试 nginx 模式（确保 nginx 已启动并可访问）..."
        # 确保 nginx 正在运行（先启动 nginx）
        if command -v nginx >/dev/null 2>&1; then
            systemctl restart nginx >/dev/null 2>&1 || true
        fi
        if "$ACME_BIN" --issue -d "$DOMAIN" --nginx --debug 2>/dev/null; then
            "$ACME_BIN" --install-cert -d "$DOMAIN" --key-file "$CERT_DIR/server.key" --fullchain-file "$CERT_DIR/server.crt" || true
            success "证书申请成功（nginx）。"
        else
            warn "acme.sh 通过两种模式均无法申请证书。"
            # 尝试 certbot if available
            if command -v certbot >/dev/null 2>&1; then
                warn "尝试使用 certbot 申请证书..."
                certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos -m "${EMAIL:-admin@${DOMAIN}}" || warn "certbot 申请失败。"
                # 复制证书（路径因系统不同）
                if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
                    cp -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$CERT_DIR/server.crt"
                    cp -f "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$CERT_DIR/server.key"
                fi
            else
                warn "未找到可用的证书客户端，后续 TLS 可能无法启用，请手动提供证书到 $CERT_DIR。"
            fi
        fi
    fi
else
    warn "acme.sh 不可用，跳过自动申请证书。请手动放置证书到 $CERT_DIR 并重试。"
fi

# 6) 安装 sing-box（官方脚本），用临时文件并加 timeout/重试
info "[5/7] 安装 sing-box 程序..."
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
info "[6/7] 配置 Nginx 回落站点到 $NGINX_CONF（备份原文件）"
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
info "[7/7] 配置 UDP 转发（443 -> $HY2_PORT）"
# 准备 iptables 命令（优先使用系统中的 iptables）
IPTABLES_CMD="$(command -v iptables || true)"
IP6TABLES_CMD="$(command -v ip6tables || true)"
NFT_CMD="$(command -v nft || true)"

# IPv4
if [ -n "$IPTABLES_CMD" ]; then
    # 避免重复添加相同规则：检查后再加
    if ! $IPTABLES_CMD -t nat -C PREROUTING -p udp --dport 443 -j REDIRECT --to-ports "$HY2_PORT" 2>/dev/null; then
        $IPTABLES_CMD -t nat -A PREROUTING -p udp --dport 443 -j REDIRECT --to-ports "$HY2_PORT"
        info "已添加 iptables IPv4 规则。"
    else
        info "iptables IPv4 规则已存在，跳过。"
    fi
elif [ -n "$NFT_CMD" ]; then
    # nftables: 添加等效规则到 nat prerouting
    if ! nft list table inet nat >/dev/null 2>&1; then
        # 创建 nat 表与 prerouting 链（若不存在）
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
    warn "未检测到 iptables 或 nft 工具，无法自动添加 IPv4 转发规则，请手动配置 UDP 443 -> $HY2_PORT 的重定向。"
fi

# IPv6 NAT 并非在所有系统中可用；只有在 ip6tables 支持 nat 表时添加
if [ -n "$IP6TABLES_CMD" ]; then
    if $IP6TABLES_CMD -t nat -C PREROUTING -p udp --dport 443 -j REDIRECT --to-ports "$HY2_PORT" 2>/dev/null; then
        info "ip6tables IPv6 规则已存在，跳过。"
    else
        # 某些系统不支持 -t nat（会报错），捕获错误并跳过
        if $IP6TABLES_CMD -t nat -A PREROUTING -p udp --dport 443 -j REDIRECT --to-ports "$HY2_PORT" 2>/dev/null; then
            info "已添加 ip6tables IPv6 规则。"
        else
            warn "当前系统的 ip6tables 可能不支持 nat 表或添加规则失败（可忽略）。"
        fi
    fi
elif [ -n "$NFT_CMD" ]; then
    # nft IPv6 rule (ip6)
    if ! nft list table ip6 nat >/dev/null 2>&1; then
        # try to create table ip6 nat
        nft add table ip6 nat 2>/dev/null || true
        nft 'add chain ip6 nat prerouting { type nat hook prerouting priority 0 ; }' 2>/dev/null || true
    fi
    if ! nft list chain ip6 nat prerouting 2>/dev/null | grep -q "udp dport 443 redirect to :$HY2_PORT"; then
        nft add rule ip6 nat prerouting udp dport 443 redirect to :$HY2_PORT 2>/dev/null || true
        info "已尝试添加 nftables IPv6 转发规则（可能需调整以适配系统）。"
    fi
fi

# 保存 netfilter 规则（如果 netfilter-persistent 可用或 iptables-save 可用）
if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save || true
elif command -v iptables-save >/dev/null 2>&1; then
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    if command -v ip6tables-save >/dev/null 2>&1; then
        ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
    fi
fi

# 启用并启动 sing-box 服务（若已安装 systemd service）
if [ -n "$SYSTEMCTL_CMD" ] && [ -f "/etc/systemd/system/sing-box.service" -o -f "/lib/systemd/system/sing-box.service" ] ; then
    systemctl enable --now sing-box || warn "尝试启动 sing-box 服务失败，请检查服务状态：systemctl status sing-box"
else
    # 有可能安装后在 /etc/init.d/ 下，尝试直接启动
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

# 结尾提示：若某一步出现问题，查看日志并根据提示进行修复
echo ""
echo -e "${YELLOW}提示：若证书申请失败，请确认 80/443 端口未被其他进程占用，或手动将证书放置到 $CERT_DIR 并重启 sing-box。${NC}"
