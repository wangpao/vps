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

IP4=`curl -sL -4 ip.sb`
IP6=`curl -sL -6 ip.sb`
CPU=`uname -m`
snell_conf="/etc/snell/snell-server.conf"
stls_conf="/etc/systemd/system/shadowtls.service"

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
    if [[ $(lsb_release -rs) < "22.04" ]]; then
        colorEcho $RED "仅支持Ubuntu 22.04及以上版本"
        exit 1
    fi
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

status_stls() {
    if [[ ! -f /etc/snell/shadowtls ]]; then
        echo 0
        return
    fi
    if [[ ! -f $stls_conf ]]; then
        echo 1
        return
    fi
    if [[ -f "$snell_conf" ]]; then
        V6=`grep ipv6 ${snell_conf} | awk -F '= ' '{print $2}'`
    else
        V6="false"
    fi
    if [[ $V6 = "true" ]]; then
	tmp2=`grep listen ${stls_conf} | cut -d- -f7 | cut -d: -f4`
    else
	tmp2=`grep listen ${stls_conf} | cut -d- -f7 | cut -d: -f2`
    fi
    res2=`ss -nutlp| grep ${tmp2} | grep -i shadowtls`
    if [[ -z $res2 ]]; then
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
    colorEcho $YELLOW "正在获取 Snell 最新版本..."
    LATEST_SNELL_VER=$(curl -fsSL "${SNELL_RELEASE_PAGE}" | grep -Eo 'snell-server-v[0-9]+(\.[0-9]+)+-linux-amd64\.zip' | sed -E 's/snell-server-(v[0-9.]+)-linux-amd64\.zip/\1/' | sort -Vu | tail -n 1)
    if [[ -z "${LATEST_SNELL_VER}" ]]; then
        colorEcho $RED "无法获取 Snell 最新版本, 请检查网络或官方发布页面。"
        return 1
    fi
    LATEST_DOWNLOAD_LINK="https://dl.nssurge.com/snell/snell-server-${LATEST_SNELL_VER}-linux-amd64.zip"
    colorEcho $BLUE "Snell 最新版本: ${LATEST_SNELL_VER}"
}

Download_snell(){
    Resolve_snell_latest || exit 1
    rm -rf /etc/snell /tmp/snell
    mkdir -p /etc/snell /tmp/snell
    colorEcho $YELLOW "下载Snell: ${LATEST_DOWNLOAD_LINK}"
    wget -O /tmp/snell/snell.zip ${LATEST_DOWNLOAD_LINK}
    if [[ $? -ne 0 ]]; then
        colorEcho $RED "下载 Snell 失败, 请检查网络或链接有效性。"
        exit 1
    fi
    unzip /tmp/snell/snell.zip -d /tmp/snell/
    mv /tmp/snell/snell-server /etc/snell/snell
    chmod +x /etc/snell/snell
}

Download_stls() {
    rm -rf /etc/snell/shadowtls
    TAG_URL="https://api.github.com/repos/ihciah/shadow-tls/releases/latest"
    DOWN_VER=`curl -s "${TAG_URL}" --connect-timeout 10| grep -Eo '\"tag_name\"(.*?)\",' | cut -d\" -f4`
    DOWNLOAD_LINK="https://github.com/ihciah/shadow-tls/releases/download/${DOWN_VER}/shadow-tls-x86_64-unknown-linux-musl"
    colorEcho $YELLOW "下载ShadowTLS: ${DOWNLOAD_LINK}"
    curl -L -H "Cache-Control: no-cache" -o /etc/snell/shadowtls ${DOWNLOAD_LINK}
    if [[ $? -ne 0 ]]; then
        colorEcho $RED "下载 ShadowTLS 失败, 请检查网络或链接有效性。"
        exit 1
    fi
    chmod +x /etc/snell/shadowtls
}

Generate_conf(){
    Set_port
    Set_psk
    show_psk
}

Generate_stls() {
    Set_sport
    Set_domain
    show_domain
    Set_pass
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
    echo "net.ipv4.tcp_fastopen = 3" >> /etc/sysctl.conf
    sysctl -p
}

Deploy_stls() {
    cd /etc/systemd/system
    cat > shadowtls.service<<-EOF
[Unit]
Description=Shadow-TLS Server Service
Documentation=man:sstls-server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/etc/snell/shadowtls --fastopen --v3 server --listen 0.0.0.0:$SPORT --server 127.0.0.1:$PORT --tls $DOMAIN --password $PASS
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=shadow-tls
Environment=MONOIO_FORCE_LEGACY_DRIVER=1

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable shadowtls
    systemctl restart shadowtls
}

Set_port(){
    local default_port="${DEFAULT_PORT:-6666}"
    read -p $'请输入 Snell 端口 [1-65535]\n'"(默认: ${default_port}，回车): " PORT
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
    if [[ -n "${DEFAULT_PSK}" ]]; then
        read -p $'请输入 Snell PSK 密钥\n'"(默认保持当前值: ${DEFAULT_PSK}，回车): " PSK
        [[ -z "${PSK}" ]] && PSK="${DEFAULT_PSK}"
    else
        read -p $'请输入 Snell PSK 密钥\n(推荐随机生成，直接回车): ' PSK
        [[ -z "${PSK}" ]] && PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8)
    fi
}

show_psk() {
    colorEcho $BLUE "PSK: ${PSK}"
    echo ""
}

Set_sport() {
    read -p $'请输入 ShadowTLS 端口 [1-65535]\n(默认: 9999，回车): ' SPORT
    [[ -z "${SPORT}" ]] && SPORT="9999"
    echo $((${SPORT}+0)) &>/dev/null
    if [[ $? -eq 0 ]]; then
	if [[ ${SPORT} -ge 1 ]] && [[ ${SPORT} -le 65535 ]]; then
		colorEcho $BLUE "端口: ${SPORT}"
		echo ""
	else
		colorEcho $RED "输入错误, 请输入正确的端口。"
		Set_sport
	fi
    else
	colorEcho $RED "输入错误, 请输入数字。"
	Set_sport
    fi
}

Set_domain() {
    echo "请选择 ShadowTLS 伪装域名："
    echo "  1. gateway.icloud.com（默认）"
    echo "  2. livepeer.com"
    echo "  3. icloud-content.com"
    echo "  4. livepeer.studio"
    while true; do
        read -p "请选择 [1-4]（默认: 1，回车）: " domain_choice
        [[ -z "$domain_choice" ]] && domain_choice="1"
        case "$domain_choice" in
            1) DOMAIN="gateway.icloud.com"; break ;;
            2) DOMAIN="livepeer.com"; break ;;
            3) DOMAIN="icloud-content.com"; break ;;
            4) DOMAIN="livepeer.studio"; break ;;
            *) colorEcho $RED "输入错误，请选择 1-4。" ;;
        esac
    done
    colorEcho $BLUE "域名：${DOMAIN}"
    echo ""
}

show_domain() {
	colorEcho $BLUE "域名：${DOMAIN}"
	echo ""
}

Set_pass() {
    read -p $'请设置ShadowTLS的密码\n(默认随机生成, 回车): ' PASS
    [[ -z "$PASS" ]] && PASS=`cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 8 | head -n 1`
    colorEcho $BLUE " 密码：$PASS"
    echo ""
}

Write_config(){
    if [[ -z "${LATEST_SNELL_VER}" ]] && [[ -f "${snell_conf}" ]]; then
        LATEST_SNELL_VER=$(grep '^# ' ${snell_conf} | awk -F '# ' '{print $2}')
    fi
    cat > ${snell_conf}<<-EOF
[snell-server]
listen = 0.0.0.0:${PORT}
psk = ${PSK}
ipv6 = false
obfs = off
tfo = true
# ${LATEST_SNELL_VER}
EOF
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
        echo ""
        colorEcho $YELLOW "如需启用 ShadowTLS，请进入「管理 ShadowTLS」菜单安装。"
    fi
}

Install_stls() {
    if [[ ! -f "$snell_conf" ]]; then
        colorEcho $RED "请先安装 Snell，再安装 ShadowTLS。"
        return
    fi
    if [[ -f /etc/snell/shadowtls ]] && [[ -f "$stls_conf" ]]; then
        if ! confirm "ShadowTLS 已安装，是否重新安装并覆盖配置？"; then
            colorEcho $YELLOW "取消安装"
            return
        fi
    fi
    GetConfig
    PORT=${port}
    Generate_stls
    Download_stls
    Deploy_stls
    colorEcho $GREEN "ShadowTLS 安装完成"
}

Restart_all(){
    if [[ -f /etc/snell/snell ]] && [[ -f "$snell_conf" ]]; then
        systemctl restart snell
        colorEcho $BLUE "Snell已重启"
    else
        colorEcho $YELLOW "Snell 未安装，跳过重启"
    fi
    if [[ -f "$stls_conf" ]]; then
        systemctl restart shadowtls
        colorEcho $BLUE "ShadowTLS已重启"
    fi
}

Stop_snell(){
    systemctl stop snell
    colorEcho $BLUE " Snell已停止"
}

Uninstall_all(){
    if confirm "是否卸载 Snell 和 ShadowTLS？"; then
        systemctl stop snell >/dev/null 2>&1
        systemctl disable snell >/dev/null 2>&1
        rm -f /etc/systemd/system/snell.service

	if [[ -f "$stls_conf" ]]; then
		systemctl stop shadowtls >/dev/null 2>&1
		systemctl disable shadowtls >/dev/null 2>&1
		rm -f /etc/systemd/system/shadowtls.service
	fi
 
	rm -rf /etc/snell
	systemctl daemon-reload
	colorEcho $GREEN "Snell 及 ShadowTLS 已经卸载完毕"
    else
	colorEcho $YELLOW "取消卸载"
    fi
}

Uninstall_stls(){
    if [[ ! -f /etc/snell/shadowtls ]] && [[ ! -f "$stls_conf" ]]; then
        colorEcho $YELLOW "ShadowTLS 未安装"
        return
    fi

    if confirm "是否单独卸载 ShadowTLS？"; then
        systemctl stop shadowtls >/dev/null 2>&1
        systemctl disable shadowtls >/dev/null 2>&1
        rm -f /etc/systemd/system/shadowtls.service
        rm -f /etc/snell/shadowtls
        systemctl daemon-reload
        colorEcho $GREEN "ShadowTLS 已经卸载完毕"
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
    if [[ -f $stls_conf ]]; then
	GetConfig_stls
	outputSTLS
	echo ""
	echo -e " ${BLUE}若要使用ShadowTLS, 请将${PLAIN}${RED} 端口 ${PLAIN}${BLUE}替换为${PLAIN}${RED} ${sport} ${PLAIN}"
    fi
}

ShowMenuInfo() {
    echo -e "${BLUE}当前配置：${PLAIN}"
    if [[ ! -f $snell_conf ]]; then
        echo -e "   ${BLUE}Snell:${PLAIN} ${RED}未安装${PLAIN}"
        echo -e "   ${BLUE}ShadowTLS:${PLAIN} ${RED}未安装${PLAIN}"
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

    if [[ -f $stls_conf ]]; then
        GetConfig_stls
        res2=`status_stls`
        if [[ ${res2} = "3" ]]; then
            stls_status="${GREEN}正在运行${PLAIN}"
        else
            stls_status="${RED}未运行${PLAIN}"
        fi
        echo -e "   ${BLUE}ShadowTLS状态:${PLAIN} ${stls_status}"
        outputSTLS
    else
        echo -e "   ${BLUE}ShadowTLS:${PLAIN} ${RED}未安装${PLAIN}"
    fi
}

GetConfig() {
    port=`grep listen ${snell_conf} | awk -F '=' '{print $2}' | cut -d: -f2`
    if [[ -z "${port}" ]]; then
	port=`grep listen ${snell_conf} | awk -F '=' '{print $2}' | cut -d: -f4`
    fi
    psk=`grep psk ${snell_conf} | awk -F '= ' '{print $2}'`
    ipv6=`grep ipv6 ${snell_conf} | awk -F '= ' '{print $2}'`
    if [[ $ipv6 == "true" ]]; then
	IP=${IP6}
    else
	IP=${IP4}
    fi
    obfs=`grep obfs ${snell_conf} | awk -F '= ' '{print $2}'`
    tfo=`grep tfo ${snell_conf} | awk -F '= ' '{print $2}'`
    ver=`grep '#' ${snell_conf} | awk -F '# ' '{print $2}'`
}

GetConfig_stls() {
    V6=`grep ipv6 ${snell_conf} | awk -F '= ' '{print $2}'`
    if [[ $V6 = "true" ]]; then
	sport=`grep listen ${stls_conf} | cut -d- -f7 | cut -d: -f4`
    else
	sport=`grep listen ${stls_conf} | cut -d- -f7 | cut -d: -f2`
    fi
    pass=`grep password ${stls_conf} | cut -d- -f13 | cut -d " " -f 2`
    domain=`grep password ${stls_conf} | cut -d- -f11 | cut -d " " -f 2`
}

outputSnell() {
    echo -e "   ${BLUE}协议: ${PLAIN} ${RED}snell${PLAIN}"
    echo -e "   ${BLUE}地址(IP): ${PLAIN} ${RED}${IP}${PLAIN}"
    echo -e "   ${BLUE}Snell端口(PORT)：${PLAIN} ${RED}${port}${PLAIN}"
    echo -e "   ${BLUE}Snell密钥(PSK)：${PLAIN} ${RED}${psk}${PLAIN}"
    echo -e "   ${BLUE}IPV6：${PLAIN} ${RED}${ipv6}${PLAIN}"
    echo -e "   ${BLUE}混淆(OBFS)：${PLAIN} ${RED}${obfs}${PLAIN}"
    echo -e "   ${BLUE}TCP加速(TFO)：${PLAIN} ${RED}${tfo}${PLAIN}"
    echo -e "   ${BLUE}Snell版本(VER)：${PLAIN} ${RED}${ver}${PLAIN}"
}

outputSTLS() {
    echo -e "   ${BLUE}ShadowTLS端口(PORT)：${PLAIN} ${RED}${sport}${PLAIN}"
    echo -e "   ${BLUE}ShadowTLS密码(PASS)：${PLAIN} ${RED}${pass}${PLAIN}"
    echo -e "   ${BLUE}ShadowTLS域名(DOMAIN)：${PLAIN} ${RED}${domain}${PLAIN}"
    echo -e "   ${BLUE}ShadowTLS版本(VER)：${PLAIN} ${RED}v3${PLAIN}"
}

Change_snell(){
    if [[ ! -f "$snell_conf" ]]; then
        colorEcho $RED "Snell未安装，无法修改。"
        return
    fi
    colorEcho $BLUE "开始修改 Snell 配置..."
    GetConfig
    DEFAULT_PORT=${port}
    DEFAULT_PSK=${psk}
    Generate_conf # 获取新的 PORT 和 PSK
    unset DEFAULT_PORT DEFAULT_PSK
    
    # 如果ShadowTLS已安装，需要更新其启动参数中的Snell端口
    if [[ -f "$stls_conf" ]]; then
        colorEcho $YELLOW "检测到ShadowTLS，将同步更新其配置..."
        GetConfig_stls # 获取当前的 sport, pass, domain
        SPORT=${sport} # 赋值给大写变量以供Deploy_stls使用
        PASS=${pass}
        DOMAIN=${domain}
        Deploy_stls # 使用新的PORT和旧的STLS参数重新生成服务文件
    fi

    Write_config # 写入新的Snell配置文件
    systemctl restart snell
    colorEcho $GREEN "修改配置成功！"
    ShowInfo
}

Change_stls() {
    if [[ ! -f "$stls_conf" ]]; then
        colorEcho $RED "未安装ShadowTLS，无法修改。"
        return
    fi
    colorEcho $BLUE "开始修改 ShadowTLS 配置..."
    GetConfig # 获取当前的 Snell port
    PORT=${port} # 赋值给大写变量以供Deploy_stls使用
    Generate_stls # 获取新的 SPORT, DOMAIN, PASS
    Deploy_stls # 部署新的ShadowTLS服务
    colorEcho $GREEN "修改配置成功！"
    ShowInfo
}

Upgrade_snell() {
    if [[ ! -f "$snell_conf" ]]; then
        colorEcho $RED "Snell未安装，无法升级。"
        return
    fi
    Resolve_snell_latest || return
    
    installed_ver=$(grep '#' ${snell_conf} | awk -F '# ' '{print $2}')
    if [[ -z "$installed_ver" ]]; then
        colorEcho $YELLOW "无法检测到已安装版本，将尝试直接升级。"
    elif [[ "$installed_ver" == "$LATEST_SNELL_VER" ]]; then
        colorEcho $GREEN "恭喜！当前已是最新版本 ($LATEST_SNELL_VER)，无需升级。"
        return
    fi

    colorEcho $YELLOW "发现新版本！"
    colorEcho $BLUE "当前版本: ${installed_ver:-未知}"
    colorEcho $BLUE "最新版本: ${LATEST_SNELL_VER}"
    read -p "是否要升级? [y/n] (默认y, 回车): " answer
    [[ -z "$answer" ]] && answer="y"
    if [[ "$answer" != "y" ]]; then
        colorEcho $YELLOW "已取消升级。"
        return
    fi

    colorEcho $BLUE "开始升级Snell..."
    systemctl stop snell
    
    # 下载新版本
    colorEcho $YELLOW "下载新版Snell: ${LATEST_DOWNLOAD_LINK}"
    wget -O /tmp/snell.zip ${LATEST_DOWNLOAD_LINK}
    if [[ $? -ne 0 ]]; then
        colorEcho $RED "下载新版本失败，升级已中止。"
        systemctl start snell
        return
    fi
    
    unzip -o /tmp/snell.zip -d /tmp/
    mv /tmp/snell-server /etc/snell/snell
    chmod +x /etc/snell/snell
    rm -f /tmp/snell.zip
    
    # 更新配置文件中的版本号
    if grep -q '^# ' "${snell_conf}"; then
        sed -i "s/^# .*/# ${LATEST_SNELL_VER}/" "${snell_conf}"
    else
        echo "# ${LATEST_SNELL_VER}" >> "${snell_conf}"
    fi

    systemctl start snell
    colorEcho $GREEN "Snell已成功升级到 ${LATEST_SNELL_VER} 并重新启动！"
}

Snell_menu() {
    clear
    echo "################################"
    echo -e "#      ${YELLOW}管理 Snell 配置${PLAIN}        #"
    echo "################################"
    echo ""
    echo -e "  ${GREEN}1.${PLAIN}  修改 Snell 配置 (端口/密钥)"
    echo -e "  ${GREEN}2.${PLAIN}  检查并升级 Snell"
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

ShadowTLS_menu() {
    clear
    echo "################################"
    echo -e "#      ${YELLOW}管理 ShadowTLS${PLAIN}        #"
    echo "################################"
    echo ""
    echo -e "  ${GREEN}1.${PLAIN}  安装 ShadowTLS"
    echo -e "  ${GREEN}2.${PLAIN}  修改 ShadowTLS 配置"
    echo -e "  ${GREEN}3.${PLAIN}  卸载 ShadowTLS"
    echo -e "  ${GREEN}0.${PLAIN}  返回主菜单"
    echo ""
    read -p " 请选择操作[0-3]：" answer
    case $answer in
        0)
            menu
            ;;
        1)
            Install_stls
            ;;
        2)
            Change_stls
            ;;
        3)
            Uninstall_stls
            ;;
        *)
            colorEcho $RED " 请选择正确的操作！"
            sleep 2s
            ShadowTLS_menu
            ;;
    esac
}

Uninstall_menu() {
    clear
    echo "################################"
    echo -e "#      ${RED}卸载菜单${PLAIN}              #"
    echo "################################"
    echo ""
    echo -e "  ${GREEN}1.${PLAIN}  卸载 ShadowTLS"
    echo -e "  ${GREEN}2.${PLAIN}  ${RED}卸载 Snell 和 ShadowTLS${PLAIN}"
    echo -e "  ${GREEN}0.${PLAIN}  返回主菜单"
    echo ""
    read -p " 请选择操作[0-2]：" answer
    case $answer in
        0)
            menu
            ;;
        1)
            Uninstall_stls
            ;;
        2)
            Uninstall_all
            ;;
        *)
            colorEcho $RED " 请选择正确的操作！"
            sleep 2s
            Uninstall_menu
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
    colorEcho $YELLOW "正在配置 BBR..."
    sed -i '/^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=/d' /etc/sysctl.conf
    sed -i '/^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=/d' /etc/sysctl.conf
    cat >> /etc/sysctl.conf <<-EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

    if ! sysctl -p >/dev/null 2>&1; then
        colorEcho $RED "应用内核参数失败，请检查 /etc/sysctl.conf。"
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
	echo -e "  ${GREEN}3.${PLAIN}  管理 ShadowTLS"
	echo -e "  ${GREEN}4.${PLAIN}  重启服务"
	echo -e "  ${GREEN}5.${PLAIN}  卸载"
	if [[ "$BBR_ENABLED" != "true" ]]; then
		echo -e "  ${GREEN}6.${PLAIN}  开启 BBR"
	fi
	echo -e "  ${GREEN}0.${PLAIN}  退出"
	echo ""
	if [[ "$BBR_ENABLED" == "true" ]]; then
		read -p " 请选择操作[0-5]：" answer
	else
		read -p " 请选择操作[0-6]：" answer
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
			ShadowTLS_menu
			;;
		4)
			Restart_all
			;;
		5)
			Uninstall_menu
			;;
		6)
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
