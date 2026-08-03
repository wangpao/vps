#!/usr/bin/env bash

set -e

CONFIG_FILE="/etc/monthly-reboot.conf"
SERVICE_FILE="/etc/systemd/system/monthly-reboot.service"
TIMER_FILE="/etc/systemd/system/monthly-reboot.timer"

# 必须 root
if [ "$EUID" -ne 0 ]; then
    echo "请使用 sudo 运行:"
    echo "sudo $0"
    exit 1
fi


load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        ENABLED=true
    else
        ENABLED=false
    fi
}


show_status() {

    load_config

    echo
    echo "================================="
    echo " VPS Monthly Reboot Manager"
    echo "================================="
    echo

    if [ "$ENABLED" = true ]; then

        echo "当前状态:"
        echo " 自动重启: 已设置"
        echo " 日期: 每月 ${DAY} 日"
        echo " 时间: ${TIME}"

        if [ -n "$TIMEZONE" ]; then
            echo " 时区: ${TIMEZONE}"
        else
            echo " 时区: 系统默认"
        fi

        echo

        if command -v systemctl >/dev/null; then
            echo "下一次执行:"
            systemctl list-timers monthly-reboot.timer \
                --no-pager \
                | grep monthly-reboot || true
        fi

    else

        echo "当前状态:"
        echo " 自动重启: 未设置"

    fi

    echo
}


create_service() {

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Monthly VPS automatic reboot

[Service]
Type=oneshot
ExecStart=/usr/sbin/reboot
EOF


cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Monthly VPS automatic reboot timer

[Timer]
OnCalendar=*-*-${DAY} ${TIME}:00
Persistent=true

[Install]
WantedBy=timers.target
EOF


systemctl daemon-reload
systemctl enable monthly-reboot.timer >/dev/null
systemctl restart monthly-reboot.timer

}


setup_reboot() {

echo
echo "设置自动重启"
echo "----------------"

read -p "每月哪一天执行 [默认 1]: " input_day

DAY=${input_day:-1}


if ! [[ "$DAY" =~ ^[0-9]+$ ]] || \
   [ "$DAY" -lt 1 ] || [ "$DAY" -gt 31 ]; then

    echo "日期错误"
    return
fi



read -p "执行时间 HH:MM [默认 04:00]: " input_time

TIME=${input_time:-04:00}



if ! [[ "$TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then

    echo "时间格式错误"
    return
fi



read -p "时区 (留空使用系统时区): " TIMEZONE


cat > "$CONFIG_FILE" <<EOF
DAY=$DAY
TIME=$TIME
TIMEZONE=$TIMEZONE
EOF


create_service


echo
echo "设置完成"
echo "每月 ${DAY} 日 ${TIME} 自动重启"
echo

}



remove_reboot() {

echo

read -p "确认取消自动重启? (y/N): " confirm


if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then

    echo "取消"
    return

fi



systemctl disable --now monthly-reboot.timer \
    >/dev/null 2>&1 || true


rm -f "$TIMER_FILE"
rm -f "$SERVICE_FILE"
rm -f "$CONFIG_FILE"


systemctl daemon-reload


echo
echo "自动重启已取消"
echo

}



menu() {

while true
do

    show_status


    echo "请选择:"
    echo


    if [ "$ENABLED" = true ]; then

        echo "1) 设置自动重启"
        echo "2) 修改重启时间"
        echo "3) 取消自动重启"

    else

        echo "1) 设置自动重启"

    fi


    echo "0) 退出"
    echo


    read -p "选择: " choice


    case "$choice" in

        1)
            setup_reboot
            ;;

        2)

            if [ "$ENABLED" = true ]; then
                setup_reboot
            else
                echo "尚未设置自动重启"
            fi

            ;;


        3)

            if [ "$ENABLED" = true ]; then
                remove_reboot
            else
                echo "尚未设置自动重启"
            fi

            ;;


        0)
            exit 0
            ;;


        *)
            echo "无效选择"
            ;;

    esac


done

}



menu