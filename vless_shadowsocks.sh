cat > install_xray_both.sh <<'EOF'
#!/bin/sh
set -eu

# =========================
# VLESS Reality + SS2022
# 支持 Alpine / Debian / Ubuntu / Rocky 等
# =========================

XRAY_DIR="/etc/xray"
CONFIG="$XRAY_DIR/config.json"
XRAY_BIN="/usr/local/bin/xray"
SS_TAG="ss2022-in"
VLESS_TAG="vless-reality-in"

# 必须 root
if [ "$(id -u)" != "0" ]; then
    echo "请使用 root 用户执行"
    exit 1
fi

echo "======================================"
echo "     Xray VLESS Reality + SS2022"
echo "======================================"

# ---------- 安装依赖 ----------
install_deps() {
    echo ">>> 检测系统并安装依赖..."

    if command -v apk >/dev/null 2>&1; then
        apk update
        apk add curl unzip openssl ca-certificates jq
    elif command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y curl unzip openssl ca-certificates jq
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl unzip openssl ca-certificates jq
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl unzip openssl ca-certificates jq
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm curl unzip openssl ca-certificates jq
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install curl unzip openssl ca-certificates jq
    else
        echo "不支持的包管理器，请手动安装 curl unzip openssl jq"
        exit 1
    fi
}

install_deps

# ---------- 检测架构 ----------
ARCH="$(uname -m)"

case "$ARCH" in
    x86_64|amd64)
        XRAY_ARCH="64"
        ;;
    aarch64|arm64)
        XRAY_ARCH="arm64-v8a"
        ;;
    *)
        echo "暂不支持此架构：$ARCH"
        exit 1
        ;;
esac

# ---------- 安装 Xray ----------
if [ ! -x "$XRAY_BIN" ]; then
    echo ">>> 未检测到 Xray，开始安装..."

    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$TMP_DIR"' EXIT

    DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XRAY_ARCH}.zip"

    if ! curl -fL --retry 2 "$DOWNLOAD_URL" -o "$TMP_DIR/xray.zip"; then
        echo "GitHub 下载失败，尝试镜像..."
        curl -fL --retry 2 \
            "https://ghproxy.net/${DOWNLOAD_URL}" \
            -o "$TMP_DIR/xray.zip"
    fi

    unzip -o "$TMP_DIR/xray.zip" -d "$TMP_DIR"
    install -m 755 "$TMP_DIR/xray" "$XRAY_BIN"
else
    echo ">>> 检测到已有 Xray，保留现有版本："
    "$XRAY_BIN" version | head -n 1 || true
fi

# ---------- 输入端口 ----------
printf "请输入 VLESS Reality 端口（默认 443）："
read VLESS_PORT
VLESS_PORT="${VLESS_PORT:-443}"

printf "请输入 SS2022 端口（默认 8443）："
read SS_PORT
SS_PORT="${SS_PORT:-8443}"

check_port() {
    case "$1" in
        ''|*[!0-9]*)
            echo "端口必须是数字"
            exit 1
            ;;
    esac

    if [ "$1" -lt 1 ] || [ "$1" -gt 65535 ]; then
        echo "端口范围必须是 1-65535"
        exit 1
    fi
}

check_port "$VLESS_PORT"
check_port "$SS_PORT"

if [ "$VLESS_PORT" = "$SS_PORT" ]; then
    echo "VLESS 和 SS2022 不能使用相同端口"
    exit 1
fi

# ---------- 准备配置目录 ----------
mkdir -p "$XRAY_DIR"

if [ -f "$CONFIG" ]; then
    echo ">>> 检测到已有配置，先备份..."
    BACKUP="${CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "$CONFIG" "$BACKUP"
    echo "备份位置：$BACKUP"

    if ! jq empty "$CONFIG" >/dev/null 2>&1; then
        echo "现有 config.json 不是合法 JSON，停止操作，未覆盖配置。"
        exit 1
    fi
else
    echo ">>> 未检测到旧配置，准备创建新配置..."
    printf '%s\n' '{"inbounds":[],"outbounds":[{"protocol":"freedom","tag":"direct"}]}' > "$CONFIG"
fi

# ---------- 检查现有协议 ----------
HAS_VLESS="$(jq '[.inbounds[]? | select(.protocol == "vless")] | length' "$CONFIG")"

if [ "$HAS_VLESS" -gt 0 ]; then
    echo ">>> 检测到现有 VLESS 入站，将保留原配置，不修改其密钥和端口。"
    CREATE_VLESS=0
else
    echo ">>> 未检测到 VLESS，将创建新的 Reality 入站。"
    CREATE_VLESS=1
fi

# 检查端口冲突
if [ "$CREATE_VLESS" -eq 1 ]; then
    if jq -e --argjson p "$VLESS_PORT" \
        '[.inbounds[]? | select(.port == $p)] | length > 0' \
        "$CONFIG" >/dev/null; then
        echo "VLESS 端口 $VLESS_PORT 已被现有入站占用，请更换端口。"
        exit 1
    fi
fi

if jq -e --argjson p "$SS_PORT" \
    '[.inbounds[]? | select(.port == $p and .protocol != "shadowsocks")] | length > 0' \
    "$CONFIG" >/dev/null; then
    echo "SS2022 端口 $SS_PORT 已被其他入站占用，请更换端口。"
    exit 1
fi

# ---------- 生成 SS2022 密码 ----------
echo ">>> 生成 SS2022 密码..."
SS_PASSWORD="$(openssl rand -base64 16)"
SS_METHOD="2022-blake3-aes-128-gcm"

# ---------- 生成 VLESS Reality 参数 ----------
if [ "$CREATE_VLESS" -eq 1 ]; then
    echo ">>> 生成 VLESS Reality 参数..."

    UUID="$("$XRAY_BIN" uuid)"
    X25519_OUTPUT="$("$XRAY_BIN" x25519 2>&1)"

    PRIVATE_KEY="$(printf '%s\n' "$X25519_OUTPUT" |
        sed -n -E 's/^[[:space:]]*Private(Key)?[[:space:]]*:[[:space:]]*//Ip' |
        head -n 1)"

    PUBLIC_KEY="$(printf '%s\n' "$X25519_OUTPUT" |
        sed -n -E 's/^[[:space:]]*(Public(Key)?|Password)[[:space:]]*:[[:space:]]*//Ip' |
        head -n 1)"

    if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
        echo "无法解析 xray x25519 输出："
        echo "$X25519_OUTPUT"
        echo "请检查 Xray 版本和密钥输出格式。"
        exit 1
    fi

    SHORT_ID="$(openssl rand -hex 8)"
    SNI="gateway.icloud.com"
fi

# ---------- 生成临时配置 ----------
TMP_CONFIG="${CONFIG}.tmp"

if [ "$CREATE_VLESS" -eq 1 ]; then
    jq \
        --arg uuid "$UUID" \
        --arg private "$PRIVATE_KEY" \
        --arg shortid "$SHORT_ID" \
        --arg sni "$SNI" \
        --argjson port "$VLESS_PORT" \
        --arg ss_password "$SS_PASSWORD" \
        --arg ss_method "$SS_METHOD" \
        --argjson ss_port "$SS_PORT" \
        --arg ss_tag "$SS_TAG" \
        --arg vless_tag "$VLESS_TAG" '
        .inbounds = ((.inbounds // []) |
            map(select(.protocol != "shadowsocks"))) |
        .inbounds += [
            {
                "tag": $vless_tag,
                "listen": "0.0.0.0",
                "port": $port,
                "protocol": "vless",
                "settings": {
                    "clients": [
                        {
                            "id": $uuid,
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
                        "dest": ($sni + ":443"),
                        "xver": 0,
                        "serverNames": [$sni],
                        "privateKey": $private,
                        "shortIds": [$shortid]
                    }
                }
            },
            {
                "tag": $ss_tag,
                "listen": "0.0.0.0",
                "port": $ss_port,
                "protocol": "shadowsocks",
                "settings": {
                    "method": $ss_method,
                    "password": $ss_password,
                    "network": "tcp,udp"
                }
            }
        ] |
        .outbounds = (
            if ((.outbounds // []) | length) == 0
            then [{"protocol":"freedom","tag":"direct"}]
            else .outbounds
            end
        )
    ' "$CONFIG" > "$TMP_CONFIG"
else
    jq \
        --arg ss_password "$SS_PASSWORD" \
        --arg ss_method "$SS_METHOD" \
        --argjson ss_port "$SS_PORT" \
        --arg ss_tag "$SS_TAG" '
        .inbounds = ((.inbounds // []) |
            map(select(.protocol != "shadowsocks"))) |
        .inbounds += [
            {
                "tag": $ss_tag,
                "listen": "0.0.0.0",
                "port": $ss_port,
                "protocol": "shadowsocks",
                "settings": {
                    "method": $ss_method,
                    "password": $ss_password,
                    "network": "tcp,udp"
                }
            }
        ] |
        .outbounds = (
            if ((.outbounds // []) | length) == 0
            then [{"protocol":"freedom","tag":"direct"}]
            else .outbounds
            end
        )
    ' "$CONFIG" > "$TMP_CONFIG"
fi

# ---------- 验证配置 ----------
echo ">>> 验证 Xray 配置..."

if ! "$XRAY_BIN" run -test -config "$TMP_CONFIG"; then
    echo "配置验证失败，保留原配置，不进行替换。"
    rm -f "$TMP_CONFIG"
    exit 1
fi

# 原子替换
chmod 600 "$TMP_CONFIG"
mv "$TMP_CONFIG" "$CONFIG"

# ---------- 创建服务 ----------
create_systemd_service() {
    cat > /etc/systemd/system/xray.service <<'SERVICE'
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
User=root
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SERVICE
    systemctl daemon-reload
    systemctl enable xray
    systemctl restart xray
}

create_openrc_service() {
    cat > /etc/init.d/xray <<'SERVICE'
#!/sbin/openrc-run

name="xray"
description="Xray Service"
command="/usr/local/bin/xray"
command_args="run -config /etc/xray/config.json"
command_background=true
pidfile="/run/xray.pid"
output_log="/var/log/xray.log"
error_log="/var/log/xray-error.log"

depend() {
    need net
    after firewall
}
SERVICE
    chmod +x /etc/init.d/xray
    rc-update add xray default
    rc-service xray restart
}

echo ">>> 启动 Xray 服务..."

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    if [ ! -f /etc/systemd/system/xray.service ] &&
       [ ! -f /lib/systemd/system/xray.service ]; then
        create_systemd_service
    else
        systemctl restart xray
        systemctl enable xray >/dev/null 2>&1 || true
    fi
elif command -v rc-service >/dev/null 2>&1; then
    if [ ! -f /etc/init.d/xray ]; then
        create_openrc_service
    else
        rc-update add xray default >/dev/null 2>&1 || true
        rc-service xray restart
    fi
else
    echo "没有检测到 systemd 或 OpenRC。"
    echo "配置已经写入：$CONFIG"
    echo "请在当前系统中手动启动 Xray。"
    exit 1
fi

sleep 2

# ---------- 获取服务器 IP ----------
SERVER_IP="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"

echo
echo "======================================"
echo "          安装完成"
echo "======================================"

if [ "$CREATE_VLESS" -eq 1 ]; then
    echo
    echo "[ VLESS Reality ]"
    echo "地址：${SERVER_IP:-请填写服务器IP}"
    echo "端口：$VLESS_PORT"
    echo "协议：VLESS"
    echo "传输：TCP"
    echo "安全：Reality"
    echo "UUID：$UUID"
    echo "Public Key：$PUBLIC_KEY"
    echo "Short ID：$SHORT_ID"
    echo "SNI：$SNI"
    echo "Flow：xtls-rprx-vision"
    echo
    echo "VLESS 链接："
    echo "vless://${UUID}@${SERVER_IP:-服务器IP}:${VLESS_PORT}?security=reality&encryption=none&pb=${PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${SNI}&sid=${SHORT_ID}#VLESS-Reality"
else
    echo
    echo "[ VLESS Reality ]"
    echo "检测到原有 VLESS 配置，已保留，没有修改原有参数。"
    echo "请继续使用原来的 VLESS 节点链接。"
fi

echo
echo "[ SS2022 ]"
echo "地址：${SERVER_IP:-请填写服务器IP}"
echo "端口：$SS_PORT"
echo "协议：Shadowsocks 2022"
echo "加密方式：$SS_METHOD"
echo "密码：$SS_PASSWORD"
echo "传输：TCP + UDP"

echo
echo "配置文件：$CONFIG"
echo "服务名称：xray"
echo
echo "请记得在 VPS 防火墙和云厂商安全组中放行："
echo "TCP $VLESS_PORT"
echo "TCP $SS_PORT"
echo "UDP $SS_PORT"
echo "======================================"
EOF

chmod +x install_xray_both.sh
./install_xray_both.sh
