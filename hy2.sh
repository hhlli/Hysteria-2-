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
    if [ -f "/usr/local/bin/hysteria" ]; then
        if systemctl is-active --quiet hysteria-server; then
            echo -e "Hysteria 2 状态: ${GREEN}运行中${NC}"
        else
            echo -e "Hysteria 2 状态: ${YELLOW}已安装，未运行${NC}"
        fi
    else
        echo -e "Hysteria 2 状态: ${RED}未安装${NC}"
    fi
}

# 安装功能
install_hy2() {
    read -p "设置域名: " DOMAIN
    read -p "设置端口 (默认 443): " PORT
    PORT=${PORT:-443}
    read -p "设置连接密码: " PASSWORD
    
    # 安装核心
    bash <(curl -fsSL https://get.hy2.sh/)
    
    # 证书申请 (Standalone)
    if [ ! -f "$HOME/.acme.sh/acme.sh" ]; then
        curl https://get.acme.sh | sh -s email=admin@$DOMAIN
    fi
    ~/.acme.sh/acme.sh --issue -d $DOMAIN --standalone
    
    mkdir -p /etc/hysteria/certs
    ~/.acme.sh/acme.sh --install-cert -d $DOMAIN \
        --key-file /etc/hysteria/certs/server.key \
        --fullchain-file /etc/hysteria/certs/server.crt \
        --reloadcmd "systemctl restart hysteria-server"

    # 生成配置
    cat << EOF > /etc/hysteria/config.yaml
listen: :$PORT
tls:
  cert: /etc/hysteria/certs/server.crt
  key: /etc/hysteria/certs/server.key
auth:
  type: password
  password: $PASSWORD
masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true
ignoreClientBandwidth: true
EOF

    chown -R hysteria:hysteria /etc/hysteria/certs
    systemctl enable --now hysteria-server
    
    echo -e "${GREEN}安装成功!${NC}"
    echo -e "Surge 配置: ${YELLOW}Hy2 = hysteria2, $DOMAIN, $PORT, password=$PASSWORD, sni=$DOMAIN${NC}"
}

# 卸载功能
uninstall_hy2() {
    systemctl stop hysteria-server
    systemctl disable hysteria-server
    rm -rf /etc/hysteria /usr/local/bin/hysteria /etc/systemd/system/hysteria-server.service
    echo -e "${GREEN}卸载完成${NC}"
}

# 主菜单
echo -e "${GREEN}Hysteria 2 一键管理脚本 (2026)${NC}"
check_status
echo "--------------------------------"
echo "1. 安装"
echo "2. 卸载"
echo "3. 重启"
echo "4. 查看配置/日志"
echo "5. 退出"
read -p "请选择: " opt

case $opt in
    1) install_hy2 ;;
    2) uninstall_hy2 ;;
    3) systemctl restart hysteria-server && echo "已重启" ;;
    4) journalctl -u hysteria-server -f ;;
    *) exit 0 ;;
esac
