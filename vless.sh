
#!/bin/sh
set -eu

# ==========================================
# Xray-core + VLESS + Reality 一键安装
# 支持常见 Linux 发行版
# 架构：x86_64 / aarch64
# 服务：systemd / OpenRC
# ==========================================

# 必须使用 root
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：必须使用 root 权限运行此脚本！"
    exit 1
fi

# 检测系统信息
if [ -r /etc/os-release ]; then
    . /etc/os-release
else
    ID=unknown
    PRETTY_NAME=$(uname -s)
fi

echo ">>> 操作系统：${PRETTY_NAME:-${ID:-unknown}}"

# 识别包管理器
if command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
elif command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
elif command -v pacman >/dev/null 2>&1; then
    PKG_MANAGER="pacman"
elif command -v zypper >/dev/null 2>&1; then
    PKG_MANAGER="zypper"
else
    echo "错误：未找到支持的包管理器。"
    echo "支持 apk、apt、dnf、yum、pacman、zypper。"
    exit 1
fi

echo ">>> 包管理器：$PKG_MANAGER"

# 检测服务管理器
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    SERVICE_MANAGER="systemd"
elif command -v rc-update >/dev/null 2>&1 &&
     command -v rc-service >/dev/null 2>&1; then
    SERVICE_MANAGER="openrc"
else
    echo "错误：未检测到正在运行的 systemd 或 OpenRC。"
    echo "请使用带有完整服务管理功能的 Linux 系统。"
    exit 1
fi

echo ">>> 服务管理器：$SERVICE_MANAGER"

# 端口输入与校验
DEFAULT_PORT=443

while true; do
    printf "请输入连接端口 (默认: %s): " "$DEFAULT_PORT"
    read -r PORT </dev/tty
    PORT=${PORT:-$DEFAULT_PORT}

    case "$PORT" in
        ''|*[!0-9]*)
            echo "输入无效：请输入 1-65535 之间的纯数字。"
            ;;
        *)
            if [ "$PORT" -ge 1 ] 2>/dev/null &&
               [ "$PORT" -le 65535 ] 2>/dev/null; then
                break
            fi
            echo "端口超出范围，请重新输入。"
            ;;
    esac
done

echo ">>> 使用端口：$PORT"

# 安装系统依赖
echo ">>> 正在安装系统依赖..."

case "$PKG_MANAGER" in
    apk)
        apk update
        apk add curl unzip openssl ca-certificates
        ;;
    apt)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y curl unzip openssl ca-certificates
        ;;
    dnf)
        dnf install -y curl unzip openssl ca-certificates
        ;;
    yum)
        yum install -y curl unzip openssl ca-certificates
        ;;
    pacman)
        pacman -Sy --noconfirm --needed curl unzip openssl ca-certificates
        ;;
    zypper)
        zypper --non-interactive refresh
        zypper --non-interactive install curl unzip openssl ca-certificates
        ;;
esac

# 检测 CPU 架构
RAW_ARCH=$(uname -m)

case "$RAW_ARCH" in
    x86_64|amd64)
        XRAY_ARCH="64"
        ;;
    aarch64|arm64)
        XRAY_ARCH="arm64-v8a"
        ;;
    *)
        echo "错误：暂不支持 CPU 架构：$RAW_ARCH"
        exit 1
        ;;
esac

echo ">>> CPU 架构：$RAW_ARCH -> $XRAY_ARCH"

# 下载 Xray-core
DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XRAY_ARCH}.zip"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
trap 'exit 1' HUP INT TERM

echo ">>> 下载地址：$DOWNLOAD_URL"
echo ">>> 正在下载 Xray-core..."

if ! curl -fsSL --retry 2 \
    -o "$TMP_DIR/xray.zip" "$DOWNLOAD_URL"; then

    echo "警告：GitHub 下载失败，尝试镜像..."

    MIRROR_URL="https://ghproxy.net/${DOWNLOAD_URL}"

    curl -fsSL --retry 2 \
        -o "$TMP_DIR/xray.zip" "$MIRROR_URL"
fi

# 校验压缩包
if ! unzip -tq "$TMP_DIR/xray.zip" >/dev/null 2>&1; then
    echo "错误：下载文件损坏或不是合法 ZIP 包。"
    exit 1
fi

echo ">>> 正在安装 Xray-core..."

mkdir -p /usr/local/bin /etc/xray

unzip -oq "$TMP_DIR/xray.zip" xray -d /usr/local/bin/
chmod 755 /usr/local/bin/xray

# 检查二进制是否可运行
if ! /usr/local/bin/xray version; then
    echo "错误：Xray 无法运行，请检查系统架构和运行库。"
    exit 1
fi

# 生成 Reality 参数
echo ">>> 正在生成 Reality 密钥..."

UUID=$(/usr/local/bin/xray uuid)
KEYS=$(/usr/local/bin/xray x25519)

# 兼容新旧 Xray 密钥输出格式
PRIVATE_KEY=$(
    printf '%s\n' "$KEYS" |
    grep -Ei '^[[:space:]]*(PrivateKey|Private key|Private)[[:space:]]*:' |
    head -n 1 |
    sed 's/^[^:]*:[[:space:]]*//' |
    tr -d '\r\n '
)

PUBLIC_KEY=$(
    printf '%s\n' "$KEYS" |
    grep -Ei '^[[:space:]]*(Password|PublicKey|Public key|Public)[[:space:]]*:' |
    head -n 1 |
    sed 's/^[^:]*:[[:space:]]*//' |
    tr -d '\r\n '
)

SHORT_ID=$(openssl rand -hex 8)
SNI="gateway.icloud.com"

if [ -z "$UUID" ] || [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    echo "错误：Xray Reality 密钥生成或解析失败。"
    echo "密钥命令输出如下："
    printf '%s\n' "$KEYS"
    exit 1
fi

# 获取公网 IP
echo ">>> 正在获取公网 IP..."

SERVER_IP=$(curl -4 -fsS --connect-timeout 5 \
    https://api.ipify.org 2>/dev/null || true)

if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(curl -6 -fsS --connect-timeout 5 \
        https://api64.ipify.org 2>/dev/null || true)
fi

if [ -z "$SERVER_IP" ]; then
    SERVER_IP="YOUR_SERVER_IP"
    echo "警告：无法自动获取公网 IP，请稍后手动替换。"
fi

# 生成配置
echo ">>> 正在生成 Xray 配置文件..."

cat > /etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${SNI}:443",
          "xver": 0,
          "serverNames": [
            "${SNI}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
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

# 启动前检查配置
echo ">>> 正在验证 Xray 配置..."

if ! /usr/local/bin/xray run \
    -test -config /etc/xray/config.json; then
    echo "错误：Xray 配置验证失败。"
    exit 1
fi

# 配置 systemd
if [ "$SERVICE_MANAGER" = "systemd" ]; then

    echo ">>> 配置 systemd 服务..."

    cat > /etc/systemd/system/xray.service <<'EOF'
[Unit]
Description=Xray Service
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

# 配置 OpenRC
else

    echo ">>> 配置 OpenRC 服务..."

    cat > /etc/init.d/xray <<'EOF'
#!/sbin/openrc-run

name="xray"
description="Xray Service"
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

fi

# 生成 VLESS Reality 导入链接
VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${SNI}&sid=${SHORT_ID}#AU-Reality"

echo ""
echo "=========================================="
echo "       Xray Reality 安装完成"
echo "=========================================="
echo "系统：        ${PRETTY_NAME:-${ID:-unknown}}"
echo "包管理器：    ${PKG_MANAGER}"
echo "服务管理器：  ${SERVICE_MANAGER}"
echo "CPU 架构：    ${RAW_ARCH}"
echo "IP 地址：     ${SERVER_IP}"
echo "端口：        ${PORT}"
echo "UUID：        ${UUID}"
echo "Flow：        xtls-rprx-vision"
echo "SNI：         ${SNI}"
echo "PublicKey：   ${PUBLIC_KEY}"
echo "ShortID：     ${SHORT_ID}"
echo "------------------------------------------"
echo "节点导入链接："
echo "${VLESS_LINK}"
echo "=========================================="

echo ">>> 服务状态："

if [ "$SERVICE_MANAGER" = "systemd" ]; then
    systemctl --no-pager --full status xray || true
else
    rc-service xray status || true
fi

echo ""
echo "请在云服务器安全组和系统防火墙中放行 TCP ${PORT}。"
