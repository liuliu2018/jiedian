
#!/bin/sh
set -eu

# ==========================================
# Hysteria 2 独立安装脚本
# 支持 Alpine / Debian / Ubuntu / 常见 Linux
# 服务：OpenRC / systemd
# ==========================================

[ "$(id -u)" -eq 0 ] || {
    echo "错误：请使用 root 用户运行。"
    exit 1
}

# 检测操作系统
if [ -r /etc/os-release ]; then
    . /etc/os-release
else
    ID=unknown
    PRETTY_NAME="Unknown Linux"
fi

echo ">>> 系统：${PRETTY_NAME:-$ID}"

# 检测服务管理器
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    SERVICE_MANAGER="systemd"
elif command -v rc-update >/dev/null 2>&1 &&
     command -v rc-service >/dev/null 2>&1; then
    SERVICE_MANAGER="openrc"
else
    echo "错误：未检测到正在运行的 systemd 或 OpenRC。"
    echo "容器或精简系统可能不支持此脚本。"
    exit 1
fi

echo ">>> 服务管理器：$SERVICE_MANAGER"

# 识别包管理器
if command -v apk >/dev/null 2>&1; then
    PKG="apk"
elif command -v apt-get >/dev/null 2>&1; then
    PKG="apt"
elif command -v dnf >/dev/null 2>&1; then
    PKG="dnf"
elif command -v yum >/dev/null 2>&1; then
    PKG="yum"
elif command -v zypper >/dev/null 2>&1; then
    PKG="zypper"
else
    echo "错误：未找到支持的包管理器。"
    exit 1
fi

# 安装依赖
echo ">>> 安装 curl、openssl、ca-certificates..."

case "$PKG" in
    apk)
        apk add curl openssl ca-certificates
        ;;
    apt)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y curl openssl ca-certificates
        ;;
    dnf)
        dnf install -y curl openssl ca-certificates
        ;;
    yum)
        yum install -y curl openssl ca-certificates
        ;;
    zypper)
        zypper --non-interactive install curl openssl ca-certificates
        ;;
esac

# 输入域名
printf "请输入已解析到本机公网 IP 的域名："
read -r DOMAIN </dev/tty

if [ -z "$DOMAIN" ]; then
    echo "错误：域名不能为空。"
    exit 1
fi

# 基础域名格式检查
case "$DOMAIN" in
    *[!A-Za-z0-9.-]*|.*|*-|*.)
        echo "错误：域名格式不正确。"
        exit 1
        ;;
esac

# 输入邮箱
printf "请输入证书申请邮箱："
read -r EMAIL </dev/tty

if [ -z "$EMAIL" ] || ! printf '%s' "$EMAIL" | grep -Eq '^[^ @]+@[^ @]+\.[^ @]+$'; then
    echo "错误：邮箱格式不正确。"
    exit 1
fi

# 输入 UDP 端口
DEFAULT_PORT=443

while true; do
    printf "请输入 HY2 UDP 端口 (默认: %s): " "$DEFAULT_PORT"
    read -r PORT </dev/tty
    PORT=${PORT:-$DEFAULT_PORT}

    case "$PORT" in
        ''|*[!0-9]*)
            echo "端口必须是 1-65535 的数字。"
            ;;
        *)
            if [ "$PORT" -ge 1 ] 2>/dev/null &&
               [ "$PORT" -le 65535 ] 2>/dev/null; then
                break
            fi
            echo "端口范围错误。"
            ;;
    esac
done

# 生成强随机密码
PASSWORD=$(openssl rand -hex 24)

# 检测 CPU 架构
RAW_ARCH=$(uname -m)

case "$RAW_ARCH" in
    x86_64|amd64)
        HY2_ARCH="amd64"
        ;;
    aarch64|arm64)
        HY2_ARCH="arm64"
        ;;
    *)
        echo "错误：暂不支持 CPU 架构：$RAW_ARCH"
        exit 1
        ;;
esac

# 下载 Hysteria 官方发布的 Linux 二进制文件
DOWNLOAD_URL="https://download.hysteria.network/app/latest/hysteria-linux-${HY2_ARCH}"

TMP_FILE=$(mktemp)
trap 'rm -f "$TMP_FILE"' EXIT
trap 'exit 1' HUP INT TERM

echo ">>> 下载 Hysteria 2：$DOWNLOAD_URL"

if ! curl -fsSL --retry 2 \
    -o "$TMP_FILE" "$DOWNLOAD_URL"; then
    echo "错误：下载失败，请检查服务器网络或官方发布地址。"
    exit 1
fi

if ! chmod 755 "$TMP_FILE" ||
   ! "$TMP_FILE" version; then
    echo "错误：下载的 Hysteria 文件无法运行。"
    exit 1
fi

# 安装程序
install -d -m 755 /usr/local/bin /etc/hysteria
install -m 755 "$TMP_FILE" /usr/local/bin/hysteria

# 生成配置
echo ">>> 生成 HY2 配置..."

cat > /etc/hysteria/config.yaml <<EOF
listen: :${PORT}

acme:
  domains:
    - ${DOMAIN}
  email: ${EMAIL}

auth:
  type: password
  password: "${PASSWORD}"
EOF

chmod 600 /etc/hysteria/config.yaml

# 配置 systemd 服务
if [ "$SERVICE_MANAGER" = "systemd" ]; then
    echo ">>> 配置 systemd..."

    cat > /etc/systemd/system/hysteria-server.service <<'EOF'
[Unit]
Description=Hysteria 2 Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable hysteria-server
    systemctl restart hysteria-server

# 配置 Alpine OpenRC
else
    echo ">>> 配置 OpenRC..."

    cat > /etc/init.d/hysteria-server <<'EOF'
#!/sbin/openrc-run

name="Hysteria 2 Server"
description="Hysteria 2 Server"
command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/hysteria-server.log"
error_log="/var/log/hysteria-server.log"

depend() {
    need net
    after firewall
}
EOF

    chmod 755 /etc/init.d/hysteria-server
    rc-update add hysteria-server default
    rc-service hysteria-server restart
fi

# 获取公网 IP（仅用于提示）
SERVER_IP=$(curl -4 -fsS --connect-timeout 5 \
    https://api.ipify.org 2>/dev/null || true)

if [ -z "$SERVER_IP" ]; then
    SERVER_IP="请自行确认公网 IP"
fi

# 输出节点信息
echo ""
echo "=========================================="
echo "       Hysteria 2 安装完成"
echo "=========================================="
echo "域名：       $DOMAIN"
echo "公网 IP：    $SERVER_IP"
echo "UDP 端口：   $PORT"
echo "协议：       Hysteria 2"
echo "密码：       $PASSWORD"
echo "TLS：        ACME 自动申请"
echo "服务管理：   $SERVICE_MANAGER"
echo "------------------------------------------"
echo "HY2 节点链接："
echo "hysteria2://${PASSWORD}@${DOMAIN}:${PORT}/?sni=${DOMAIN}#HY2"
echo "=========================================="

echo "请确认以下端口已放行："
echo "TCP 80：用于 ACME HTTP 证书验证"
echo "UDP $PORT：用于 Hysteria 2 连接"

echo ""
echo ">>> 服务状态："

if [ "$SERVICE_MANAGER" = "systemd" ]; then
    systemctl --no-pager --full status hysteria-server || true
else
    rc-service hysteria-server status || true
fi
