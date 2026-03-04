#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 检查权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行此脚本!${NC}" && exit 1

# 检查状态
check_status() {
    if systemctl is-active --quiet tuic; then
        echo -e "状态: ${GREEN}运行中${NC}"
    else
        echo -e "状态: ${YELLOW}未安装或已停止${NC}"
    fi
}

# 1. 查看配置 (精准解析 JSON)
view_config() {
    CONF="/etc/tuic/config.json"
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}配置文件不存在!${NC}"
        return
    fi
    PORT=$(grep '"server":' $CONF | awk -F: '{print $NF}' | tr -d '", ')
    UUID=$(grep -oE '[a-z0-9-]{36}' $CONF | head -1)
    TOKEN=$(grep "\"$UUID\":" $CONF | awk -F: '{print $2}' | tr -d '", ')
    
    echo -e "${GREEN}=== 当前 TUIC v5 配置 ===${NC}"
    echo -e "监听端口: ${YELLOW}$PORT${NC}"
    echo -e "UUID:     ${YELLOW}$UUID${NC}"
    echo -e "Token:    ${YELLOW}$TOKEN${NC}"
    echo -e "---------------------------"
    echo -e "Surge 配置参考:"
    echo -e "${GREEN}TUIC-Node = tuic, 你的域名, $PORT, token=$TOKEN, uuid=$UUID, sni=你的域名, alpn=h3${NC}"
}

# 2. 修改端口和 Token
modify_config() {
    CONF="/etc/tuic/config.json"
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}请先安装 TUIC v5!${NC}"
        return
    fi
    
    read -p "请输入新的端口: " NEW_PORT
    read -p "请输入新的 Token (留空随机): " NEW_TOKEN
    [[ -z "$NEW_TOKEN" ]] && NEW_TOKEN=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 12)
    
    # 获取现有 UUID
    UUID=$(grep -oE '[a-z0-9-]{36}' $CONF | head -1)
    
    # 替换端口和 Token
    sed -i "s/\"server\": \".*\"/\"server\": \"[::]:$NEW_PORT\"/" $CONF
    sed -i "s/\"$UUID\": \".*\"/\"$UUID\": \"$NEW_TOKEN\"/" $CONF
    
    systemctl restart tuic
    echo -e "${GREEN}修改成功并已重启服务!${NC}"
    view_config
}

# 3. 安装功能
install_tuic() {
    read -p "设置域名: " DOMAIN
    read -p "设置端口 (默认 443): " PORT
    PORT=${PORT:-443}
    read -p "设置 Token (留空随机): " TOKEN
    [[ -z "$TOKEN" ]] && TOKEN=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 12)
    
    # 生成随机 UUID
    NEW_UUID=$(cat /proc/sys/kernel/random/uuid)
    
    # 下载
    arch=$(uname -m)
    if [ "$arch" == "x86_64" ]; then
        url="https://github.com/EAimTY/tuic/releases/download/tuic-server-1.0.0/tuic-server-1.0.0-x86_64-unknown-linux-gnu"
    else
        url="https://github.com/EAimTY/tuic/releases/download/tuic-server-1.0.0/tuic-server-1.0.0-aarch64-unknown-linux-gnu"
    fi
    curl -L $url -o /usr/local/bin/tuic-server && chmod +x /usr/local/bin/tuic-server

    # 路径
    mkdir -p /etc/tuic
    
    # 写入配置 (确保变量被正确引用)
    cat << EOF > /etc/tuic/config.json
{
    "server": "[::]:$PORT",
    "users": {
        "$NEW_UUID": "$TOKEN"
    },
    "certificate": "/etc/hysteria/certs/server.crt",
    "private_key": "/etc/hysteria/certs/server.key",
    "congestion_control": "bbr",
    "alpn": ["h3"],
    "zero_rtt_handshake": true,
    "dual_stack": true
}
EOF

    # 服务文件
    cat << EOF > /etc/systemd/system/tuic.service
[Unit]
Description=TUIC v5 Server
After=network.target

[Service]
ExecStart=/usr/local/bin/tuic-server -c /etc/tuic/config.json
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable tuic
    systemctl restart tuic
    echo -e "${GREEN}安装完成!${NC}"
    view_config
}

# 主菜单
clear
echo -e "${GREEN}TUIC v5 管理脚本 (2026 稳定版)${NC}"
check_status
echo "--------------------------------"
echo "1. 安装 / 覆盖安装"
echo "2. 卸载"
echo "3. 重启服务"
echo "4. 查看日志"
echo "5. 查看当前配置"
echo "6. 修改端口和Token"
echo "7. 退出"
read -p "选择: " opt

case $opt in
    1) install_tuic ;;
    2) systemctl stop tuic; rm -rf /etc/tuic /usr/local/bin/tuic-server /etc/systemd/system/tuic.service; echo -e "${GREEN}卸载成功${NC}" ;;
    3) systemctl restart tuic; echo -e "${GREEN}已重启${NC}" ;;
    4) journalctl -u tuic -f ;;
    5) view_config ;;
    6) modify_config ;;
    *) exit 0 ;;
esac
