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
            echo -e "AnyTLS 状态: ${GREEN}运行中 (Sing-box 核心)${NC}"
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
    
    PORT=$(grep '"listen_port":' $CONF | awk -F: '{print $NF}' | tr -d '", ')
    PASSWORD=$(grep '"password":' $CONF | awk -F: '{print $2}' | tr -d '", ')
    DOMAIN=$(grep '"server_name":' $CONF | awk -F: '{print $2}' | tr -d '", ')

    echo -e "${GREEN}=== 当前 AnyTLS 配置 ===${NC}"
    echo -e "监听端口: ${YELLOW}$PORT${NC}"
    echo -e "Password: ${YELLOW}$PASSWORD${NC}"
    echo -e "----------------------------------------"
    echo -e "Surge 配置参考 (已启用真实证书校验):"
    echo -e "${GREEN}AnyTLS-Node = anytls, $DOMAIN, $PORT, password=$PASSWORD, sni=$DOMAIN${NC}"
}

# 2. 修改端口和 Password
modify_config() {
    CONF="/etc/anytls/config.json"
    if [ ! -f "$CONF" ]; then
        echo -e "${RED}配置文件不存在，请先安装!${NC}"
        return
    fi

    read -p "设置新端口: " NEW_PORT
    NEW_PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)

    sed -i -E "s/\"listen_port\": [0-9]+/\"listen_port\": $NEW_PORT/" $CONF
    sed -i -E "s/\"password\": \".*\"/\"password\": \"$NEW_PASSWORD\"/" $CONF

    systemctl restart anytls
    echo -e "${GREEN}配置已更新并重启服务。新的强密码已生效。${NC}"
    view_config
}

# 3. 安装功能
install_anytls() {
    read -p "设置域名 (请输入域名): " DOMAIN
    read -p "设置端口 (默认 4430): " PORT
    PORT=${PORT:-4430}
    
    echo -e "${YELLOW}正在自动生成强密码...${NC}"
    PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
    
    echo -e "${YELLOW}获取 Sing-box 最新版本核心...${NC}"
    LATEST_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    [[ -z "$LATEST_VERSION" ]] && LATEST_VERSION="1.11.4"
    
    arch=$(uname -m)
    if [ "$arch" == "x86_64" ]; then
        url="https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VERSION}/sing-box-${LATEST_VERSION}-linux-amd64.tar.gz"
    elif [ "$arch" == "aarch64" ]; then
        url="https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VERSION}/sing-box-${LATEST_VERSION}-linux-arm64.tar.gz"
    else
        echo -e "${RED}不支持的架构: $arch${NC}" && exit 1
    fi
    
    apt update && apt install -y curl tar
    wget -q -O /tmp/sb.tar.gz $url
    tar -xzf /tmp/sb.tar.gz -C /tmp/
    mv /tmp/sing-box-*/sing-box /usr/local/bin/anytls-server
    chmod +x /usr/local/bin/anytls-server
    rm -rf /tmp/sb.tar.gz /tmp/sing-box-*

    # 证书申请与检测逻辑 (复用现有安全证书)
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

    # 生成标准的 Sing-box AnyTLS 服务端配置
    mkdir -p /etc/anytls
    cat << EOF > /etc/anytls/config.json
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": $PORT,
      "users": [
        {
          "name": "user",
          "password": "$PASSWORD"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "certificate_path": "$CERT_PATH",
        "key_path": "$KEY_PATH"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

    # 创建 Systemd 服务
    cat << EOF > /etc/systemd/system/anytls.service
[Unit]
Description=AnyTLS Server Service (Sing-box Core)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/anytls
ExecStart=/usr/local/bin/anytls-server run -c /etc/anytls/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=512000

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable anytls
    systemctl restart anytls
    
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}AnyTLS (Sing-box 核心) 安装成功!${NC}"
    view_config
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
echo -e "${GREEN}AnyTLS 高级服务端 一键管理脚本 (基于 Sing-box)${NC}"
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
