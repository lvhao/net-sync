#!/usr/bin/env python3
"""NetSync — Mac 端图形界面。

双击即用：自动启动同步服务，显示二维码、同步文件夹和已连接的手机。
"""

from __future__ import annotations

import json
import queue
import threading
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

import mac_server as core

STATE = core.STATE_DIR
QR_PNG = STATE / "pairing.png"

BG = "#f5f5f3"
CARD = "#ffffff"
INK = "#1d1d1f"
MUTED = "#6e6e73"
ACCENT = "#0a84ff"
OK = "#1d9e4f"
WARN = "#c77700"


class App:
    def __init__(self, root: tk.Tk):
        self.root = root
        self.cfg = core.load_config()
        self.server: core.Server | None = None
        self.host = core.lan_ip()
        self.qr_image = None
        self.qr_taken = None
        self.events: queue.Queue = queue.Queue()
        self.state_label_text = "正在启动…"
        self.peers_signature = ""

        root.title("NetSync 内网同步")
        root.geometry("560x760")
        root.configure(bg=BG)
        root.minsize(520, 640)

        self._build()
        self._start_server()
        self._render()
        self._update_peers()
        self.root.after(500, self._poll)

    # ---------------------------------------------------------------- UI
    def _build(self) -> None:
        pad = {"padx": 20}

        header = tk.Frame(self.root, bg=BG)
        header.pack(fill="x", pady=(18, 6), **pad)
        tk.Label(header, text="内网同步", bg=BG, fg=INK,
                 font=("PingFang SC", 22, "bold")).pack(anchor="w")
        self.subtitle = tk.Label(header, text="", bg=BG, fg=MUTED, font=("PingFang SC", 11))
        self.subtitle.pack(anchor="w", pady=(2, 0))

        # 二维码卡片
        self.qr_card = tk.Frame(self.root, bg=CARD, highlightthickness=1,
                                highlightbackground="#e3e3e6")
        self.qr_card.pack(fill="x", pady=10, **pad)
        self.qr_label = tk.Label(self.qr_card, bg=CARD, text="正在生成二维码…",
                                 font=("PingFang SC", 11), fg=MUTED)
        self.qr_label.pack(pady=(16, 6))
        self.address = tk.Label(self.qr_card, bg=CARD, fg=INK, font=("Menlo", 11))
        self.address.pack(pady=(0, 14))

        # 文件夹卡片
        folders_head = tk.Frame(self.root, bg=BG)
        folders_head.pack(fill="x", pady=(10, 4), **pad)
        tk.Label(folders_head, text="同步文件夹", bg=BG, fg=INK,
                 font=("PingFang SC", 13, "bold")).pack(side="left")
        tk.Button(folders_head, text="＋ 添加", command=self._add_folder, relief="flat",
                  bg="#e9e9ec", fg=INK, font=("PingFang SC", 11), cursor="hand2",
                  activebackground="#dcdce0", padx=10, pady=2).pack(side="right")

        self.folder_box = tk.Frame(self.root, bg=CARD, highlightthickness=1,
                                   highlightbackground="#e3e3e6")
        self.folder_box.pack(fill="x", **pad)

        # 手机卡片
        tk.Label(self.root, text="已连接的手机", bg=BG, fg=INK,
                 font=("PingFang SC", 13, "bold")).pack(anchor="w", pady=(18, 4), **pad)
        self.peer_box = tk.Frame(self.root, bg=CARD, highlightthickness=1,
                                 highlightbackground="#e3e3e6")
        self.peer_box.pack(fill="x", **pad)

        # 底部
        footer = tk.Frame(self.root, bg=BG)
        footer.pack(fill="x", pady=14, **pad)
        self.state_label = tk.Label(footer, text="", bg=BG, fg=MUTED, font=("PingFang SC", 10))
        self.state_label.pack(side="left")
        tk.Button(footer, text="重新生成二维码", command=self._refresh_qr, relief="flat",
                  bg=BG, fg=ACCENT, font=("PingFang SC", 10), cursor="hand2",
                  activebackground=BG).pack(side="right")

    # ---------------------------------------------------------------- server
    def _start_server(self) -> None:
        try:
            self.server = core.Server(("0.0.0.0", self.cfg["port"]), core.Handler,
                                      self.cfg, on_config_change=self._config_changed)
            threading.Thread(target=self.server.serve_forever, daemon=True).start()
            self.state_label_text = "服务运行中"
        except OSError as exc:
            self.server = None
            self.state_label_text = f"端口被占用：{self.cfg['port']}"
            messagebox.showwarning("无法启动", f"端口 {self.cfg['port']} 已被占用。\n"
                                         f"可能已有一个 NetSync 在运行。\n\n{exc}")

    def _config_changed(self) -> None:
        self.events.put("refresh")

    def _poll(self) -> None:
        try:
            while True:
                self.events.get_nowait()
                self._render()
        except queue.Empty:
            pass
        self._update_peers()
        self.root.after(1500, self._poll)

    # ---------------------------------------------------------------- render
    def _render(self) -> None:
        flist = [f for f in self.cfg["folders"] if f.get("enabled", True)]
        self.subtitle.config(text=f"{self.host}:{self.cfg['port']} · {len(flist)} 个文件夹")
        self.state_label.config(text=self.state_label_text)
        self.address.config(text=f"http://{self.host}:{self.cfg['port']}")

        self._render_folders(flist)
        self._render_qr()

    def _render_folders(self, flist: list[dict]) -> None:
        for w in self.folder_box.winfo_children():
            w.destroy()
        if not flist:
            tk.Label(self.folder_box, text="还没有同步文件夹，点右上角添加",
                     bg=CARD, fg=MUTED, font=("PingFang SC", 11)).pack(pady=18)
            return
        for i, f in enumerate(flist):
            row = tk.Frame(self.folder_box, bg=CARD)
            row.pack(fill="x", padx=14, pady=10)
            dot = "●" if Path(f["path"]).is_dir() else "○"
            color = OK if Path(f["path"]).is_dir() else WARN
            tk.Label(row, text=dot, bg=CARD, fg=color, font=("PingFang SC", 12)).pack(side="left")
            box = tk.Frame(row, bg=CARD)
            box.pack(side="left", fill="x", expand=True, padx=(8, 0))
            tk.Label(box, text=f["name"], bg=CARD, fg=INK,
                     font=("PingFang SC", 12, "bold")).pack(anchor="w")
            tk.Label(box, text=f["path"], bg=CARD, fg=MUTED,
                     font=("Menlo", 9), anchor="w", justify="left",
                     wraplength=400).pack(anchor="w")
            tk.Button(row, text="移除", relief="flat", bg=CARD, fg=MUTED,
                      command=lambda fid=f["id"]: self._remove_folder(fid),
                      font=("PingFang SC", 10), cursor="hand2").pack(side="right")

    def _render_qr(self) -> None:
        try:
            from PIL import Image, ImageTk
            core.qr_png(self.cfg, self.host, QR_PNG)
            st = QR_PNG.stat()
            if self.qr_taken != st.st_mtime:
                img = Image.open(QR_PNG).resize((220, 220), Image.NEAREST)
                self.qr_image = ImageTk.PhotoImage(img)
                self.qr_label.config(image=self.qr_image, text="")
                self.qr_taken = st.st_mtime
        except Exception as exc:
            self.qr_label.config(text=f"二维码生成失败：{exc}")

    def _update_peers(self) -> None:
        peers = list(self.cfg.get("peers", {}).values())
        sig = "|".join(f'{p.get("name")}:{p.get("lastSeen")}' for p in peers)
        if sig == self.peers_signature:
            return
        self.peers_signature = sig
        for w in self.peer_box.winfo_children():
            w.destroy()
        if not peers:
            tk.Label(self.peer_box, text="用手机扫上面的二维码，配对后这里会出现",
                     bg=CARD, fg=MUTED, font=("PingFang SC", 11),
                     wraplength=470, justify="left").pack(pady=18, padx=14)
            return
        for p in peers[-5:]:
            row = tk.Frame(self.peer_box, bg=CARD)
            row.pack(fill="x", padx=14, pady=8)
            tk.Label(row, text="●", bg=CARD, fg=OK, font=("PingFang SC", 12)).pack(side="left")
            box = tk.Frame(row, bg=CARD)
            box.pack(side="left", fill="x", expand=True, padx=(8, 0))
            tk.Label(box, text=p.get("name", "Android"), bg=CARD, fg=INK,
                     font=("PingFang SC", 12, "bold")).pack(anchor="w")
            tk.Label(box, text=p.get("lastSeen", ""), bg=CARD, fg=MUTED,
                     font=("Menlo", 9)).pack(anchor="w")

    # ---------------------------------------------------------------- actions
    def _add_folder(self) -> None:
        path = filedialog.askdirectory(title="选择要同步的文件夹")
        if not path:
            return
        path = str(Path(path).resolve())
        if any(f["path"] == path for f in self.cfg["folders"]):
            messagebox.showinfo("已存在", "这个文件夹已经在同步列表里了。")
            return
        fid = f"f{len(self.cfg['folders']) + 1}"
        while core.folder_by_id(self.cfg, fid):
            fid = f"f{int(fid[1:]) + 1}"
        self.cfg["folders"].append({
            "id": fid, "name": Path(path).name or path, "path": path, "enabled": True,
        })
        core.save_config(self.cfg)
        if self.server:
            self.server.cfg = self.cfg
        self._render()

    def _remove_folder(self, fid: str) -> None:
        folder = core.folder_by_id(self.cfg, fid)
        if not folder:
            return
        if not messagebox.askyesno("移除", f"不再同步「{folder['name']}」？\n"
                                         "本机文件不会删除，只是手机的同步列表里会没有它。"):
            return
        self.cfg["folders"] = [f for f in self.cfg["folders"] if f["id"] != fid]
        core.save_config(self.cfg)
        if self.server:
            self.server.cfg = self.cfg
        self._render()

    def _refresh_qr(self) -> None:
        self.qr_taken = None
        self._render_qr()

    def on_close(self) -> None:
        if self.server:
            self.server.shutdown()
        self.root.destroy()


def main() -> None:
    root = tk.Tk()
    app = App(root)
    root.protocol("WM_DELETE_WINDOW", app.on_close)
    root.mainloop()


if __name__ == "__main__":
    main()
