#!/bin/sh
set -e

# 确保以 root 用户运行
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：必须使用 root 权限运行此脚本！"
    exit 1
fi

# 端口交互输入与校验
DEFAULT_PORT=443
while true; do
    printf "请输入连接端口 (默认: %s): " "${DEFAULT_PORT}"
    read -r PORT </dev/tty
    PORT=${PORT:-$DEFAULT_PORT}
    
    case "${PORT}" in
        ''|*[!0-9]*)
            echo "输入无效，端口必须为 1-65535 之间的纯数字，请重新输入！"
            ;;
        *)
            if [ "${PORT}" -ge 1 ] && [ "${PORT}" -le 65535 ]; then
                break
            else
                echo "端口超出范围 (1-65535)，请重新输入！"
            fi
            ;;
    esac
done

echo ">>> 使用端口: ${PORT}"

echo ">>> 正在更新 Alpine 系统依赖..."
apk update
apk add curl unzip openssl ca-certificates openrc bash

# 架构判断与参数显示
RAW_ARCH=$(uname -m)
case "${RAW_ARCH}" in
    x86_64|amd64) XRAY_ARCH="64" ;;
    aarch64|arm64) XRAY_ARCH="arm64-v8a" ;;
    *) echo "不支持的 CPU 架构: ${RAW_ARCH}"; exit 1 ;;
esac

echo ">>> 系统架构: ${RAW_ARCH} -> XRAY_ARCH 匹配参数: [ ${XRAY_ARCH} ]"

# 使用 GitHub 最新版 Release 的固定重定向下载链接
DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XRAY_ARCH}.zip"
echo ">>> 最新版下载地址: ${DOWNLOAD_URL}"

TMP_DIR=$(mktemp -d)
echo ">>> 正在下载 Xray-core 最新版..."

# -L 自动跟随 GitHub 的重定向，-f 在 404/500 时直接报错不产生垃圾文件
if ! curl -fsSL -o "${TMP_DIR}/xray.zip" "${DOWNLOAD_URL}"; then
    echo "警告：GitHub 直连下载失败，尝试使用加速镜像下载..."
    MIRROR_URL="https://ghproxy.net/${DOWNLOAD_URL}"
    curl -fsSL -o "${TMP_DIR}/xray.zip" "${MIRROR_URL}"
fi

# 校验 zip 包合法性
if ! unzip -tq "${TMP_DIR}/xray.zip" >/dev/null 2>&1; then
    echo "错误：下载的文件损坏或不是合法的 zip 压缩包！"
    rm -rf "${TMP_DIR}"
    exit 1
fi

echo ">>> 提取二进制文件..."
mkdir -p /usr/local/bin /etc/xray
unzip -o "${TMP_DIR}/xray.zip" xray -d /usr/local/bin/
chmod +x /usr/local/bin/xray
rm -rf "${TMP_DIR}"

# 生成 Reality 参数（兼容新旧 Xray x25519 密钥名称格式）
UUID=$(/usr/local/bin/xray uuid)
KEYS=$(/usr/local/bin/xray x25519)
PRIVATE_KEY=$(echo "${KEYS}" | grep -Ei "Private" | head -n 1 | sed -E 's/.*:[[:space:]]*//' | tr -d '\r\n ')
PUBLIC_KEY=$(echo "${KEYS}" | grep -Ei "Public|Password" | head -n 1 | sed -E 's/.*:[[:space:]]*//' | tr -d '\r\n ')
SHORT_ID=$(openssl rand -hex 8)
SNI="gateway.icloud.com"

if [ -z "${PRIVATE_KEY}" ] || [ -z "${PUBLIC_KEY}" ]; then
    echo "错误：未能成功生成并识别 Xray 密钥！"
    exit 1
fi

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

# 启动并加入开机自启
rc-update add xray default 2>/dev/null || true
rc-service xray restart

# 清理 apk 缓存
rm -rf /var/cache/apk/*

# 生成节点导入链接
VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${SNI}&sid=${SHORT_ID}#AU-Reality"

echo ""
echo "=========================================="
echo "      Alpine Linux Xray 安装完成          "
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
