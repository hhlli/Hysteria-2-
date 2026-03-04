#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限!${NC}" && exit 1

check_status() {
    systemctl is-active --quiet tuic && echo -e "状态: ${GREEN}运行中${NC}" || echo -e "状态: ${RED}未安装或停止${NC}"
}

view_config() {
    if [ ! -f "/etc/tuic/config.json" ]; then
        echo -e "${RED}配置文件不存在!${NC}"
        return
    fi
    PORT=$(grep '"server":' /etc/tuic/config.json | awk -F: '{print $NF}' | tr -d '", ')
    UUID=$(grep -oE '[a-z0-9-]{36}' /etc/tuic/config.json | head -1)
    TOKEN=$(grep -A 1 "$UUID" /etc/tuic/config.json | grep -v "$UUID" | tr -d '":, ')
    
    echo -e "${GREEN}=== 当前 TUIC v5 配置 ===${NC}"
    echo -e "监听端口: ${YELLOW}$PORT${NC}"
    echo -e "UUID: ${YELLOW}$UUID${NC}"
    echo -e "Token: ${YELLOW}$TOKEN${NC}"
    echo -e "---------------------------"
    echo -e "Surge 配置参考:"
    echo -e "${GREEN}TUIC = tuic, 你的域名, $PORT, token=$TOKEN, uuid=$UUID, sni=你的域名, alpn=h3${NC}"
}

modify_config() {
    read -p "请输入新的端口: " NEW_PORT
    read -p "请输入新的 Token: " NEW_TOKEN
    
    # 使用 sed 修改 JSON 中的端口和密码 (假设结构固定)
    sed -i "s/\"server\": \".*\"/\"server\": \"[::]:$NEW_PORT\"/" /etc/tuic/config.json
    # 修改用户 Token
    UUID=$(grep -oE '[a-z0-9-]{36}' /etc/tuic/config.json | head -1)
    sed -i "s/\"$UUID\": \".*\"/\"$UUID\": \"$NEW_TOKEN\"/" /etc/tuic/config.json
    
    systemctl restart tuic
    echo -e "${GREEN}配置已更新并重启。${NC}"
}

install_tuic() {
    read -p "域名: " DOMAIN
    read -p "端口: " PORT
    PORT=${PORT:-443}
    UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
    read -p "Token (留空随机): " TOKEN
    [[ -z "$TOKEN" ]] && TOKEN=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 12)
    
    arch=$(uname -m)
    url="https://github.com/EAimTY/tuic/releases/download/tuic-server-1.0.0/tuic-server-1.0.0-x86_64-unknown-linux-gnu"
    curl -L $url -o /usr/local/bin/tuic-server && chmod +x /usr/local/bin/tuic-server

    mkdir -p /etc/tuic
    cat << EOF > /etc/tuic/config.json
{
    "server": "[::]:$PORT",
    "users": { "$UUID": "$TOKEN" },
    "certificate": "/etc/hysteria/certs/server.crt",
    "private_key": "/etc/hysteria/certs/server.key",
    "congestion_control": "bbr",
    "alpn": ["h3"],
    "zero_rtt_handshake": true
}
EOF
    cat << EOF > /etc/systemd/system/tuic.service
[Unit]
Description=TUIC v5
After=network.target
[Service]
ExecStart=/usr/local/bin/tuic-server -c /etc/tuic/config.json
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now tuic
    echo -e "${GREEN}安装完成!${NC}"
}

clear
echo -e "${GREEN}TUIC v5 管理脚本 (2026)${NC}"
check_status
echo "--------------------------------"
echo "1. 安装"
echo "2. 卸载"
echo "3. 重启"
echo "4. 日志"
echo "5. 查看当前配置"
echo "6. 修改端口和Token"
echo "7. 退出"
read -p "选择: " opt

case $opt in
    1) install_tuic ;;
    2) systemctl stop tuic; rm -rf /etc/tuic /usr/local/bin/tuic-server ;;
    3) systemctl restart tuic ;;
    4) journalctl -u tuic -f ;;
    5) view_config ;;
    6) modify_config ;;
    *) exit 0 ;;
esac
