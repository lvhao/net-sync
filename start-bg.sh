#!/bin/zsh
# 后台启动同步服务；重复执行不会起第二个
cd "$(dirname "$0")" || exit 1
[ -f .env.local ] && source .env.local
PYTHON="${NETSYNC_PYTHON:-python3}"
if lsof -nP -iTCP:8765 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "已在运行"
  exit 0
fi
nohup "$PYTHON" mac_server.py --daemon >/dev/null 2>&1 &
sleep 2
lsof -nP -iTCP:8765 -sTCP:LISTEN >/dev/null 2>&1 && echo "已启动" || echo "启动失败，看 ~/Library/Application Support/NetSync/server.log"
