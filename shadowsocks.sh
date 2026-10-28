
#!/bin/sh
set -eu

# ==========================================
# Xray-core + Shadowsocks 2022 一键安装
# 支持 Alpine / Debian / Ubuntu
# 加密：2022-blake3-aes-128-gcm
# ==========================================

# 必须使用 root
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：必须使用 root 权限运行！"
    exit 1
fi

# 识别系统
if [ ! -r /etc/os-release ]; then
    echo "错误：无法识别操作系统。"
    exit 1
fi

. /etc/os-release

case "${ID:-}" in
    alpine)
        OS_TYPE="alpine"
        ;;
    debian|ubuntu)
        OS_TYPE="debian"
        ;;
    *)
        echo "错误：暂不支持系统 ${ID:-unknown}"
        echo "支持 Alpine、Debian、Ubuntu。"
        exit 1
        ;;
esac

echo ">>> 操作系统：${PRETTY_NAME:-$ID}"

# 端口输入
DEFAULT_PORT=443

while true; do
    printf "请输入 SS2022 端口 (默认: %s): " "$DEFAULT_PORT"
    read -r PORT </dev/tty
    PORT=${PORT:-$DEFAULT_PORT}

    case "$PORT" in
        ''|*[!0-9]*)
            echo "端口无效，请输入 1-65535 的数字。"
            ;;
        *)
            if [ "$PORT" -ge 1 ] 2>/dev/null &&
               [ "$PORT" -le 65535 ] 2>/dev/null; then
                break
            fi
            echo "端口必须在 1-65535 之间。"
            ;;
    esac
done

echo ">>> 使用端口：$PORT"

# 安装依赖
echo ">>> 正在安装系统依赖..."

if [ "$OS_TYPE" = "alpine" ]; then
    apk update
    apk add curl unzip openssl ca-certificates
else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y curl unzip openssl ca-certificates
fi

# CPU 架构
RAW_ARCH=$(uname -m)

case "$RAW_ARCH" in
    x86_64|amd64)
        XRAY_ARCH="64"
        ;;
    aarch64|arm64)
        XRAY_ARCH="arm64-v8a"
        ;;
    *)
        echo "错误：不支持的 CPU 架构：$RAW_ARCH"
        exit 1
        ;;
esac

echo ">>> 架构：$RAW_ARCH -> $XRAY_ARCH"

# 下载 Xray-core
DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XRAY_ARCH}.zip"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
trap 'exit 1' HUP INT TERM

echo ">>> 正在下载 Xray-core..."

if ! curl -fsSL --retry 2 \
    -o "$TMP_DIR/xray.zip" "$DOWNLOAD_URL"; then

    echo ">>> GitHub 下载失败，尝试镜像..."

    MIRROR_URL="https://ghproxy.net/${DOWNLOAD_URL}"

    curl -fsSL --retry 2 \
        -o "$TMP_DIR/xray.zip" "$MIRROR_URL"
fi

if ! unzip -tq "$TMP_DIR/xray.zip" >/dev/null 2>&1; then
    echo "错误：下载文件损坏或不是有效 ZIP 包。"
    exit 1
fi

mkdir -p /usr/local/bin /etc/xray

unzip -oq "$TMP_DIR/xray.zip" xray \
    -d /usr/local/bin/

chmod 755 /usr/local/bin/xray

# SS2022 加密方式
METHOD="2022-blake3-aes-128-gcm"

# 生成 16 字节随机预共享密钥，Base64 编码
PASSWORD=$(openssl rand -base64 16 | tr -d '\r\n')

if [ -z "$PASSWORD" ]; then
    echo "错误：SS2022 密钥生成失败。"
    exit 1
fi

echo ">>> SS2022 加密方式：$METHOD"
echo ">>> 正在生成 Xray 配置..."

# 生成服务端配置
cat > /etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "shadowsocks",
      "settings": {
        "method": "${METHOD}",
        "password": "${PASSWORD}",
        "network": "tcp,udp"
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

chmod 600 /etc/xray/config.json

# 检查配置是否合法
echo ">>> 正在检查 Xray 配置..."

if ! /usr/local/bin/xray run \
    -test -config /etc/xray/config.json; then
    echo "错误：Xray 配置检查失败。"
    exit 1
fi

# 配置服务
if [ "$OS_TYPE" = "alpine" ]; then

    echo ">>> 配置 OpenRC..."

    cat > /etc/init.d/xray <<'EOF'
#!/sbin/openrc-run

name="xray"
description="Xray SS2022 Service"
command="/usr/local/bin/xray"
command_args="run -config /etc/xray/config.json"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"

depend() {
    need net
    after firewall
}
EOF

    chmod 755 /etc/init.d/xray
    rc-update add xray default
    rc-service xray restart

else

    echo ">>> 配置 systemd..."

    cat > /etc/systemd/system/xray.service <<'EOF'
[Unit]
Description=Xray SS2022 Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray
    systemctl restart xray

fi

# 获取公网 IPv4
SERVER_IP=$(curl -4 -fsS --connect-timeout 5 \
    https://api.ipify.org 2>/dev/null || true)

if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(curl -4 -fsS --connect-timeout 5 \
        https://ifconfig.me/ip 2>/dev/null || true)
fi

if [ -z "$SERVER_IP" ]; then
    SERVER_IP="YOUR_SERVER_IP"
fi

# 生成 SS2022 SIP022 格式节点链接
# SS2022 URI 不应把 method:password 整体 Base64 编码。
# 对密钥中的特殊字符进行百分号编码。
ENCODED_PASSWORD=$(printf '%s' "$PASSWORD" |
    sed -e 's/+/%2B/g' \
        -e 's#/#%2F#g' \
        -e 's/=/%3D/g')

SS_LINK="ss://${METHOD}:${ENCODED_PASSWORD}@${SERVER_IP}:${PORT}#SS2022"

# 输出结果
echo ""
echo "=========================================="
echo "       Xray SS2022 安装完成"
echo "=========================================="
echo "系统：       $OS_TYPE"
echo "IP 地址：    $SERVER_IP"
echo "端口：       $PORT"
echo "协议：       Shadowsocks 2022"
echo "加密方式：   $METHOD"
echo "密钥：       $PASSWORD"
echo "TCP：        已配置"
echo "UDP：        已配置"
echo "------------------------------------------"
echo "节点导入链接："
echo "$SS_LINK"
echo "=========================================="

echo ">>> 服务状态："

if [ "$OS_TYPE" = "alpine" ]; then
    rc-service xray status || true
else
    systemctl --no-pager --full status xray || true
fi

echo ""
echo "请在云服务器安全组中放行 TCP 和 UDP 的 $PORT 端口。"
echo "请使用支持 SS2022 / SIP022 的客户端导入节点。"
