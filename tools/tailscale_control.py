from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable


CREATE_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)
Runner = Callable[..., subprocess.CompletedProcess[str]]


@dataclass(frozen=True)
class TailscaleResult:
    success: bool
    available: bool
    changed: bool
    state: str
    detail: str


def _truthy(value: str | None) -> bool:
    return str(value or "").strip().casefold() in {"1", "true", "yes", "on"}


def find_tailscale() -> Path | None:
    override = os.environ.get("AGENT_REMOTE_TAILSCALE_EXE")
    candidates = [
        override,
        shutil.which("tailscale"),
        str(Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "Tailscale" / "tailscale.exe"),
        str(Path(os.environ.get("LOCALAPPDATA", "")) / "Tailscale" / "tailscale.exe"),
    ]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return Path(candidate).resolve()
    return None


def _run(executable: Path, arguments: list[str], runner: Runner | None = None):
    command_runner = runner or subprocess.run
    return command_runner(
        [str(executable), *arguments],
        capture_output=True,
        text=True,
        check=False,
        timeout=15,
        creationflags=CREATE_NO_WINDOW,
    )


def _status(executable: Path, runner: Runner | None = None) -> tuple[str | None, bool | None, str]:
    try:
        result = _run(executable, ["status", "--json"], runner)
    except (OSError, subprocess.SubprocessError) as error:
        return None, None, str(error)
    try:
        payload = json.loads(result.stdout or "{}")
    except json.JSONDecodeError:
        detail = (result.stderr or result.stdout or "Status Tailscale tidak valid").strip()
        return None, None, detail[:300]
    state = str(payload.get("BackendState") or "Unknown")
    registered = bool(payload.get("HaveNodeKey"))
    health = payload.get("Health")
    detail = ""
    if isinstance(health, list):
        detail = " ".join(str(item).strip() for item in health if str(item).strip())
    auth_url = str(payload.get("AuthURL") or "").strip()
    if auth_url:
        detail = f"Login Tailscale diperlukan: {auth_url}"
    return state, registered, detail[:500]


def set_tailscale_online(
    online: bool,
    *,
    executable: Path | None = None,
    runner: Runner | None = None,
) -> TailscaleResult:
    if _truthy(os.environ.get("AGENT_REMOTE_DISABLE_TAILSCALE")):
        return TailscaleResult(True, False, False, "Disabled", "Kontrol Tailscale dinonaktifkan")

    tailscale = executable or find_tailscale()
    if tailscale is None:
        return TailscaleResult(False, False, False, "Missing", "tailscale.exe tidak ditemukan")

    state, registered, status_detail = _status(tailscale, runner)
    if online and state == "Running":
        return TailscaleResult(True, True, False, state, "Tailscale sudah aktif")
    if not online and state and state != "Running":
        return TailscaleResult(True, True, False, state, "Tailscale sudah nonaktif")
    if online and registered is not True:
        detail = status_detail or "Perangkat belum terdaftar pada akun Tailscale"
        return TailscaleResult(False, True, False, state or "Unknown", detail)

    arguments = ["up", "--unattended=true", "--accept-dns=false"] if online else ["down"]
    try:
        result = _run(tailscale, arguments, runner)
    except (OSError, subprocess.SubprocessError) as error:
        return TailscaleResult(False, True, False, state or "Unknown", str(error)[:300])

    final_state, _, final_detail = _status(tailscale, runner)
    if online and runner is None:
        deadline = time.monotonic() + 20
        while final_state != "Running" and time.monotonic() < deadline:
            if "logged out" in final_detail.casefold() or "login tailscale" in final_detail.casefold():
                break
            time.sleep(0.5)
            final_state, _, final_detail = _status(tailscale, runner)
    success = (
        final_state == "Running"
        if online
        else final_state is not None and final_state != "Running"
    )
    detail = (result.stderr or result.stdout or final_detail).strip()[:500]
    if not success and "logged out" in final_detail.casefold():
        detail = "Tailscale logout. Buka aplikasi Tailscale Windows lalu login kembali."
    if not success and not detail:
        detail = f"tailscale {arguments[0]} gagal"
    return TailscaleResult(success, True, success, final_state or "Unknown", detail)


def write_tailscale_log(source: str, result: TailscaleResult) -> None:
    try:
        root = Path(os.environ.get("LOCALAPPDATA", Path.home())) / "AgentRemote"
        root.mkdir(parents=True, exist_ok=True)
        timestamp = datetime.now(timezone.utc).isoformat()
        line = (
            f"{timestamp} {source} success={result.success} available={result.available} "
            f"changed={result.changed} state={result.state} detail={result.detail}\n"
        )
        with (root / "launcher.log").open("a", encoding="utf-8") as handle:
            handle.write(line)
    except OSError:
        pass
