#!/bin/zsh
cd "$(dirname "$0")" || exit 1
[ -f .env.local ] && source .env.local
PYTHON="${NETSYNC_PYTHON:-python3}"
clear
echo "======================================"
echo "  内网同步 · Mac 端"
echo "======================================"
echo
echo "手机和这台 Mac 要连同一个 Wi-Fi。"
echo "把下面出现的二维码用手机 App 扫一下。"
echo
"$PYTHON" mac_server.py
