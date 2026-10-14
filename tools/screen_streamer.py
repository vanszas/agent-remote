"""Screen and audio streamer with input injection for HermesRemote."""

import ctypes
import ctypes.wintypes
import io
import threading
import time
from typing import Generator

try:
    import mss
    import mss.windows
    HAS_MSS = True
except ImportError:
    HAS_MSS = False

try:
    from PIL import ImageGrab, Image
    HAS_PIL = True
except ImportError:
    HAS_PIL = False

# Enable Win32 Per-Monitor DPI Awareness so mouse coordinates are 1:1 on scaled displays
try:
    ctypes.windll.shcore.SetProcessDpiAwareness(2)
except Exception:
    try:
        ctypes.windll.user32.SetProcessDPIAware()
    except Exception:
        pass

# Win32 Mouse & Keyboard constants
INPUT_MOUSE = 0
INPUT_KEYBOARD = 1
MOUSEEVENTF_MOVE = 0x0001
MOUSEEVENTF_LEFTDOWN = 0x0002
MOUSEEVENTF_LEFTUP = 0x0004
MOUSEEVENTF_RIGHTDOWN = 0x0008
MOUSEEVENTF_RIGHTUP = 0x0010
MOUSEEVENTF_MIDDLEDOWN = 0x0020
MOUSEEVENTF_MIDDLEUP = 0x0040
MOUSEEVENTF_WHEEL = 0x0800
MOUSEEVENTF_ABSOLUTE = 0x8000

KEYEVENTF_KEYDOWN = 0x0000
KEYEVENTF_EXTENDEDKEY = 0x0001
KEYEVENTF_KEYUP = 0x0002
KEYEVENTF_UNICODE = 0x0004
KEYEVENTF_SCANCODE = 0x0008

class KEYBDINPUT(ctypes.Structure):
    _fields_ = [
        ("wVk", ctypes.wintypes.WORD),
        ("wScan", ctypes.wintypes.WORD),
        ("dwFlags", ctypes.wintypes.DWORD),
        ("time", ctypes.wintypes.DWORD),
        ("dwExtraInfo", ctypes.c_ulonglong),
    ]

class MOUSEINPUT(ctypes.Structure):
    _fields_ = [
        ("dx", ctypes.wintypes.LONG),
        ("dy", ctypes.wintypes.LONG),
        ("mouseData", ctypes.wintypes.DWORD),
        ("dwFlags", ctypes.wintypes.DWORD),
        ("time", ctypes.wintypes.DWORD),
        ("dwExtraInfo", ctypes.c_ulonglong),
    ]

class HARDWAREINPUT(ctypes.Structure):
    _fields_ = [
        ("uMsg", ctypes.wintypes.DWORD),
        ("wParamL", ctypes.wintypes.WORD),
        ("wParamH", ctypes.wintypes.WORD),
    ]

class INPUT_UNION(ctypes.Union):
    _fields_ = [
        ("ki", KEYBDINPUT),
        ("mi", MOUSEINPUT),
        ("hi", HARDWAREINPUT),
    ]

class INPUT(ctypes.Structure):
    _fields_ = [
        ("type", ctypes.wintypes.DWORD),
        ("u", INPUT_UNION),
    ]

ctypes.windll.user32.SendInput.argtypes = [ctypes.wintypes.UINT, ctypes.POINTER(INPUT), ctypes.c_int]
ctypes.windll.user32.SendInput.restype = ctypes.wintypes.UINT

VK_BACK = 0x08
VK_TAB = 0x09
VK_RETURN = 0x0D
VK_ESCAPE = 0x1B
VK_SPACE = 0x20
VK_LEFT = 0x25
VK_UP = 0x26
VK_RIGHT = 0x27
VK_DOWN = 0x28

RESOLUTIONS = {
    "540p": (960, 540),
    "720p": (1280, 720),
    "1080p": (1920, 1080),
    "native": (0, 0),
}

STREAM_PROFILES: dict[str, dict[str, object]] = {
    "hemat": {
        "id": "hemat",
        "name": "Hemat (540p / 15 FPS / Q50)",
        "resolution": "540p",
        "max_dim": 540,
        "quality": 50,
        "fps": 15,
        "max_kbps": 800,
    },
    "seimbang": {
        "id": "seimbang",
        "name": "Seimbang (720p / 24 FPS / Q75)",
        "resolution": "720p",
        "max_dim": 720,
        "quality": 75,
        "fps": 24,
        "max_kbps": 2500,
    },
    "tajam": {
        "id": "tajam",
        "name": "Tajam (1080p / 30 FPS / Q88)",
        "resolution": "1080p",
        "max_dim": 1080,
        "quality": 88,
        "fps": 30,
        "max_kbps": 6000,
    },
    "ultra": {
        "id": "ultra",
        "name": "Ultra Native (Asli / 30 FPS / Q95)",
        "resolution": "native",
        "max_dim": 0,
        "quality": 95,
        "fps": 30,
        "max_kbps": 0,
    },
}


def list_monitors() -> list[dict[str, object]]:
    """Enumerate all active displays on Windows."""
    monitors: list[dict[str, object]] = []
    try:
        user32 = ctypes.windll.user32

        class _RECT(ctypes.Structure):
            _fields_ = [
                ("left", ctypes.c_long),
                ("top", ctypes.c_long),
                ("right", ctypes.c_long),
                ("bottom", ctypes.c_long),
            ]

        class _MONITORINFO(ctypes.Structure):
            _fields_ = [
                ("cbSize", ctypes.c_ulong),
                ("rcMonitor", _RECT),
                ("rcWork", _RECT),
                ("dwFlags", ctypes.c_ulong),
            ]

        def callback(h_monitor, hdc_monitor, lprc_monitor, dw_data):
            info = _MONITORINFO()
            info.cbSize = ctypes.sizeof(_MONITORINFO)
            user32.GetMonitorInfoW(h_monitor, ctypes.byref(info))
            rc = info.rcMonitor
            is_primary = bool(info.dwFlags & 1)
            w = rc.right - rc.left
            h = rc.bottom - rc.top
            idx = len(monitors) + 1
            monitors.append({
                "id": "primary" if is_primary else f"monitor_{idx}",
                "index": idx,
                "name": f"Monitor {idx} (Utama)" if is_primary else f"Monitor {idx}",
                "width": w,
                "height": h,
                "left": rc.left,
                "top": rc.top,
                "right": rc.right,
                "bottom": rc.bottom,
                "is_primary": is_primary,
            })
            return 1

        mon_enum_proc = ctypes.WINFUNCTYPE(
            ctypes.c_int,
            ctypes.c_void_p,
            ctypes.c_void_p,
            ctypes.c_void_p,
            ctypes.c_void_p,
        )
        proc = mon_enum_proc(callback)
        user32.EnumDisplayMonitors(None, None, proc, 0)

        # Virtual / Combined display
        vx = user32.GetSystemMetrics(76)
        vy = user32.GetSystemMetrics(77)
        vw = user32.GetSystemMetrics(78)
        vh = user32.GetSystemMetrics(79)
        monitors.append({
            "id": "all",
            "index": 0,
            "name": f"Semua Layar ({vw}x{vh})",
            "width": vw,
            "height": vh,
            "left": vx,
            "top": vy,
            "right": vx + vw,
            "bottom": vy + vh,
            "is_primary": False,
        })
    except Exception:
        monitors = [
            {
                "id": "primary",
                "index": 1,
                "name": "Monitor Utama",
                "width": 1920,
                "height": 1080,
                "left": 0,
                "top": 0,
                "right": 1920,
                "bottom": 1080,
                "is_primary": True,
            }
        ]

    return monitors


def get_screen_bounds(monitor: str = "primary") -> tuple[int, int, int, int]:
    """Returns (left, top, width, height) of requested monitor."""
    monitors = list_monitors()
    target = monitor.strip().lower()

    if target in {"all", "virtual"}:
        for m in monitors:
            if m["id"] == "all":
                return int(m["left"]), int(m["top"]), int(m["width"]), int(m["height"])

    for m in monitors:
        if m["id"].lower() == target or str(m.get("index")) == target:
            return int(m["left"]), int(m["top"]), int(m["width"]), int(m["height"])

    # Default to primary monitor
    for m in monitors:
        if m.get("is_primary"):
            return int(m["left"]), int(m["top"]), int(m["width"]), int(m["height"])

    if monitors:
        m = monitors[0]
        return int(m["left"]), int(m["top"]), int(m["width"]), int(m["height"])

    return 0, 0, 1920, 1080


def inject_input(
    action: str = "move",
    x: float = 0.0,
    y: float = 0.0,
    button: str = "left",
    delta: int = 0,
    key: str = "",
    text: str = "",
    monitor: str = "primary",
    **kwargs: object,
) -> dict:
    """Injects mouse and keyboard events into Windows."""
    user32 = ctypes.windll.user32
    left, top, width, height = get_screen_bounds(monitor)

    target_x = int(left + x * width)
    target_y = int(top + y * height)

    if action == "move":
        user32.SetCursorPos(target_x, target_y)
    elif action == "down":
        user32.SetCursorPos(target_x, target_y)
        flag = MOUSEEVENTF_RIGHTDOWN if button == "right" else MOUSEEVENTF_LEFTDOWN
        user32.mouse_event(flag, 0, 0, 0, 0)
    elif action == "up":
        flag = MOUSEEVENTF_RIGHTUP if button == "right" else MOUSEEVENTF_LEFTUP
        user32.mouse_event(flag, 0, 0, 0, 0)
    elif action == "click":
        user32.SetCursorPos(target_x, target_y)
        flag_down = MOUSEEVENTF_RIGHTDOWN if button == "right" else MOUSEEVENTF_LEFTDOWN
        flag_up = MOUSEEVENTF_RIGHTUP if button == "right" else MOUSEEVENTF_LEFTUP
        user32.mouse_event(flag_down, 0, 0, 0, 0)
        time.sleep(0.01)
        user32.mouse_event(flag_up, 0, 0, 0, 0)
    elif action == "rclick":
        user32.SetCursorPos(target_x, target_y)
        user32.mouse_event(MOUSEEVENTF_RIGHTDOWN, 0, 0, 0, 0)
        time.sleep(0.01)
        user32.mouse_event(MOUSEEVENTF_RIGHTUP, 0, 0, 0, 0)
    elif action == "double_click":
        user32.SetCursorPos(target_x, target_y)
        for _ in range(2):
            user32.mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0)
            user32.mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0)
            time.sleep(0.02)
    elif action == "scroll":
        user32.SetCursorPos(target_x, target_y)
        wheel_delta = delta if delta != 0 else 120
        user32.mouse_event(MOUSEEVENTF_WHEEL, 0, 0, wheel_delta, 0)
    elif action in ("key", "type", "text"):
        target_key = text if text else key
        _inject_key(target_key)
    elif action in ("hotkey", "shortcut"):
        _inject_hotkey(key)
    else:
        raise ValueError(f"unknown action: {action}")

    return {
        "status": "ok",
        "action": action,
        "x": target_x,
        "y": target_y,
    }


VK_CONTROL = 0x11
VK_SHIFT = 0x10
VK_MENU = 0x12  # Alt
VK_LWIN = 0x5B
VK_RWIN = 0x5C
VK_DELETE = 0x2E

KEY_MAP = {
    "ctrl": VK_CONTROL,
    "control": VK_CONTROL,
    "alt": VK_MENU,
    "shift": VK_SHIFT,
    "win": VK_LWIN,
    "windows": VK_LWIN,
    "cmd": VK_LWIN,
    "enter": VK_RETURN,
    "return": VK_RETURN,
    "backspace": VK_BACK,
    "tab": VK_TAB,
    "esc": VK_ESCAPE,
    "escape": VK_ESCAPE,
    "space": VK_SPACE,
    "delete": VK_DELETE,
    "del": VK_DELETE,
    "up": VK_UP,
    "down": VK_DOWN,
    "left": VK_LEFT,
    "right": VK_RIGHT,
}
for i in range(1, 13):
    KEY_MAP[f"f{i}"] = 0x70 + (i - 1)


def _inject_hotkey(combo: str) -> None:
    user32 = ctypes.windll.user32
    if not combo:
        return
    parts = [p.strip().lower() for p in combo.replace("+", " ").replace("-", " ").split() if p.strip()]
    if not parts:
        return
    vk_list = []
    for part in parts:
        if part in KEY_MAP:
            vk_list.append(KEY_MAP[part])
        elif len(part) == 1:
            vk_list.append(ord(part.upper()))

    pressed = []
    try:
        for vk in vk_list:
            user32.keybd_event(vk, 0, KEYEVENTF_KEYDOWN, 0)
            pressed.append(vk)
            time.sleep(0.01)
        time.sleep(0.02)
    finally:
        for vk in reversed(pressed):
            user32.keybd_event(vk, 0, KEYEVENTF_KEYUP, 0)
            time.sleep(0.005)


def _inject_key(key: str) -> None:
    user32 = ctypes.windll.user32
    if not key:
        return

    special_keys = {
        "Enter": VK_RETURN,
        "\n": VK_RETURN,
        "\r": VK_RETURN,
        "Backspace": VK_BACK,
        "BackSpace": VK_BACK,
        "Delete": 0x2E,
        "Tab": VK_TAB,
        "Escape": VK_ESCAPE,
        "Space": VK_SPACE,
        " ": VK_SPACE,
        "ArrowLeft": VK_LEFT,
        "ArrowUp": VK_UP,
        "ArrowRight": VK_RIGHT,
        "ArrowDown": VK_DOWN,
    }

    VK_SHIFT = 0x10

    def send_vk(vk: int, with_shift: bool = False) -> None:
        scan = user32.MapVirtualKeyW(vk, 0)
        if with_shift:
            shift_down = INPUT(
                type=INPUT_KEYBOARD,
                u=INPUT_UNION(ki=KEYBDINPUT(wVk=VK_SHIFT, wScan=0x2A, dwFlags=KEYEVENTF_KEYDOWN, time=0, dwExtraInfo=0)),
            )
            user32.SendInput(1, (INPUT * 1)(shift_down), ctypes.sizeof(INPUT))
            time.sleep(0.005)

        inp_down = INPUT(
            type=INPUT_KEYBOARD,
            u=INPUT_UNION(ki=KEYBDINPUT(wVk=vk, wScan=scan, dwFlags=KEYEVENTF_KEYDOWN, time=0, dwExtraInfo=0)),
        )
        user32.SendInput(1, (INPUT * 1)(inp_down), ctypes.sizeof(INPUT))
        time.sleep(0.01)

        inp_up = INPUT(
            type=INPUT_KEYBOARD,
            u=INPUT_UNION(ki=KEYBDINPUT(wVk=vk, wScan=scan, dwFlags=KEYEVENTF_KEYUP, time=0, dwExtraInfo=0)),
        )
        user32.SendInput(1, (INPUT * 1)(inp_up), ctypes.sizeof(INPUT))
        time.sleep(0.005)

        if with_shift:
            shift_up = INPUT(
                type=INPUT_KEYBOARD,
                u=INPUT_UNION(ki=KEYBDINPUT(wVk=VK_SHIFT, wScan=0x2A, dwFlags=KEYEVENTF_KEYUP, time=0, dwExtraInfo=0)),
            )
            user32.SendInput(1, (INPUT * 1)(shift_up), ctypes.sizeof(INPUT))
            time.sleep(0.005)

    # 1. Cek special key tunggal
    if key in special_keys:
        send_vk(special_keys[key])
        return

    # 2. String / karakter per karakter
    for ch in key:
        if ch in special_keys:
            send_vk(special_keys[ch])
            continue

        vks = user32.VkKeyScanW(ord(ch))
        if vks != -1 and vks != 0xFFFF:
            vk = vks & 0xFF
            need_shift = bool((vks >> 8) & 1)
            send_vk(vk, with_shift=need_shift)
        else:
            # Fallback unicode SendInput untuk karakter non-keyboard / CJK / emoji
            code = ord(ch)
            inp_down = INPUT(
                type=INPUT_KEYBOARD,
                u=INPUT_UNION(ki=KEYBDINPUT(wVk=0, wScan=code, dwFlags=KEYEVENTF_UNICODE, time=0, dwExtraInfo=0)),
            )
            user32.SendInput(1, (INPUT * 1)(inp_down), ctypes.sizeof(INPUT))
            time.sleep(0.01)

            inp_up = INPUT(
                type=INPUT_KEYBOARD,
                u=INPUT_UNION(ki=KEYBDINPUT(wVk=0, wScan=code, dwFlags=KEYEVENTF_UNICODE | KEYEVENTF_KEYUP, time=0, dwExtraInfo=0)),
            )
            user32.SendInput(1, (INPUT * 1)(inp_up), ctypes.sizeof(INPUT))
            time.sleep(0.005)


class ScreenStreamer:
    """Manages high-fps screen capturing, adaptive scaling, and background streaming."""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.latest_frame: bytes = b""
        self.running = False
        self.active_clients = 0
        self.worker_thread: threading.Thread | None = None
        self.monitor = "primary"
        self.resolution = "720p"
        self.quality = 65

    def _ensure_worker(self) -> None:
        with self.lock:
            if not self.running or not self.worker_thread or not self.worker_thread.is_alive():
                self.running = True
                self.worker_thread = threading.Thread(target=self._worker_loop, daemon=True)
                self.worker_thread.start()

    def _worker_loop(self) -> None:
        target_fps = 30
        interval = 1.0 / target_fps
        last_active = time.time()
        sct = None
        if HAS_MSS:
            try:
                sct = mss.MSS()
            except Exception:
                sct = None

        try:
            while self.running:
                t0 = time.perf_counter()
                with self.lock:
                    clients = self.active_clients
                if clients <= 0:
                    if time.time() - last_active > 10.0:
                        break
                else:
                    last_active = time.time()

                try:
                    frame = self._capture_frame(sct)
                    if frame:
                        with self.lock:
                            self.latest_frame = frame
                except Exception:
                    time.sleep(0.05)

                elapsed = time.perf_counter() - t0
                sleep_time = interval - elapsed
                if sleep_time > 0:
                    time.sleep(sleep_time)
                else:
                    time.sleep(0.001)
        finally:
            if sct:
                try:
                    sct.close()
                except Exception:
                    pass
            with self.lock:
                self.running = False
                self.worker_thread = None

    def _capture_frame(
        self,
        sct=None,
        target_max: int | None = None,
        quality: int | None = None,
    ) -> bytes:
        left, top, width, height = get_screen_bounds(self.monitor)
        if target_max is None:
            target_max = {"540p": 540, "720p": 720, "1080p": 1080, "native": 0}.get(self.resolution, 720)
        eff_quality = self.quality if quality is None else quality

        if sct:
            mon = {"left": left, "top": top, "width": width, "height": height}
            raw = sct.grab(mon)
            img = Image.frombytes("RGB", raw.size, raw.bgra, "raw", "BGRX")
        elif HAS_PIL:
            bbox = (left, top, left + width, top + height)
            img = ImageGrab.grab(bbox=bbox, all_screens=True)
        else:
            raise RuntimeError("No capture engine available")

        # Modular scaling: target_max == 0 preserves 100% native unscaled sharp pixels
        if target_max and target_max > 0 and max(img.size) > target_max:
            scale = target_max / max(img.size)
            new_size = (max(1, int(img.width * scale)), max(1, int(img.height * scale)))
            img = img.resize(new_size, Image.Resampling.BILINEAR)

        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=eff_quality, optimize=False)
        return buf.getvalue()

    def grab_jpeg(
        self,
        resolution: str = "720p",
        quality: int = 70,
        monitor: str = "primary",
        profile: str | None = None,
    ) -> bytes:
        if profile and profile in STREAM_PROFILES:
            cfg = STREAM_PROFILES[profile]
            resolution = str(cfg["resolution"])
            quality = int(cfg["quality"])

        self.resolution = resolution
        self.quality = quality
        self.monitor = monitor
        target_max = {"540p": 540, "720p": 720, "1080p": 1080, "native": 0}.get(resolution, 720)
        return self._capture_frame(None, target_max=target_max, quality=quality)

    def stream_mjpeg(
        self,
        fps: int = 30,
        resolution: str = "720p",
        quality: int = 65,
        monitor: str = "primary",
        profile: str | None = None,
    ) -> Generator[bytes, None, None]:
        max_kbps = 0
        if profile and profile in STREAM_PROFILES:
            cfg = STREAM_PROFILES[profile]
            resolution = str(cfg["resolution"])
            quality = int(cfg["quality"])
            fps = int(cfg["fps"])
            max_kbps = int(cfg.get("max_kbps", 0))

        self.resolution = resolution
        self.quality = quality
        self.monitor = monitor
        interval = 1.0 / max(1, min(60, fps))

        with self.lock:
            self.active_clients += 1
        self._ensure_worker()

        try:
            while True:
                t0 = time.perf_counter()
                frame = self.grab_jpeg(resolution=resolution, quality=quality, monitor=monitor)

                yield (
                    b"--frame\r\n"
                    b"Content-Type: image/jpeg\r\n"
                    b"Content-Length: " + str(len(frame)).encode() + b"\r\n\r\n"
                    + frame + b"\r\n"
                )

                elapsed = time.perf_counter() - t0
                sleep_time = interval - elapsed
                # Bitrate pacing if bandwidth ceiling is set
                if max_kbps > 0 and len(frame) > 0:
                    bitrate_delay = (len(frame) * 8) / (max_kbps * 1000)
                    sleep_time = max(sleep_time, bitrate_delay)

                if sleep_time > 0:
                    time.sleep(sleep_time)
                else:
                    time.sleep(0.001)
        finally:
            with self.lock:
                self.active_clients = max(0, self.active_clients - 1)


# Global singleton instance
STREAMER = ScreenStreamer()
