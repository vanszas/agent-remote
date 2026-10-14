from __future__ import annotations

import base64
import json
import os
import queue
import secrets
import shutil
import socket
import subprocess
import sys
import threading
import tkinter as tk
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from tkinter import messagebox, simpledialog, ttk

try:
    import qrcode
    import qrcode.image.pil
    from PIL import Image, ImageTk
    HAS_QR = True
except ImportError:
    HAS_QR = False

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


def run_hidden(command: list[str], *, wait: bool = False, cwd: str | None = None, detached: bool = False):
    environment = os.environ.copy()
    environment.pop("AGENT_REMOTE_TOKEN", None)
    environment.pop("HERMES_REMOTE_TOKEN", None)
    
    flags = CREATE_NO_WINDOW
    if detached and sys.platform == "win32":
        flags |= getattr(subprocess, "DETACHED_PROCESS", 0x00000008) | getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0x00000200)

    options = {
        "creationflags": flags,
        "env": environment,
        "cwd": cwd or str(launcher_dir()),
    }
    if wait:
        return subprocess.run(
            command, capture_output=True, text=True, check=False, **options
        )
    return subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        close_fds=True,
        **options
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
def get_all_desktop_and_start_menu_folders() -> list[str]:
    folders = set()
    userprofile = os.environ.get("USERPROFILE", str(Path.home()))
    appdata = os.environ.get("APPDATA", str(Path.home() / "AppData" / "Roaming"))
    
    # Standard User profile locations
    folders.add(str(Path(userprofile) / "Desktop"))
    folders.add(str(Path(appdata) / "Microsoft" / "Windows" / "Start Menu" / "Programs"))
    
    # Registry User Shell Folders (OneDrive / Custom paths)
    try:
        import winreg
        key = winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders")
        for val_name in ("Desktop", "Programs"):
            try:
                raw_val, _ = winreg.QueryValueEx(key, val_name)
                expanded = os.path.expandvars(raw_val)
                if Path(expanded).exists():
                    folders.add(str(Path(expanded)))
            except Exception:
                pass
        winreg.CloseKey(key)
    except Exception:
        pass
        
    return [f for f in folders if Path(f).exists()]


def install_binaries() -> Path:
    source_root = launcher_dir()
    INSTALL_ROOT.mkdir(parents=True, exist_ok=True)
    
    for name in PACKAGE_FILES:
        source = (source_root / name).resolve()
        target = (INSTALL_ROOT / name).resolve()
        if source.is_file() and source != target:
            try:
                temporary = target.with_suffix(target.suffix + ".tmp")
                shutil.copy2(source, temporary)
                try:
                    temporary.replace(target)
                except OSError:
                    # Target might be locked by active background process (e.g. PetUsage.exe), keep running
                    pass
            except OSError:
                pass
                
    installed_setup = INSTALL_ROOT / "AgentRemoteSetup.exe"
    if installed_setup.is_file():
        return installed_setup
    return (source_root / "AgentRemoteSetup.exe").resolve()


def _powershell_quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def shortcut_script(target: Path) -> str:
    quoted_target = _powershell_quote(str(target))
    quoted_working = _powershell_quote(str(target.parent))
    target_folders = get_all_desktop_and_start_menu_folders()
    folders_array_ps = "@(" + ", ".join([_powershell_quote(f) for f in target_folders]) + ")"
    
    return f"""
$shell = New-Object -ComObject WScript.Shell
$target = {quoted_target}
$working = {quoted_working}
$folders = {folders_array_ps}
foreach ($folder in $folders) {{
  if (Test-Path $folder) {{
    $path = Join-Path $folder 'Agent Remote Setup.lnk'
    $shortcut = $shell.CreateShortcut($path)
    $shortcut.TargetPath = $target
    $shortcut.WorkingDirectory = $working
    $shortcut.IconLocation = "$target,0"
    $shortcut.Description = 'Agent Remote Setup'
    $shortcut.Save()
  }}
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
        self.root.geometry("640x780")
        self.root.minsize(580, 680)
        self.token = read_or_create_token()
        self.endpoint = "Mencari koneksi..."
        self.qr_photo = None
        self.status = tk.StringVar(value="Memuat status...")
        self.endpoint_text = tk.StringVar(value=self.endpoint)
        self.pet_autostart = tk.BooleanVar(value=pet_autostart_enabled())
        self.debate_status = tk.StringVar(value="Server 3D Deck: Mati")
        self.router_status_text = tk.StringVar(value="Mengecek SmartRouter...")
        self.router_feedback_var = tk.StringVar(value="")
        self.ui_queue = queue.Queue()
        self._poll_ui_queue()
        self._build()
        self._refresh_async()
        self._load_models()

    def _build(self) -> None:
        header = ttk.Frame(self.root, padding=(18, 14, 18, 6))
        header.pack(fill="x")
        ttk.Label(
            header,
            text=f"Agent Remote Setup {SETUP_VERSION}",
            font=("Segoe UI", 18, "bold"),
        ).pack(anchor="w")
        ttk.Label(
            header, text="Setup PC, kontrol server, dan QR pairing HP."
        ).pack(anchor="w", pady=(1, 6))

        # Notebook tabs for organized layout
        self.notebook = ttk.Notebook(self.root)
        self.notebook.pack(fill="both", expand=True, padx=14, pady=(0, 14))

        self.tab_pairing = ttk.Frame(self.notebook, padding=12)
        self.tab_router = ttk.Frame(self.notebook, padding=12)
        self.tab_more = ttk.Frame(self.notebook, padding=12)

        self.notebook.add(self.tab_pairing, text="  Koneksi & QR Pairing  ")
        self.notebook.add(self.tab_router, text="  Setup Model AI (SmartRouter)  ")
        self.notebook.add(self.tab_more, text="  PET & 3D Debate  ")

        # ==========================================
        # TAB 1: KONEKSI & QR PAIRING (SELALU TERLIHAT)
        # ==========================================
        info = ttk.LabelFrame(self.tab_pairing, text="Koneksi PC", padding=10)
        info.pack(fill="x", pady=(0, 8))
        self._row(info, "Device", socket.gethostname())
        self._row(info, "Endpoint", self.endpoint_text)
        self._row(info, "Status", self.status)

        pairing = ttk.LabelFrame(self.tab_pairing, text="QR Pairing HP", padding=(10, 6))
        pairing.pack(fill="x", pady=(0, 6))

        # Card container latar putih murni (quiet zone kontras tinggi)
        qr_card = tk.Frame(pairing, bg="#ffffff", bd=1, relief="solid", padx=8, pady=8)
        qr_card.pack(pady=2)
        self.qr_label = tk.Label(qr_card, bg="#ffffff", anchor="center")
        self.qr_label.pack()

        ttk.Label(
            pairing,
            text="Arahkan kamera aplikasi Agent Remote di HP ke QR code ini untuk menghubungkan perangkat.",
            wraplength=480,
            justify="center",
            font=("Segoe UI", 9),
        ).pack(pady=(2, 2))
        ttk.Button(
            pairing,
            text="Salin Link / Token Pairing",
            command=self.copy_pairing_link,
        ).pack(pady=(0, 2))

        controls = ttk.LabelFrame(self.tab_pairing, text="Kontrol Server", padding=8)
        controls.pack(fill="x", pady=(0, 8))
        btn_row1 = ttk.Frame(controls)
        btn_row1.pack(fill="x", pady=(0, 4))
        ttk.Button(btn_row1, text="Start Server", command=self.start_server).pack(
            side="left", expand=True, fill="x", padx=(0, 3)
        )
        ttk.Button(btn_row1, text="Stop Server", command=self.stop_server).pack(
            side="left", expand=True, fill="x", padx=3
        )
        ttk.Button(btn_row1, text="Test Koneksi", command=self.test_connection).pack(
            side="left", expand=True, fill="x", padx=(3, 0)
        )
        ttk.Button(
            controls,
            text="Nyalakan Semua (Server + SmartRouter + 9Router + PET)",
            command=self.start_pc_mode,
        ).pack(fill="x")

        action_row = ttk.Frame(self.tab_pairing)
        action_row.pack(fill="x")
        ttk.Button(action_row, text="Salin Koneksi", command=self.copy_connection).pack(
            side="left", expand=True, fill="x", padx=(0, 2)
        )
        ttk.Button(action_row, text="Ganti Password", command=self.change_password).pack(
            side="left", expand=True, fill="x", padx=2
        )
        ttk.Button(action_row, text="Buka Tailscale", command=self.open_tailscale).pack(
            side="left", expand=True, fill="x", padx=2
        )
        ttk.Button(action_row, text="Desktop Shortcut", command=self.add_shortcuts).pack(
            side="left", expand=True, fill="x", padx=2
        )
        ttk.Button(action_row, text="Kelola Perangkat", command=self.manage_devices).pack(
            side="left", expand=True, fill="x", padx=(2, 0)
        )

        # ==========================================
        # TAB 2: SMART ROUTER & MODEL SETUP
        # ==========================================
        ttk.Label(
            self.tab_router,
            text="SmartHermes & Model Setup (Port 4010 / 20128)",
            font=("Segoe UI", 13, "bold"),
        ).pack(anchor="w", pady=(0, 2))
        ttk.Label(
            self.tab_router,
            text="Routing cerdas SmartHermes (Port 4010) dengan upstream 9Router (Port 20128).",
            wraplength=520,
        ).pack(anchor="w", pady=(0, 8))

        router_status_frame = ttk.LabelFrame(self.tab_router, text="Status Router & Proxy", padding=10)
        router_status_frame.pack(fill="x", pady=(0, 8))
        self._row(router_status_frame, "SmartHermes URL", "http://localhost:4010/v1")
        self._row(router_status_frame, "Upstream URL", "http://localhost:20128/v1 (9Router)")
        self._row(router_status_frame, "Status Port", self.router_status_text)

        cfg_frame = ttk.LabelFrame(self.tab_router, text="Pengaturan Model AI", padding=10)
        cfg_frame.pack(fill="x", pady=(0, 8))

        saved_r_cfg = self._load_saved_router_config()

        # Mode
        m_row = ttk.Frame(cfg_frame)
        m_row.pack(fill="x", pady=3)
        ttk.Label(m_row, text="Mode Routing:", width=18).pack(side="left")
        self.router_mode_var = tk.StringVar(value=saved_r_cfg.get("mode", "auto"))
        self.router_mode_cb = ttk.Combobox(
            m_row,
            textvariable=self.router_mode_var,
            values=["auto", "simple_only", "complex_only", "off"],
            state="readonly",
            width=22,
        )
        self.router_mode_cb.pack(side="left", fill="x", expand=True)

        # Model Ringan
        s_row = ttk.Frame(cfg_frame)
        s_row.pack(fill="x", pady=3)
        ttk.Label(s_row, text="Model Ringan (Fast):", width=18).pack(side="left")
        self.simple_model_var = tk.StringVar(value=saved_r_cfg.get("simple_model", "ag/gemini-3.8-flash-high"))
        self.simple_model_cb = ttk.Combobox(
            s_row,
            textvariable=self.simple_model_var,
            width=36,
        )
        self.simple_model_cb.pack(side="left", fill="x", expand=True)

        # Model Berat
        c_row = ttk.Frame(cfg_frame)
        c_row.pack(fill="x", pady=3)
        ttk.Label(c_row, text="Model Berat (Code):", width=18).pack(side="left")
        self.complex_model_var = tk.StringVar(value=saved_r_cfg.get("complex_model", "ag/gemini-pro-agent"))
        self.complex_model_cb = ttk.Combobox(
            c_row,
            textvariable=self.complex_model_var,
            width=36,
        )
        self.complex_model_cb.pack(side="left", fill="x", expand=True)

        # Threshold
        t_row = ttk.Frame(cfg_frame)
        t_row.pack(fill="x", pady=3)
        ttk.Label(t_row, text="Skor Ambang:", width=18).pack(side="left")
        self.threshold_var = tk.StringVar(value=str(saved_r_cfg.get("complexity_threshold", 35)))
        ttk.Entry(t_row, textvariable=self.threshold_var, width=8).pack(side="left")
        ttk.Label(t_row, text="  (Skor prompt >= ambang dialihkan ke Model Berat)").pack(side="left")

        # Fallback Models
        f_row = ttk.Frame(cfg_frame)
        f_row.pack(fill="x", pady=3)
        ttk.Label(f_row, text="Model Fallback:", width=18).pack(side="left")
        fb_list = saved_r_cfg.get("fallback_models", ["ag/gemini-3.7-flash-high", "ag/gemini-3.1-pro-low", "gemini-model"])
        self.fallback_models_var = tk.StringVar(value=", ".join(fb_list) if isinstance(fb_list, list) else str(fb_list))
        ttk.Entry(f_row, textvariable=self.fallback_models_var).pack(side="left", fill="x", expand=True)
        ttk.Label(
            cfg_frame,
            text="* Pisahkan koma. Otomatis dipakai berurutan jika model utama gagal/503.",
            foreground="#666",
            font=("Segoe UI", 8),
        ).pack(anchor="w", pady=(1, 4))

        # Buttons
        r_btns = ttk.Frame(self.tab_router)
        r_btns.pack(fill="x", pady=(4, 6))
        ttk.Button(
            r_btns,
            text="Simpan Pengaturan Model",
            command=self.save_router_config,
        ).pack(side="left", expand=True, fill="x", padx=(0, 4))
        ttk.Button(
            r_btns,
            text="Muat dari 9Router",
            command=self._load_models,
        ).pack(side="left", expand=True, fill="x", padx=(4, 4))
        ttk.Button(
            r_btns,
            text="Muat dari SmartHermes (4010)",
            command=self._load_models_litellm,
        ).pack(side="left", expand=True, fill="x", padx=(0, 0))

        ttk.Label(
            self.tab_router,
            textvariable=self.router_feedback_var,
            foreground="#007700",
            wraplength=520,
            font=("Segoe UI", 9, "bold"),
        ).pack(anchor="w", pady=4)

        # ==========================================
        # TAB 3: FITUR LAIN (PET & 3D DEBATE)
        # ==========================================
        pet_frame = ttk.LabelFrame(self.tab_more, text="Desktop PET", padding=10)
        pet_frame.pack(fill="x", pady=(0, 10))
        ttk.Checkbutton(
            pet_frame,
            text="Nyalakan PET otomatis saat server start",
            variable=self.pet_autostart,
            command=self._save_pet_autostart,
        ).pack(anchor="w")

        debate_section = ttk.LabelFrame(self.tab_more, text="3D Debate Arena (HDO)", padding=10)
        debate_section.pack(fill="x", pady=(0, 10))
        
        debate_btn_frame = ttk.Frame(debate_section)
        debate_btn_frame.pack(fill="x", pady=(0, 6))
        ttk.Button(
            debate_btn_frame, 
            text="Buka 3D Deck", 
            command=self.start_debate_deck
        ).pack(side="left", expand=True, fill="x", padx=(0, 4))
        ttk.Button(
            debate_btn_frame,
            text="Hentikan Deck",
            command=self.stop_debate_deck
        ).pack(side="left", expand=True, fill="x", padx=4)
        
        ttk.Label(debate_section, textvariable=self.debate_status, wraplength=460).pack(anchor="w", pady=(0, 6))
        
        models_grid = ttk.Frame(debate_section)
        models_grid.pack(fill="x", pady=(4, 6))
        saved_d_cfg = self._load_saved_debate_config()
        
        ttk.Label(models_grid, text="Codex:", width=12).grid(row=0, column=0, sticky="w", pady=2)
        self.codex_model_var = tk.StringVar(value=saved_d_cfg.get("codex", {}).get("model", "QODER"))
        self.codex_cb = ttk.Combobox(models_grid, textvariable=self.codex_model_var, width=28)
        self.codex_cb.grid(row=0, column=1, sticky="ew", pady=2)
        
        ttk.Label(models_grid, text="Claude:", width=12).grid(row=1, column=0, sticky="w", pady=2)
        self.claude_model_var = tk.StringVar(value=saved_d_cfg.get("claude", {}).get("model", "ag/gemini-3.7-flash-high"))
        self.claude_cb = ttk.Combobox(models_grid, textvariable=self.claude_model_var, width=28)
        self.claude_cb.grid(row=1, column=1, sticky="ew", pady=2)
        
        ttk.Label(models_grid, text="Antigravity:", width=12).grid(row=2, column=0, sticky="w", pady=2)
        self.antigravity_model_var = tk.StringVar(value=saved_d_cfg.get("antigravity", {}).get("model", "ag/claude-sonnet-4-6"))
        self.antigravity_cb = ttk.Combobox(models_grid, textvariable=self.antigravity_model_var, width=28)
        self.antigravity_cb.grid(row=2, column=1, sticky="ew", pady=2)
        
        ttk.Button(debate_section, text="Simpan Model Debate", command=self.save_debate_models).pack(fill="x", pady=(4, 0))

    def _load_saved_router_config(self) -> dict:
        router_cfg_file = STATE_ROOT / "router_config.json"
        if router_cfg_file.is_file():
            try:
                return json.loads(router_cfg_file.read_text(encoding="utf-8"))
            except Exception:
                pass
        return {
            "enabled": True,
            "mode": "auto",
            "simple_model": "ag/gemini-3.8-flash-high",
            "complex_model": "ag/gemini-pro-agent",
            "fallback_models": ["ag/gemini-3.7-flash-high", "ag/gemini-3.1-pro-low", "ag/gpt-oss-120b-medium", "gemini-model"],
            "complexity_threshold": 35,
        }

    def save_router_config(self) -> None:
        mode = self.router_mode_var.get().strip() or "auto"
        simple_m = self.simple_model_var.get().strip() or "ag/gemini-3.8-flash-high"
        complex_m = self.complex_model_var.get().strip() or "ag/gemini-pro-agent"
        try:
            threshold = int(self.threshold_var.get().strip())
        except ValueError:
            threshold = 35
        fb_raw = self.fallback_models_var.get().strip()
        fb_list = [x.strip() for x in fb_raw.split(",") if x.strip()]

        cfg = {
            "enabled": mode != "off",
            "mode": mode,
            "simple_model": simple_m,
            "complex_model": complex_m,
            "fallback_models": fb_list,
            "complexity_threshold": threshold,
            "listen_port": 20130,
            "upstream_url": "http://localhost:20128/v1",
        }

        router_cfg_file = STATE_ROOT / "router_config.json"
        router_cfg_file.write_text(json.dumps(cfg, indent=2), encoding="utf-8")

        # Sync ke config.yaml LiteLLM (Port 4010) langsung dari GUI
        try:
            candidates = [
                Path(__file__).parent / "litellm_proxy" / "config.yaml",
                launcher_dir() / "tools" / "litellm_proxy" / "config.yaml",
                launcher_dir() / "litellm_proxy" / "config.yaml",
            ]
            for p_yaml in candidates:
                if p_yaml.is_file():
                    txt = p_yaml.read_text(encoding="utf-8")
                    import re
                    txt = re.sub(
                        r"(- model_name:\s*gemini_flash_high\s*\n\s*litellm_params:\s*\n\s*model:\s*)openai/[^\n]+",
                        r"\g<1>openai/" + simple_m,
                        txt,
                    )
                    txt = re.sub(
                        r"(gemini_flash_high:\s*\n\s*route:\s*)[^\n]+",
                        r"\g<1>" + simple_m,
                        txt,
                    )
                    txt = re.sub(
                        r"(- model_name:\s*claude_opus_46_thinking\s*\n\s*litellm_params:\s*\n\s*model:\s*)openai/[^\n]+",
                        r"\g<1>openai/" + complex_m,
                        txt,
                    )
                    txt = re.sub(
                        r"(claude_opus_46_thinking:\s*\n\s*route:\s*)[^\n]+",
                        r"\g<1>" + complex_m,
                        txt,
                    )
                    txt = re.sub(
                        r"(- model_name:\s*SmartHermes\s*\n\s*litellm_params:\s*\n\s*model:\s*)openai/[^\n]+",
                        r"\g<1>openai/" + simple_m,
                        txt,
                    )
                    p_yaml.write_text(txt, encoding="utf-8")
                    break
        except Exception as e_sync:
            print(f"[SmartHermes GUI Sync Error] {e_sync}")

        # Sync ke running server jika aktif
        try:
            req = urllib.request.Request(
                f"http://127.0.0.1:{PORT}/api/router/config",
                data=json.dumps(cfg).encode("utf-8"),
                headers={"Authorization": f"Bearer {self.token}", "Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=1.5) as _:
                pass
        except Exception:
            pass

        self.router_feedback_var.set(f"Tersimpan: {simple_m} (Ringan) & {complex_m} (Berat) | Mode: {mode}")
        messagebox.showinfo(
            "Agent Remote",
            f"Pengaturan model berhasil disimpan!\n\nMode: {mode}\nModel Ringan: {simple_m}\nModel Berat: {complex_m}\n\nSmartRouter langsung menerapkan model baru."
        )

    def _poll_ui_queue(self) -> None:
        try:
            while True:
                fn = self.ui_queue.get_nowait()
                fn()
        except queue.Empty:
            pass
        self.root.after(100, self._poll_ui_queue)

    def _load_models(self) -> None:
        def worker():
            try:
                import sqlite3
                db_p = Path(os.environ.get("APPDATA", Path.home())) / "9router" / "db" / "data.sqlite"
                k = ""
                if db_p.exists():
                    conn = sqlite3.connect(f"file:{db_p.as_posix()}?mode=ro", uri=True, timeout=1)
                    cur = conn.cursor()
                    cur.execute("SELECT key FROM apiKeys WHERE isActive = 1 ORDER BY createdAt DESC LIMIT 1")
                    row = cur.fetchone()
                    conn.close()
                    if row:
                        k = row[0]
                req = urllib.request.Request(
                    "http://127.0.0.1:20128/v1/models",
                    headers={"Authorization": f"Bearer {k}"} if k else {},
                )
                with urllib.request.urlopen(req, timeout=2.5) as r:
                    d = json.loads(r.read().decode("utf-8"))
                    m_list = [m["id"] for m in d.get("data", [])]
                    if m_list:
                        def update_ui():
                            self.simple_model_cb["values"] = m_list
                            self.complex_model_cb["values"] = m_list
                            self.codex_cb["values"] = m_list
                            self.claude_cb["values"] = m_list
                            self.antigravity_cb["values"] = m_list
                            self.router_feedback_var.set(f"Daftar model siap: {len(m_list)} model terdeteksi dari 9Router.")
                        self.ui_queue.put(update_ui)
            except Exception:
                def on_err():
                    self.router_feedback_var.set("Info: 9Router port 20128 belum aktif saat ini.")
                self.ui_queue.put(on_err)

        threading.Thread(target=worker, daemon=True).start()

    def _load_models_litellm(self) -> None:
        """Cek koneksi dan status LiteLLM proxy port 4010 tanpa menimpa model list 9Router."""
        def worker():
            try:
                master_key = os.environ.get("LITELLM_MASTER_KEY", "").strip()
                if not master_key:
                    candidates = [
                        Path(__file__).parent / ".env",
                        launcher_dir() / "tools" / ".env",
                        launcher_dir() / ".env",
                        Path(os.environ.get("LOCALAPPDATA", "")) / "AgentRemote" / ".env",
                    ]
                    for p in candidates:
                        if p.exists():
                            for line in p.read_text(encoding="utf-8-sig").splitlines():
                                name, sep, val = line.partition("=")
                                if sep and name.strip() == "LITELLM_MASTER_KEY":
                                    master_key = val.strip().strip('"').strip("'")
                                    if master_key:
                                        break
                        if master_key:
                            break

                req = urllib.request.Request(
                    "http://127.0.0.1:4010/health/liveliness",
                )
                with urllib.request.urlopen(req, timeout=3) as r:
                    if r.status == 200:
                        def update_ui():
                            self.router_feedback_var.set("SmartHermes (Port 4010) aktif & siap routing ke 9Router.")
                        self.ui_queue.put(update_ui)
            except Exception as e:
                def on_err(err=e):
                    self.router_feedback_var.set(f"SmartHermes (4010) belum aktif: {err}")
                self.ui_queue.put(on_err)
        threading.Thread(target=worker, daemon=True).start()

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
                    self.ui_queue.put(lambda: callback(result))
            except Exception as error:
                self.ui_queue.put(
                    lambda: messagebox.showerror("Agent Remote", str(error))
                )

        threading.Thread(target=worker, daemon=True).start()

    def _refresh_async(self) -> None:
        self._background(self._refresh_data, self._apply_refresh)

    def _refresh_data(self) -> tuple[str, str, object, str]:
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

        router_status = "Nonaktif / Standby"
        try:
            req_litellm = urllib.request.Request("http://127.0.0.1:4010/health/liveliness")
            with urllib.request.urlopen(req_litellm, timeout=1.0) as resp:
                if resp.status == 200:
                    router_status = "Aktif (Port 4010 SmartHermes)"
        except Exception:
            try:
                req_r = urllib.request.Request("http://127.0.0.1:20130/health")
                with urllib.request.urlopen(req_r, timeout=1.0) as resp:
                    if resp.status == 200:
                        router_status = "Aktif (Port 20130)"
            except Exception:
                router_status = "Nonaktif (Port 4010 / 20130)"

        if HAS_QR:
            try:
                qr = qrcode.QRCode(
                    version=None,
                    error_correction=qrcode.constants.ERROR_CORRECT_M,
                    box_size=8,
                    border=2,
                )
                qr.add_data(pairing_payload(endpoint, self.token))
                qr.make(fit=True)
                img = qr.make_image(fill_color="black", back_color="white")
                if hasattr(img, "convert"):
                    img = img.convert("RGB")
                resample = getattr(getattr(Image, "Resampling", Image), "LANCZOS", Image.NEAREST)
                image = img.resize((180, 180), resample=resample)
            except Exception:
                image = qrcode.make(pairing_payload(endpoint, self.token)).resize((180, 180))
        else:
            image = None
        return endpoint, status, image, router_status

    def _apply_refresh(self, result: tuple[str, str, object, str]) -> None:
        self.endpoint, status, image, router_status = result
        self.endpoint_text.set(self.endpoint)
        self.status.set(status)
        self.router_status_text.set(router_status)
        if image is not None and HAS_QR:
            self.qr_photo = ImageTk.PhotoImage(image)
            self.qr_label.configure(image=self.qr_photo, text="", bg="#ffffff")
            self.qr_label.image = self.qr_photo
        else:
            self.qr_label.configure(image="", text="Modul QR (qrcode) tidak terpasang.", bg="#ffffff")

    def copy_token_only(self) -> None:
        self.root.clipboard_clear()
        self.root.clipboard_append(self.token)
        self.status.set("Token disalin ke clipboard")

    def copy_pairing_link(self) -> None:
        self.root.clipboard_clear()
        payload = pairing_payload(self.endpoint, self.token)
        self.root.clipboard_append(payload)
        self.status.set("Link pairing disalin ke clipboard")

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

    @staticmethod
    def ensure_debate_deck(open_browser: bool = False) -> str:
        try:
            import sys
            from pathlib import Path
            plugins_dir = Path.home() / "AppData" / "Local" / "hermes" / "profiles" / "vans" / "plugins"
            if str(plugins_dir) not in sys.path:
                sys.path.insert(0, str(plugins_dir))
            import importlib
            hdo_srv = importlib.import_module("hermes-debate-orchestrator.server")
            srv = hdo_srv.DashboardServer.get_instance()
            info = srv.start()
            if open_browser:
                import webbrowser
                webbrowser.open(f"{info['url']}/index.html?run=ACTIVE-SESSION")
            return f"3D Deck Online: {info['url']}"
        except Exception as e:
            return f"3D Deck Gagal: {e}"

    def start_pc_mode(self) -> None:
        self.status.set("Menyalakan PET + 9Router + Server + Debate...")
        self._background(
            self._start_pc_mode,
            lambda status: self.status.set(status),
        )

    @staticmethod
    def _start_pc_mode() -> str:
        # 1. 9Router
        exe = nine_router_executable()
        cwd_target = str(exe.parent) if exe else None
        try:
            run_hidden(nine_router_command(), cwd=cwd_target, detached=True)
        except Exception:
            pass

        # 2. 9Router Watchdog Guard (Auto-restart jika 9Router mati)
        guard_script = launcher_dir() / "tools" / "nine_router_guard.py"
        if guard_script.is_file():
            try:
                python_bin = sys.executable if not getattr(sys, "frozen", False) else (shutil.which("python") or "python")
                run_hidden([str(python_bin), str(guard_script)], detached=True)
            except Exception:
                pass

        # 3. SmartRouter Proxy (port 20130, dynamic complexity + fallback)
        router_script = launcher_dir() / "tools" / "smart_router_proxy.py"
        if router_script.is_file():
            try:
                python_bin = sys.executable if not getattr(sys, "frozen", False) else (shutil.which("python") or "python")
                run_hidden([str(python_bin), str(router_script)], detached=True)
            except Exception:
                pass

        # 4. PetUsage
        pet = launcher_dir() / "PetUsage.exe"
        if pet.is_file():
            try:
                run_hidden([str(pet)], detached=True)
            except Exception:
                pass

        # 5. Agent Remote Server (port 9120)
        server_exe = launcher_dir() / "ServerStart.exe"
        if server_exe.is_file():
            try:
                run_hidden([str(server_exe)], detached=True)
            except Exception:
                pass

        # 6. Debate Arena Server (headless, tanpa buka browser)
        SetupApp.ensure_debate_deck(open_browser=False)

        return "Mode Full Stack aktif | PET + 9Router (Guarded) + SmartRouter (20130) + Server + Debate berjalan"

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

    def manage_devices(self) -> None:
        win = tk.Toplevel(self.root)
        win.title("Kelola Perangkat Terdaftar")
        win.geometry("580x360")
        win.transient(self.root)

        tree_frame = ttk.Frame(win, padding=10)
        tree_frame.pack(fill="both", expand=True)

        cols = ("name", "id", "ip", "status", "paired_at")
        tree = ttk.Treeview(tree_frame, columns=cols, show="headings", selectmode="browse")
        tree.heading("name", text="Nama Perangkat")
        tree.heading("id", text="Device ID")
        tree.heading("ip", text="IP")
        tree.heading("status", text="Status")
        tree.heading("paired_at", text="Waktu Pairing")

        tree.column("name", width=120)
        tree.column("id", width=110)
        tree.column("ip", width=90)
        tree.column("status", width=80)
        tree.column("paired_at", width=130)

        tree.pack(side="left", fill="both", expand=True)
        scrollbar = ttk.Scrollbar(tree_frame, orient="vertical", command=tree.yview)
        tree.configure(yscrollcommand=scrollbar.set)
        scrollbar.pack(side="right", fill="y")

        def _load_data():
            for item in tree.get_children():
                tree.delete(item)
            trusted_file = launcher_dir() / "trusted_devices.json"
            banned_file = launcher_dir() / "banned_devices.json"
            trusted = {}
            banned = {}
            if trusted_file.is_file():
                try:
                    trusted = json.loads(trusted_file.read_text(encoding="utf-8"))
                except Exception:
                    pass
            if banned_file.is_file():
                try:
                    banned = json.loads(banned_file.read_text(encoding="utf-8"))
                except Exception:
                    pass

            for d_id, d in trusted.items():
                tree.insert("", "end", values=(
                    d.get("device_name", "Android"),
                    d_id,
                    d.get("ip", "-"),
                    "Terpercaya",
                    d.get("paired_at", "-")
                ))
            for d_id, d in banned.items():
                tree.insert("", "end", values=(
                    d.get("device_name", "Android"),
                    d_id,
                    d.get("ip", "-"),
                    "DIBLOKIR",
                    d.get("banned_at", "-")
                ))

        btn_box = ttk.Frame(win, padding=10)
        btn_box.pack(fill="x")

        def _revoke():
            sel = tree.selection()
            if not sel:
                return
            dev_id = str(tree.item(sel[0])["values"][1])
            trusted_file = launcher_dir() / "trusted_devices.json"
            if trusted_file.is_file():
                try:
                    trusted = json.loads(trusted_file.read_text(encoding="utf-8"))
                    if dev_id in trusted:
                        del trusted[dev_id]
                        trusted_file.write_text(json.dumps(trusted, indent=2), encoding="utf-8")
                except Exception:
                    pass
            _load_data()
            messagebox.showinfo("Kelola Perangkat", f"Akses untuk device {dev_id} telah dicabut.")

        def _ban():
            sel = tree.selection()
            if not sel:
                return
            item = tree.item(sel[0])["values"]
            dev_name = str(item[0])
            dev_id = str(item[1])
            dev_ip = str(item[2])
            trusted_file = launcher_dir() / "trusted_devices.json"
            banned_file = launcher_dir() / "banned_devices.json"
            if trusted_file.is_file():
                try:
                    trusted = json.loads(trusted_file.read_text(encoding="utf-8"))
                    if dev_id in trusted:
                        del trusted[dev_id]
                        trusted_file.write_text(json.dumps(trusted, indent=2), encoding="utf-8")
                except Exception:
                    pass
            banned = {}
            if banned_file.is_file():
                try:
                    banned = json.loads(banned_file.read_text(encoding="utf-8"))
                except Exception:
                    pass
            banned[dev_id] = {
                "device_id": dev_id,
                "device_name": dev_name,
                "ip": dev_ip,
                "banned_at": time.strftime("%Y-%m-%d %H:%M:%S")
            }
            banned_file.write_text(json.dumps(banned, indent=2), encoding="utf-8")
            _load_data()
            messagebox.showwarning("Kelola Perangkat", f"Device {dev_name} ({dev_id}) telah diblokir.")

        def _unban():
            sel = tree.selection()
            if not sel:
                return
            dev_id = str(tree.item(sel[0])["values"][1])
            banned_file = launcher_dir() / "banned_devices.json"
            if banned_file.is_file():
                try:
                    banned = json.loads(banned_file.read_text(encoding="utf-8"))
                    if dev_id in banned:
                        del banned[dev_id]
                        banned_file.write_text(json.dumps(banned, indent=2), encoding="utf-8")
                except Exception:
                    pass
            _load_data()
            messagebox.showinfo("Kelola Perangkat", f"Blokir untuk device {dev_id} telah dibuka.")

        ttk.Button(btn_box, text="Cabut Akses (Revoke)", command=_revoke).pack(side="left", padx=4)
        ttk.Button(btn_box, text="Blokir (Ban)", command=_ban).pack(side="left", padx=4)
        ttk.Button(btn_box, text="Buka Blokir (Unban)", command=_unban).pack(side="left", padx=4)
        ttk.Button(btn_box, text="Tutup", command=win.destroy).pack(side="right", padx=4)

        _load_data()

    def start_debate_deck(self) -> None:
        self.debate_status.set("Menyalakan 3D Deck...")
        self._background(
            lambda: SetupApp.ensure_debate_deck(open_browser=True),
            lambda msg: self.debate_status.set(msg),
        )

    def stop_debate_deck(self) -> None:
        def _action():
            import sys
            from pathlib import Path
            plugins_dir = Path.home() / "AppData" / "Local" / "hermes" / "profiles" / "vans" / "plugins"
            if str(plugins_dir) not in sys.path:
                sys.path.insert(0, str(plugins_dir))
            import importlib
            hdo_srv = importlib.import_module("hermes-debate-orchestrator.server")
            hdo_srv.DashboardServer.get_instance().stop()
            return "Server 3D Deck: Mati"
        self._background(_action, lambda msg: self.debate_status.set(msg))

    def _load_saved_debate_config(self) -> dict:
        try:
            from pathlib import Path
            cfg_path = Path.home() / ".hermes" / "hdo" / "config.json"
            if cfg_path.exists():
                return json.loads(cfg_path.read_text(encoding="utf-8")).get("seats", {})
        except Exception:
            pass
        return {}

    def save_debate_models(self) -> None:
        cfg = {
            "provider": "9router",
            "base_url": "http://127.0.0.1:20128/v1",
            "seats": {
                "codex": {"model": self.codex_model_var.get().strip(), "role": "Implementation & Systems"},
                "claude": {"model": self.claude_model_var.get().strip(), "role": "Architecture & Protocol"},
                "antigravity": {"model": self.antigravity_model_var.get().strip(), "role": "Adversarial & Security"}
            }
        }
        from pathlib import Path
        cfg_path = Path.home() / ".hermes" / "hdo" / "config.json"
        cfg_path.parent.mkdir(parents=True, exist_ok=True)
        cfg_path.write_text(json.dumps(cfg, indent=2), encoding="utf-8")
        messagebox.showinfo("3D Arena", "Konfigurasi model agen berhasil disimpan!")

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
            if hasattr(self, "token_var"):
                self.token_var.set(new_password)
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
    if "--check-qr" in sys.argv:
        print(f"HAS_QR={HAS_QR}")
        return 0 if HAS_QR else 1
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
