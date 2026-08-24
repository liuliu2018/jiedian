#!/bin/sh
set -e

# 确保以 root 用户运行
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：必须使用 root 权限运行此脚本！"
    exit 1
fi

# 提示用户输入端口
echo "=========================================="
echo "          Alpine Xray 极简安装            "
echo "=========================================="
while true; do
    printf "请输入想要监听的端口 [默认: 443]: "
    read -r PORT_INPUT </dev/tty || PORT_INPUT=""
    PORT=${PORT_INPUT:-443}

    # 验证输入是否为 1-65535 的合法数字
    if echo "${PORT}" | grep -Eq '^[0-9]+$' && [ "${PORT}" -ge 1 ] && [ "${PORT}" -le 65535 ]; then
        echo ">>> 已选择端口: ${PORT}"
        break
    else
        echo "错误：端口号必须是 1 到 65535 之间的数字，请重新输入！"
    fi
done

echo ">>> 正在更新 Alpine 系统依赖..."
apk update
apk add curl unzip openssl ca-certificates openrc bash

# 架构判断
ARCH=$(uname -m)
case "${ARCH}" in
    x86_64|amd64) XRAY_ARCH="64" ;;
    aarch64|arm64) XRAY_ARCH="arm64-v8a" ;;
    *) echo "不支持的架构: ${ARCH}"; exit 1 ;;
esac

echo ">>> 正在获取 Xray-core 最新版本..."
LATEST_TAG=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
if [ -z "${LATEST_TAG}" ]; then
    LATEST_TAG="v24.11.30"
fi

DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_TAG}/Xray-linux-${XRAY_ARCH}.zip"

# 创建临时目录下载
TMP_DIR=$(mktemp -d)
echo ">>> 正在下载 Xray-core (${LATEST_TAG})..."
curl -L -o "${TMP_DIR}/xray.zip" "${DOWNLOAD_URL}"

# 仅解压 xray 单二进制文件（节省磁盘空间）
echo ">>> 提取二进制文件..."
mkdir -p /usr/local/bin /etc/xray
unzip -o "${TMP_DIR}/xray.zip" xray -d /usr/local/bin/
chmod +x /usr/local/bin/xray
rm -rf "${TMP_DIR}"

# 生成 Reality 参数
UUID=$(/usr/local/bin/xray uuid)
KEYS=$(/usr/local/bin/xray x25519)
PRIVATE_KEY=$(echo "${KEYS}" | grep -i "Private key:" | awk '{print $3}' | tr -d '\r\n')
PUBLIC_KEY=$(echo "${KEYS}" | grep -i "Public key:" | awk '{print $3}' | tr -d '\r\n')
SHORT_ID=$(openssl rand -hex 8)
SNI="gateway.icloud.com"

# 获取公网 IP
SERVER_IP=$(curl -s4m 5 https://api.ipify.org || curl -s6m 5 https://api64.ipify.org || echo "YOUR_SERVER_IP")

echo ">>> 正在生成 Xray 配置文件..."
cat << EOF > /etc/xray/config.json
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

# 配置 Alpine OpenRC 守护服务
echo ">>> 配置 OpenRC 服务..."
cat << 'EOF' > /etc/init.d/xray
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

chmod +x /etc/init.d/xray

# 启动并设置开机自启
rc-update add xray default
rc-service xray restart

# 清理 apk 缓存以释放磁盘
rm -rf /var/cache/apk/*

# 生成节点导入链接
VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${SNI}&sid=${SHORT_ID}#AU-Reality-${PORT}"

echo ""
echo "=========================================="
echo "      Alpine Linux Xray 安装完成          "
echo "=========================================="
echo "IP 地址:      ${SERVER_IP}"
echo "监听端口:     ${PORT}"
echo "UUID:         ${UUID}"
echo "Flow:         xtls-rprx-vision"
echo "SNI:          ${SNI}"
echo "PublicKey:    ${PUBLIC_KEY}"
echo "ShortID:      ${SHORT_ID}"
echo "------------------------------------------"
echo "节点导入链接："
echo "${VLESS_LINK}"
echo "=========================================="
