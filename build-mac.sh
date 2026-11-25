#!/bin/zsh
# 构建 NetSync.app（原生 AppKit，内嵌同步服务）
set -euo pipefail
cd "$(dirname "$0")"

APP="NetSync.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/out"

cp macapp/Info.plist "$APP/Contents/Info.plist"
cp macapp/icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp mac_server.py "$APP/Contents/Resources/mac_server.py"

# 有 Android 产物就一并塞进 App，手机扫码即可下载安装
if [ -f out/netsync.apk ]; then
  cp out/netsync.apk "$APP/Contents/Resources/out/netsync.apk"
fi

swiftc -O -o "$APP/Contents/MacOS/NetSync" \
  macapp/main.swift macapp/app.swift macapp/server.swift

codesign --force --sign - "$APP"
echo "已生成 $APP"
