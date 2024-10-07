#!/bin/bash

# 获取本机外网IP地址
IP=$(curl -s https://ipinfo.io/ip)

# 检查 curl 命令是否成功获取到IP
if [ -z "$IP" ]; then
    echo "无法获取外网IP地址，请检查网络连接或使用其他IP获取服务。"
    exit 1
fi

# 让用户输入端口、用户名和密码
read -p "请输入你想要使用的端口号: " PORT
read -p "请输入用户名: " USERNAME
read -sp "请输入密码: " PASSWORD
echo

# 确认用户输入的信息
echo "外网IP地址: $IP"
echo "端口号: $PORT"
echo "用户名: $USERNAME"
echo "密码: ********"

# 下载最新的 gost 二进制文件（如果未安装）
if ! command -v gost &> /dev/null
then
    echo "正在下载 gost..."
    wget https://github.com/ginuerzh/gost/releases/download/v2.11.1/gost-linux-amd64-2.11.1.gz
    gunzip gost-linux-amd64-2.11.1.gz
    chmod +x gost-linux-amd64-2.11.1
    mv gost-linux-amd64-2.11.1 /usr/local/bin/gost
    echo "gost 安装完成"
else
    echo "gost 已经安装"
fi

# 使用 nohup 启动 gost 作为 SOCKS5 代理
nohup gost -L "socks5://$USERNAME:$PASSWORD@$IP:$PORT" > gost.log 2>&1 &

# 提示用户代理已启动
if [ $? -eq 0 ]; then
    echo "SOCKS5 代理已成功启动"
    echo "外网IP: $IP"
    echo "端口: $PORT"
    echo "用户名: $USERNAME"
    echo "用户名: $PASSWORD"
    echo "日志文件: gost.log"
else
    echo "启动代理失败，请检查日志文件: gost.log"
fi
