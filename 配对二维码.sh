#!/bin/zsh
# 生成/显示配对二维码（服务需已启动）
cd "$(dirname "$0")" || exit 1
[ -f .env.local ] && source .env.local
PYTHON="${NETSYNC_PYTHON:-python3}"
"$PYTHON" - <<'PY'
import json, pathlib, subprocess

cfg = json.load(open(pathlib.Path.home() / "Library/Application Support/NetSync/config.json"))

out = subprocess.run(["ifconfig"], capture_output=True, text=True).stdout
host, cur = None, ""
for line in out.splitlines():
    if line and not line[0].isspace():
        cur = line.split(":")[0]
    if "inet " in line and cur.startswith("en"):
        v = line.split("inet ")[1].split()[0]
        if not v.startswith(("127.", "169.254.", "198.18.")):
            host = v
            break

payload = json.dumps({"v": 2, "app": "NetSync", "host": host,
                      "port": cfg["port"], "token": cfg["token"]}, ensure_ascii=False)
import qrcode
qr = qrcode.QRCode(border=1)
qr.add_data(payload)
qr.make(fit=True)
print()
print(f"手机访问地址: http://{host}:{cfg['port']}")
qr.print_ascii(invert=True)
img_path = pathlib.Path.home() / "Library/Application Support/NetSync/pairing.png"
qrcode.make(payload).save(img_path)
print(f"\n也可用手机扫这张图: {img_path}")
PY
