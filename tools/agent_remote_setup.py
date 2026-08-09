from __future__ import annotations

import base64
import json
import os
import secrets
import shutil
import socket
import subprocess
import sys
import threading
import tkinter as tk
import urllib.error
import urllib.request
from pathlib import Path
from tkinter import messagebox, simpledialog, ttk

from tailscale_control import find_tailscale

CREATE_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)
SETUP_VERSION = "0.5.0"
SHORTCUT_BUTTON_TEXT = "Tambahkan ke Desktop + Start Menu"
PORT = 9120
STATE_ROOT = Path(os.environ.get("LOCALAPPDATA", Path.home())) / "AgentRemote"
TOKEN_FILE = STATE_ROOT / "server-token.txt"
PET_STATE_FILE = STATE_ROOT / "pet-usage.json"
INSTALL_ROOT = STATE_ROOT / "bin"
ACTIVE_STATUSES = {"queued", "running", "generating"}
PACKAGE_FILES = ("AgentRemoteSetup.exe", "ServerStart.exe", "ServerStop.exe", "PetUsage.exe")


def launcher_dir() -> Path:
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent.parent


def read_or_create_token() -> str:
    try:
        saved = TOKEN_FILE.read_text(encoding="utf-8").strip()
    except OSError:
        saved = ""
    if saved:
        return saved
    token = secrets.token_urlsafe(32)
    write_token(token)
    return token


def pet_autostart_enabled() -> bool:
    try:
        value = json.loads(PET_STATE_FILE.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return True
    return value.get("start_with_server", True) is not False if isinstance(value, dict) else True

def set_pet_autostart(enabled: bool) -> None:
    STATE_ROOT.mkdir(parents=True, exist_ok=True)
    try:
        value = json.loads(PET_STATE_FILE.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        value = {}
    if not isinstance(value, dict):
        value = {}
    value["start_with_server"] = bool(enabled)
    temporary = PET_STATE_FILE.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
    temporary.replace(PET_STATE_FILE)

def write_token(token: str) -> None:
    if len(token.strip()) < 16:
        raise ValueError("Password minimal 16 karakter.")
    STATE_ROOT.mkdir(parents=True, exist_ok=True)
    temporary = TOKEN_FILE.with_suffix(".tmp")
    temporary.write_text(token.strip() + "\n", encoding="utf-8")
    temporary.replace(TOKEN_FILE)


def run_hidden(command: list[str], *, wait: bool = False):
    environment = os.environ.copy()
    environment.pop("AGENT_REMOTE_TOKEN", None)
    environment.pop("HERMES_REMOTE_TOKEN", None)
    options = {
        "creationflags": CREATE_NO_WINDOW,
        "env": environment,
        "cwd": str(launcher_dir()),
    }
    if wait:
        return subprocess.run(
            command, capture_output=True, text=True, check=False, **options
        )
    return subprocess.Popen(
        command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, **options
    )


def nine_router_executable() -> Path | None:
    for command in ("9router.cmd", "9router"):
        resolved = shutil.which(command)
        if resolved:
            return Path(resolved).resolve()
    appdata = os.environ.get("APPDATA")
    if appdata:
        fallback = Path(appdata) / "npm" / "9router.cmd"
        if fallback.is_file():
            return fallback.resolve()
    return None

def nine_router_command() -> list[str]:
    executable = nine_router_executable()
    if executable is None:
        raise RuntimeError(
            "9Router tidak ditemukan. Pastikan perintah 9router tersedia di PATH."
        )
    arguments = ["--no-browser", "--skip-update", "--tray"]
    if executable.suffix.lower() in {".cmd", ".bat"}:
        return ["cmd.exe", "/d", "/c", str(executable), *arguments]
    return [str(executable), *arguments]
def install_binaries() -> Path:
    source_root = launcher_dir()
    missing = [name for name in PACKAGE_FILES if not (source_root / name).is_file()]
    if missing:
        raise RuntimeError(
            "File paket tidak lengkap: " + ", ".join(missing)
        )
    INSTALL_ROOT.mkdir(parents=True, exist_ok=True)
    for name in PACKAGE_FILES:
        source = (source_root / name).resolve()
        target = (INSTALL_ROOT / name).resolve()
        if source == target:
            continue
        temporary = target.with_suffix(target.suffix + ".tmp")
        shutil.copy2(source, temporary)
        temporary.replace(target)
    return INSTALL_ROOT / "AgentRemoteSetup.exe"


def _powershell_quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def shortcut_script(target: Path) -> str:
    quoted_target = _powershell_quote(str(target))
    quoted_working = _powershell_quote(str(target.parent))
    return f"""
$shell = New-Object -ComObject WScript.Shell
$target = {quoted_target}
$working = {quoted_working}
$folders = @(
  [Environment]::GetFolderPath('Desktop'),
  [Environment]::GetFolderPath('Programs')
)
foreach ($folder in $folders) {{
  $path = Join-Path $folder 'Agent Remote.lnk'
  $shortcut = $shell.CreateShortcut($path)
  $shortcut.TargetPath = $target
  $shortcut.WorkingDirectory = $working
  $shortcut.IconLocation = "$target,0"
  $shortcut.Save()
}}
"""


def install_shortcuts() -> None:
    target = install_binaries()
    encoded = base64.b64encode(
        shortcut_script(target).encode("utf-16le")
    ).decode("ascii")
    result = run_hidden(
        [
            "powershell.exe",
            "-NoProfile",
            "-NonInteractive",
            "-EncodedCommand",
            encoded,
        ],
        wait=True,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "Shortcut gagal dibuat").strip()
        raise RuntimeError(detail[:500])


def tailscale_ip() -> str | None:
    executable = find_tailscale()
    if executable is None:
        return None
    result = run_hidden([str(executable), "ip", "-4"], wait=True)
    if result.returncode == 0:
        return next(
            (line.strip() for line in result.stdout.splitlines() if line.strip()),
            None,
        )
    return None


def local_ip() -> str | None:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
            client.connect(("1.1.1.1", 80))
            address = client.getsockname()[0]
            return address if not address.startswith("127.") else None
    except OSError:
        return None


def connection_endpoint() -> str:
    address = tailscale_ip() or local_ip()
    if not address:
        raise RuntimeError("IP Tailscale/LAN tidak ditemukan.")
    return f"http://{address}:{PORT}"


def pairing_payload(endpoint: str, token: str, name: str | None = None) -> str:
    data = json.dumps(
        {
            "v": 1,
            "endpoint": endpoint,
            "token": token,
            "name": name or socket.gethostname(),
        },
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode("utf-8")
    encoded = base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")
    return f"agentremote://pair?data={encoded}"


def api_json(path: str, token: str, timeout: float = 2.5) -> dict:
    request = urllib.request.Request(
        f"http://127.0.0.1:{PORT}{path}",
        headers={"Authorization": f"Bearer {token}"},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        value = json.loads(response.read().decode("utf-8"))
    return value if isinstance(value, dict) else {}


def active_tasks(token: str) -> list[dict]:
    try:
        tasks = api_json("/api/tasks", token).get("tasks", [])
    except urllib.error.HTTPError as error:
        if error.code == 401:
            raise RuntimeError(
                "Server aktif memakai password berbeda. Hentikan server manual sebelum mengganti password."
            ) from error
        return []
    except (OSError, urllib.error.URLError, json.JSONDecodeError):
        return []
    return [
        task
        for task in tasks
        if isinstance(task, dict) and task.get("status") in ACTIVE_STATUSES
    ]


class SetupApp:
    def __init__(self, root: tk.Tk):
        self.root = root
        self.root.title(f"Agent Remote Setup {SETUP_VERSION}")
        self.root.geometry("600x760")
        self.root.minsize(540, 620)
        self.token = read_or_create_token()
        self.endpoint = "Mencari koneksi..."
        self.qr_photo = None
        self.status = tk.StringVar(value="Memuat status...")
        self.endpoint_text = tk.StringVar(value=self.endpoint)
        self.pet_autostart = tk.BooleanVar(value=pet_autostart_enabled())
        self._build()
        self._refresh_async()

    def _build(self) -> None:
        viewport = ttk.Frame(self.root)
        viewport.pack(fill="both", expand=True)
        canvas = tk.Canvas(viewport, highlightthickness=0, borderwidth=0)
        scrollbar = ttk.Scrollbar(viewport, orient="vertical", command=canvas.yview)
        canvas.configure(yscrollcommand=scrollbar.set)
        scrollbar.pack(side="right", fill="y")
        canvas.pack(side="left", fill="both", expand=True)
        frame = ttk.Frame(canvas, padding=22)
        window = canvas.create_window((0, 0), window=frame, anchor="nw")
        frame.bind(
            "<Configure>",
            lambda _event: canvas.configure(scrollregion=canvas.bbox("all")),
        )
        canvas.bind(
            "<Configure>",
            lambda event: canvas.itemconfigure(window, width=event.width),
        )
        self.root.bind(
            "<MouseWheel>",
            lambda event: canvas.yview_scroll(-int(event.delta / 120), "units"),
        )
        ttk.Label(
            frame,
            text=f"Agent Remote Setup {SETUP_VERSION}",
            font=("Segoe UI", 22, "bold"),
        ).pack(anchor="w")
        ttk.Label(
            frame, text="Setup PC, kontrol server, dan QR pairing HP."
        ).pack(anchor="w", pady=(2, 18))

        info = ttk.LabelFrame(frame, text="Koneksi PC", padding=14)
        info.pack(fill="x")
        self._row(info, "Device", socket.gethostname())
        self._row(info, "Endpoint", self.endpoint_text)
        self._row(info, "Status", self.status)

        controls = ttk.LabelFrame(frame, text="Mode Remote / HP", padding=8)
        controls.pack(fill="x", pady=14)
        ttk.Button(controls, text="Start Remote Server", command=self.start_server).pack(
            side="left", expand=True, fill="x", padx=(0, 5)
        )
        ttk.Button(controls, text="Stop Remote Server", command=self.stop_server).pack(
            side="left", expand=True, fill="x", padx=5
        )
        ttk.Button(controls, text="Test", command=self.test_connection).pack(
            side="left", expand=True, fill="x", padx=(5, 0)
        )

        pc_controls = ttk.LabelFrame(frame, text="Mode PC biasa", padding=8)
        pc_controls.pack(fill="x", pady=(0, 14))
        ttk.Button(
            pc_controls,
            text="Nyalakan PET + 9Router",
            command=self.start_pc_mode,
        ).pack(fill="x")
        ttk.Label(
            pc_controls,
            text="Tidak menyalakan Agent Remote Server. 9Router berjalan di tray.",
            wraplength=460,
        ).pack(anchor="w", pady=(6, 0))

        ttk.Checkbutton(
            frame,
            text="Nyalakan PET otomatis saat server start",
            variable=self.pet_autostart,
            command=self._save_pet_autostart,
        ).pack(anchor="w", pady=(0, 10))

        ttk.Button(
            frame,
            text=SHORTCUT_BUTTON_TEXT,
            command=self.add_shortcuts,
        ).pack(fill="x", pady=(0, 14))

        pairing = ttk.LabelFrame(frame, text="QR Pairing", padding=14)
        pairing.pack(fill="both", expand=True)
        self.qr_label = ttk.Label(pairing, anchor="center")
        self.qr_label.pack(fill="both", expand=True)
        ttk.Label(
            pairing,
            text="Buka Koneksi Agent Remote di HP, lalu tekan Hubungkan dengan QR.",
            wraplength=460,
            justify="center",
        ).pack(pady=(8, 0))

        security = ttk.LabelFrame(frame, text="Keamanan", padding=14)
        security.pack(fill="x", pady=(14, 0))
        ttk.Label(security, text="Password tersimpan lokal dan tidak ditampilkan.").pack(
            side="left", fill="x", expand=True
        )
        ttk.Button(
            security, text="Copy Connection", command=self.copy_connection
        ).pack(side="right", padx=(6, 0))
        ttk.Button(
            security, text="Change Password", command=self.change_password
        ).pack(side="right")

        ttk.Button(
            frame, text="Buka Tailscale", command=self.open_tailscale
        ).pack(fill="x", pady=(14, 0))
        ttk.Label(
            frame,
            text="QR memuat token akses. Jangan screenshot atau bagikan ke orang lain.",
            foreground="#a33",
            wraplength=500,
        ).pack(anchor="w", pady=(12, 0))

    @staticmethod
    def _row(parent: ttk.LabelFrame, label: str, value: str | tk.StringVar) -> None:
        row = ttk.Frame(parent)
        row.pack(fill="x", pady=3)
        ttk.Label(row, text=label, width=12).pack(side="left")
        ttk.Label(
            row,
            textvariable=value if isinstance(value, tk.StringVar) else None,
            text=value if isinstance(value, str) else "",
        ).pack(side="left", fill="x", expand=True)

    def _background(self, action, callback=None) -> None:
        def worker():
            try:
                result = action()
                if callback:
                    self.root.after(0, callback, result)
            except Exception as error:
                self.root.after(
                    0, messagebox.showerror, "Agent Remote", str(error)
                )

        threading.Thread(target=worker, daemon=True).start()

    def _refresh_async(self) -> None:
        self._background(self._refresh_data, self._apply_refresh)

    def _refresh_data(self) -> tuple[str, str, object]:
        endpoint = connection_endpoint()
        try:
            server = api_json("/api/status", self.token)
            pet = server.get("pet", {})
            if pet.get("running"):
                status = "Server aktif | PET aktif"
            elif pet.get("auto_start") and pet.get("available"):
                status = "Server aktif | PET gagal start"
            elif pet.get("auto_start"):
                status = "Server aktif | PET belum terpasang"
            else:
                status = "Server aktif | PET nonaktif"
        except urllib.error.HTTPError as error:
            status = (
                "Server aktif, password berbeda"
                if error.code == 401
                else f"Server error {error.code}"
            )
        except (OSError, urllib.error.URLError):
            status = "Server berhenti"
        import qrcode
        image = qrcode.make(pairing_payload(endpoint, self.token)).resize((280, 280))
        return endpoint, status, image

    def _apply_refresh(self, result: tuple[str, str, object]) -> None:
        from PIL import ImageTk

        self.endpoint, status, image = result
        self.qr_photo = ImageTk.PhotoImage(image)
        self.endpoint_text.set(self.endpoint)
        self.status.set(status)
        self.qr_label.configure(image=self.qr_photo)

    def _save_pet_autostart(self) -> None:
        try:
            set_pet_autostart(self.pet_autostart.get())
            self.status.set(
                "PET aktif saat server start"
                if self.pet_autostart.get()
                else "PET tidak otomatis dinyalakan"
            )
        except OSError as error:
            self.pet_autostart.set(not self.pet_autostart.get())
            messagebox.showerror("Agent Remote", f"Pengaturan PET gagal disimpan: {error}")

    def start_server(self) -> None:
        executable = launcher_dir() / "ServerStart.exe"
        if not executable.is_file():
            messagebox.showerror(
                "Agent Remote", "ServerStart.exe tidak ditemukan di folder yang sama."
            )
            return
        run_hidden([str(executable)])
        self.status.set("Server sedang dimulai...")
        self.root.after(2500, self._refresh_async)

    def start_pc_mode(self) -> None:
        self.status.set("Menyalakan PET + 9Router...")
        self._background(
            self._start_pc_mode,
            lambda status: self.status.set(status),
        )

    @staticmethod
    def _start_pc_mode() -> str:
        pet = launcher_dir() / "PetUsage.exe"
        if not pet.is_file():
            raise RuntimeError("PetUsage.exe tidak ditemukan di folder yang sama.")
        run_hidden(nine_router_command())
        run_hidden([str(pet)])
        return "Mode PC aktif | PET + 9Router berjalan"

    def stop_server(self) -> None:
        executable = launcher_dir() / "ServerStop.exe"
        if not executable.is_file():
            messagebox.showerror(
                "Agent Remote", "ServerStop.exe tidak ditemukan di folder yang sama."
            )
            return
        self.status.set("Server sedang dihentikan...")
        self._background(
            lambda: run_hidden([str(executable), "--silent"], wait=True),
            lambda _: self.root.after(500, self._refresh_async),
        )

    def test_connection(self) -> None:
        def completed(_: dict) -> None:
            messagebox.showinfo("Agent Remote", "Koneksi server valid.")
            self._refresh_async()

        self._background(lambda: api_json("/api/status", self.token), completed)

    def copy_connection(self) -> None:
        if self.endpoint.startswith("Mencari"):
            return
        self.root.clipboard_clear()
        self.root.clipboard_append(
            f"Endpoint: {self.endpoint}\n"
            f"Device Name: {socket.gethostname()}\n"
            f"Password: {self.token}"
        )
        self.root.update()
        messagebox.showinfo(
            "Agent Remote", "Data koneksi disalin. Jangan bagikan password."
        )

    def add_shortcuts(self) -> None:
        self._background(
            install_shortcuts,
            lambda _: messagebox.showinfo(
                "Agent Remote",
                "Shortcut Agent Remote dibuat pada Desktop dan Start Menu.",
            ),
        )

    def change_password(self) -> None:
        try:
            tasks = active_tasks(self.token)
        except RuntimeError as error:
            messagebox.showerror("Agent Remote", str(error))
            return
        if tasks:
            messagebox.showwarning(
                "Agent Remote", "Password tidak diubah karena task masih aktif."
            )
            return
        password = simpledialog.askstring(
            "Change Password",
            "Password baru minimal 16 karakter. Kosongkan untuk generate otomatis:",
            show="*",
        )
        if password is None:
            return
        password = password.strip() or secrets.token_urlsafe(32)
        if len(password) < 16:
            messagebox.showerror("Agent Remote", "Password minimal 16 karakter.")
            return

        def restart() -> str:
            stop = launcher_dir() / "ServerStop.exe"
            start = launcher_dir() / "ServerStart.exe"
            if not stop.is_file() or not start.is_file():
                raise RuntimeError(
                    "ServerStart.exe dan ServerStop.exe harus satu folder dengan setup."
                )
            result = run_hidden([str(stop), "--silent"], wait=True)
            if result.returncode != 0:
                raise RuntimeError("Server gagal dihentikan. Password belum diubah.")
            write_token(password)
            run_hidden([str(start)])
            return password

        def completed(new_password: str) -> None:
            self.token = new_password
            self.status.set("Server dimulai ulang...")
            self.root.after(2500, self._refresh_async)
            messagebox.showinfo(
                "Agent Remote",
                "Password berubah. Scan QR ulang pada HP; token lama tidak berlaku.",
            )

        self.status.set("Mengganti password...")
        self._background(restart, completed)

    def open_tailscale(self) -> None:
        executable = find_tailscale()
        if executable is None:
            messagebox.showerror("Agent Remote", "tailscale.exe tidak ditemukan.")
            return
        os.startfile(executable)


def self_check() -> None:
    token = "x" * 32
    payload = pairing_payload("http://100.64.0.1:9120", token, "PC-Test")
    encoded = payload.split("data=", 1)[1]
    decoded = json.loads(
        base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4))
    )
    assert decoded == {
        "v": 1,
        "endpoint": "http://100.64.0.1:9120",
        "token": token,
        "name": "PC-Test",
    }
    assert "CreateShortcut" in shortcut_script(
        Path("C:/AgentRemote/AgentRemoteSetup.exe")
    )
    assert SETUP_VERSION and "Desktop" in SHORTCUT_BUTTON_TEXT
    assert "PetUsage.exe" in PACKAGE_FILES


def main() -> int:
    if "--self-check" in sys.argv:
        self_check()
        return 0
    if "--install-shortcuts" in sys.argv:
        install_shortcuts()
        return 0
    root = tk.Tk()
    SetupApp(root)
    root.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
