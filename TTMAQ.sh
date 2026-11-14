#!/bin/bash
#
# Surge TrustTunnel & MASQUE (volto) VPS 一键安装与管理脚本
# 适用系统: Debian 11+ / Ubuntu 22.04+ (x86_64 / aarch64)
# 参考风格: https://raw.githubusercontent.com/wangpao/vps/main/snell.sh
#

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN="\033[0m"

CONNECT_TIMEOUT=15

# TrustTunnel 路径与默认版本
TT_DIR="/opt/trusttunnel"
TT_BIN="${TT_DIR}/trusttunnel_endpoint"
TT_VPN_CONF="${TT_DIR}/vpn.toml"
TT_HOSTS_CONF="${TT_DIR}/hosts.toml"
TT_CRED_CONF="${TT_DIR}/credentials.toml"
TT_RULES_CONF="${TT_DIR}/rules.toml"
TT_META="${TT_DIR}/.script_meta"
TT_SERVICE="/etc/systemd/system/trusttunnel.service"
TT_DEFAULT_VER="v1.1.0"

# MASQUE (volto) 路径与默认版本
MASQUE_BIN="/usr/local/bin/volto"
MASQUE_DIR="/etc/volto"
MASQUE_CONF="${MASQUE_DIR}/config.toml"
MASQUE_META="${MASQUE_DIR}/.script_meta"
MASQUE_SERVICE="/etc/systemd/system/volto.service"
MASQUE_HOP_SERVICE="/etc/systemd/system/volto-port-hopping.service"
MASQUE_DEFAULT_VER="v1.4.0"

IP4=""
IP6=""
ARCH_RAW=""
TT_ARCH=""
MASQUE_ARCH=""

colorEcho() {
    echo -e "${1}${*:2}${PLAIN}"
}

confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local answer
    if [[ "$default" == "y" ]]; then
        read -r -p "${prompt} [y/n] (默认y, 回车): " answer </dev/tty
        [[ -z "$answer" ]] && answer="y"
    else
        read -r -p "${prompt} [y/n] (默认n, 回车): " answer </dev/tty
        [[ -z "$answer" ]] && answer="n"
    fi
    [[ "${answer}" =~ ^[Yy]$ ]]
}

pause() {
    echo ""
    read -r -p "按回车键继续..." _ </dev/tty
}

checkRoot() {
    if [[ ${EUID} -ne 0 ]]; then
        colorEcho "$RED" "错误：此脚本必须以 root 用户身份运行！"
        exit 1
    fi
}

checkSystem() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        if [[ "$ID" == "ubuntu" ]]; then
            if dpkg --compare-versions "${VERSION_ID:-0}" lt "22.04"; then
                colorEcho "$RED" "仅支持 Ubuntu 22.04 及以上版本"
                exit 1
            fi
        elif [[ "$ID" == "debian" ]]; then
            if dpkg --compare-versions "${VERSION_ID:-0}" lt "11"; then
                colorEcho "$RED" "仅支持 Debian 11 及以上版本"
                exit 1
            fi
        else
            colorEcho "$RED" "仅支持 Debian 11+ 或 Ubuntu 22.04+ 系统（当前: ${ID:-unknown}）"
            exit 1
        fi
    else
        colorEcho "$RED" "无法识别系统版本，仅支持 Debian 11+ 或 Ubuntu 22.04+"
        exit 1
    fi

    ARCH_RAW="$(uname -m)"
    case "${ARCH_RAW}" in
        x86_64|amd64)
            TT_ARCH="linux-x86_64"
            MASQUE_ARCH="x86_64-unknown-linux-musl"
            ;;
        aarch64|arm64)
            TT_ARCH="linux-aarch64"
            MASQUE_ARCH="aarch64-unknown-linux-musl"
            ;;
        *)
            colorEcho "$RED" "不支持的 CPU 架构: ${ARCH_RAW}（仅支持 x86_64 / aarch64）"
            exit 1
            ;;
    esac
}

detectPublicIPs() {
    IP4=$(curl -sL --connect-timeout 4 --max-time 6 -4 ip.sb 2>/dev/null | tr -d '[:space:]')
    if [[ -z "$IP4" ]]; then
        IP4=$(curl -sL --connect-timeout 4 --max-time 6 -4 ifconfig.me 2>/dev/null | tr -d '[:space:]')
    fi
    IP6=$(curl -sL --connect-timeout 4 --max-time 6 -6 ip.sb 2>/dev/null | tr -d '[:space:]')
}

installDependencies() {
    local need_update=0
    local pkgs=()
    for cmd_pkg in "curl:curl" "wget:wget" "tar:tar" "openssl:openssl" "ss:iproute2" "iptables:iptables"; do
        local cmd="${cmd_pkg%%:*}"
        local pkg="${cmd_pkg##*:}"
        if ! command -v "$cmd" >/dev/null 2>&1; then
            pkgs+=("$pkg")
            need_update=1
        fi
    done
    if [[ ! -f /etc/ssl/certs/ca-certificates.crt ]]; then
        pkgs+=("ca-certificates")
        need_update=1
    fi
    if [[ $need_update -eq 1 ]]; then
        colorEcho "$YELLOW" "正在安装基础依赖: ${pkgs[*]} ..."
        apt-get update -y && apt-get install -y "${pkgs[@]}"
        if [[ $? -ne 0 ]]; then
            colorEcho "$RED" "基础依赖安装失败，请检查 apt 源或网络连接。"
            exit 1
        fi
    fi
}

installCertbot() {
    if ! command -v certbot >/dev/null 2>&1; then
        colorEcho "$YELLOW" "正在安装 certbot..."
        apt-get update -y && apt-get install -y certbot
        if [[ $? -ne 0 ]]; then
            colorEcho "$RED" "certbot 安装失败！"
            return 1
        fi
    fi
    return 0
}

hasIPv6Route() {
    ip -6 route show default 2>/dev/null | grep -q .
}

getListenHost() {
    if [[ -n "$IP4" ]]; then
        echo "0.0.0.0"
    elif [[ -n "$IP6" ]]; then
        echo "[::]"
    else
        echo "0.0.0.0"
    fi
}

validatePort() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] && [[ "$p" -ge 1 && "$p" -le 65535 ]]
}

checkTcpPortInUse() {
    local p="$1"
    ss -H -ltn "sport = :${p}" 2>/dev/null | grep -q .
}

checkUdpPortInUse() {
    local p="$1"
    ss -H -lun "sport = :${p}" 2>/dev/null | grep -q .
}

generateSafePassword() {
    local len="${1:-16}"
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len"
}

validateCredentialField() {
    local val="$1"
    local field="$2"
    local max_bytes="${3:-128}"
    if [[ -z "$val" ]]; then
        colorEcho "$RED" "${field} 不能为空。"
        return 1
    fi
    if [[ "$(printf '%s' "$val" | wc -c)" -gt "$max_bytes" ]]; then
        colorEcho "$RED" "${field} 长度不能超过 ${max_bytes} 字节。"
        return 1
    fi
    case "$val" in
        *'"'*|*\\*|*'|'*|*'&'*|*,*|*[[:space:]]*)
            colorEcho "$RED" "${field} 不能包含引号(\" )、反斜杠(\\)、竖线(|)、&、逗号(,)或空白字符。"
            return 1
            ;;
    esac
    if [[ "$field" == "用户名" && "$val" == *:* ]]; then
        colorEcho "$RED" "用户名不能包含冒号(:)。"
        return 1
    fi
    return 0
}

allowUfwPort() {
    local port="$1"
    local proto="$2"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        ufw allow "${port}/${proto}" >/dev/null 2>&1 && \
            colorEcho "$GREEN" "已放行 ufw 防火墙: ${port}/${proto}"
    fi
}

generateSelfSignedCert() {
    local sni="$1"
    local cert_out="$2"
    local key_out="$3"
    mkdir -p "$(dirname "$cert_out")"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$key_out" -out "$cert_out" \
        -days 3650 -nodes \
        -subj "/CN=${sni}" \
        -addext "subjectAltName=DNS:${sni}" \
        -addext "basicConstraints=critical,CA:FALSE" \
        -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
        -addext "extendedKeyUsage=serverAuth" >/dev/null 2>&1
}

getCertFingerprint() {
    local cert="$1"
    if [[ -f "$cert" ]]; then
        openssl x509 -in "$cert" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//'
    fi
}

getCertExpiry() {
    local cert="$1"
    if [[ -f "$cert" ]]; then
        openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2
    fi
}

checkDomainResolvesToSelf() {
    local domain="$1"
    local resolved
    resolved=$(getent ahosts "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
    if [[ -z "$resolved" ]]; then
        colorEcho "$YELLOW" "警告：当前无法在 VPS 上解析域名 ${domain}，请确认 DNS A/AAAA 记录已生效。"
        return 1
    fi
    local matched=0
    for ip in $resolved; do
        if [[ -n "$IP4" && "$ip" == "$IP4" ]] || [[ -n "$IP6" && "$ip" == "$IP6" ]]; then
            matched=1
            break
        fi
    done
    if [[ $matched -eq 0 ]]; then
        colorEcho "$YELLOW" "警告：域名 ${domain} 解析结果为 [$(echo "$resolved" | tr '\n' ' ')]，与本机公网 IP (${IP4:-无}/${IP6:-无}) 不一致。"
        colorEcho "$YELLOW" "如果前面套了 CDN（如 Cloudflare 橙色云朵），HTTP-01 申请 Let's Encrypt 证书会失败！"
        return 1
    fi
    colorEcho "$GREEN" "域名解析验证通过: ${domain} -> ${IP4:-$IP6}"
    return 0
}

issueLetsEncryptCert() {
    local domain="$1"
    installCertbot || return 1

    if checkTcpPortInUse 80; then
        colorEcho "$RED" "检测到本机 80/tcp 端口已被占用："
        ss -tlpn "sport = :80" 2>/dev/null
        colorEcho "$YELLOW" "Let's Encrypt standalone 模式需要临时使用 80/tcp 端口，请先停止占用 80 端口的服务后重试。"
        return 1
    fi

    checkDomainResolvesToSelf "$domain" || {
        confirm "DNS 解析似乎尚未指向本机，仍要强行尝试申请吗？" "n" || return 1
    }

    local email
    read -r -p "请输入证书通知邮箱 (可选，直接回车跳过): " email </dev/tty
    colorEcho "$YELLOW" "正在通过 Let's Encrypt 申请 ECDSA 证书 (${domain})..."

    if [[ -n "$email" ]]; then
        certbot certonly --standalone --non-interactive --agree-tos \
            --email "$email" --key-type ecdsa -d "$domain"
    else
        certbot certonly --standalone --non-interactive --agree-tos \
            --register-unsafely-without-email --key-type ecdsa -d "$domain"
    fi

    if [[ $? -ne 0 ]] || [[ ! -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
        colorEcho "$RED" "Let's Encrypt 证书申请失败！请检查：1) 域名是否已解析到本机 IP；2) 80/tcp 防火墙是否放行。"
        return 1
    fi
    colorEcho "$GREEN" "Let's Encrypt 证书申请成功！"
    return 0
}

# ==================== BBR & 内核优化 ====================

Get_bbr_status() {
    BBR_ALGO=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    BBR_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null)
}

Show_bbr_menu_status() {
    Get_bbr_status
    if [[ "$BBR_ALGO" == "bbr" && "$BBR_QDISC" == "fq" ]]; then
        echo -e "   ${BLUE}BBR 状态:${PLAIN} ${GREEN}已开启 (bbr + fq)${PLAIN}"
        BBR_ENABLED=true
    else
        echo -e "   ${BLUE}BBR 状态:${PLAIN} ${RED}未开启 (${BBR_ALGO:-未知} / ${BBR_QDISC:-未知})${PLAIN}"
        BBR_ENABLED=false
    fi
}

Enable_bbr() {
    local sysctl_file="/etc/sysctl.d/99-surge-proxy.conf"
    mkdir -p /etc/sysctl.d
    colorEcho "$YELLOW" "正在配置 BBR 及 QUIC/UDP 缓冲区..."
    if [[ -f /etc/sysctl.conf ]]; then
        sed -i '/^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=/d' /etc/sysctl.conf
        sed -i '/^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=/d' /etc/sysctl.conf
        sed -i '/^[[:space:]]*net\.ipv4\.tcp_fastopen[[:space:]]*=/d' /etc/sysctl.conf
    fi
    cat > "$sysctl_file" <<-EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 4194304
net.core.wmem_max = 4194304
EOF
    if ! (sysctl --system >/dev/null 2>&1 || sysctl -p "$sysctl_file" >/dev/null 2>&1); then
        colorEcho "$RED" "应用内核参数失败，请检查 ${sysctl_file}。"
        return 1
    fi
    Get_bbr_status
    if [[ "$BBR_ALGO" == "bbr" && "$BBR_QDISC" == "fq" ]]; then
        colorEcho "$GREEN" "BBR 与 UDP 缓冲区优化已生效 (bbr + fq)。"
    else
        colorEcho "$RED" "配置已写入，但验证失败，当前内核可能不支持 BBR。"
        return 1
    fi
}

BBR_menu() {
    clear
    echo "########################################"
    echo -e "#       ${YELLOW}管理 BBR 与内核网络优化${PLAIN}        #"
    echo "########################################"
    echo ""
    Show_bbr_menu_status
    echo ""
    if [[ "$BBR_ENABLED" == "true" ]]; then
        colorEcho "$GREEN" "BBR 已开启。"
        if confirm "是否仍要写入 QUIC/UDP 缓冲区优化参数？" "n"; then
            Enable_bbr
        fi
    else
        if confirm "是否立即开启 BBR 并优化 UDP 缓冲区？" "y"; then
            Enable_bbr
        fi
    fi
    pause
}

# ==================== TrustTunnel 模块 ====================

TT_status_code() {
    if [[ ! -f "$TT_BIN" ]]; then
        echo 0
        return
    fi
    if [[ ! -f "$TT_VPN_CONF" || ! -f "$TT_HOSTS_CONF" ]]; then
        echo 1
        return
    fi
    if systemctl is-active --quiet trusttunnel 2>/dev/null; then
        echo 3
    else
        echo 2
    fi
}

TT_load_meta() {
    TT_VER=""
    TT_PORT=""
    TT_DOMAIN=""
    TT_CERT_MODE=""
    TT_CERT_PATH=""
    TT_KEY_PATH=""
    TT_USERNAME=""
    TT_PASSWORD=""
    TT_ENABLE_H3=""
    if [[ -f "$TT_META" ]]; then
        . "$TT_META"
    fi
}

TT_save_meta() {
    mkdir -p "$TT_DIR"
    cat > "$TT_META" <<-EOF
TT_VER='${TT_VER}'
TT_PORT='${TT_PORT}'
TT_DOMAIN='${TT_DOMAIN}'
TT_CERT_MODE='${TT_CERT_MODE}'
TT_CERT_PATH='${TT_CERT_PATH}'
TT_KEY_PATH='${TT_KEY_PATH}'
TT_USERNAME='${TT_USERNAME}'
TT_PASSWORD='${TT_PASSWORD}'
TT_ENABLE_H3='${TT_ENABLE_H3}'
EOF
    chmod 600 "$TT_META"
}

TT_resolve_version() {
    local target_ver=""
    colorEcho "$YELLOW" "正在获取 TrustTunnel 最新稳定版本..."
    target_ver=$(curl -fsSL --connect-timeout "${CONNECT_TIMEOUT}" --max-time 20 \
        "https://api.github.com/repos/TrustTunnel/TrustTunnel/releases/latest" 2>/dev/null \
        | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/')
    if [[ -z "$target_ver" ]]; then
        target_ver="$TT_DEFAULT_VER"
        colorEcho "$YELLOW" "无法连接 GitHub API，将使用默认版本: ${target_ver}"
    else
        colorEcho "$GREEN" "检测到 TrustTunnel 最新稳定版: ${target_ver}"
    fi
    TT_VER="$target_ver"
}

TT_download_and_install() {
    local ver="$1"
    local tarball="trusttunnel-${ver}-${TT_ARCH}.tar.gz"
    local url="https://github.com/TrustTunnel/TrustTunnel/releases/download/${ver}/${tarball}"
    local tmp_dir="/tmp/trusttunnel_install"
    local archive="${tmp_dir}/${tarball}"

    rm -rf "$tmp_dir"
    mkdir -p "$tmp_dir" "$TT_DIR"

    if [[ -n "${TRUSTTUNNEL_TAR:-}" && -f "${TRUSTTUNNEL_TAR}" ]]; then
        colorEcho "$YELLOW" "使用本地安装包: ${TRUSTTUNNEL_TAR}"
        cp "${TRUSTTUNNEL_TAR}" "$archive"
    else
        colorEcho "$YELLOW" "正在下载 TrustTunnel: ${url}"
        wget --connect-timeout="${CONNECT_TIMEOUT}" --read-timeout=60 --timeout=60 --tries=3 \
            -O "$archive" "$url"
        if [[ $? -ne 0 || ! -s "$archive" ]]; then
            colorEcho "$RED" "下载 TrustTunnel 失败！如果 VPS 无法访问 GitHub，可手动下载 ${tarball} 并上传到 VPS。"
            local local_tar
            read -r -p "请输入本地安装包路径（直接回车退出）: " local_tar </dev/tty
            if [[ -z "$local_tar" || ! -f "$local_tar" ]]; then
                rm -rf "$tmp_dir"
                return 1
            fi
            cp "$local_tar" "$archive"
        fi
    fi

    tar -xzf "$archive" -C "$tmp_dir"
    if [[ $? -ne 0 ]]; then
        colorEcho "$RED" "解压失败: ${archive}"
        rm -rf "$tmp_dir"
        return 1
    fi

    local found_bin
    found_bin=$(find "$tmp_dir" -type f -name "trusttunnel_endpoint" | head -n 1)
    if [[ -z "$found_bin" ]]; then
        colorEcho "$RED" "压缩包中未找到 trusttunnel_endpoint 可执行文件！"
        rm -rf "$tmp_dir"
        return 1
    fi

    local src_dir
    src_dir="$(dirname "$found_bin")"
    install -m 0755 "${src_dir}/trusttunnel_endpoint" "${TT_DIR}/trusttunnel_endpoint"
    [[ -f "${src_dir}/setup_wizard" ]] && install -m 0755 "${src_dir}/setup_wizard" "${TT_DIR}/setup_wizard"
    [[ -f "${src_dir}/trusttunnel.service.template" ]] && install -m 0644 "${src_dir}/trusttunnel.service.template" "${TT_DIR}/trusttunnel.service.template"
    rm -rf "$tmp_dir"
    colorEcho "$GREEN" "TrustTunnel 二进制文件已安装到 ${TT_DIR}"
    return 0
}

TT_configure_interactive() {
    local default_port="${TT_PORT:-443}"
    local default_user="${TT_USERNAME:-surge}"
    local default_pass="${TT_PASSWORD:-}"
    local default_h3="${TT_ENABLE_H3:-true}"

    # 1. 端口
    while true; do
        read -r -p "请输入 TrustTunnel 监听端口 [1-65535] (默认: ${default_port}): " TT_PORT </dev/tty
        [[ -z "$TT_PORT" ]] && TT_PORT="$default_port"
        if ! validatePort "$TT_PORT"; then
            colorEcho "$RED" "端口格式错误，请输入 1-65535 之间的数字。"
            continue
        fi
        if checkTcpPortInUse "$TT_PORT" && ! systemctl is-active --quiet trusttunnel 2>/dev/null; then
            colorEcho "$YELLOW" "警告：TCP 端口 ${TT_PORT} 当前已被其他进程占用："
            ss -tlpn "sport = :${TT_PORT}" 2>/dev/null
            confirm "确定仍要使用端口 ${TT_PORT} 吗？" "n" || continue
        fi
        break
    done

    # 2. HTTP/3 (QUIC)
    echo ""
    colorEcho "$BLUE" "是否开启 TrustTunnel 的 HTTP/3 (QUIC) 支持？"
    echo "  提示：Surge Mac 6.4.4+ 原生支持 HTTP/2 (TCP)；开启 HTTP/3 后会同时监听 UDP ${TT_PORT}。"
    echo "  提示：如果你打算在同一台 VPS 的相同端口 (${TT_PORT}) 上同时部署 MASQUE，请选 n（只保留 TCP/HTTP2）。"
    if [[ "$default_h3" == "true" ]]; then
        if confirm "开启 TrustTunnel HTTP/3 (QUIC)？" "y"; then
            TT_ENABLE_H3="true"
        else
            TT_ENABLE_H3="false"
        fi
    else
        if confirm "开启 TrustTunnel HTTP/3 (QUIC)？" "n"; then
            TT_ENABLE_H3="true"
        else
            TT_ENABLE_H3="false"
        fi
    fi

    if [[ "$TT_ENABLE_H3" == "true" ]] && checkUdpPortInUse "$TT_PORT" && ! systemctl is-active --quiet trusttunnel 2>/dev/null; then
        colorEcho "$YELLOW" "警告：UDP 端口 ${TT_PORT} 已被其他进程（如 MASQUE/volto）占用！"
        if ! confirm "继续开启 QUIC 可能导致端口冲突，仍要开启吗？" "n"; then
            TT_ENABLE_H3="false"
        fi
    fi

    # 3. 证书方式
    echo ""
    colorEcho "$YELLOW" "请选择 TrustTunnel TLS 证书方式："
    echo -e "  ${GREEN}1.${PLAIN} Let's Encrypt 自动申请域名证书 (推荐，需有域名解析到本机且 80/tcp 空闲)"
    echo -e "  ${GREEN}2.${PLAIN} 自签 ECDSA 证书 + 指纹固定 (无需域名，Surge 使用指纹验证)"
    echo -e "  ${GREEN}3.${PLAIN} 使用已有证书文件 (手动输入路径)"
    local cert_choice
    while true; do
        read -r -p "请选择证书方式 [1-3] (默认: 1): " cert_choice </dev/tty
        [[ -z "$cert_choice" ]] && cert_choice="1"
        case "$cert_choice" in
            1)
                local d_in
                read -r -p "请输入已解析到本机 VPS 的域名 (如 tt.example.com): " d_in </dev/tty
                [[ -z "$d_in" ]] && { colorEcho "$RED" "域名不能为空。"; continue; }
                if ! issueLetsEncryptCert "$d_in"; then
                    continue
                fi
                TT_CERT_MODE="letsencrypt"
                TT_DOMAIN="$d_in"
                TT_CERT_PATH="/etc/letsencrypt/live/${TT_DOMAIN}/fullchain.pem"
                TT_KEY_PATH="/etc/letsencrypt/live/${TT_DOMAIN}/privkey.pem"
                mkdir -p /etc/letsencrypt/renewal-hooks/deploy
                cat > /etc/letsencrypt/renewal-hooks/deploy/trusttunnel.sh <<-'HOOK'
#!/bin/sh
systemctl restart trusttunnel >/dev/null 2>&1 || true
HOOK
                chmod +x /etc/letsencrypt/renewal-hooks/deploy/trusttunnel.sh
                break
                ;;
            2)
                local sni_in
                read -r -p "请输入自签证书 SNI 伪装域名 (默认: ${TT_DOMAIN:-tt.internal}): " sni_in </dev/tty
                [[ -z "$sni_in" ]] && sni_in="${TT_DOMAIN:-tt.internal}"
                TT_CERT_MODE="selfsigned"
                TT_DOMAIN="$sni_in"
                TT_CERT_PATH="${TT_DIR}/certs/cert.pem"
                TT_KEY_PATH="${TT_DIR}/certs/key.pem"
                generateSelfSignedCert "$TT_DOMAIN" "$TT_CERT_PATH" "$TT_KEY_PATH"
                chmod 644 "$TT_CERT_PATH"
                chmod 600 "$TT_KEY_PATH"
                colorEcho "$GREEN" "自签证书已生成: ${TT_CERT_PATH}"
                break
                ;;
            3)
                local c_path k_path h_in
                read -r -p "请输入证书主机名/SNI (如 tt.example.com): " h_in </dev/tty
                read -r -p "请输入证书链文件 (fullchain.pem) 路径: " c_path </dev/tty
                read -r -p "请输入私钥文件 (privkey.pem) 路径: " k_path </dev/tty
                if [[ -z "$h_in" || ! -f "$c_path" || ! -f "$k_path" ]]; then
                    colorEcho "$RED" "主机名或证书文件路径无效，请重新输入。"
                    continue
                fi
                TT_CERT_MODE="custom"
                TT_DOMAIN="$h_in"
                TT_CERT_PATH="$c_path"
                TT_KEY_PATH="$k_path"
                break
                ;;
            *)
                colorEcho "$RED" "输入无效，请输入 1-3。"
                ;;
        esac
    done

    # 4. 用户名与密码
    echo ""
    while true; do
        read -r -p "请输入 TrustTunnel 用户名 (默认: ${default_user}): " TT_USERNAME </dev/tty
        [[ -z "$TT_USERNAME" ]] && TT_USERNAME="$default_user"
        validateCredentialField "$TT_USERNAME" "用户名" 64 && break
    done

    while true; do
        if [[ -n "$default_pass" ]]; then
            read -r -p "请输入 TrustTunnel 密码 (直接回车保持当前密码): " TT_PASSWORD </dev/tty
            [[ -z "$TT_PASSWORD" ]] && TT_PASSWORD="$default_pass"
        else
            read -r -p "请输入 TrustTunnel 密码 (直接回车随机生成 16 位密码): " TT_PASSWORD </dev/tty
            [[ -z "$TT_PASSWORD" ]] && TT_PASSWORD="$(generateSafePassword 16)"
        fi
        validateCredentialField "$TT_PASSWORD" "密码" 128 && break
        default_pass=""
    done
    colorEcho "$BLUE" "用户名: ${TT_USERNAME} | 密码: ${TT_PASSWORD}"
}

TT_write_configs() {
    local ipv6_flag="false"
    hasIPv6Route && ipv6_flag="true"
    local listen_host
    listen_host="$(getListenHost)"

    cat > "$TT_VPN_CONF" <<-EOF
listen_address = "${listen_host}:${TT_PORT}"
ipv6_available = ${ipv6_flag}
allow_private_network_connections = false
tls_handshake_timeout_secs = 10
client_listener_timeout_secs = 600
connection_establishment_timeout_secs = 30
tcp_connections_timeout_secs = 604800
udp_connections_timeout_secs = 300
credentials_file = "${TT_CRED_CONF}"
rules_file = "${TT_RULES_CONF}"

[listen_protocols]

[listen_protocols.http1]
upload_buffer_size = 32768

[listen_protocols.http2]
initial_connection_window_size = 8388608
initial_stream_window_size = 131072
max_concurrent_streams = 1000
max_frame_size = 16384
header_table_size = 65536
EOF

    if [[ "$TT_ENABLE_H3" == "true" ]]; then
        cat >> "$TT_VPN_CONF" <<-EOF

[listen_protocols.quic]
recv_udp_payload_size = 1350
send_udp_payload_size = 1350
initial_max_data = 104857600
initial_max_stream_data_bidi_local = 1048576
initial_max_stream_data_bidi_remote = 1048576
initial_max_stream_data_uni = 1048576
initial_max_streams_bidi = 4096
initial_max_streams_uni = 4096
max_connection_window = 25165824
max_stream_window = 16777216
disable_active_migration = true
enable_early_data = true
message_queue_capacity = 4096
EOF
    fi

    cat >> "$TT_VPN_CONF" <<-EOF

[forward_protocol]
direct = {}
EOF

    cat > "$TT_HOSTS_CONF" <<-EOF
[[main_hosts]]
hostname = "${TT_DOMAIN}"
cert_chain_path = "${TT_CERT_PATH}"
private_key_path = "${TT_KEY_PATH}"
EOF

    cat > "$TT_CRED_CONF" <<-EOF
[[client]]
username = "${TT_USERNAME}"
password = "${TT_PASSWORD}"
EOF

    if [[ ! -f "$TT_RULES_CONF" ]]; then
        cat > "$TT_RULES_CONF" <<-EOF
# TrustTunnel 连接过滤规则（默认留空则允许所有已认证连接）
EOF
    fi

    TT_save_meta
}

TT_deploy_service() {
    cat > "$TT_SERVICE" <<-EOF
[Unit]
Description=TrustTunnel Endpoint
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${TT_DIR}
ExecStart=${TT_BIN} ${TT_VPN_CONF} ${TT_HOSTS_CONF}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable trusttunnel >/dev/null 2>&1
    systemctl restart trusttunnel

    allowUfwPort "$TT_PORT" "tcp"
    if [[ "$TT_ENABLE_H3" == "true" ]]; then
        allowUfwPort "$TT_PORT" "udp"
    fi

    sleep 1
    if ! systemctl is-active --quiet trusttunnel; then
        colorEcho "$RED" "TrustTunnel 启动失败，最近日志如下："
        journalctl -u trusttunnel -n 20 --no-pager
        return 1
    fi
    return 0
}

TT_show_surge_config() {
    TT_load_meta
    if [[ -z "$TT_PORT" || ! -f "$TT_VPN_CONF" ]]; then
        colorEcho "$RED" "TrustTunnel 尚未安装或配置不完整。"
        return
    fi

    local host="${TT_DOMAIN}"
    local extra=""
    if [[ "$TT_CERT_MODE" == "selfsigned" ]]; then
        host="${IP4:-${IP6:-<VPS_IP>}}"
        local fp
        fp=$(getCertFingerprint "$TT_CERT_PATH")
        extra=", sni=${TT_DOMAIN}, server-cert-fingerprint-sha256=${fp}"
    fi

    echo ""
    colorEcho "$GREEN" "=== TrustTunnel Surge 配置信息 ==="
    echo -e "  ${BLUE}配置文件:${PLAIN} ${TT_VPN_CONF}"
    echo -e "  ${BLUE}安装版本:${PLAIN} ${TT_VER:-未知}"
    echo -e "  ${BLUE}证书模式:${PLAIN} ${TT_CERT_MODE} (域名/SNI: ${TT_DOMAIN})"
    echo -e "  ${BLUE}HTTP/3:${PLAIN}   ${TT_ENABLE_H3}"
    if [[ -f "$TT_CERT_PATH" ]]; then
        echo -e "  ${BLUE}证书到期:${PLAIN} $(getCertExpiry "$TT_CERT_PATH")"
    fi
    echo ""
    colorEcho "$YELLOW" "可直接粘贴到 Surge [Proxy] 分组："
    echo "  TrustTunnel = trust-tunnel, ${host}, ${TT_PORT}, username=${TT_USERNAME}, password=${TT_PASSWORD}${extra}"
    if [[ "$TT_ENABLE_H3" == "true" ]]; then
        echo "  # (若客户端支持 HTTP/3，可追加 h3=true)："
        echo "  TrustTunnel-H3 = trust-tunnel, ${host}, ${TT_PORT}, username=${TT_USERNAME}, password=${TT_PASSWORD}${extra}, h3=true"
    fi
    echo -e "  ${YELLOW}注: Surge 中的 trust-tunnel 仅代理 TCP（不支持 udp-relay）。${PLAIN}"
}

TT_install_or_upgrade() {
    if [[ -f "$TT_BIN" && -f "$TT_VPN_CONF" ]]; then
        colorEcho "$YELLOW" "检测到 TrustTunnel 已安装，检查更新..."
        TT_load_meta
        local old_ver="${TT_VER:-未知}"
        TT_resolve_version
        if [[ "$old_ver" == "$TT_VER" ]]; then
            colorEcho "$GREEN" "当前已是最新稳定版 (${TT_VER})。"
            confirm "是否仍要重新下载覆盖安装？" "n" || return
        fi
        systemctl stop trusttunnel >/dev/null 2>&1
        TT_download_and_install "$TT_VER" || { systemctl start trusttunnel >/dev/null 2>&1; return; }
        TT_save_meta
        systemctl start trusttunnel
        colorEcho "$GREEN" "TrustTunnel 已更新到 ${TT_VER} 并重启完成！"
        TT_show_surge_config
        return
    fi

    installDependencies
    TT_resolve_version
    TT_download_and_install "$TT_VER" || return
    TT_configure_interactive
    TT_write_configs
    TT_deploy_service && colorEcho "$GREEN" "TrustTunnel 安装并启动成功！"
    TT_show_surge_config
}

TT_uninstall() {
    if confirm "确定要彻底卸载 TrustTunnel 吗？" "n"; then
        systemctl stop trusttunnel >/dev/null 2>&1
        systemctl disable trusttunnel >/dev/null 2>&1
        rm -f "$TT_SERVICE"
        rm -f /etc/letsencrypt/renewal-hooks/deploy/trusttunnel.sh
        rm -rf "$TT_DIR"
        systemctl daemon-reload
        colorEcho "$GREEN" "TrustTunnel 已卸载。"
    else
        colorEcho "$YELLOW" "已取消卸载。"
    fi
}

TT_menu() {
    while true; do
        clear
        echo "########################################"
        echo -e "#       ${BLUE}TrustTunnel 服务管理${PLAIN}           #"
        echo "########################################"
        echo ""
        local st
        st=$(TT_status_code)
        TT_load_meta
        case "$st" in
            0) echo -e "  状态: ${RED}未安装${PLAIN}" ;;
            1) echo -e "  状态: ${YELLOW}已安装但缺少配置${PLAIN}" ;;
            2) echo -e "  状态: ${RED}未运行${PLAIN} (端口: ${TT_PORT}, 版本: ${TT_VER:-未知})" ;;
            3) echo -e "  状态: ${GREEN}正在运行${PLAIN} (端口: ${TT_PORT}, H3: ${TT_ENABLE_H3}, 域名: ${TT_DOMAIN}, 版本: ${TT_VER:-未知})" ;;
        esac
        echo ""
        echo -e "  ${GREEN}1.${PLAIN} 安装 / 更新 TrustTunnel"
        echo -e "  ${GREEN}2.${PLAIN} 修改配置 (端口/证书/HTTP3/账号密码)"
        echo -e "  ${GREEN}3.${PLAIN} 查看 Surge 配置行"
        echo -e "  ${GREEN}4.${PLAIN} 重启 TrustTunnel"
        echo -e "  ${GREEN}5.${PLAIN} 查看运行日志"
        echo -e "  ${GREEN}6.${PLAIN} 卸载 TrustTunnel"
        echo -e "  ${GREEN}0.${PLAIN} 返回主菜单"
        echo ""
        local ans
        read -r -p "请选择操作 [0-6]: " ans </dev/tty
        case "$ans" in
            0) return ;;
            1) TT_install_or_upgrade; pause ;;
            2)
                if [[ "$(TT_status_code)" == "0" ]]; then
                    colorEcho "$RED" "请先安装 TrustTunnel。"
                else
                    TT_load_meta
                    TT_configure_interactive
                    TT_write_configs
                    TT_deploy_service && colorEcho "$GREEN" "配置已更新并重启！"
                    TT_show_surge_config
                fi
                pause
                ;;
            3) TT_show_surge_config; pause ;;
            4)
                systemctl restart trusttunnel 2>/dev/null && colorEcho "$GREEN" "TrustTunnel 已重启。" || colorEcho "$RED" "重启失败。"
                pause
                ;;
            5) journalctl -u trusttunnel -n 40 --no-pager; pause ;;
            6) TT_uninstall; pause ;;
            *) colorEcho "$RED" "请输入 0-6。" ; sleep 1 ;;
        esac
    done
}

# ==================== MASQUE (volto) 模块 ====================

MASQUE_status_code() {
    if [[ ! -f "$MASQUE_BIN" ]]; then
        echo 0
        return
    fi
    if [[ ! -f "$MASQUE_CONF" ]]; then
        echo 1
        return
    fi
    if systemctl is-active --quiet volto 2>/dev/null; then
        echo 3
    else
        echo 2
    fi
}

MASQUE_load_meta() {
    MASQUE_VER=""
    MASQUE_PORT=""
    MASQUE_SNI=""
    MASQUE_CERT_MODE=""
    MASQUE_CERT_PATH=""
    MASQUE_KEY_PATH=""
    MASQUE_USERNAME=""
    MASQUE_PASSWORD=""
    MASQUE_SNI_GATE=""
    MASQUE_HOP_RANGE=""
    if [[ -f "$MASQUE_META" ]]; then
        . "$MASQUE_META"
    fi
}

MASQUE_save_meta() {
    mkdir -p "$MASQUE_DIR"
    cat > "$MASQUE_META" <<-EOF
MASQUE_VER='${MASQUE_VER}'
MASQUE_PORT='${MASQUE_PORT}'
MASQUE_SNI='${MASQUE_SNI}'
MASQUE_CERT_MODE='${MASQUE_CERT_MODE}'
MASQUE_CERT_PATH='${MASQUE_CERT_PATH}'
MASQUE_KEY_PATH='${MASQUE_KEY_PATH}'
MASQUE_USERNAME='${MASQUE_USERNAME}'
MASQUE_PASSWORD='${MASQUE_PASSWORD}'
MASQUE_SNI_GATE='${MASQUE_SNI_GATE}'
MASQUE_HOP_RANGE='${MASQUE_HOP_RANGE}'
EOF
    chmod 600 "$MASQUE_META"
}

MASQUE_resolve_version() {
    local target_ver=""
    colorEcho "$YELLOW" "正在获取 MASQUE (volto) 最新版本..."
    target_ver=$(curl -fsSL --connect-timeout "${CONNECT_TIMEOUT}" --max-time 20 \
        "https://api.github.com/repos/vcarus/volto/releases/latest" 2>/dev/null \
        | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/')
    if [[ -z "$target_ver" ]]; then
        target_ver="$MASQUE_DEFAULT_VER"
        colorEcho "$YELLOW" "无法连接 GitHub API，将使用默认版本: ${target_ver}"
    else
        colorEcho "$GREEN" "检测到 volto 最新版本: ${target_ver}"
    fi
    MASQUE_VER="$target_ver"
}

MASQUE_download_and_install() {
    local ver="$1"
    local ver_num="${ver#v}"
    local tarball="volto-${ver_num}-${MASQUE_ARCH}.tar.gz"
    local base_url="https://github.com/vcarus/volto/releases/download/${ver}"
    local url="${base_url}/${tarball}"
    local sums_url="${base_url}/SHA256SUMS"
    local tmp_dir="/tmp/volto_install"
    local archive="${tmp_dir}/${tarball}"

    rm -rf "$tmp_dir"
    mkdir -p "$tmp_dir"

    if [[ -n "${VOLTO_TAR:-}" && -f "${VOLTO_TAR}" ]]; then
        colorEcho "$YELLOW" "使用本地安装包: ${VOLTO_TAR}"
        cp "${VOLTO_TAR}" "$archive"
    else
        colorEcho "$YELLOW" "正在下载 volto: ${url}"
        wget --connect-timeout="${CONNECT_TIMEOUT}" --read-timeout=60 --timeout=60 --tries=3 \
            -O "$archive" "$url"
        if [[ $? -ne 0 || ! -s "$archive" ]]; then
            colorEcho "$RED" "下载 volto 失败！如果 VPS 无法访问 GitHub，可手动下载 ${tarball} 并上传到 VPS。"
            local local_tar
            read -r -p "请输入本地安装包路径（直接回车退出）: " local_tar </dev/tty
            if [[ -z "$local_tar" || ! -f "$local_tar" ]]; then
                rm -rf "$tmp_dir"
                return 1
            fi
            cp "$local_tar" "$archive"
        else
            if wget -q --connect-timeout="${CONNECT_TIMEOUT}" -O "${tmp_dir}/SHA256SUMS" "$sums_url" 2>/dev/null; then
                (cd "$tmp_dir" && sha256sum --ignore-missing -c SHA256SUMS) || {
                    colorEcho "$RED" "SHA256 校验失败，文件可能损坏！"
                    rm -rf "$tmp_dir"
                    return 1
                }
            fi
        fi
    fi

    tar -xzf "$archive" -C "$tmp_dir"
    if [[ $? -ne 0 ]]; then
        colorEcho "$RED" "解压失败: ${archive}"
        rm -rf "$tmp_dir"
        return 1
    fi

    local found_bin
    found_bin=$(find "$tmp_dir" -type f -name "volto" | head -n 1)
    if [[ -z "$found_bin" ]]; then
        colorEcho "$RED" "压缩包中未找到 volto 可执行文件！"
        rm -rf "$tmp_dir"
        return 1
    fi

    if [[ -f "$MASQUE_BIN" ]]; then
        cp -f "$MASQUE_BIN" "${MASQUE_BIN}.prev"
    fi
    install -m 0755 "$found_bin" "$MASQUE_BIN"
    rm -rf "$tmp_dir"
    colorEcho "$GREEN" "volto 已安装到 ${MASQUE_BIN}"
    return 0
}

MASQUE_ensure_user() {
    if ! id -u volto >/dev/null 2>&1; then
        useradd --system --no-create-home --shell /usr/sbin/nologin volto
    fi
    mkdir -p "$MASQUE_DIR"
    chown volto:volto "$MASQUE_DIR"
    chmod 0750 "$MASQUE_DIR"
}

MASQUE_configure_interactive() {
    MASQUE_ensure_user

    local suggested_port="${MASQUE_PORT:-443}"
    if [[ -z "$MASQUE_PORT" ]] && checkUdpPortInUse 443; then
        suggested_port="8443"
        colorEcho "$YELLOW" "检测到 UDP 443 已被占用（可能正在运行 TrustTunnel HTTP/3），默认推荐改用 UDP 8443。"
    fi

    # 1. UDP 端口
    while true; do
        read -r -p "请输入 MASQUE 监听 UDP 端口 [1-65535] (默认: ${suggested_port}): " MASQUE_PORT </dev/tty
        [[ -z "$MASQUE_PORT" ]] && MASQUE_PORT="$suggested_port"
        if ! validatePort "$MASQUE_PORT"; then
            colorEcho "$RED" "端口格式错误，请输入 1-65535 之间的数字。"
            continue
        fi
        if checkUdpPortInUse "$MASQUE_PORT" && ! systemctl is-active --quiet volto 2>/dev/null; then
            colorEcho "$YELLOW" "警告：UDP 端口 ${MASQUE_PORT} 当前已被其他进程占用："
            ss -ulpn "sport = :${MASQUE_PORT}" 2>/dev/null
            confirm "确定仍要使用 UDP 端口 ${MASQUE_PORT} 吗？" "n" || continue
        fi
        break
    done

    # 2. 证书方式
    echo ""
    colorEcho "$YELLOW" "请选择 MASQUE (volto) TLS 证书方式："
    echo -e "  ${GREEN}1.${PLAIN} 自签 ECDSA 证书 + 指纹固定 (无需域名！Surge 通过 SHA-256 指纹验证，安全便捷)"
    echo -e "  ${GREEN}2.${PLAIN} Let's Encrypt 自动申请域名证书 (需要已解析到本机的域名且 80/tcp 空闲)"
    echo -e "  ${GREEN}3.${PLAIN} 使用已有证书文件 (手动输入 fullchain/privkey 路径)"
    local cert_choice
    while true; do
        read -r -p "请选择证书方式 [1-3] (默认: 1): " cert_choice </dev/tty
        [[ -z "$cert_choice" ]] && cert_choice="1"
        case "$cert_choice" in
            1)
                local sni_in
                read -r -p "请输入自签证书 SNI 名称 (默认: ${MASQUE_SNI:-volto.internal}): " sni_in </dev/tty
                [[ -z "$sni_in" ]] && sni_in="${MASQUE_SNI:-volto.internal}"
                MASQUE_CERT_MODE="selfsigned"
                MASQUE_SNI="$sni_in"
                MASQUE_CERT_PATH="${MASQUE_DIR}/cert.pem"
                MASQUE_KEY_PATH="${MASQUE_DIR}/key.pem"
                generateSelfSignedCert "$MASQUE_SNI" "$MASQUE_CERT_PATH" "$MASQUE_KEY_PATH"
                chown volto:volto "$MASQUE_CERT_PATH" "$MASQUE_KEY_PATH"
                chmod 0644 "$MASQUE_CERT_PATH"
                chmod 0640 "$MASQUE_KEY_PATH"
                colorEcho "$GREEN" "自签 ECDSA 证书已生成: ${MASQUE_CERT_PATH}"
                break
                ;;
            2)
                local d_in
                read -r -p "请输入已解析到本机 VPS 的域名 (如 masque.example.com): " d_in </dev/tty
                [[ -z "$d_in" ]] && { colorEcho "$RED" "域名不能为空。"; continue; }
                if ! issueLetsEncryptCert "$d_in"; then
                    continue
                fi
                MASQUE_CERT_MODE="letsencrypt"
                MASQUE_SNI="$d_in"
                MASQUE_CERT_PATH="${MASQUE_DIR}/fullchain.pem"
                MASQUE_KEY_PATH="${MASQUE_DIR}/privkey.pem"
                install -o volto -g volto -m 0644 "/etc/letsencrypt/live/${MASQUE_SNI}/fullchain.pem" "$MASQUE_CERT_PATH"
                install -o volto -g volto -m 0640 "/etc/letsencrypt/live/${MASQUE_SNI}/privkey.pem" "$MASQUE_KEY_PATH"
                mkdir -p /etc/letsencrypt/renewal-hooks/deploy
                cat > /etc/letsencrypt/renewal-hooks/deploy/volto.sh <<-HOOK
#!/bin/sh
set -e
install -o volto -g volto -m 0644 "/etc/letsencrypt/live/${MASQUE_SNI}/fullchain.pem" "${MASQUE_CERT_PATH}"
install -o volto -g volto -m 0640 "/etc/letsencrypt/live/${MASQUE_SNI}/privkey.pem" "${MASQUE_KEY_PATH}"
systemctl reload volto >/dev/null 2>&1 || systemctl restart volto >/dev/null 2>&1 || true
HOOK
                chmod +x /etc/letsencrypt/renewal-hooks/deploy/volto.sh
                break
                ;;
            3)
                local c_path k_path h_in
                read -r -p "请输入证书对应的域名/SNI (如 masque.example.com): " h_in </dev/tty
                read -r -p "请输入证书链文件 (fullchain.pem) 路径: " c_path </dev/tty
                read -r -p "请输入私钥文件 (privkey.pem) 路径: " k_path </dev/tty
                if [[ -z "$h_in" || ! -f "$c_path" || ! -f "$k_path" ]]; then
                    colorEcho "$RED" "域名或证书路径无效，请重新输入。"
                    continue
                fi
                MASQUE_CERT_MODE="custom"
                MASQUE_SNI="$h_in"
                MASQUE_CERT_PATH="${MASQUE_DIR}/fullchain.pem"
                MASQUE_KEY_PATH="${MASQUE_DIR}/privkey.pem"
                install -o volto -g volto -m 0644 "$c_path" "$MASQUE_CERT_PATH"
                install -o volto -g volto -m 0640 "$k_path" "$MASQUE_KEY_PATH"
                break
                ;;
            *)
                colorEcho "$RED" "输入无效，请输入 1-3。"
                ;;
        esac
    done

    # 3. SNI 门控
    echo ""
    local sni_gate_default="y"
    [[ "$MASQUE_SNI_GATE" == "false" ]] && sni_gate_default="n"
    if confirm "是否启用严格 SNI 验证 (非指定 SNI 的端口扫描直接静默丢弃)？" "$sni_gate_default"; then
        MASQUE_SNI_GATE="true"
    else
        MASQUE_SNI_GATE="false"
    fi

    # 4. 用户名与密码
    local default_user="${MASQUE_USERNAME:-surge}"
    local default_pass="${MASQUE_PASSWORD:-}"
    echo ""
    while true; do
        read -r -p "请输入 MASQUE 用户名 (最多32字节，默认: ${default_user}): " MASQUE_USERNAME </dev/tty
        [[ -z "$MASQUE_USERNAME" ]] && MASQUE_USERNAME="$default_user"
        validateCredentialField "$MASQUE_USERNAME" "用户名" 32 && break
    done

    while true; do
        if [[ -n "$default_pass" ]]; then
            read -r -p "请输入 MASQUE 密码 (直接回车保持当前密码): " MASQUE_PASSWORD </dev/tty
            [[ -z "$MASQUE_PASSWORD" ]] && MASQUE_PASSWORD="$default_pass"
        else
            read -r -p "请输入 MASQUE 密码 (直接回车随机生成 18 位密码): " MASQUE_PASSWORD </dev/tty
            [[ -z "$MASQUE_PASSWORD" ]] && MASQUE_PASSWORD="$(generateSafePassword 18)"
        fi
        validateCredentialField "$MASQUE_PASSWORD" "密码" 128 && break
        default_pass=""
    done
    colorEcho "$BLUE" "用户名: ${MASQUE_USERNAME} | 密码: ${MASQUE_PASSWORD}"

    # 5. 端口跳跃 (Port Hopping)
    echo ""
    colorEcho "$BLUE" "是否配置 UDP 端口跳跃 (Port Hopping)？"
    echo "  说明：通过 iptables 将一段 UDP 端口转发到 ${MASQUE_PORT}，可应对运营商针对单一 UDP 端口的 QoS 限速。"
    local hop_default="n"
    [[ -n "$MASQUE_HOP_RANGE" ]] && hop_default="y"
    if confirm "开启 UDP 端口跳跃？" "$hop_default"; then
        while true; do
            local r_in
            read -r -p "请输入跳跃端口范围 (格式 START-END，默认: ${MASQUE_HOP_RANGE:-20000-30000}): " r_in </dev/tty
            [[ -z "$r_in" ]] && r_in="${MASQUE_HOP_RANGE:-20000-30000}"
            if [[ "$r_in" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                local s_p="${BASH_REMATCH[1]}"
                local e_p="${BASH_REMATCH[2]}"
                if validatePort "$s_p" && validatePort "$e_p" && [[ "$s_p" -lt "$e_p" ]]; then
                    MASQUE_HOP_RANGE="${s_p}-${e_p}"
                    break
                fi
            fi
            colorEcho "$RED" "范围格式错误，请输入如 20000-30000 的有效端口范围。"
        done
    else
        MASQUE_HOP_RANGE=""
    fi
}

MASQUE_write_config() {
    local sni_line="expected_sni = []"
    if [[ "$MASQUE_SNI_GATE" == "true" && -n "$MASQUE_SNI" ]]; then
        sni_line="expected_sni = [\"${MASQUE_SNI}\"]"
    fi
    local listen_host
    listen_host="$(getListenHost)"

    local tmp_conf
    tmp_conf="$(mktemp)"
    cat > "$tmp_conf" <<-EOF
[server]
listen = "${listen_host}:${MASQUE_PORT}"
cert = "${MASQUE_CERT_PATH}"
key = "${MASQUE_KEY_PATH}"
alpn = ["h3"]
shutdown_grace = 5

[auth]
users = [
  { username = "${MASQUE_USERNAME}", password = "${MASQUE_PASSWORD}" },
]

[limits]
udp_session_timeout = 180
max_targets_per_conn = 256
max_connections = 256
connect_timeout = 10
ip_family_preference = "ipv4"
max_streams_bidi = 1024
max_idle_timeout = 60
keep_alive_interval = 20
initial_mtu = 1200

[security]
allow_private_networks = false
denied_ports = [25]
unanswered_packet_budget = 64
max_auth_failures = 5
${sni_line}

[log]
level = "info"
keylog = false
EOF

    if "$MASQUE_BIN" --help 2>&1 | grep -q -- '--check-config'; then
        if ! "$MASQUE_BIN" --check-config --config "$tmp_conf"; then
            colorEcho "$RED" "volto 配置校验未通过，已中止写入！"
            rm -f "$tmp_conf"
            return 1
        fi
    fi

    install -o volto -g volto -m 0640 "$tmp_conf" "$MASQUE_CONF"
    rm -f "$tmp_conf"
    MASQUE_save_meta
    return 0
}

MASQUE_apply_port_hopping() {
    if systemctl is-active --quiet volto-port-hopping 2>/dev/null; then
        systemctl stop volto-port-hopping >/dev/null 2>&1
    fi
    systemctl disable volto-port-hopping >/dev/null 2>&1
    rm -f "$MASQUE_HOP_SERVICE"

    if [[ -z "$MASQUE_HOP_RANGE" ]]; then
        systemctl daemon-reload
        return 0
    fi

    local hop_iptables="${MASQUE_HOP_RANGE//-/:}"
    cat > "$MASQUE_HOP_SERVICE" <<-EOF
[Unit]
Description=volto MASQUE UDP Port Hopping NAT Redirect
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'iptables -w -t nat -C PREROUTING -p udp --dport ${hop_iptables} -j REDIRECT --to-ports ${MASQUE_PORT} 2>/dev/null || iptables -w -t nat -A PREROUTING -p udp --dport ${hop_iptables} -j REDIRECT --to-ports ${MASQUE_PORT}'
ExecStop=/bin/sh -c 'iptables -w -t nat -D PREROUTING -p udp --dport ${hop_iptables} -j REDIRECT --to-ports ${MASQUE_PORT} 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now volto-port-hopping
    allowUfwPort "$hop_iptables" "udp"
    colorEcho "$GREEN" "已启用 UDP 端口跳跃转发: ${MASQUE_HOP_RANGE} -> ${MASQUE_PORT}"
}

MASQUE_deploy_service() {
    cat > "$MASQUE_SERVICE" <<-EOF
[Unit]
Description=volto MASQUE proxy (HTTP/3 CONNECT + CONNECT-UDP)
Documentation=https://github.com/vcarus/volto
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${MASQUE_BIN} --config ${MASQUE_CONF}
ExecReload=/bin/kill -HUP \$MAINPID
KillSignal=SIGTERM
TimeoutStopSec=45
Restart=on-failure
RestartSec=5s
LimitNOFILE=131072

User=volto
Group=volto
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes

ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
ProtectProc=invisible
ReadOnlyPaths=${MASQUE_DIR}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable volto >/dev/null 2>&1
    systemctl restart volto

    allowUfwPort "$MASQUE_PORT" "udp"
    MASQUE_apply_port_hopping

    sleep 1
    if ! systemctl is-active --quiet volto; then
        colorEcho "$RED" "MASQUE (volto) 启动失败，最近日志如下："
        journalctl -u volto -n 20 --no-pager
        return 1
    fi
    return 0
}

MASQUE_show_surge_config() {
    MASQUE_load_meta
    if [[ -z "$MASQUE_PORT" || ! -f "$MASQUE_CONF" ]]; then
        colorEcho "$RED" "MASQUE (volto) 尚未安装或配置不完整。"
        return
    fi

    local host="${MASQUE_SNI}"
    local extra=""
    if [[ "$MASQUE_CERT_MODE" == "selfsigned" ]]; then
        host="${IP4:-${IP6:-<VPS_IP>}}"
        local fp
        fp=$(getCertFingerprint "$MASQUE_CERT_PATH")
        extra=", sni=${MASQUE_SNI}, server-cert-fingerprint-sha256=${fp}"
    fi
    if [[ -n "$MASQUE_HOP_RANGE" ]]; then
        extra="${extra}, port-hopping=${MASQUE_HOP_RANGE}, port-hopping-interval=30"
    fi

    echo ""
    colorEcho "$GREEN" "=== MASQUE (volto) Surge 配置信息 ==="
    echo -e "  ${BLUE}配置文件:${PLAIN} ${MASQUE_CONF}"
    echo -e "  ${BLUE}安装版本:${PLAIN} ${MASQUE_VER:-未知}"
    echo -e "  ${BLUE}证书模式:${PLAIN} ${MASQUE_CERT_MODE} (SNI: ${MASQUE_SNI})"
    echo -e "  ${BLUE}端口跳跃:${PLAIN} ${MASQUE_HOP_RANGE:-未开启}"
    if [[ -f "$MASQUE_CERT_PATH" ]]; then
        echo -e "  ${BLUE}证书到期:${PLAIN} $(getCertExpiry "$MASQUE_CERT_PATH")"
    fi
    echo ""
    colorEcho "$YELLOW" "可直接粘贴到 Surge [Proxy] 分组："
    echo "  MASQUE = masque, ${host}, ${MASQUE_PORT}, username=${MASQUE_USERNAME}, password=${MASQUE_PASSWORD}${extra}"
    echo -e "  ${YELLOW}注: MASQUE 原生基于 HTTP/3 (UDP)，TCP 与 UDP 转发开箱即用（要求 Surge iOS 5.22.0+ / Mac 6.9.0+）。${PLAIN}"
}

MASQUE_install_or_upgrade() {
    if [[ -f "$MASQUE_BIN" && -f "$MASQUE_CONF" ]]; then
        colorEcho "$YELLOW" "检测到 MASQUE (volto) 已安装，检查更新..."
        MASQUE_load_meta
        local old_ver="${MASQUE_VER:-未知}"
        MASQUE_resolve_version
        if [[ "$old_ver" == "$MASQUE_VER" ]]; then
            colorEcho "$GREEN" "当前已是最新版本 (${MASQUE_VER})。"
            confirm "是否仍要重新下载覆盖安装？" "n" || return
        fi
        MASQUE_download_and_install "$MASQUE_VER" || return
        if "$MASQUE_BIN" --help 2>&1 | grep -q -- '--check-config'; then
            if ! "$MASQUE_BIN" --check-config --config "$MASQUE_CONF"; then
                colorEcho "$RED" "新版 volto 无法加载现有配置，正在自动回滚旧版本..."
                [[ -f "${MASQUE_BIN}.prev" ]] && mv -f "${MASQUE_BIN}.prev" "$MASQUE_BIN"
                return 1
            fi
        fi
        MASQUE_save_meta
        systemctl restart volto
        sleep 1
        if ! systemctl is-active --quiet volto; then
            colorEcho "$RED" "新版 volto 启动失败，正在回滚旧版本..."
            [[ -f "${MASQUE_BIN}.prev" ]] && mv -f "${MASQUE_BIN}.prev" "$MASQUE_BIN"
            systemctl restart volto
            return 1
        fi
        colorEcho "$GREEN" "MASQUE (volto) 已升级到 ${MASQUE_VER} 并重启完成！"
        MASQUE_show_surge_config
        return
    fi

    installDependencies
    MASQUE_resolve_version
    MASQUE_download_and_install "$MASQUE_VER" || return
    MASQUE_configure_interactive
    MASQUE_write_config || return
    MASQUE_deploy_service && colorEcho "$GREEN" "MASQUE (volto) 安装并启动成功！"
    MASQUE_show_surge_config
}

MASQUE_uninstall() {
    if confirm "确定要彻底卸载 MASQUE (volto) 吗？" "n"; then
        systemctl stop volto-port-hopping >/dev/null 2>&1
        systemctl disable volto-port-hopping >/dev/null 2>&1
        rm -f "$MASQUE_HOP_SERVICE"

        systemctl stop volto >/dev/null 2>&1
        systemctl disable volto >/dev/null 2>&1
        rm -f "$MASQUE_SERVICE"
        rm -f /etc/letsencrypt/renewal-hooks/deploy/volto.sh
        rm -f "$MASQUE_BIN" "${MASQUE_BIN}.prev"
        rm -rf "$MASQUE_DIR"
        systemctl daemon-reload
        colorEcho "$GREEN" "MASQUE (volto) 已卸载。"
    else
        colorEcho "$YELLOW" "已取消卸载。"
    fi
}

MASQUE_menu() {
    while true; do
        clear
        echo "########################################"
        echo -e "#       ${BLUE}MASQUE (volto) 服务管理${PLAIN}        #"
        echo "########################################"
        echo ""
        local st
        st=$(MASQUE_status_code)
        MASQUE_load_meta
        case "$st" in
            0) echo -e "  状态: ${RED}未安装${PLAIN}" ;;
            1) echo -e "  状态: ${YELLOW}已安装但缺少配置${PLAIN}" ;;
            2) echo -e "  状态: ${RED}未运行${PLAIN} (UDP 端口: ${MASQUE_PORT}, 版本: ${MASQUE_VER:-未知})" ;;
            3) echo -e "  状态: ${GREEN}正在运行${PLAIN} (UDP 端口: ${MASQUE_PORT}, SNI: ${MASQUE_SNI}, 跳跃: ${MASQUE_HOP_RANGE:-关}, 版本: ${MASQUE_VER:-未知})" ;;
        esac
        echo ""
        echo -e "  ${GREEN}1.${PLAIN} 安装 / 更新 MASQUE (volto)"
        echo -e "  ${GREEN}2.${PLAIN} 修改配置 (端口/证书/SNI/账号/端口跳跃)"
        echo -e "  ${GREEN}3.${PLAIN} 查看 Surge 配置行"
        echo -e "  ${GREEN}4.${PLAIN} 重启 MASQUE"
        echo -e "  ${GREEN}5.${PLAIN} 查看运行日志"
        echo -e "  ${GREEN}6.${PLAIN} 卸载 MASQUE"
        echo -e "  ${GREEN}0.${PLAIN} 返回主菜单"
        echo ""
        local ans
        read -r -p "请选择操作 [0-6]: " ans </dev/tty
        case "$ans" in
            0) return ;;
            1) MASQUE_install_or_upgrade; pause ;;
            2)
                if [[ "$(MASQUE_status_code)" == "0" ]]; then
                    colorEcho "$RED" "请先安装 MASQUE (volto)。"
                else
                    MASQUE_load_meta
                    MASQUE_configure_interactive
                    MASQUE_write_config && MASQUE_deploy_service && colorEcho "$GREEN" "配置已更新并重启！"
                    MASQUE_show_surge_config
                fi
                pause
                ;;
            3) MASQUE_show_surge_config; pause ;;
            4)
                systemctl restart volto 2>/dev/null && colorEcho "$GREEN" "MASQUE (volto) 已重启。" || colorEcho "$RED" "重启失败。"
                pause
                ;;
            5) journalctl -u volto -n 40 --no-pager; pause ;;
            6) MASQUE_uninstall; pause ;;
            *) colorEcho "$RED" "请输入 0-6。" ; sleep 1 ;;
        esac
    done
}

# ==================== 主界面与入口 ====================

show_all_surge_configs() {
    clear
    echo "########################################"
    echo -e "#       ${BLUE}Surge 客户端配置汇总${PLAIN}           #"
    echo "########################################"
    local any=0
    if [[ "$(TT_status_code)" -ge 2 ]]; then
        TT_show_surge_config
        any=1
    fi
    if [[ "$(MASQUE_status_code)" -ge 2 ]]; then
        MASQUE_show_surge_config
        any=1
    fi
    if [[ $any -eq 0 ]]; then
        echo ""
        colorEcho "$YELLOW" "当前尚未安装 TrustTunnel 或 MASQUE。"
    fi
    pause
}

show_overview() {
    echo -e "${BLUE}服务器信息：${PLAIN}架构=${ARCH_RAW}, IPv4=${IP4:-无}, IPv6=${IP6:-无}"
    Show_bbr_menu_status

    local tt_st m_st
    tt_st=$(TT_status_code)
    m_st=$(MASQUE_status_code)
    TT_load_meta
    MASQUE_load_meta

    case "$tt_st" in
        0) echo -e "   ${BLUE}TrustTunnel:${PLAIN} ${RED}未安装${PLAIN}" ;;
        1) echo -e "   ${BLUE}TrustTunnel:${PLAIN} ${YELLOW}配置缺失${PLAIN}" ;;
        2) echo -e "   ${BLUE}TrustTunnel:${PLAIN} ${RED}已停止${PLAIN} (端口: ${TT_PORT}, 域名: ${TT_DOMAIN})" ;;
        3) echo -e "   ${BLUE}TrustTunnel:${PLAIN} ${GREEN}运行中${PLAIN} (端口: ${TT_PORT}, 域名: ${TT_DOMAIN}, H3: ${TT_ENABLE_H3})" ;;
    esac

    case "$m_st" in
        0) echo -e "   ${BLUE}MASQUE(volto):${PLAIN} ${RED}未安装${PLAIN}" ;;
        1) echo -e "   ${BLUE}MASQUE(volto):${PLAIN} ${YELLOW}配置缺失${PLAIN}" ;;
        2) echo -e "   ${BLUE}MASQUE(volto):${PLAIN} ${RED}已停止${PLAIN} (UDP: ${MASQUE_PORT}, SNI: ${MASQUE_SNI})" ;;
        3) echo -e "   ${BLUE}MASQUE(volto):${PLAIN} ${GREEN}运行中${PLAIN} (UDP: ${MASQUE_PORT}, SNI: ${MASQUE_SNI}, 跳跃: ${MASQUE_HOP_RANGE:-关})" ;;
    esac
}

main_menu() {
    while true; do
        clear
        echo "################################################"
        echo -e "#   ${RED}Surge TrustTunnel & MASQUE 一键安装脚本${PLAIN}    #"
        echo "################################################"
        echo ""
        show_overview
        echo ""
        echo " ----------------------------------------------"
        echo -e "  ${GREEN}1.${PLAIN}  安装 / 管理 TrustTunnel"
        echo -e "  ${GREEN}2.${PLAIN}  安装 / 管理 MASQUE (volto)"
        echo -e "  ${GREEN}3.${PLAIN}  一键查看 Surge 客户端配置行"
        echo -e "  ${GREEN}4.${PLAIN}  管理 BBR 与内核网络优化"
        echo -e "  ${GREEN}0.${PLAIN}  退出"
        echo ""
        local answer
        read -r -p "请选择操作 [0-4]: " answer </dev/tty
        case "$answer" in
            0) exit 0 ;;
            1) TT_menu ;;
            2) MASQUE_menu ;;
            3) show_all_surge_configs ;;
            4) BBR_menu ;;
            *) colorEcho "$RED" "请选择正确的操作！" ; sleep 1 ;;
        esac
    done
}

checkRoot
checkSystem
detectPublicIPs

case "${1:-}" in
    tt|trusttunnel|trust-tunnel)
        TT_menu
        ;;
    masque|volto)
        MASQUE_menu
        ;;
    bbr)
        BBR_menu
        ;;
    *)
        main_menu
        ;;
esac
