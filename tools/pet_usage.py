from __future__ import annotations

import ctypes
import json
import math
import os
import sys
import threading
from datetime import datetime, timezone
from time import monotonic
from pathlib import Path
from tkinter import Canvas, Scrollbar, Tk, Toplevel, simpledialog

from PIL import Image, ImageTk

from agent_remote_server import provider_usage

PET_USAGE_VERSION = "0.20.0"
REFRESH_MS = 60_000
ACTIVITY_MS = 3_000
ACTIVE_USAGE_SECONDS = 8
LOOP_MS = 1100
FRAME_COUNT = 8
FRAME_MS = LOOP_MS // FRAME_COUNT
BURN_FRAME_MS = 32
BURN_CYCLE_MS = 960
PET_MUTEX = "Local\\AgentRemote-PetUsage"
MUTEX_HANDLE = None
STATE_FILE = Path(os.environ.get("LOCALAPPDATA", Path.home())) / "AgentRemote" / "pet-usage.json"
TRANSPARENT = "#00ff00"
BG = "#0b1220"
HUD_BG = "#101d32"
HUD_HEADER = "#0b172a"
HUD_EDGE = "#2a4163"
HUD_ROW = "#152640"
HUD_ROW_HOVER = "#1d385d"
TEXT = "#eef4ff"
MUTED = "#9aa9c4"
TRACK = "#273852"
WHITE = "#ffffff"
HOT = "#ff8f86"
GOOD = "#72e0a2"
ACCENT = "#7dd3fc"
YELLOW = "#facc15"
ORANGE = "#f97316"
WARNING = "#f6c177"
SURFACE = "#111f35"
SURFACE_ELEVATED = "#172943"
PET_W, PET_H = 134, 145
BAR_H = 64
BAR_W = 480
BAR_MAX_ROWS = 6
BAR_ROW_H = 44
PANEL_W, PANEL_H = 700, 520
PANEL_GAP = 12
FRAME_W, FRAME_H = 192, 208
STATE_ROWS = {"idle": 0, "right": 1, "left": 2, "working": 8}


def asset_path(name: str) -> Path:
    root = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parents[1]))
    return root / "assets" / "pet" / name


def load_state() -> dict:
    try:
        value = json.loads(STATE_FILE.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError, json.JSONDecodeError):
        return {}


def save_state(**changes: object) -> None:
    value = load_state()
    value.update(changes)
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    temporary = STATE_FILE.with_suffix(".tmp")
    temporary.write_text(json.dumps(value), encoding="utf-8")
    temporary.replace(STATE_FILE)


def _number(value: object) -> str:
    return f"{int(value or 0):,}".replace(",", ".")


def _percentage(value: object) -> float | None:
    if value is None or isinstance(value, bool):
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return max(0.0, min(100.0, number)) if math.isfinite(number) else None


def _reset_countdown(seconds: int) -> str:
    if seconds <= 0:
        return "menunggu data reset baru"
    days, remainder = divmod(seconds, 86400)
    hours, remainder = divmod(remainder, 3600)
    minutes = remainder // 60
    if days:
        return f"{days} hari {hours} jam lagi"
    if hours:
        return f"{hours} jam {minutes} menit lagi"
    return f"{max(1, minutes)} menit lagi"


def _local_reset_text(value: str) -> str:
    if not value:
        return "Reset waktu tidak tersedia"
    try:
        reset = datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone()
    except ValueError:
        return f"Reset dari server: {value[:24]}"
    weekdays = ("Senin", "Selasa", "Rabu", "Kamis", "Jumat", "Sabtu", "Minggu")
    months = (
        "Jan", "Feb", "Mar", "Apr", "Mei", "Jun",
        "Jul", "Agu", "Sep", "Okt", "Nov", "Des",
    )
    seconds = int((reset - datetime.now(reset.tzinfo)).total_seconds())
    absolute = f"{weekdays[reset.weekday()]}, {reset.day:02d} {months[reset.month - 1]} {reset:%H:%M}"
    return f"Reset {absolute} · {_reset_countdown(seconds)}"


def _observed_text(value: object) -> str:
    if not value:
        return "belum ada sinkronisasi"
    try:
        observed = datetime.fromisoformat(str(value).replace("Z", "+00:00")).astimezone()
        return f"diperbarui {observed:%H:%M:%S}"
    except ValueError:
        return "waktu sinkronisasi tidak tersedia"


def animation_delay() -> int:
    return LOOP_MS // FRAME_COUNT

def sprite_row_frames(sheet: Image.Image, row: int) -> list[Image.Image]:
    frames = [
        sheet.crop((column * FRAME_W, row * FRAME_H, (column + 1) * FRAME_W, (row + 1) * FRAME_H))
        for column in range(FRAME_COUNT)
    ]
    frames = [frame for frame in frames if frame.getchannel("A").getbbox()]
    if not frames:
        raise ValueError(f"Sprite row {row} contains no visible frames")
    return frames

def mix_hex(start: str, end: str, amount: float) -> str:
    ratio = max(0.0, min(1.0, float(amount)))
    channels = tuple(
        round(int(start[offset:offset + 2], 16) + (int(end[offset:offset + 2], 16) - int(start[offset:offset + 2], 16)) * ratio)
        for offset in (1, 3, 5)
    )
    return "#" + "".join(f"{channel:02x}" for channel in channels)


def overlay_geometry(visible: bool) -> tuple[int, int]:
    return (PET_H + BAR_H, BAR_H) if visible else (PET_H, 0)


def bar_height_for(count: int) -> int:
    return max(BAR_H, 28 + BAR_ROW_H * min(BAR_MAX_ROWS, max(1, count)))


def display_settings(state: dict) -> tuple[float, str, bool]:
    scale = max(0.5, min(2.0, float(state.get("pet_scale", 1.0))))
    burn = bool(state.get("burn_effect", True))
    return scale, "smooth" if state.get("pet_filter") == "smooth" else "sharp", burn


def pet_dimensions(scale: float) -> tuple[int, int]:
    return round(PET_W * scale), round(PET_H * scale)


def clamp_window_position(
    x: int,
    y: int,
    width: int,
    height: int,
    bounds: tuple[int, int, int, int],
) -> tuple[int, int]:
    screen_left, screen_top, screen_right, screen_bottom = bounds
    max_x = max(screen_left, screen_right - width)
    max_y = max(screen_top, screen_bottom - height)
    return max(screen_left, min(max_x, x)), max(screen_top, min(max_y, y))


def overlay_position(
    x: int,
    y: int,
    old_offset: int,
    new_offset: int,
    pet_height: int,
    window_width: int,
    window_height: int,
    bounds: tuple[int, int, int, int],
) -> tuple[int, int]:
    pet_bottom = y + old_offset + pet_height
    next_y = pet_bottom - new_offset - pet_height
    return clamp_window_position(x, next_y, window_width, window_height, bounds)


def panel_position(
    pet_x: int,
    pet_y: int,
    pet_width: int,
    pet_height: int,
    panel_width: int,
    panel_height: int,
    bounds: tuple[int, int, int, int],
    gap: int = PANEL_GAP,
) -> tuple[int, int]:
    candidates = (
        (pet_x + pet_width - panel_width, pet_y - panel_height - gap),
        (pet_x + pet_width + gap, pet_y),
        (pet_x - panel_width - gap, pet_y),
        (pet_x + pet_width - panel_width, pet_y + pet_height + gap),
    )
    for panel_x, panel_y in candidates:
        inside = clamp_window_position(
            panel_x, panel_y, panel_width, panel_height, bounds
        ) == (panel_x, panel_y)
        overlaps = (
            panel_x < pet_x + pet_width
            and panel_x + panel_width > pet_x
            and panel_y < pet_y + pet_height
            and panel_y + panel_height > pet_y
        )
        if inside and not overlaps:
            return panel_x, panel_y
    return clamp_window_position(
        candidates[0][0], candidates[0][1], panel_width, panel_height, bounds
    )


def is_working(snapshot: dict | None) -> bool:
    if (snapshot or {}).get("active_usages"):
        return True
    active = (snapshot or {}).get("active") or {}
    return bool(active.get("is_active"))


def quota_rows(snapshot: dict) -> list[dict]:
    rows = []
    for account in snapshot.get("quota_accounts") or []:
        name = account.get("name") or account.get("provider") or "9Router"
        quotas = account.get("quotas") or []
        if not quotas:
            rows.append({"label": "QUOTA", "account": name, "provider": account.get("provider") or "unknown", "remaining": None, "reset": "", "active": bool(account.get("active")), "status": account.get("status") or "unavailable"})
            continue
        for quota in quotas:
            remaining = _percentage(quota.get("remaining_percent"))
            rows.append({
                "label": quota.get("label") or "QUOTA", "account": name,
                "provider": account.get("provider") or "unknown",
                "remaining": remaining,
                "reset": quota.get("reset_at") or "",
                "active": bool(account.get("active")),
                "status": account.get("status") or "",
            })
    return rows


def _quota_window_summary(rows: list[dict]) -> str:
    labels = []
    for row in rows:
        label = str(row.get("label") or "").strip()
        if label and label not in labels:
            labels.append(label)
    if not labels:
        return "tanpa data quota"
    visible = " · ".join(labels[:2])
    return visible if len(labels) <= 2 else f"{visible} +{len(labels) - 2}"

def quota_accounts(snapshot: dict) -> list[dict]:
    groups = []
    for account in snapshot.get("quota_accounts") or []:
        name = str(account.get("name") or account.get("provider") or "9Router")
        rows = quota_rows({"quota_accounts": [account]})
        groups.append({
            "id": str(account.get("id") or f"{account.get('provider')}:{name}"),
            "name": name, "provider": account.get("provider") or "unknown",
            "status": account.get("status") or "unavailable",
            "error": account.get("error") or "",
            "rows": rows,
            "window_summary": _quota_window_summary(rows),
        })
    return groups


def provider_badge(provider: object) -> str:
    return {"codex": "CODEX", "antigravity": "AG", "gemini": "GEMINI", "ollama": "OLLAMA"}.get(str(provider).lower(), "?")


def _recently_used(entry: dict, now: datetime, seconds: int = 120) -> bool:
    try:
        timestamp = datetime.fromisoformat(str(entry.get("timestamp", "")).replace("Z", "+00:00"))
        age = (now - timestamp.astimezone(timezone.utc)).total_seconds()
        return 0 <= age <= seconds
    except ValueError:
        return False


def active_usage_rows(snapshot: dict) -> list[dict]:
    accounts = {
        str(account.get("id") or ""): account
        for account in snapshot.get("quota_accounts") or []
    }
    candidates = snapshot.get("active_usages")
    now = datetime.now(timezone.utc)
    if isinstance(candidates, list):
        candidates = [
            entry for entry in candidates
            if isinstance(entry, dict)
            and entry.get("is_active") is not False
            and _recently_used(entry, now, ACTIVE_USAGE_SECONDS)
        ]
    else:
        candidates = [
            entry for entry in snapshot.get("recent") or []
            if _recently_used(entry, now)
        ]
    rows = []
    seen: set[tuple[str, str, str]] = set()
    seen_connections: set[str] = set()
    for entry in candidates:
        if not isinstance(entry, dict):
            continue
        connection_id = str(entry.get("connection_id") or "")
        account = accounts.get(connection_id, {})
        provider = str(entry.get("provider") or account.get("provider") or "unknown")
        account_name = str(entry.get("account") or account.get("name") or provider)
        model = str(entry.get("model") or account.get("model") or "model tidak terdeteksi")
        key = (connection_id or provider, model, account_name)
        if (connection_id and connection_id in seen_connections) or key in seen:
            continue
        if connection_id:
            seen_connections.add(connection_id)
        seen.add(key)
        quota = next((value for value in account.get("quotas") or [] if isinstance(value, dict)), None)
        raw_remaining = quota.get("remaining_percent") if quota else None
        try:
            remaining = None if raw_remaining is None else max(0.0, min(100.0, float(raw_remaining)))
        except (TypeError, ValueError):
            remaining = None
        rows.append({
            "provider": provider,
            "account": account_name,
            "model": model,
            "connection_id": connection_id,
            "label": quota.get("label") if quota else str(entry.get("label") or "USAGE"),
            "remaining": remaining,
        })
    for connection_id, account in accounts.items():
        provider = str(account.get("provider") or "unknown")
        if provider.lower() == "codex" or not account.get("active"):
            continue
        quota = next((value for value in account.get("quotas") or [] if isinstance(value, dict)), None)
        remaining = _percentage(quota.get("remaining_percent")) if quota else None
        if remaining is None:
            continue
        account_name = str(account.get("name") or provider)
        model = str(account.get("model") or "model tidak terdeteksi")
        key = (connection_id or provider, model, account_name)
        if (connection_id and connection_id in seen_connections) or key in seen:
            continue
        rows.append({
            "provider": provider,
            "account": account_name,
            "model": model,
            "connection_id": connection_id,
            "label": quota.get("label") or "QUOTA",
            "remaining": remaining,
        })
    return rows

def quota_bar_color(remaining: float | None) -> str:
    if remaining is None:
        return ACCENT
    if remaining >= 80:
        return GOOD
    if remaining >= 50:
        return ORANGE
    if remaining > 30:
        return YELLOW
    return HOT


def visible_bar_rows(snapshot: dict) -> tuple[list[dict], int]:
    rows = active_usage_rows(snapshot)
    visible = rows[:BAR_MAX_ROWS]
    return visible, max(0, len(rows) - len(visible))


def active_quota_rows(snapshot: dict) -> list[dict]:
    return [row for row in active_usage_rows(snapshot) if row["remaining"] is not None]


def usage_summary(snapshot: dict) -> tuple[str, str]:
    summary = snapshot.get("summary") or {}
    active = snapshot.get("active") or {}
    model = active.get("model") or "Tidak ada model aktif"
    tokens = int(summary.get("input_tokens") or 0) + int(summary.get("output_tokens") or 0)
    return str(model), f"{_number(summary.get('requests'))} request · {_number(tokens)} token"


class UsagePet:
    def __init__(self) -> None:
        self.root = Tk()
        self.root.overrideredirect(True)
        self.root.attributes("-topmost", True)
        self.root.configure(bg=TRANSPARENT)
        self.root.wm_attributes("-transparentcolor", TRANSPARENT)
        state = load_state()
        self.bar_visible = bool(state.get("bar_visible", True))
        self.roaming = bool(state.get("roaming", False))
        self.pet_scale, self.pet_filter, self.burn_effect = display_settings(state)
        self.pet_w, self.pet_h = pet_dimensions(self.pet_scale)
        self.direction = 1
        self.frame_index = 0
        self._animation_state_name: str | None = None
        self._animation_started_at = monotonic()
        self._last_burn_paint_at = 0.0
        self._bar_segments: list[tuple[int, str, bool]] = []
        self._bar_rows: list[dict] = []
        self._bar_hover_index: int | None = None
        self._bar_header_hint: int | None = None
        self.snapshot: dict = {}
        self._overlay_offset = 0
        self.expanded_accounts: set[str] = set()
        self.panel: Toplevel | None = None
        self._panel_drag_start: tuple[int, int] | None = None
        self._panel_click_action = None
        self._panel_resize_start = None
        self._panel_manual_position = False
        self.panel_scroll = 0
        self._drag_start: tuple[int, int] | None = None
        self._dragged = False
        self._activity_request_id = 0
        self._quota_request_id = 0
        self._activity_inflight = False
        self._quota_inflight = False
        self._last_activity_observed = ""
        self._last_quota_observed = ""
        self._set_position(state)
        self._load_frames()
        self.canvas = Canvas(self.root, width=BAR_W, height=self.pet_h + BAR_H, bg=TRANSPARENT, highlightthickness=0)
        self.canvas.pack()
        self.root.update_idletasks()
        self.sprite = self.canvas.create_image(BAR_W // 2, BAR_H + self.pet_h // 2, tags="pet")
        self._paint_sprite()
        self._paint_bar()
        self._apply_overlay_geometry()
        self.canvas.tag_bind("pet", "<ButtonPress-1>", self._drag_begin)
        self.canvas.tag_bind("pet", "<B1-Motion>", self._drag_move)
        self.canvas.tag_bind("pet", "<ButtonRelease-1>", self._drag_end)
        self.canvas.tag_bind("pet", "<Button-3>", self._right_click)
        self.root.after(FRAME_MS, self._animate)
        self.root.after(50, self._refresh)
        self.root.after(ACTIVITY_MS, self._activity_refresh)
        self.root.after(250, self._keep_topmost)

    def _keep_topmost(self) -> None:
        if not self.root.winfo_exists():
            return
        self.root.attributes("-topmost", True)
        if os.name == "nt":
            ctypes.windll.user32.SetWindowPos(
                self.root.winfo_id(), -1, 0, 0, 0, 0,
                0x0001 | 0x0002 | 0x0010,
            )
        else:
            self.root.lift()
        self.root.after(1000, self._keep_topmost)

    def _virtual_bounds(self) -> tuple[int, int, int, int]:
        if not hasattr(self, "root") or self.root is None:
            return 0, 0, 1920, 1080
        left = self.root.winfo_vrootx()
        top = self.root.winfo_vrooty()
        return left, top, left + self.root.winfo_vrootwidth(), top + self.root.winfo_vrootheight()

    def _set_position(self, state: dict) -> None:
        bounds = self._virtual_bounds()
        x = int(state.get("x", bounds[2] - BAR_W - 28))
        y = int(state.get("y", bounds[3] - self.pet_h - BAR_H - 52))
        primary_bounds = (0, 0, self.root.winfo_screenwidth(), self.root.winfo_screenheight())
        if x + BAR_W <= 0 or x >= primary_bounds[2] or y + self.pet_h + BAR_H <= 0 or y >= primary_bounds[3]:
            x = primary_bounds[2] - BAR_W - 28
            y = primary_bounds[3] - self.pet_h - BAR_H - 52
            bounds = primary_bounds
        x, y = clamp_window_position(x, y, BAR_W, self.pet_h + BAR_H, bounds)
        self.root.geometry(f"+{x}+{y}")
        self.root.update_idletasks()

    def _apply_overlay_geometry(self, pet_bottom: int | None = None) -> None:
        self.root.update_idletasks()
        rows, _overflow = visible_bar_rows(self.snapshot)
        offset = bar_height_for(len(rows)) if self.bar_visible and rows else 0
        old_offset = self._overlay_offset
        height = self.pet_h + offset
        anchor_y = self.root.winfo_y()
        if pet_bottom is not None:
            anchor_y = pet_bottom - old_offset - self.pet_h
        x, y = overlay_position(
            self.root.winfo_x(),
            anchor_y,
            old_offset,
            offset,
            self.pet_h,
            BAR_W,
            height,
            self._virtual_bounds(),
        )
        self._overlay_offset = offset
        self.canvas.configure(height=height)
        self.canvas.coords(self.sprite, BAR_W // 2, offset + self.pet_h // 2)
        self.root.geometry(f"{BAR_W}x{height}+{x}+{y}")
        if self.panel and self.panel.winfo_exists() and self.panel.state() == "normal" and not self._panel_manual_position:
            self._position_panel()

    def _load_frames(self) -> None:
        with Image.open(asset_path("maha-v2.webp")) as source:
            sheet = source.convert("RGBA")
        columns, rows = sheet.width // FRAME_W, sheet.height // FRAME_H
        if sheet.width % FRAME_W or sheet.height % FRAME_H or columns < FRAME_COUNT or max(STATE_ROWS.values()) >= rows:
            raise ValueError(
                f"Invalid pet sprite sheet {sheet.size}; expected at least {FRAME_COUNT}x{max(STATE_ROWS.values()) + 1} frames"
            )
        self.frames = {
            state: [
                self._photo(frame) for frame in sprite_row_frames(sheet, row)
            ]
            for state, row in STATE_ROWS.items()
        }

    def _photo(self, frame: Image.Image) -> ImageTk.PhotoImage:
        # Pixel sprite: discard translucent WebP edge pixels so chroma-key green cannot form a halo.
        frame.putalpha(frame.getchannel("A").point(lambda alpha: 255 if alpha >= 128 else 0))
        resample = Image.Resampling.LANCZOS if self.pet_filter == "smooth" else Image.Resampling.NEAREST
        return ImageTk.PhotoImage(frame.resize((self.pet_w, self.pet_h), resample))

    def _animation_state(self) -> str:
        if is_working(self.snapshot):
            return "working"
        if self.roaming:
            return "right" if self.direction > 0 else "left"
        return "idle"

    def _sync_animation_state(self, now: float | None = None) -> str:
        state = self._animation_state()
        if state != self._animation_state_name:
            self._animation_state_name = state
            self._animation_started_at = monotonic() if now is None else now
            self.frame_index = 0
            self._paint_sprite()
        return state

    def _paint_sprite(self) -> None:
        state = self._animation_state_name or self._animation_state()
        frames = self.frames[state]
        image = frames[self.frame_index % len(frames)]
        self.canvas.itemconfigure(self.sprite, image=image)
        self.canvas.image = image

    def _paint_burn_effect(self, now: float | None = None) -> None:
        if not self._bar_segments:
            return
        current = monotonic() if now is None else now
        working = self.burn_effect and is_working(self.snapshot)
        phase = (current * 1000 % BURN_CYCLE_MS) / BURN_CYCLE_MS
        for segment_index, (item_id, base_color, filled) in enumerate(self._bar_segments):
            color = TRACK if not filled else base_color
            if working and filled:
                segment_phase = (phase - (segment_index % 20) / 20) % 1.0
                distance = min(segment_phase, 1.0 - segment_phase)
                pulse = max(0.0, 1.0 - distance / 0.18)
                color = mix_hex(base_color, "#ffb703", pulse)
            self.canvas.itemconfigure(item_id, fill=color)

    def _bar_hover(self, index: int | None) -> None:
        if self._bar_hover_index is not None and self._bar_hover_index < len(self._bar_rows):
            previous = self._bar_rows[self._bar_hover_index]
            self.canvas.itemconfigure(previous["background"], fill=previous["fill"])
        self._bar_hover_index = index
        self.canvas.configure(cursor="hand2" if index is not None else "arrow")
        if index is None or index >= len(self._bar_rows):
            if self._bar_header_hint is not None:
                self.canvas.itemconfigure(self._bar_header_hint, text="ARAHKAN  ·  KLIK DETAIL")
            return
        current = self._bar_rows[index]
        self.canvas.itemconfigure(current["background"], fill=HUD_ROW_HOVER)
        row = current["row"]
        if self._bar_header_hint is not None:
            self.canvas.itemconfigure(
                self._bar_header_hint,
                text=f"{row['model']}  ·  {row['account']}"[:42],
            )

    def _bar_select(self, index: int) -> None:
        if index >= len(self._bar_rows):
            return
        row = self._bar_rows[index]["row"]
        connection_id = str(row.get("connection_id") or "")
        if connection_id:
            self.expanded_accounts.add(connection_id)
        self._show_panel()

    def _paint_bar(self) -> None:
        self.canvas.delete("usage-bar")
        self._bar_segments.clear()
        self._bar_rows.clear()
        self._bar_hover_index = None
        self._bar_header_hint = None
        if not self.bar_visible:
            return
        tag = "usage-bar"
        rows, overflow = visible_bar_rows(self.snapshot)
        if not rows:
            return
        height = bar_height_for(len(rows))
        self.canvas.create_rectangle(0, 0, BAR_W, height, fill=HUD_BG, outline=HUD_EDGE, tags=tag)
        self.canvas.create_rectangle(0, 0, BAR_W, 26, fill=HUD_HEADER, outline="", tags=tag)
        working = is_working(self.snapshot)
        state_label = "LIVE" if working else "RECENT" if self.snapshot.get("active") else "IDLE"
        state_color = GOOD if working else HOT if state_label == "RECENT" else MUTED
        live_dot = self.canvas.create_rectangle(12, 9, 18, 15, fill=state_color, outline="", tags=tag)
        self.canvas.create_text(26, 13, text=f"{state_label}  {len(rows)} USAGE", fill=WHITE, font=("Consolas", 9, "bold"), anchor="w", tags=tag)
        self._bar_header_hint = self.canvas.create_text(BAR_W - 12, 13, text="ARAHKAN  ·  KLIK DETAIL", fill=MUTED, font=("Consolas", 7, "bold"), anchor="e", tags=tag)
        header_tag = "usage-header"
        self.canvas.addtag_withtag(header_tag, live_dot)
        self.canvas.addtag_withtag(header_tag, self._bar_header_hint)
        self.canvas.tag_bind(header_tag, "<Button-1>", lambda _event: self._show_panel())
        self.canvas.create_line(10, 26, BAR_W - 10, 26, fill=HUD_EDGE, tags=tag)
        if overflow:
            self.canvas.create_text(BAR_W - 12, height - 7, text=f"+{overflow} DI PANEL DETAIL", fill=MUTED, font=("Consolas", 7, "bold"), anchor="e", tags=tag)
        for index, row in enumerate(rows):
            row_tag = f"usage-row-{index}"
            y = 30 + index * BAR_ROW_H
            remaining = row["remaining"]
            color = quota_bar_color(remaining)
            value = "DATA" if remaining is None else f"{remaining:.0f}%"
            background = self.canvas.create_rectangle(8, y, BAR_W - 8, y + 32, fill=HUD_ROW, outline="", tags=(tag, row_tag))
            badge = provider_badge(row["provider"])
            self.canvas.create_rectangle(14, y + 6, 62, y + 26, fill="#153e5d", outline=HUD_EDGE, tags=(tag, row_tag))
            self.canvas.create_text(38, y + 16, text=badge, fill=WHITE, font=("Consolas", 8, "bold"), anchor="c", tags=(tag, row_tag))
            model = str(row.get("model") or "model tidak terdeteksi")
            account = str(row.get("account") or "account tidak terdeteksi")
            self.canvas.create_text(72, y + 10, text=model[:27], fill=WHITE, font=("Consolas", 9, "bold"), anchor="w", tags=(tag, row_tag))
            self.canvas.create_text(72, y + 24, text=account[:29], fill=MUTED, font=("Consolas", 7), anchor="w", tags=(tag, row_tag))
            self.canvas.create_text(BAR_W - 12, y + 16, text=value, fill=color, font=("Consolas", 10, "bold"), anchor="e", tags=(tag, row_tag))
            meter_x = 250
            for segment in range(20):
                x = meter_x + segment * 6
                filled = remaining is None or segment < round(remaining / 5)
                segment_id = self.canvas.create_rectangle(x, y + 9, x + 5, y + 15, fill=color if filled else TRACK, outline="", tags=(tag, row_tag))
                self._bar_segments.append((segment_id, color, filled))
            self._bar_rows.append({"background": background, "fill": HUD_ROW, "row": {**row, "connection_id": row.get("connection_id", "")}})
            self.canvas.tag_bind(row_tag, "<Enter>", lambda _event, row_index=index: self._bar_hover(row_index))
            self.canvas.tag_bind(row_tag, "<Leave>", lambda _event: self._bar_hover(None))
            self.canvas.tag_bind(row_tag, "<Button-1>", lambda _event, row_index=index: self._bar_select(row_index))
            self.canvas.tag_bind(row_tag, "<Button-3>", lambda _event: self._toggle_bar())
        self._paint_burn_effect()

    def _animate(self) -> None:
        now = monotonic()
        self._sync_animation_state(now)
        frame_count = len(self.frames[self._animation_state_name or self._animation_state()])
        next_frame = int(max(0.0, now - self._animation_started_at) * 1000 // FRAME_MS) % frame_count
        if next_frame != self.frame_index:
            self.frame_index = next_frame
            self._paint_sprite()
        if self.roaming and not is_working(self.snapshot) and not self._drag_start:
            self._roam_step()
            self._sync_animation_state(now)
        if now - self._last_burn_paint_at >= BURN_FRAME_MS / 1000:
            self._last_burn_paint_at = now
            self._paint_burn_effect(now)
        self.root.after(16, self._animate)

    def _roam_step(self) -> None:
        x, y = self.root.winfo_x(), self.root.winfo_y()
        bounds = self._virtual_bounds()
        min_x = bounds[0]
        max_x = bounds[2] - BAR_W
        if (self.direction > 0 and x >= max_x) or (self.direction < 0 and x <= min_x):
            self.direction *= -1
        next_x, next_y = clamp_window_position(
            x + 4 * self.direction,
            y,
            BAR_W,
            self.pet_h + self._overlay_offset,
            bounds,
        )
        self.root.geometry(f"+{next_x}+{next_y}")

    def _right_click(self, _event) -> None:
        self.root.destroy()

    def _drag_begin(self, event) -> None:
        self._drag_start = (event.x_root, event.y_root)
        self._dragged = False

    def _drag_move(self, event) -> None:
        if not self._drag_start:
            return
        dx, dy = event.x_root - self._drag_start[0], event.y_root - self._drag_start[1]
        self._dragged = self._dragged or abs(dx) + abs(dy) > 4
        next_x, next_y = clamp_window_position(
            self.root.winfo_x() + dx,
            self.root.winfo_y() + dy,
            BAR_W,
            self.pet_h + self._overlay_offset,
            self._virtual_bounds(),
        )
        self.root.geometry(f"+{next_x}+{next_y}")
        self._drag_start = (event.x_root, event.y_root)

    def _drag_end(self, _event) -> None:
        if self._drag_start:
            save_state(x=self.root.winfo_x(), y=self.root.winfo_y())
        self._drag_start = None
        if not self._dragged:
            self._toggle_panel()

    def _toggle_bar(self) -> None:
        self.bar_visible = not self.bar_visible
        save_state(bar_visible=self.bar_visible)
        self._apply_overlay_geometry()
        self._paint_bar()
        self._render()

    def _toggle_panel(self) -> None:
        if self.panel and self.panel.winfo_exists() and self.panel.state() == "normal":
            self._hide_panel()
            return
        self._show_panel()

    def _position_panel(self) -> None:
        if not self.panel or not self.panel.winfo_exists():
            return
        panel_width = max(PANEL_W, self.panel.winfo_width())
        panel_height = max(PANEL_H, self.panel.winfo_height())
        bounds = self._virtual_bounds()
        if self._panel_manual_position:
            panel_x, panel_y = clamp_window_position(
                self.panel.winfo_x(),
                self.panel.winfo_y(),
                panel_width,
                panel_height,
                bounds,
            )
        else:
            pet_x = self.root.winfo_x()
            pet_y = self.root.winfo_y()
            panel_x, panel_y = panel_position(
                pet_x,
                pet_y,
                BAR_W,
                self._overlay_offset + self.pet_h,
                panel_width,
                panel_height,
                bounds,
            )
        self.panel.geometry(f"{panel_width}x{panel_height}+{panel_x}+{panel_y}")

    def _show_panel(self) -> None:
        if self.panel is None or not self.panel.winfo_exists():
            self.panel = Toplevel(self.root, bg=BG)
            self.panel.overrideredirect(True)
            self.panel.attributes("-topmost", True)
            self.panel.geometry(f"{PANEL_W}x{PANEL_H}+0+0")
            self.panel.bind("<Escape>", lambda _event: self._hide_panel())
            self.panel.bind("<ButtonPress-1>", self._panel_drag_begin)
            self.panel.bind("<B1-Motion>", self._panel_drag_move)
            self.panel.bind("<ButtonRelease-1>", self._panel_drag_end)
        self.panel.deiconify()
        self.panel.lift()
        self.canvas.itemconfigure(self.sprite, state="hidden")
        self._position_panel()
        self._render()

    def _panel_drag_begin(self, event) -> None:
        widget = getattr(event, "widget", None)
        if isinstance(widget, Scrollbar):
            self._panel_drag_start = None
            self._panel_click_action = None
            return
        self._panel_drag_start = (event.x_root, event.y_root)
        y = widget.canvasy(event.y) if isinstance(widget, Canvas) else event.y
        self._panel_click_action = next((action for x1, y1, x2, y2, action in self._panel_actions if x1 <= event.x <= x2 and y1 <= y <= y2), None)

    def _panel_drag_move(self, event) -> None:
        if not self.panel or not self._panel_drag_start:
            return
        dx, dy = event.x_root - self._panel_drag_start[0], event.y_root - self._panel_drag_start[1]
        panel_w = self.panel.winfo_width() if hasattr(self.panel, "winfo_width") else PANEL_W
        panel_h = self.panel.winfo_height() if hasattr(self.panel, "winfo_height") else PANEL_H
        if abs(dx) + abs(dy) > 3:
            self._panel_click_action = None
            self._panel_manual_position = True
            panel_x, panel_y = clamp_window_position(
                self.panel.winfo_x() + dx,
                self.panel.winfo_y() + dy,
                max(PANEL_W, panel_w),
                max(PANEL_H, panel_h),
                self._virtual_bounds(),
            )
            self.panel.geometry(f"+{panel_x}+{panel_y}")
            self._panel_drag_start = (event.x_root, event.y_root)

    def _panel_drag_end(self, _event) -> None:
        action, self._panel_click_action = self._panel_click_action, None
        self._panel_drag_start = None
        if action:
            action()

    def _refresh(self) -> None:
        self._request_usage("quota")
        self.root.after(REFRESH_MS, self._refresh)

    def _activity_refresh(self) -> None:
        self._request_usage("activity")
        self.root.after(ACTIVITY_MS, self._activity_refresh)

    def _request_usage(self, kind: str) -> None:
        if kind == "activity":
            if self._activity_inflight:
                return
            self._activity_request_id += 1
            request_id = self._activity_request_id
            self._activity_inflight = True
            include_quotas = False
        else:
            if self._quota_inflight:
                return
            self._quota_request_id += 1
            request_id = self._quota_request_id
            self._quota_inflight = True
            include_quotas = True
        threading.Thread(
            target=self._load_usage,
            args=(kind, request_id, include_quotas),
            daemon=True,
        ).start()

    def _load_usage(self, kind: str, request_id: int, include_quotas: bool) -> None:
        try:
            snapshot = provider_usage(
                range_name="24h",
                limit=100,
                include_quotas=include_quotas,
            )
        except Exception as error:
            snapshot = {
                "available": False,
                "active": None,
                "reason": str(error)[:160],
                "quota_complete": False,
            }
        snapshot.setdefault(
            "observed_at",
            datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        )
        self.root.after(
            0,
            lambda: self._accept_snapshot(snapshot, kind, request_id),
        )

    def _accept_snapshot(self, snapshot: dict, kind: str = "quota", request_id: int = 0) -> None:
        previous_state = self._animation_state()
        if kind == "activity":
            if request_id != self._activity_request_id:
                return
            self._activity_inflight = False
            observed_at = str(snapshot.get("observed_at") or "")
            if observed_at and observed_at < self._last_activity_observed:
                return
            self._last_activity_observed = observed_at
            self.snapshot.update({
                key: snapshot[key]
                for key in (
                    "available", "source", "range", "summary", "active",
                    "active_usages", "providers", "models", "recent", "updated_at",
                    "observed_at", "reason", "scope", "attribution",
                )
                if key in snapshot
            })
        else:
            if request_id != self._quota_request_id:
                return
            self._quota_inflight = False
            observed_at = str(snapshot.get("observed_at") or "")
            if observed_at and observed_at < self._last_quota_observed:
                return
            self._last_quota_observed = observed_at
            self.snapshot.update({
                key: snapshot[key]
                for key in (
                    "available", "source", "range", "quota_accounts",
                    "quota_complete", "updated_at", "scope",
                    "mobile_filter_available", "mobile_key_name",
                    "attribution", "reason",
                )
                if key in snapshot
            })
            if not self._last_activity_observed or observed_at >= self._last_activity_observed:
                self.snapshot.update({
                    key: snapshot[key]
                    for key in (
                        "summary", "active", "active_usages", "providers", "models", "recent",
                        "observed_at",
                    )
                    if key in snapshot
                })
        if self._animation_state() != previous_state:
            self._sync_animation_state()
        self._apply_overlay_geometry()
        self._paint_bar()
        if self.panel and self.panel.winfo_exists() and self.panel.state() == "normal":
            self._render()

    @staticmethod
    def _reset_label(value: str) -> str:
        return _local_reset_text(value)

    def _render(self) -> None:
        if self.panel is None or not self.panel.winfo_exists():
            return
        accounts = quota_accounts(self.snapshot)
        if not accounts:
            accounts = [{
                "id": "local",
                "name": "9Router lokal",
                "provider": "unknown",
                "status": "unavailable",
                "error": self.snapshot.get("reason") or "Quota belum tersedia.",
                "rows": [],
            }]
        panel_w = max(PANEL_W, self.panel.winfo_width())
        panel_h = max(PANEL_H, self.panel.winfo_height())
        content_h = 224
        for account in accounts:
            content_h += 68
            if account["id"] in self.expanded_accounts:
                content_h += 108 * len(account["rows"]) if account["rows"] else 64
        self.panel.geometry(f"{panel_w}x{panel_h}+{self.panel.winfo_x()}+{self.panel.winfo_y()}")
        for child in self.panel.winfo_children():
            child.destroy()
        self._panel_actions = []
        viewport_w = max(PANEL_W - 18, panel_w - 18)
        right = viewport_w - 28
        footer_h = 76
        footer = Canvas(self.panel, height=footer_h, bg=BG, highlightthickness=0)
        footer.pack(side="bottom", fill="x")
        c = Canvas(self.panel, width=viewport_w, height=panel_h - footer_h, bg=BG, highlightthickness=0)
        scrollbar = Scrollbar(self.panel, orient="vertical", command=c.yview)
        c.configure(
            yscrollcommand=lambda first, last: (
                scrollbar.set(first, last),
                setattr(self, "panel_scroll", float(first)),
            ),
            scrollregion=(0, 0, viewport_w, max(panel_h - footer_h, content_h)),
        )
        c.pack(side="left", fill="both", expand=True)
        scrollbar.pack(side="right", fill="y")
        c.bind("<ButtonPress-1>", self._panel_drag_begin)
        c.bind("<B1-Motion>", self._panel_drag_move)
        c.bind("<ButtonRelease-1>", self._panel_drag_end)
        c.bind("<MouseWheel>", lambda event: c.yview_scroll(-int(event.delta / 120), "units"))
        c.yview_moveto(self.panel_scroll)
        c.create_rectangle(0, 0, viewport_w, content_h, fill=BG, outline="")
        c.create_rectangle(0, 0, viewport_w, 92, fill=HUD_HEADER, outline="")
        c.create_rectangle(0, 0, 8, 92, fill=ACCENT, outline="")
        c.create_text(30, 28, text="AGENT REMOTE", fill=WHITE, font=("Segoe UI", 17, "bold"), anchor="w")
        c.create_text(30, 59, text="Monitor quota 9Router", fill=MUTED, font=("Segoe UI", 10), anchor="w")
        if not self.snapshot:
            connection_label, connection_color = "MENUNGGU DATA", MUTED
        elif self.snapshot.get("available") and self.snapshot.get("quota_complete"):
            connection_label, connection_color = "DATA LIVE", GOOD
        elif self.snapshot.get("available"):
            connection_label, connection_color = "DATA TIDAK LENGKAP", WARNING
        else:
            connection_label, connection_color = "OFFLINE", HOT
        c.create_rectangle(right - 168, 22, right, 50, fill=SURFACE_ELEVATED, outline=connection_color)
        c.create_text(right - 84, 36, text=connection_label, fill=connection_color, font=("Segoe UI", 9, "bold"), anchor="c")
        c.create_text(right, 70, text=f"PC · 24 jam · {_observed_text(self.snapshot.get('observed_at'))}", fill=MUTED, font=("Segoe UI", 9), anchor="e")

        model, summary = usage_summary(self.snapshot)
        working = is_working(self.snapshot)
        active = self.snapshot.get("active") or {}
        activity_source = str(active.get("activity_source") or "")
        state_label = "PULSE" if working and active.get("is_approximate") else "BEKERJA" if working else "BARU SELESAI" if activity_source == "recent_request" else "IDLE"
        state_color = GOOD if working else HOT if activity_source == "recent_request" else MUTED
        c.create_rectangle(20, 112, right, 194, fill=SURFACE, outline=HUD_EDGE)
        c.create_text(38, 134, text="AKTIVITAS 24 JAM", fill=MUTED, font=("Segoe UI", 9, "bold"), anchor="w")
        c.create_text(right - 20, 134, text=state_label, fill=state_color, font=("Segoe UI", 9, "bold"), anchor="e")
        c.create_text(38, 160, text=model, fill=WHITE, font=("Segoe UI", 12, "bold"), anchor="w", width=max(260, right - 290))
        c.create_text(right - 20, 160, text=summary, fill=TEXT, font=("Segoe UI", 10), anchor="e")
        c.create_text(38, 181, text="Angka quota berasal dari response 9Router. Tidak ada estimasi.", fill=MUTED, font=("Segoe UI", 8), anchor="w")

        c.create_text(28, 222, text="QUOTA PER AKUN", fill=WHITE, font=("Segoe UI", 11, "bold"), anchor="w")
        c.create_text(right, 222, text=f"{len(accounts)} akun", fill=MUTED, font=("Segoe UI", 9), anchor="e")
        y = 246
        for account in accounts:
            expanded = account["id"] in self.expanded_accounts
            marker = "⌄" if expanded else "›"
            title = str(account["name"])
            status = str(account.get("status") or "unavailable").lower()
            status_label = {
                "active": "TERHUBUNG",
                "error": "ERROR",
                "inactive": "NONAKTIF",
                "unavailable": "DATA TIDAK TERSEDIA",
            }.get(status, status.upper())
            status_color = GOOD if status == "active" else HOT if status == "error" else MUTED
            header_top = y
            header_bottom = y + 56
            c.create_rectangle(20, header_top, right, header_bottom, fill=SURFACE_ELEVATED if expanded else SURFACE, outline=HUD_EDGE)
            c.create_rectangle(36, header_top + 15, 98, header_top + 41, fill=HUD_ROW, outline=HUD_EDGE)
            c.create_text(67, header_top + 28, text=provider_badge(account["provider"]), fill=ACCENT, font=("Consolas", 8, "bold"), anchor="c")
            c.create_text(116, header_top + 20, text=f"{marker}  {title}", fill=WHITE, font=("Segoe UI", 10, "bold"), anchor="w", width=max(260, right - 300))
            c.create_text(right - 20, header_top + 19, text=status_label, fill=status_color, font=("Segoe UI", 8, "bold"), anchor="e")
            count_label = f"{len(account['rows'])} jendela" if account["rows"] else "tanpa data quota"
            window_summary = str(account.get("window_summary") or "tanpa data quota")
            quota_summary = "quota tidak tersedia"
            known_remaining = [row.get("remaining") for row in account["rows"] if row.get("remaining") is not None]
            if known_remaining:
                quota_summary = f"{min(known_remaining):.0f}% tersisa"
            c.create_text(right - 20, header_top + 39, text=f"{quota_summary} · {count_label} · {window_summary}", fill=MUTED, font=("Segoe UI", 8), anchor="e", width=right - 250)
            self._panel_actions.append((20, header_top, right, header_bottom, lambda account_id=account["id"]: self._toggle_account(account_id)))
            y = header_bottom + 12
            if not expanded:
                continue
            for row in account["rows"]:
                card_top = y
                card_bottom = y + 96
                remaining = row.get("remaining")
                known = remaining is not None
                color = quota_bar_color(remaining)
                quota_right = right - 20
                quota_width = quota_right - 52
                c.create_rectangle(36, card_top, quota_right, card_bottom, fill=SURFACE, outline=TRACK)
                c.create_text(52, card_top + 20, text=str(row["label"]), fill=WHITE, font=("Segoe UI", 10, "bold"), anchor="w")
                c.create_text(quota_right - 14, card_top + 20, text=f"{remaining:.0f}% tersisa" if known else "DATA TIDAK TERSEDIA", fill=color, font=("Segoe UI", 9, "bold"), anchor="e")
                c.create_text(52, card_top + 44, text=self._reset_label(str(row["reset"])), fill=MUTED, font=("Segoe UI", 8), anchor="w")
                c.create_rectangle(52, card_top + 66, quota_right - 14, card_top + 74, fill=TRACK, outline="")
                if known:
                    c.create_rectangle(52, card_top + 66, 52 + quota_width * remaining / 100, card_top + 74, fill=color, outline="")
                y = card_bottom + 12
            if not account["rows"]:
                c.create_text(52, y + 20, text=account.get("error") or "Provider tidak mengirim data quota.", fill=MUTED, font=("Segoe UI", 9), anchor="w", width=right - 80)
                y += 52

        footer.create_line(26, 0, panel_w - 26, 0, fill=TRACK)
        footer.bind("<ButtonPress-1>", self._panel_drag_begin)
        footer.bind("<B1-Motion>", self._panel_drag_move)
        footer.bind("<ButtonRelease-1>", self._panel_drag_end)
        button_width = 82
        button_gap = 7
        button_start = max(16, (panel_w - (7 * button_width + 6 * button_gap)) // 2)
        buttons = (
            ("IDLE", not self.roaming, lambda: self._set_roaming(False)),
            ("ROAM", self.roaming, lambda: self._set_roaming(True)),
            ("BAR ON" if self.bar_visible else "BAR OFF", self.bar_visible, self._toggle_bar),
            ("BURN ON" if self.burn_effect else "BURN OFF", self.burn_effect, self._toggle_burn),
            (f"SIZE {self.pet_scale:.2g}x", False, self._prompt_scale),
            (self.pet_filter.upper(), self.pet_filter == "sharp", self._toggle_filter),
            ("TUTUP", False, self._hide_panel),
        )
        for index, (label, selected, action) in enumerate(buttons):
            self._button(footer, button_start + index * (button_width + button_gap), 20, label, selected, action, width=button_width)
        grip = "resize-grip"
        footer.create_text(panel_w - 14, 59, text="◢", fill=MUTED, font=("Segoe UI", 10), tags=grip)
        footer.tag_bind(grip, "<ButtonPress-1>", self._resize_begin)
        footer.tag_bind(grip, "<B1-Motion>", self._resize_move)
        footer.tag_bind(grip, "<ButtonRelease-1>", self._resize_end)
    def _button(self, c: Canvas, x: int, y: int, label: str, selected: bool, action, width: int = 74) -> None:
        tag = f"button-{x}-{y}"
        fill, text = (ACCENT, BG) if selected else (SURFACE, WHITE)
        hover_fill = "#a7e3ff" if selected else HUD_ROW_HOVER
        rect_id = c.create_rectangle(x, y, x + width, y + 34, fill=fill, outline=HUD_EDGE, tags=tag)
        c.create_text(x + width // 2, y + 17, text=label, fill=text, font=("Segoe UI", 8, "bold"), tags=tag)
        # ponytail: native Canvas hover fix - update item direct, avoid tag fill bug.
        c.tag_bind(tag, "<Enter>", lambda _event, r=rect_id, h=hover_fill: c.itemconfigure(r, fill=h))
        c.tag_bind(tag, "<Leave>", lambda _event, r=rect_id, f=fill: c.itemconfigure(r, fill=f))
        self._panel_actions.append((x, y, x + width, y + 34, action))

    def _resize_begin(self, event) -> None:
        self._panel_resize_start = (event.x_root, event.y_root, self.panel.winfo_width(), self.panel.winfo_height())

    def _resize_move(self, event) -> None:
        if not self.panel or not self._panel_resize_start:
            return
        x, y, width, height = self._panel_resize_start
        panel_width = max(PANEL_W, width + event.x_root - x)
        panel_height = max(PANEL_H, height + event.y_root - y)
        panel_x, panel_y = clamp_window_position(
            self.panel.winfo_x(),
            self.panel.winfo_y(),
            panel_width,
            panel_height,
            self._virtual_bounds(),
        )
        self.panel.geometry(f"{panel_width}x{panel_height}+{panel_x}+{panel_y}")

    def _resize_end(self, _event) -> None:
        self._panel_resize_start = None
        self._position_panel()
        self._render()

    def _toggle_account(self, account_id: str) -> None:
        if account_id in self.expanded_accounts:
            self.expanded_accounts.remove(account_id)
        else:
            self.expanded_accounts.add(account_id)
        self._render()

    def _hide_panel(self) -> None:
        if self.panel:
            self.panel.withdraw()
        self.canvas.itemconfigure(self.sprite, state="normal")

    def _prompt_scale(self) -> None:
        value = simpledialog.askfloat("Ukuran Maha", "Skala 0.5 sampai 2.0", initialvalue=self.pet_scale, minvalue=0.5, maxvalue=2.0, parent=self.panel)
        if value is not None:
            self._set_scale(value)

    def _set_scale(self, value: float) -> None:
        pet_bottom = self.root.winfo_y() + self._overlay_offset + self.pet_h
        self.pet_scale = max(0.5, min(2.0, round(value, 2)))
        self.pet_w, self.pet_h = pet_dimensions(self.pet_scale)
        save_state(pet_scale=self.pet_scale)
        self._load_frames()
        self._apply_overlay_geometry(pet_bottom)
        self._paint_sprite()
        self._render()

    def _toggle_burn(self) -> None:
        self.burn_effect = not self.burn_effect
        save_state(burn_effect=self.burn_effect)
        self._paint_bar()
        self._render()

    def _toggle_filter(self) -> None:
        self.pet_filter = "smooth" if self.pet_filter == "sharp" else "sharp"
        save_state(pet_filter=self.pet_filter)
        self._load_frames()
        self._paint_sprite()
        self._render()

    def _set_roaming(self, value: bool) -> None:
        self.roaming = value
        save_state(roaming=value)
        self._sync_animation_state()
        self._render()

    def run(self) -> None:
        self.root.mainloop()


def acquire_instance() -> bool:
    global MUTEX_HANDLE
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.CreateMutexW.argtypes = [ctypes.c_void_p, ctypes.c_bool, ctypes.c_wchar_p]
    kernel32.CreateMutexW.restype = ctypes.c_void_p
    MUTEX_HANDLE = kernel32.CreateMutexW(None, False, PET_MUTEX)
    return bool(MUTEX_HANDLE) and ctypes.get_last_error() != 183


if __name__ == "__main__":
    if "--print" in sys.argv:
        print("\n".join(usage_summary(provider_usage(range_name="24h", limit=5))))
    elif acquire_instance():
        UsagePet().run()
