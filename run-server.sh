#!/bin/zsh
cd "$(dirname "$0")" || exit 1
[ -f .env.local ] && source .env.local
PYTHON="${NETSYNC_PYTHON:-python3}"
exec "$PYTHON" mac_server.py "$@" 2>&1
