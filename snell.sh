#!/bin/bash

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN='\033[0m'

# Snell 发布信息页面，用于安装/升级时自动解析最新版本
SNELL_RELEASE_PAGE="https://kb.nssurge.com/surge-knowledge-base/release-notes/snell"
LATEST_SNELL_VER=""
LATEST_DOWNLOAD_LINK=""
CONNECT_TIMEOUT=15

IP4=`curl -sL --connect-timeout 5 --max-time 10 -4 ip.sb`
IP6=`curl -sL --connect-timeout 5 --max-time 10 -6 ip.sb`
CPU=`uname -m`
snell_conf="/etc/snell/snell-server.conf"

colorEcho() {
    echo -e "${1}${@:2}${PLAIN}"
}

confirm() {
    local answer
    read -p "$1 [y/n] (默认n, 回车): " answer
    [[ "${answer}" =~ ^[Yy]$ ]]
}

checkRoot() {
    if [[ ${EUID} -ne 0 ]]; then
        colorEcho $RED "错误：此脚本必须以 root 用户身份运行！"
        exit 1
    fi
}

checkSystem() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        if [[ "$ID" == "ubuntu" ]]; then
            if dpkg --compare-versions "${VERSION_ID:-0}" lt "22.04"; then
                colorEcho $RED "仅支持 Ubuntu 22.04 及以上版本"
                exit 1
            fi
            return
        elif [[ "$ID" == "debian" ]]; then
            if dpkg --compare-versions "${VERSION_ID:-0}" lt "11"; then
                colorEcho $RED "仅支持 Debian 11 及以上版本"
                exit 1
            fi
            return
        fi
    fi
    colorEcho $RED "仅支持 Debian 11+ 或 Ubuntu 22.04+ 系统"
    exit 1
}

status() {
    if [[ ! -f /etc/snell/snell ]]; then
        echo 0
        return
    fi
    if [[ ! -f $snell_conf ]]; then
        echo 1
        return
    fi
    tmp=`grep listen ${snell_conf} | awk -F '=' '{print $2}' | cut -d: -f2`
    if [[ -z ${tmp} ]]; then
        tmp=`grep listen ${snell_conf} | awk -F '=' '{print $2}' | cut -d: -f4`
    fi
    res=`ss -nutlp| grep ${tmp} | grep -i snell`
    if [[ -z $res ]]; then
	echo 2
    else
	echo 3
	return
    fi
}

Install_dependency(){
    apt update
    apt install unzip wget -y
}

Resolve_snell_latest() {
    echo "请选择要安装/切换的 Snell 版本："
    echo "  1. Snell v5 (v5.0.1 最终稳定版，兼容 v4/v5 客户端)"
    echo "  2. Snell v6 (最新 v6 版本，需客户端支持 v6)"
    local ver_choice
    while true; do
        read -p "请选择 [1-2] (默认: 1，直接回车选 v5): " ver_choice
        [[ -z "$ver_choice" ]] && ver_choice="1"
        case "$ver_choice" in
            1)
                LATEST_SNELL_VER="v5.0.1"
                break
                ;;
            2)
                colorEcho $YELLOW "正在获取 Snell v6 最新版本..."
                LATEST_SNELL_VER=$(curl -fsSL --connect-timeout ${CONNECT_TIMEOUT} --max-time 60 "${SNELL_RELEASE_PAGE}" | grep -Eo 'snell-server-v6(\.[0-9]+)+-linux-amd64\.zip' | sed -E 's/snell-server-(v[0-9.]+)-linux-amd64\.zip/\1/' | sort -Vu | tail -n 1)
                [[ -z "${LATEST_SNELL_VER}" ]] && LATEST_SNELL_VER="v6.0.0"
                break
                ;;
            *)
                colorEcho $RED "输入错误，请选择 1 或 2。"
                ;;
        esac
    done
    LATEST_DOWNLOAD_LINK="https://dl.nssurge.com/snell/snell-server-${LATEST_SNELL_VER}-linux-amd64.zip"
    colorEcho $BLUE "已选择 Snell 版本: ${LATEST_SNELL_VER}"
}

Use_local_snell_zip() {
    local target_zip="$1"
    local local_zip="${SNELL_ZIP}"

    if [[ -n "${local_zip}" ]]; then
        if [[ ! -f "${local_zip}" ]]; then
            colorEcho $RED "SNELL_ZIP 指定的文件不存在: ${local_zip}"
            return 1
        fi
        cp "${local_zip}" "${target_zip}"
        return $?
    fi

    colorEcho $YELLOW "如果 VPS 无法连接 dl.nssurge.com，可先在本地下载 Snell zip，再上传到 VPS。"
    colorEcho $YELLOW "例如上传到: /tmp/snell-server-${LATEST_SNELL_VER}-linux-amd64.zip"
    read -p "请输入已上传的 Snell zip 文件路径（直接回车退出）: " local_zip
    if [[ -z "${local_zip}" ]]; then
        return 1
    fi
    if [[ ! -f "${local_zip}" ]]; then
        colorEcho $RED "文件不存在: ${local_zip}"
        return 1
    fi
    cp "${local_zip}" "${target_zip}"
}

Download_snell(){
    Resolve_snell_latest || exit 1
    rm -rf /tmp/snell
    mkdir -p /tmp/snell

    if [[ -n "${SNELL_ZIP}" ]]; then
        colorEcho $YELLOW "使用本地 Snell 安装包: ${SNELL_ZIP}"
        Use_local_snell_zip /tmp/snell/snell.zip || exit 1
    else
        colorEcho $YELLOW "下载Snell: ${LATEST_DOWNLOAD_LINK}"
        wget --connect-timeout=${CONNECT_TIMEOUT} --read-timeout=30 --timeout=30 --tries=3 -O /tmp/snell/snell.zip ${LATEST_DOWNLOAD_LINK}
        if [[ $? -ne 0 ]]; then
            colorEcho $RED "下载 Snell 失败或超时，请检查 VPS 到 dl.nssurge.com 的网络连通性。"
            Use_local_snell_zip /tmp/snell/snell.zip || exit 1
        fi
    fi

    unzip /tmp/snell/snell.zip -d /tmp/snell/
    if [[ $? -ne 0 || ! -f /tmp/snell/snell-server ]]; then
        colorEcho $RED "解压 Snell 失败，下载文件可能不完整。"
        exit 1
    fi
    mkdir -p /etc/snell
    mv /tmp/snell/snell-server /etc/snell/snell
    chmod +x /etc/snell/snell
}

Generate_conf(){
    Set_port
    Set_psk
    show_psk
}

Deploy_snell(){
    cd /etc/systemd/system
    cat > snell.service<<-EOF
[Unit]
Description=Snell Server
After=network.target

[Service]
ExecStart=/etc/snell/snell -c /etc/snell/snell-server.conf
Restart=on-failure
RestartSec=1s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable snell
    systemctl restart snell
    mkdir -p /etc/sysctl.d
    if [[ -f /etc/sysctl.conf ]]; then
        sed -i '/^[[:space:]]*net\.ipv4\.tcp_fastopen[[:space:]]*=/d' /etc/sysctl.conf
    fi
    if [[ -f /etc/sysctl.d/99-snell.conf ]]; then
        sed -i '/^[[:space:]]*net\.ipv4\.tcp_fastopen[[:space:]]*=/d' /etc/sysctl.d/99-snell.conf
    fi
    echo "net.ipv4.tcp_fastopen = 3" >> /etc/sysctl.d/99-snell.conf
    sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-snell.conf >/dev/null 2>&1
}

Set_port(){
    local default_port="${DEFAULT_PORT:-6666}"
    if [[ -n "${DEFAULT_PORT}" ]]; then
        read -p $'请输入新的 Snell 端口 [1-65535]\n'"(当前值: ${default_port}，直接回车保持不变): " PORT
    else
        read -p $'请输入 Snell 端口 [1-65535]\n'"(默认: ${default_port}，回车): " PORT
    fi
    [[ -z "${PORT}" ]] && PORT="${default_port}"
    echo $((${PORT}+0)) &>/dev/null
    if [[ $? -eq 0 ]]; then
	if [[ ${PORT} -ge 1 ]] && [[ ${PORT} -le 65535 ]]; then
		colorEcho $BLUE "端口: ${PORT}"
		echo ""
	else
		colorEcho $RED "输入错误, 请输入正确的端口。"
		Set_port
	fi
    else
	colorEcho $RED "输入错误, 请输入数字。"
	Set_port
    fi
}

Set_psk(){
    while true; do
        if [[ -n "${DEFAULT_PSK}" ]]; then
            read -p $'请输入新的 Snell PSK 密钥 (至少 12 位)\n'"(当前值: ${DEFAULT_PSK}，直接回车保持不变): " PSK
            [[ -z "${PSK}" ]] && PSK="${DEFAULT_PSK}"
        else
            read -p $'请输入 Snell PSK 密钥 (至少 12 位)\n(推荐随机生成 12 位，直接回车): ' PSK
            [[ -z "${PSK}" ]] && PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)
        fi
        if [[ ${#PSK} -lt 12 || ${#PSK} -gt 255 ]]; then
            colorEcho $RED "PSK 长度需在 12~255 位之间（当前 ${#PSK} 位），请重新输入或回车随机生成。"
            DEFAULT_PSK=""
        else
            break
        fi
    done
}

show_psk() {
    colorEcho $BLUE "PSK: ${PSK}"
    echo ""
}

Write_config(){
    if [[ -z "${LATEST_SNELL_VER}" ]] && [[ -f "${snell_conf}" ]]; then
        LATEST_SNELL_VER=$(grep '^# ' ${snell_conf} | awk -F '# ' '{print $2}')
    fi
    if [[ "${LATEST_SNELL_VER}" == v6* ]]; then
        cat > ${snell_conf}<<-EOF
[snell-server]
listen = 0.0.0.0:${PORT}
psk = ${PSK}
mode = default
dns-ip-preference = default
# ${LATEST_SNELL_VER}
EOF
    else
        cat > ${snell_conf}<<-EOF
[snell-server]
listen = 0.0.0.0:${PORT}
psk = ${PSK}
ipv6 = false
tfo = true
# ${LATEST_SNELL_VER}
EOF
    fi
}

Install_snell(){
    if [[ -f /etc/snell/snell ]] && [[ -f "$snell_conf" ]]; then
        colorEcho $YELLOW "Snell 已安装，如需更新请选择检查更新。"
        return
    fi

    Install_dependency
    Generate_conf
    Download_snell
    Write_config
    Deploy_snell
    colorEcho $GREEN "安装完成"
    ShowInfo
}

Install_or_upgrade_snell(){
    if [[ -f /etc/snell/snell ]] && [[ -f "$snell_conf" ]]; then
        colorEcho $YELLOW "检测到 Snell 已安装，将检查是否有新版本。"
        Upgrade_snell
    else
        Install_snell
    fi
}

Restart_all(){
    if [[ -f /etc/snell/snell ]] && [[ -f "$snell_conf" ]]; then
        systemctl restart snell
        colorEcho $BLUE "Snell已重启"
    else
        colorEcho $YELLOW "Snell 未安装，跳过重启"
    fi
}

Stop_snell(){
    systemctl stop snell
    colorEcho $BLUE " Snell已停止"
}

Uninstall_all(){
    if confirm "是否卸载 Snell？"; then
        systemctl stop snell >/dev/null 2>&1
        systemctl disable snell >/dev/null 2>&1
        rm -f /etc/systemd/system/snell.service
        rm -rf /etc/snell
        systemctl daemon-reload
        colorEcho $GREEN "Snell 已经卸载完毕"
    else
        colorEcho $YELLOW "取消卸载"
    fi
}

ShowInfo() {
    if [[ ! -f $snell_conf ]]; then
	colorEcho $RED "Snell未安装"
 	return
    fi
    echo ""
    echo -e " ${BLUE}Snell配置文件: ${PLAIN} ${RED}${snell_conf}${PLAIN}"
    colorEcho $BLUE " Snell配置信息："
    GetConfig
    outputSnell
}

ShowMenuInfo() {
    echo -e "${BLUE}当前配置：${PLAIN}"
    if [[ ! -f $snell_conf ]]; then
        echo -e "   ${BLUE}Snell:${PLAIN} ${RED}未安装${PLAIN}"
        return
    fi

    GetConfig
    res=`status`
    if [[ ${res} = "3" ]]; then
        snell_status="${GREEN}正在运行${PLAIN}"
    else
        snell_status="${RED}未运行${PLAIN}"
    fi
    echo -e "   ${BLUE}Snell状态:${PLAIN} ${snell_status}"
    outputSnell
}

GetConfig() {
    port=`grep listen ${snell_conf} | awk -F '=' '{print $2}' | cut -d: -f2`
    if [[ -z "${port}" ]]; then
	port=`grep listen ${snell_conf} | awk -F '=' '{print $2}' | cut -d: -f4`
    fi
    psk=`grep psk ${snell_conf} | awk -F '= ' '{print $2}'`
    ipv6=`grep ipv6 ${snell_conf} | awk -F '= ' '{print $2}'`
    mode=`grep '^mode' ${snell_conf} | awk -F '= ' '{print $2}'`
    dns_pref=`grep '^dns-ip-preference' ${snell_conf} | awk -F '= ' '{print $2}'`
    if [[ $ipv6 == "true" ]]; then
	IP=${IP6}
    else
	IP=${IP4}
    fi
    tfo=`grep tfo ${snell_conf} | awk -F '= ' '{print $2}'`
    ver=`grep '#' ${snell_conf} | awk -F '# ' '{print $2}'`
}

outputSnell() {
    echo -e "   ${BLUE}协议: ${PLAIN} ${RED}snell${PLAIN}"
    echo -e "   ${BLUE}地址(IP): ${PLAIN} ${RED}${IP}${PLAIN}"
    echo -e "   ${BLUE}Snell端口(PORT)：${PLAIN} ${RED}${port}${PLAIN}"
    echo -e "   ${BLUE}Snell密钥(PSK)：${PLAIN} ${RED}${psk}${PLAIN}"
    if [[ "${ver}" == v6* ]]; then
        echo -e "   ${BLUE}加密模式(MODE)：${PLAIN} ${RED}${mode:-default}${PLAIN}"
        echo -e "   ${BLUE}DNS偏好(DNS)：${PLAIN} ${RED}${dns_pref:-default}${PLAIN}"
    else
        echo -e "   ${BLUE}IPV6：${PLAIN} ${RED}${ipv6:-false}${PLAIN}"
        echo -e "   ${BLUE}TCP加速(TFO)：${PLAIN} ${RED}${tfo:-true}${PLAIN}"
    fi
    echo -e "   ${BLUE}Snell版本(VER)：${PLAIN} ${RED}${ver}${PLAIN}"
}

Change_snell(){
    if [[ ! -f "$snell_conf" ]]; then
        colorEcho $RED "Snell未安装，无法修改。"
        return
    fi
    colorEcho $BLUE "开始修改 Snell 配置..."
    GetConfig
    LATEST_SNELL_VER="${ver}"
    DEFAULT_PORT=${port}
    DEFAULT_PSK=${psk}
    Generate_conf # 获取新的 PORT 和 PSK
    unset DEFAULT_PORT DEFAULT_PSK

    Write_config # 写入新的Snell配置文件
    systemctl restart snell
    colorEcho $GREEN "修改配置成功！"
    ShowInfo
}

Upgrade_snell() {
    if [[ ! -f "$snell_conf" ]]; then
        colorEcho $RED "Snell未安装，无法升级。"
        return
    fi
    Resolve_snell_latest || return
    
    GetConfig
    installed_ver="${ver}"
    if [[ -z "$installed_ver" ]]; then
        colorEcho $YELLOW "无法检测到已安装版本，将尝试直接升级。"
    elif [[ "$installed_ver" == "$LATEST_SNELL_VER" ]]; then
        colorEcho $GREEN "恭喜！当前已是所选最新版本 ($LATEST_SNELL_VER)，无需升级。"
        return
    fi

    colorEcho $YELLOW "准备切换/升级版本！"
    colorEcho $BLUE "当前版本: ${installed_ver:-未知}"
    colorEcho $BLUE "目标版本: ${LATEST_SNELL_VER}"
    read -p "是否确认切换/升级? [y/n] (默认y, 回车): " answer
    [[ -z "$answer" ]] && answer="y"
    if [[ "$answer" != "y" ]]; then
        colorEcho $YELLOW "已取消升级。"
        return
    fi

    colorEcho $BLUE "开始升级Snell..."
    systemctl stop snell
    
    # 下载新版本
    colorEcho $YELLOW "下载新版Snell: ${LATEST_DOWNLOAD_LINK}"
    wget --connect-timeout=${CONNECT_TIMEOUT} --read-timeout=30 --timeout=30 --tries=3 -O /tmp/snell.zip ${LATEST_DOWNLOAD_LINK}
    if [[ $? -ne 0 ]]; then
        colorEcho $RED "下载新版本失败或超时，请检查 VPS 到 dl.nssurge.com 的网络连通性。"
        if ! Use_local_snell_zip /tmp/snell.zip; then
            colorEcho $RED "升级已中止。"
            systemctl start snell
            return
        fi
    fi
    
    unzip -o /tmp/snell.zip -d /tmp/
    if [[ $? -ne 0 || ! -f /tmp/snell-server ]]; then
        colorEcho $RED "解压新版本失败，升级已中止。"
        systemctl start snell
        return
    fi
    mv /tmp/snell-server /etc/snell/snell
    chmod +x /etc/snell/snell
    rm -f /tmp/snell.zip
    
    # 同步重写对应版本（v5/v6）的配置文件格式，并在升级到 v6 时校验 PSK 长度
    PORT="${port}"
    PSK="${psk}"
    if [[ "${LATEST_SNELL_VER}" == v6* && ${#PSK} -lt 12 ]]; then
        colorEcho $YELLOW "检测到旧版 PSK 长度不足 12 位，Snell v6 要求至少 12 位，请重新设置："
        DEFAULT_PSK=""
        Set_psk
        show_psk
    fi
    Write_config

    systemctl start snell
    colorEcho $GREEN "Snell已成功升级到 ${LATEST_SNELL_VER} 并重新启动！"
    ShowInfo
}

Snell_menu() {
    clear
    echo "################################"
    echo -e "#      ${YELLOW}管理 Snell 配置${PLAIN}        #"
    echo "################################"
    echo ""
    echo -e "  ${GREEN}1.${PLAIN}  修改 Snell 配置 (端口/密钥)"
    echo -e "  ${GREEN}2.${PLAIN}  检查并升级/切换 Snell 版本"
    echo -e "  ${GREEN}0.${PLAIN}  返回主菜单"
    echo ""
    read -p " 请选择操作[0-2]：" answer
    case $answer in
        0)
            menu
            ;;
        1)
            Change_snell
            ;;
        2)
            Upgrade_snell
            ;;
        *)
            colorEcho $RED " 请选择正确的操作！"
            sleep 2s
            Snell_menu
            ;;
    esac
}

Get_bbr_status() {
    BBR_ALGO=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    BBR_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null)
}

Show_bbr_status() {
    Get_bbr_status
    colorEcho $YELLOW "当前 BBR 配置："
    echo -n "  TCP 拥塞控制算法: "
    if [[ "$BBR_ALGO" == "bbr" ]]; then
        colorEcho $GREEN "${BBR_ALGO}"
    else
        colorEcho $RED "${BBR_ALGO:-未知}"
    fi
    echo -n "  默认队列调度算法: "
    if [[ "$BBR_QDISC" == "fq" ]]; then
        colorEcho $GREEN "${BBR_QDISC}"
    else
        colorEcho $RED "${BBR_QDISC:-未知}"
    fi
}

Enable_bbr() {
    local sysctl_file="/etc/sysctl.d/99-snell.conf"
    mkdir -p /etc/sysctl.d
    colorEcho $YELLOW "正在配置 BBR..."
    if [[ -f /etc/sysctl.conf ]]; then
        sed -i '/^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=/d' /etc/sysctl.conf
        sed -i '/^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=/d' /etc/sysctl.conf
    fi
    if [[ -f "$sysctl_file" ]]; then
        sed -i '/^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=/d' "$sysctl_file"
        sed -i '/^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=/d' "$sysctl_file"
    fi
    cat >> "$sysctl_file" <<-EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

    if ! (sysctl --system >/dev/null 2>&1 || sysctl -p "$sysctl_file" >/dev/null 2>&1); then
        colorEcho $RED "应用内核参数失败，请检查 ${sysctl_file}。"
        return 1
    fi

    Get_bbr_status
    if [[ "$BBR_ALGO" == "bbr" && "$BBR_QDISC" == "fq" ]]; then
        colorEcho $GREEN "BBR 已正确开启，队列调度算法为 fq。"
    else
        colorEcho $RED "配置已写入，但运行状态验证失败；当前内核可能不支持 BBR。"
        return 1
    fi
}

BBR_menu() {
    clear
    echo "################################"
    echo -e "#      ${YELLOW}管理 BBR 网络加速${PLAIN}      #"
    echo "################################"
    echo ""
    Show_bbr_status
    echo ""

    if [[ "$BBR_ALGO" == "bbr" && "$BBR_QDISC" == "fq" ]]; then
        colorEcho $GREEN "BBR 已完全开启，无需修改。"
        return
    fi

    if confirm "是否自动配置并开启 BBR？"; then
        Enable_bbr
    else
        colorEcho $YELLOW "操作已取消。"
    fi
}

Show_bbr_menu_status() {
    Get_bbr_status
    if [[ "$BBR_ALGO" == "bbr" && "$BBR_QDISC" == "fq" ]]; then
        echo -e "   ${BLUE}BBR状态:${PLAIN} ${GREEN}已开启 (bbr + fq)${PLAIN}"
        BBR_ENABLED=true
    else
        echo -e "   ${BLUE}BBR状态:${PLAIN} ${RED}未开启${PLAIN}"
        BBR_ENABLED=false
    fi
}

menu() {
	clear
	echo "################################"
	echo -e "#      ${RED}Snell一键安装脚本${PLAIN}       #"
	echo "################################"
	echo ""
	Show_bbr_menu_status
	echo ""
	ShowMenuInfo
	echo ""
	echo " ----------------------"
	echo -e "  ${GREEN}1.${PLAIN}  安装 / 更新 Snell"
	echo -e "  ${GREEN}2.${PLAIN}  管理 Snell 配置"
	echo -e "  ${GREEN}3.${PLAIN}  重启服务"
	echo -e "  ${GREEN}4.${PLAIN}  卸载 Snell"
	if [[ "$BBR_ENABLED" != "true" ]]; then
		echo -e "  ${GREEN}5.${PLAIN}  开启 BBR"
	fi
	echo -e "  ${GREEN}0.${PLAIN}  退出"
	echo ""
	if [[ "$BBR_ENABLED" == "true" ]]; then
		read -p " 请选择操作[0-4]：" answer
	else
		read -p " 请选择操作[0-5]：" answer
	fi
	case $answer in
		0)
			exit 0
			;;
		1)
			Install_or_upgrade_snell
			;;
		2)
			Snell_menu
			;;
		3)
			Restart_all
			;;
		4)
			Uninstall_all
			;;
		5)
			if [[ "$BBR_ENABLED" != "true" ]]; then
				BBR_menu
			else
				colorEcho $YELLOW "BBR 已开启，无需重复配置。"
			fi
			;;
		*)
			colorEcho $RED " 请选择正确的操作！"
   			sleep 2s
			menu
			;;
	esac
}

checkRoot
checkSystem
menu
