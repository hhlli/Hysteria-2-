#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 检查权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行此脚本!${NC}" && exit 1

# 检查安装状态
check_status() {
    if [ -f "/usr/local/bin/anytls-server" ]; then
        if systemctl is-active --quiet anytls; then
            echo -e "AnyTLS 状态: ${GREEN}运行中${NC}"
        else
            echo -e "AnyTLS 状态: ${YELLOW}已安装，但未运行${NC}"
        fi
    else
        echo -e "AnyTLS 状态: ${RED}未安装${NC}"
    fi
}

# 1. 查看当前配置
view_config() {
    CONF="/etc/anytls/config.json"
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}配置文件不存在，请先安装!${NC}"
        return
    fi
    
    # 解析 JSON (兼容 listen 和 server 字段)
    PORT=$(grep -E '"(server|listen)":' $CONF | awk -F: '{print $NF}' | tr -d '", ')
    PASSWORD=$(grep '"password":' $CONF | awk -F: '{print $2}' | tr -d '", ')

    # 如果密码在 users 数组中，则提取备用密码逻辑
    if [ -z "$PASSWORD" ]; then
        PASSWORD=$(grep -A 1 '"users":' $CONF | tail -n 1 | awk -F: '{print $2}' | tr -d '", ')
    fi

    echo -e "${GREEN}=== 当前 AnyTLS 配置 ===${NC}"
    echo -e "监听端口: ${YELLOW}$PORT${NC}"
    echo -e "Password: ${YELLOW}$PASSWORD${NC}"
    echo -e "----------------------------------------"
    echo -e "Surge 配置参考 (请关闭 skip-cert-verify):"
    echo -e "${GREEN}AnyTLS-Node = anytls, 你的域名, $PORT, password=$PASSWORD, sni=你的域名${NC}"
}

# 2. 修改端口和 Password
modify_config() {
    CONF="/etc/anytls/config.json"
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}配置文件不存在，请先安装!${NC}"
        return
    fi

    read -p "设置新端口: " NEW_PORT
    
    # 自动生成新的 16 位强密码
    NEW_PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)

    # 替换端口 (匹配 server 或 listen)
    sed -i -E "s/\"(server|listen)\": \".*\"/\"server\": \"[::]:$NEW_PORT\"/" $CONF
    
    # 替换密码
    sed -i -E "s/\"password\": \".*\"/\"password\": \"$NEW_PASSWORD\"/" $CONF
    # 兼容 users 字段模式
    sed -i -E "s/\"user\": \".*\"/\"user\": \"$NEW_PASSWORD\"/" $CONF

    systemctl restart anytls
    echo -e "${GREEN}配置已更新并重启服务。新的强密码已生效。${NC}"
    view_config
}

# 3. 安装功能
install_anytls() {
    read -p "设置域名 (如 dc1.767667.xyz): " DOMAIN
    read -p "设置端口 (默认 4430): " PORT
    PORT=${PORT:-4430}
    
    # 全自动生成 16位强密码
    echo -e "${YELLOW}正在自动生成强密码...${NC}"
    PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
    
    # 下载二进制文件 (v0.0.12 最新版)
    arch=$(uname -m)
    echo -e "${YELLOW}正在下载 AnyTLS v0.0.12 服务端...${NC}"
    
    apt update && apt install -y curl socat unzip
    
    if [ "$arch" == "x86_64" ]; then
        url="https://github.com/anytls/anytls-go/releases/download/v0.0.12/anytls_0.0.12_linux_amd64.zip"
    elif [ "$arch" == "aarch64" ]; then
        url="https://github.com/anytls/anytls-go/releases/download/v0.0.12/anytls_0.0.12_linux_arm64.zip"
    else
        echo -e "${RED}不支持的架构: $arch${NC}" && exit 1
    fi
    
    # 下载并解压 ZIP 包
    wget -q -O /tmp/anytls.zip $url
    unzip -o -q /tmp/anytls.zip -d /tmp/anytls_ext
    # 获取二进制文件并赋予权限
    BIN_PATH=$(find /tmp/anytls_ext -type f -name "anytls*" -executable | head -n 1)
    if [ -z "$BIN_PATH" ]; then BIN_PATH="/tmp/anytls_ext/anytls"; fi
    mv "$BIN_PATH" /usr/local/bin/anytls-server
    chmod +x /usr/local/bin/anytls-server
    rm -rf /tmp/anytls.zip /tmp/anytls_ext

    # 证书申请与检测逻辑 (优先复用 TUIC 和 Hy2 证书)
    if [ -f "/etc/hysteria/certs/server.crt" ]; then
        echo -e "${GREEN}检测到现有 Hysteria 2 证书，直接复用。${NC}"
        CERT_PATH="/etc/hysteria/certs/server.crt"
        KEY_PATH="/etc/hysteria/certs/server.key"
    elif [ -f "/etc/tuic/certs/server.crt" ]; then
        echo -e "${GREEN}检测到现有 TUIC 证书，直接复用。${NC}"
        CERT_PATH="/etc/tuic/certs/server.crt"
        KEY_PATH="/etc/tuic/certs/server.key"
    else
        echo -e "${YELLOW}未检测到可用证书，开始自动申请独立证书...${NC}"
        curl https://get.acme.sh | sh -s email=admin@$DOMAIN
        source ~/.bashrc
        ~/.acme.sh/acme.sh --issue -d $DOMAIN --standalone --force
        mkdir -p /etc/anytls/certs
        ~/.acme.sh/acme.sh --install-cert -d $DOMAIN \
            --key-file /etc/anytls/certs/server.key \
            --fullchain-file /etc/anytls/certs/server.crt
        CERT_PATH="/etc/anytls/certs/server.crt"
        KEY_PATH="/etc/anytls/certs/server.key"
    fi

    # 生成 JSON 配置文件 (适配通用 Go 服务端格式)
    mkdir -p /etc/anytls
    cat << EOF > /etc/anytls/config.json
{
    "server": "[::]:$PORT",
    "password": "$PASSWORD",
    "users": {
        "user": "$PASSWORD"
    },
    "certificate": "$CERT_PATH",
    "private_key": "$KEY_PATH",
    "private-key": "$KEY_PATH"
}
EOF
    # 注意: 上方配置同时写入了 password 和 users，以及两种私钥格式，以兼容不同版本的参数解析。

    # 创建 Systemd 服务
    cat << EOF > /etc/systemd/system/anytls.service
[Unit]
Description=AnyTLS Server Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/anytls
ExecStart=/usr/local/bin/anytls-server -c /etc/anytls/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=512000

[Install]
WantedBy=multi-user.target
EOF

    # 启动服务
    systemctl daemon-reload
    systemctl enable anytls
    systemctl restart anytls
    
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}AnyTLS v0.0.12 安装成功!${NC}"
    echo -e "域名: ${YELLOW}$DOMAIN${NC}"
    echo -e "端口: ${YELLOW}$PORT${NC}"
    echo -e "Password: ${YELLOW}$PASSWORD${NC}"
    echo -e "----------------------------------------"
    echo -e "Surge 配置参考 (可直接复制):"
    echo -e "${GREEN}AnyTLS-Node = anytls, $DOMAIN, $PORT, password=$PASSWORD, sni=$DOMAIN${NC}"
    echo -e "${GREEN}========================================${NC}"
}

# 卸载功能
uninstall_anytls() {
    echo -e "${YELLOW}正在卸载 AnyTLS...${NC}"
    systemctl stop anytls
    systemctl disable anytls
    rm -f /usr/local/bin/anytls-server
    rm -rf /etc/anytls
    rm -f /etc/systemd/system/anytls.service
    systemctl daemon-reload
    echo -e "${GREEN}卸载完成。${NC}"
}

# 主菜单
clear
echo -e "${GREEN}AnyTLS (v0.0.12) 一键管理脚本${NC}"
check_status
echo "--------------------------------"
echo "1. 安装 / 覆盖安装"
echo "2. 卸载"
echo "3. 重启服务"
echo "4. 查看实时日志"
echo "5. 查看当前配置"
echo "6. 修改端口和 Password"
echo "7. 退出"
read -p "请选择 [1-7]: " opt

case $opt in
    1) install_anytls ;;
    2) uninstall_anytls ;;
    3) systemctl restart anytls && echo -e "${GREEN}已重启${NC}" ;;
    4) journalctl -u anytls -f ;;
    5) view_config ;;
    6) modify_config ;;
    *) exit 0 ;;
esac
