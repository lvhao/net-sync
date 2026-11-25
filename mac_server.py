#!/usr/bin/env python3
"""NetSync —— 局域网内 Mac 与 Android 的极简双向同步服务。

既可单独运行，也被 Mac 图形界面内嵌使用。
数据只在两台设备之间直连，不经任何云服务。
"""

from __future__ import annotations

import fnmatch
import hashlib
import http.server
import json
import os
import re
import secrets
import socket
import socketserver
import subprocess
import sys
import urllib.parse
from pathlib import Path

BASE = Path.home() / "Library/Application Support/NetSync"
STATE_DIR = BASE
CONFIG_FILE = STATE_DIR / "config.json"
HASH_FILE = STATE_DIR / "hashes.json"
APP_VERSION = "2.0"

DEFAULT_IGNORE = [
    ".git", ".git/**", ".smart-env", ".smart-env/**", ".netsync", ".netsync/**",
    ".DS_Store", "**/.DS_Store", "._*", "**/._*", ".AppleDouble", "**/.AppleDouble",
    ".LSOverride", "*.swp", "*.swo", "*~", ".sync-conflict-*", "**/.sync-conflict-*",
    "*.conflict-*", "**/*.conflict-*", "*.part", "**/*.part", "*.netsync-tmp",
    ".netsync-state", "**/.netsync-state", ".netsync-sent", "**/.netsync-sent",
    "__pycache__", "**/__pycache__", "node_modules", "**/node_modules",
    ".venv", "**/.venv",
    ".obsidian/workspace.json", ".obsidian/workspace-mobile.json", ".obsidian/cache/**",
    "*.db", "*.db-wal", "*.db-shm", "*.sqlite", "*.sqlite-wal", "*.sqlite-shm",
]

# 默认不参与同步的目录（可在某个文件夹里的 .netsyncignore 覆盖/增补）
SKIP_DIRS = {
    ".git", ".smart-env", ".netsync", ".obsidian/plugins", "node_modules",
    "__pycache__", ".venv", "copilot", "videos",
}


# ---------------------------------------------------------------- 配置

def _now() -> str:
    from datetime import datetime
    return datetime.now().isoformat(timespec="seconds")


def default_folder() -> dict:
    # 首次启动的默认目录：NETSYNC_FOLDER，否则当前目录
    folder = Path(os.environ.get("NETSYNC_FOLDER", Path.cwd())).expanduser().resolve()
    return {"id": "default", "name": folder.name or "folder", "path": str(folder), "enabled": True}


def load_config() -> dict:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    if CONFIG_FILE.exists():
        try:
            cfg = json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            cfg = {}
    else:
        cfg = {}
    changed = False
    if not cfg.get("token"):
        cfg["token"] = secrets.token_urlsafe(24)
        changed = True
    if not cfg.get("port"):
        cfg["port"] = 8765
        changed = True
    if "folders" not in cfg:
        cfg["folders"] = [default_folder()]
        changed = True
    if "peers" not in cfg:
        cfg["peers"] = {}
        changed = True
    for f in cfg["folders"]:
        f.setdefault("enabled", True)
    if changed:
        save_config(cfg)
    return cfg


def save_config(cfg: dict) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    CONFIG_FILE.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")


def lan_ip() -> str:
    """取 en* 物理网卡的 IPv4，避开 Clash/VPN 等虚拟接口。"""
    try:
        out = subprocess.run(["ifconfig"], capture_output=True, text=True, timeout=5).stdout
        current, found = "", []
        for line in out.splitlines():
            if line and not line[0].isspace():
                current = line.split(":")[0]
            m = re.search(r"inet (\d+\.\d+\.\d+\.\d+)", line)
            if m and current.startswith("en"):
                ip = m.group(1)
                if not ip.startswith(("127.", "169.254.", "198.18.", "198.19.")):
                    found.append(ip)
        if found:
            return found[0]
    except Exception:
        pass
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("223.5.5.5", 80))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


# ---------------------------------------------------------------- 忽略规则

def folder_by_id(cfg: dict, fid: str) -> dict | None:
    for f in cfg["folders"]:
        if f["id"] == fid:
            return f
    return None


def patterns_for(folder: dict) -> list[str]:
    root = Path(folder["path"])
    lines = list(DEFAULT_IGNORE)
    local = root / ".netsyncignore"
    if local.is_file():
        try:
            for raw in local.read_text(encoding="utf-8").splitlines():
                raw = raw.strip()
                if raw and not raw.startswith(("#", "//")):
                    lines.append(raw.rstrip("/"))
        except OSError:
            pass
    return lines


def ignored(rel: str, patterns: list[str]) -> bool:
    """规则相对文件夹根：含 / 的匹配整条路径，纯名字匹配任意一层。"""
    rel = rel.strip("/")
    parts = rel.split("/")
    for pat in patterns:
        pat = pat.strip("/")
        if "/" in pat:
            if fnmatch.fnmatchcase(rel, pat) or fnmatch.fnmatchcase(rel, pat + "/**"):
                return True
        elif any(fnmatch.fnmatchcase(part, pat) for part in parts):
            return True
    return False


# ---------------------------------------------------------------- 文件与清单

_HASHES: dict | None = None


def load_hashes() -> dict:
    global _HASHES
    if _HASHES is None:
        try:
            _HASHES = json.loads(HASH_FILE.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            _HASHES = {}
    return _HASHES


def save_hashes() -> None:
    if _HASHES is not None:
        try:
            HASH_FILE.write_text(json.dumps(_HASHES), encoding="utf-8")
        except OSError:
            pass


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def file_hash(key: str, path: Path, st) -> str:
    hashes = load_hashes()
    stamp = [st.st_size, int(st.st_mtime * 1000)]
    cached = hashes.get(key)
    if cached and cached[:2] == stamp:
        return cached[2]
    digest = sha256(path)
    hashes[key] = [stamp[0], stamp[1], digest]
    return digest


def manifest(folder: dict) -> list[dict]:
    root = Path(folder["path"])
    if not root.is_dir():
        return []
    patterns = patterns_for(folder)
    files = []
    for dirpath, dirs, names in os.walk(root):
        here = Path(dirpath)
        rel_dir = here.relative_to(root).as_posix()
        rel_dir = "" if rel_dir == "." else rel_dir
        dirs[:] = sorted(
            d for d in dirs
            if not ignored(f"{rel_dir}/{d}".lstrip("/"), patterns)
            and f"{rel_dir}/{d}".lstrip("/") not in SKIP_DIRS
            and d not in SKIP_DIRS
        )
        for name in sorted(names):
            rel = f"{rel_dir}/{name}".lstrip("/")
            if ignored(rel, patterns):
                continue
            path = here / name
            if not path.is_file():
                continue
            try:
                st = path.stat()
            except OSError:
                continue
            files.append({
                "p": rel,
                "s": st.st_size,
                "m": int(st.st_mtime * 1000),
                "h": file_hash(f'{folder["id"]}:{rel}', path, st),
            })
    save_hashes()
    return files


def safe_target(folder: dict, rel: str) -> Path:
    root = Path(folder["path"]).resolve()
    rel = rel.replace("\\", "/").lstrip("/")
    target = (root / rel).resolve()
    if target != root and root not in target.parents:
        raise ValueError("path escapes folder")
    return target


# ---------------------------------------------------------------- HTTP

class Handler(http.server.BaseHTTPRequestHandler):
    server_version = f"NetSync/{APP_VERSION}"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    # -- helpers
    def _json(self, code: int, payload) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _auth(self) -> bool:
        if self.headers.get("X-Sync-Token") == self.server.cfg["token"]:
            self._track_device()
            return True
        self._json(403, {"error": "bad token"})
        return False

    def _track_device(self) -> None:
        did = self.headers.get("X-Device-Id", "").strip()
        if not did:
            return
        cfg = self.server.cfg
        peers = cfg.setdefault("peers", {})
        name = self.headers.get("X-Device-Name", "").strip() or "Android"
        entry = peers.get(did, {})
        entry.update({"name": name, "lastSeen": _now()})
        peers[did] = entry
        try:
            save_config(cfg)
            self.server.on_config_change()
        except OSError:
            pass

    def _folder(self) -> dict | None:
        qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        fid = (qs.get("folder") or [""])[0]
        folder = folder_by_id(self.server.cfg, fid)
        if not folder or not folder.get("enabled", True):
            self._json(404, {"error": "unknown folder"})
            return None
        return folder

    # -- routes
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(parsed.query)

        if parsed.path == "/api/ping":
            if not self._auth():
                return
            return self._json(200, {
                "ok": True, "app": "NetSync", "version": APP_VERSION,
                "name": socket.gethostname(), "folders": len(self.server.cfg["folders"]),
            })

        if parsed.path == "/api/folders":
            if not self._auth():
                return
            items = []
            for f in self.server.cfg["folders"]:
                if not f.get("enabled", True):
                    continue
                root = Path(f["path"])
                items.append({
                    "id": f["id"], "name": f["name"],
                    "exists": root.is_dir(),
                })
            return self._json(200, {"folders": items})

        if parsed.path == "/api/manifest":
            if not self._auth():
                return
            folder = self._folder()
            if not folder:
                return
            return self._json(200, {"folder": folder["id"], "files": manifest(folder)})

        if parsed.path == "/api/file":
            if not self._auth():
                return
            folder = self._folder()
            if not folder:
                return
            try:
                target = safe_target(folder, (qs.get("p") or [""])[0])
            except ValueError:
                return self._json(400, {"error": "bad path"})
            if not target.is_file():
                return self._json(404, {"error": "not found"})
            size = target.stat().st_size
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(size))
            self.end_headers()
            with target.open("rb") as fh:
                for chunk in iter(lambda: fh.read(1 << 20), b""):
                    self.wfile.write(chunk)
            return

        self._json(404, {"error": "unknown endpoint"})

    def do_PUT(self):
        parsed = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(parsed.query)
        if parsed.path != "/api/file":
            return self._json(404, {"error": "unknown endpoint"})
        if not self._auth():
            return
        folder = self._folder()
        if not folder:
            return
        try:
            target = safe_target(folder, (qs.get("p") or [""])[0])
        except ValueError:
            return self._json(400, {"error": "bad path"})

        length = int(self.headers.get("Content-Length", "0"))
        target.parent.mkdir(parents=True, exist_ok=True)
        tmp = target.with_name(target.name + ".netsync-tmp")
        remaining = length
        with tmp.open("wb") as fh:
            while remaining > 0:
                chunk = self.rfile.read(min(1 << 20, remaining))
                if not chunk:
                    break
                fh.write(chunk)
                remaining -= len(chunk)
        os.replace(tmp, target)
        mtime = self.headers.get("X-Mtime")
        if mtime:
            try:
                os.utime(target, (int(mtime) / 1000, int(mtime) / 1000))
            except (ValueError, OSError):
                pass
        return self._json(200, {"ok": True})

    def do_DELETE(self):
        parsed = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(parsed.query)
        if parsed.path != "/api/file":
            return self._json(404, {"error": "unknown endpoint"})
        if not self._auth():
            return
        folder = self._folder()
        if not folder:
            return
        try:
            target = safe_target(folder, (qs.get("p") or [""])[0])
        except ValueError:
            return self._json(400, {"error": "bad path"})
        if target.is_file():
            target.unlink()
        return self._json(200, {"ok": True})


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, addr, handler, cfg: dict, on_config_change=None):
        super().__init__(addr, handler)
        self.cfg = cfg
        self.on_config_change = on_config_change or (lambda: None)


def pairing_payload(cfg: dict, host: str) -> str:
    return json.dumps({
        "v": 2, "app": "NetSync", "host": host, "port": cfg["port"],
        "token": cfg["token"],
    }, ensure_ascii=False)


def qr_png(cfg: dict, host: str, out: Path) -> Path:
    import qrcode
    img = qrcode.make(pairing_payload(cfg, host))
    img.save(out)
    return out


def main() -> int:
    import argparse
    ap = argparse.ArgumentParser(description="NetSync Mac 端服务")
    ap.add_argument("--port", type=int)
    ap.add_argument("--print-pairing", action="store_true", help="打印配对信息与终端二维码")
    ap.add_argument("--daemon", action="store_true")
    args = ap.parse_args()

    cfg = load_config()
    if args.port:
        cfg["port"] = args.port
        save_config(cfg)
    host = lan_ip()

    if args.print_pairing:
        print(f"地址: http://{host}:{cfg['port']}")
        print(f"文件夹: " + ", ".join(f["name"] for f in cfg["folders"] if f.get("enabled", True)))
        print(qr_png(cfg, host, STATE_DIR / "pairing.png"))
        return 0

    if args.daemon:
        sys.stdout = (STATE_DIR / "server.log").open("a", buffering=1)
        sys.stderr = sys.stdout
    else:
        print(f"NetSync {APP_VERSION} — http://{host}:{cfg['port']}")
        print("文件夹: " + ", ".join(f["name"] for f in cfg["folders"] if f.get("enabled", True)))

    try:
        server = Server(("0.0.0.0", cfg["port"]), Handler, cfg)
    except OSError as exc:
        print(f"端口 {cfg['port']} 被占用: {exc}")
        return 1
    print(f"服务已启动，局域网地址 http://{host}:{cfg['port']}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
