#!/bin/zsh
pkill -f "mac_server.py" 2>/dev/null && echo "已停止" || echo "未在运行"
