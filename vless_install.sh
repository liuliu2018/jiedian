#!/usr/bin/env bash
set -e

# 确保以 root 用户运行
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：必须使用 root 权限运行此脚本！"
    exit 1
fi

echo ">>> 正在更新系统依赖..."
if command -v apt >/dev/null 2>&1; then
    apt update -y && apt install -y curl unzip openssl
elif command -v apk >/dev/null 2>&1; then
    apk update && apk add curl unzip openssl
elif command -v yum >/dev/null 2>&1; then
    yum install -y curl unzip openssl
fi

# 获取系统架构
ARCH=$(uname -m)
case "${ARCH}" in
    x86_64|amd64) XRAY_ARCH="64" ;;
    aarch64|arm64) XRAY_ARCH="arm64-v8a" ;;
    *) echo "不支持的架构: ${ARCH}"; exit 1 ;;
esac

echo ">>> 正在获取 Xray-core 最新版本..."
LATEST_TAG=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
if [ -z "${LATEST_TAG}" ]; then
    LATEST_TAG="v24.11.30" # 兜底版本
fi

DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_TAG}/Xray-linux-${XRAY_ARCH}.zip"

# 创建临时目录
TMP_DIR=$(mktemp -d)
echo ">>> 正在下载 Xray-core (${LATEST_TAG})..."
curl -L -o "${TMP_DIR}/xray.zip" "${DOWNLOAD_URL}"

# 解压并仅保留 xray 单文件（不保留 geoip/geosite 节省 800M 盘）
echo ">>> 提取单二进制文件..."
mkdir -p /usr/local/bin /etc/xray
unzip -o "${TMP_DIR}/xray.zip" xray -d /usr/local/bin/
chmod +x /usr/local/bin/xray
rm -rf "${TMP_DIR}"

# 生成配置参数
UUID=$(/usr/local/bin/xray uuid)
KEYS=$(/usr/local/bin/xray x25519)
PRIVATE_KEY=$(echo "${KEYS}" | grep -i "Private key:" | awk '{print $3}' | tr -d '\r\n')
PUBLIC_KEY=$(echo "${KEYS}" | grep -i "Public key:" | awk '{print $3}' | tr -d '\r\n')
SHORT_ID=$(openssl rand -hex 8)
SNI="gateway.icloud.com"
PORT=443

# 获取公网 IP
SERVER_IP=$(curl -s4m 5 https://api.ipify.org || curl -s6m 5 https://api64.ipify.org || echo "YOUR_SERVER_IP")

echo ">>> 正在生成精简版 Xray 配置文件..."
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

# 配置 Systemd 守护进程
echo ">>> 正在配置 Systemd 服务..."
cat << EOF > /etc/systemd/system/xray.service
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

# 启动并清理包管理缓存
systemctl daemon-reload
systemctl enable --now xray

if command -v apt >/dev/null 2>&1; then
    apt clean && rm -rf /var/lib/apt/lists/*
elif command -v apk >/dev/null 2>&1; then
    rm -rf /var/cache/apk/*
fi

# 拼接 VLESS 链接
VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${SNI}&sid=${SHORT_ID}#AU-Reality"

echo ""
echo "=========================================="
echo "          Xray-Reality 极简安装完成         "
echo "=========================================="
echo "IP 地址:      ${SERVER_IP}"
echo "端口:         ${PORT}"
echo "UUID:         ${UUID}"
echo "Flow:         xtls-rprx-vision"
echo "SNI:          ${SNI}"
echo "PublicKey:    ${PUBLIC_KEY}"
echo "ShortID:      ${SHORT_ID}"
echo "------------------------------------------"
echo "节点导入链接："
echo "${VLESS_LINK}"
echo "=========================================="
