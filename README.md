bash <(curl -fsSL https://raw.githubusercontent.com/wangpao/VPN/main/snell.sh)

bash <(curl -fsSL https://raw.githubusercontent.com/wangpao/VPN/main/bbr.sh)

bash <(curl -fsSL https://raw.githubusercontent.com/wangpao/VPN/main/clean_vps.sh)



sudo truncate -s 0 /var/log/syslog

df -h /


echo "if \$programname == 'shadow-tls' then stop" | sudo tee /etc/rsyslog.d/10-discard-shadow-tls.conf && sudo systemctl restart rsyslog.service && echo "✅ 操作成功！shadow-tls 的日志已被过滤。"

sudo sed -i '/^#\?SystemMaxUse=/c\SystemMaxUse=200M' /etc/systemd/journald.conf && sudo systemctl restart systemd-journald.service && echo "✅ 操作成功！Journald 日志大小已被限制在 200MB。"


sudo journalctl --vacuum-size=200M
