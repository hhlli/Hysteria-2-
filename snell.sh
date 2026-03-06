#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行此脚本!${NC}" && exit 1

check_status() {
    systemctl is-active --quiet snell && echo -e "Snell v5 状态: ${GREEN}运行中${NC}" || echo -e "Snell v5 状态: ${RED}未安装或停止${NC}"
    systemctl is-active --quiet shadowtls && echo -e "ShadowTLS v3 状态: ${GREEN}运行中${NC}" || echo -e "ShadowTLS v3 状态: ${YELLOW}未安装或停止${NC}"
}

view_config() {
    if [ ! -f "/etc/snell/snell-server.conf" ]; then
        echo -e "${RED}未找到 Snell 配置文件!${NC}"
        return
    fi

    SNELL_PORT=$(grep "listen =" /etc/snell/snell-server.conf | tr -d ' ' | awk -F: '{print $NF}')
    SNELL_PSK=$(grep "psk =" /etc/snell/snell-server.conf | awk -F= '{print $2}' | tr -d ' ')
    IPV6_STATUS=$(grep "ipv6 =" /etc/snell/snell-server.conf | awk -F= '{print $2}' | tr -d ' ')

    echo -e "${GREEN}=== 当前 Snell v5 配置 ===${NC}"
    echo -e "内部监听端口: ${YELLOW}$SNELL_PORT${NC}"
    echo -e "PSK 密码:     ${YELLOW}$SNELL_PSK${NC}"
    echo -e "IPv6 支持:    ${YELLOW}$IPV6_STATUS${NC}"
    echo -e "----------------------------------------"

    if [ -f "/etc/systemd/system/shadowtls.service" ]; then
        # 从位置参数中提取配置
        EXEC_LINE=$(grep "ExecStart" /etc/systemd/system/shadowtls.service)
        STLS_PORT=$(echo "$EXEC_LINE" | awk '{print $4}' | awk -F: '{print $2}')
        STLS_SNI=$(echo "$EXEC_LINE" | awk '{print $6}' | awk -F: '{print $1}')
        STLS_PASS=$(echo "$EXEC_LINE" | awk '{print $7}')

        echo -e "${GREEN}=== 当前 ShadowTLS v3 配置 ===${NC}"
        echo -e "外部暴露端口: ${YELLOW}$STLS_PORT${NC}"
        echo -e "伪装域名 SNI: ${YELLOW}$STLS_SNI${NC}"
        echo -e "ShadowTLS密码:${YELLOW}$STLS_PASS${NC}"
        echo -e "----------------------------------------"
        echo -e "Surge 配置参考 (Snell v5 + ShadowTLS v3):"
        echo -e "${GREEN}Snell-Node = snell, 你的服务器IP, $STLS_PORT, psk=$SNELL_PSK, version=5, shadow-tls-password=$STLS_PASS, shadow-tls-sni=$STLS_SNI, shadow-tls-version=3${NC}"
    else
        echo -e "Surge 配置参考 (仅 Snell v5):"
        echo -e "${GREEN}Snell-Node = snell, 你的服务器IP, $SNELL_PORT, psk=$SNELL_PSK, version=5${NC}"
    fi
}

install_snell_shadowtls() {
    read -p "设置 ShadowTLS 外部暴露端口 (默认 443): " STLS_PORT
    STLS_PORT=${STLS_PORT:-443}
    
    SNELL_PORT=$(shuf -i 10000-65000 -n 1)
    SNELL_PSK=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)
    STLS_PASS=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)

    read -p "设置 ShadowTLS 伪装域名 SNI (默认 gateway.icloud.com): " STLS_SNI
    STLS_SNI=${STLS_SNI:-gateway.icloud.com}

    echo -e "${YELLOW}正在下载 Snell v5 服务端...${NC}"
    arch=$(uname -m)
    if [ "$arch" == "x86_64" ]; then
        url="https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-amd64.zip"
    elif [ "$arch" == "aarch64" ]; then
        url="https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-aarch64.zip"
    else
        echo -e "${RED}不支持的架构!${NC}" && exit 1
    fi

    apt update && apt install -y unzip curl
    wget -q -O /tmp/snell.zip $url
    unzip -o -q /tmp/snell.zip -d /usr/local/bin/
    chmod +x /usr/local/bin/snell-server
    rm -f /tmp/snell.zip

    mkdir -p /etc/snell
    cat << EOF > /etc/snell/snell-server.conf
[snell-server]
listen = 127.0.0.1:$SNELL_PORT
psk = $SNELL_PSK
ipv6 = false
EOF

    cat << EOF > /etc/systemd/system/snell.service
[Unit]
Description=Snell v5 Proxy Service
After=network.target

[Service]
Type=simple
LimitNOFILE=32768
ExecStart=/usr/local/bin/snell-server -c /etc/snell/snell-server.conf
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    echo -e "${YELLOW}正在下载 ShadowTLS v3 服务端...${NC}"
    if [ "$arch" == "x86_64" ]; then
        stls_url="https://github.com/ihciah/shadow-tls/releases/latest/download/shadow-tls-x86_64-unknown-linux-musl"
    elif [ "$arch" == "aarch64" ]; then
        stls_url="https://github.com/ihciah/shadow-tls/releases/latest/download/shadow-tls-aarch64-unknown-linux-musl"
    fi

    wget -q -O /usr/local/bin/shadowtls $stls_url
    chmod +x /usr/local/bin/shadowtls

    # 修正：采用位置参数格式启动 ShadowTLS v3
    cat << EOF > /etc/systemd/system/shadowtls.service
[Unit]
Description=ShadowTLS v3 Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/shadowtls --v3 0.0.0.0:$STLS_PORT 127.0.0.1:$SNELL_PORT $STLS_SNI:443 $STLS_PASS
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now snell
    systemctl enable --now shadowtls

    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Snell v5 + ShadowTLS v3 安装成功!${NC}"
    view_config
}

uninstall_all() {
    systemctl stop snell shadowtls
    systemctl disable snell shadowtls
    rm -f /usr/local/bin/snell-server /usr/local/bin/shadowtls
    rm -rf /etc/snell
    rm -f /etc/systemd/system/snell.service /etc/systemd/system/shadowtls.service
    systemctl daemon-reload
    echo -e "${GREEN}卸载完成!${NC}"
}

clear
echo -e "${GREEN}Snell v5 + ShadowTLS v3 一键管理脚本 (2026)${NC}"
check_status
echo "--------------------------------"
echo "1. 安装 / 覆盖安装"
echo "2. 卸载全部"
echo "3. 重启服务"
echo "4. 查看当前配置"
echo "5. 退出"
read -p "选择 [1-5]: " opt

case $opt in
    1) install_snell_shadowtls ;;
    2) uninstall_all ;;
    3) systemctl restart snell shadowtls && echo -e "${GREEN}已重启${NC}" ;;
    4) view_config ;;
    *) exit 0 ;;
esac
