import base64
import ctypes
import difflib
import hashlib
import json
import os
import queue
import re
import shutil
import secrets
import sqlite3
import stat
import subprocess
import sys
import threading
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

TOOLS_ROOT = Path(__file__).resolve().parent
if str(TOOLS_ROOT) not in sys.path:
    sys.path.insert(0, str(TOOLS_ROOT))

from agent_runtime import (
    AgentRuntime,
    SessionStore,
    available_agents as discover_agents,
    infer_activity_phase,
    normalize_codex_event,
    now_iso,
)
from tailscale_control import set_tailscale_online, write_tailscale_log

CREATE_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)
HOST = os.environ.get("AGENT_REMOTE_HOST") or os.environ.get(
    "HERMES_REMOTE_HOST", "0.0.0.0"
)
PORT = 9120
SERVER_INSTANCE_MUTEX = "Local\\AgentRemoteServer-9120"
STATE_ROOT = Path(
    os.environ.get("LOCALAPPDATA", Path.home() / ".agent-remote")
) / "AgentRemote"
STATE_FILE = STATE_ROOT / "server.json"
BRIDGE_FILE = STATE_ROOT / "bridge.json"
CODEX_TASKS_FILE = STATE_ROOT / "codex_tasks.json"
SECURITY_AUDIT_FILE = STATE_ROOT / "security_audit.jsonl"
SECURITY_AUDIT_BACKUP_FILE = STATE_ROOT / "security_audit.jsonl.1"
SECURITY_AUDIT_MAX_BYTES = 2 * 1024 * 1024
NINE_ROUTER_DB = Path(
    os.environ.get(
        "AGENT_REMOTE_9ROUTER_DB",
        Path(os.environ.get("APPDATA", Path.home())) / "9router" / "db" / "data.sqlite",
    )
)
CODEX_STATE_DB = Path(
    os.environ.get(
        "AGENT_REMOTE_CODEX_STATE_DB",
        Path.home() / ".codex" / "state_5.sqlite",
    )
)
CODEX_ROLLOUT_TAIL_BYTES = 2 * 1024 * 1024
CODEX_DESKTOP_THREAD_LIMIT = 200
CODEX_DESKTOP_STALE_SECONDS = 10 * 60
CODEX_DESKTOP_ORPHAN_SECONDS = 30 * 60
CODEX_ROLLOUT_CACHE_LOCK = threading.RLock()
CODEX_ROLLOUT_CACHE: dict[str, tuple[int, int, dict | None]] = {}
CODEX_ROLLOUT_CACHE_MAX_ENTRIES = 400
TASK_LIST_CACHE_SECONDS = 1.0
TASK_LIST_CACHE_LOCK = threading.RLock()
TASK_LIST_CACHE: tuple[float, list[dict]] | None = None
TASK_LIST_MAX_ITEMS = 10
CODEX_TASK_HISTORY_LIMIT = 10
PC_AGENT_PROCESS_CACHE_SECONDS = 4.0
PC_AGENT_PROCESS_LOCK = threading.RLock()
PC_AGENT_PROCESS_CACHE: tuple[float, list[dict]] | None = None
PC_AGENT_ACTIVE: dict[str, dict] = {}
PC_AGENT_RECENT: list[dict] = []
PC_AGENT_DISPLAY_NAMES = {
    "codex": "Codex",
    "claude": "Claude Code",
    "gemini": "Gemini CLI",
    "opencode": "OpenCode",
    "hermes": "Hermes",
    "aider": "Aider",
    "amp": "Amp",
    "goose": "Goose",
    "qwen": "Qwen Code",
    "copilot": "GitHub Copilot CLI",
    "cursor-agent": "Cursor Agent",
}
PC_AGENT_EXECUTABLES = {
    "codex.exe": "codex",
    "claude.exe": "claude",
    "gemini.exe": "gemini",
    "opencode.exe": "opencode",
    "hermes.exe": "hermes",
    "aider.exe": "aider",
    "amp.exe": "amp",
    "goose.exe": "goose",
    "qwen.exe": "qwen",
    "copilot.exe": "copilot",
    "cursor-agent.exe": "cursor-agent",
}
PC_AGENT_WRAPPERS = {"node.exe", "python.exe", "pythonw.exe", "bun.exe", "deno.exe"}
PC_AGENT_COMMAND_MARKERS = {
    "codex": ("node_modules\\@openai\\codex", "node_modules/@openai/codex"),
    "claude": ("@anthropic-ai\\claude-code", "@anthropic-ai/claude-code"),
    "gemini": ("@google\\gemini-cli", "@google/gemini-cli"),
    "opencode": ("node_modules\\opencode", "node_modules/opencode"),
    "hermes": ("hermes-agent", "hermes_agent"),
    "aider": ("aider-chat", "aider.main", "\\aider\\"),
    "amp": ("node_modules\\@sourcegraph\\amp", "node_modules/@sourcegraph/amp"),
    "goose": ("block.github.io\\goose", "\\goose\\bin"),
    "qwen": ("@qwen-code\\qwen-code", "@qwen-code/qwen-code"),
    "copilot": ("@github\\copilot", "@github/copilot", "github-copilot-cli"),
    "cursor-agent": ("cursor-agent",),
}
NINE_ROUTER_QUOTA_CACHE_SECONDS = 55
NINE_ROUTER_QUOTA_CACHE: dict[str, tuple[float, dict]] = {}
GIT_STATUS_CACHE_SECONDS = 4
GIT_REMOTE_CACHE_SECONDS = 30
GIT_DISCOVERY_CACHE_SECONDS = 60
GITHUB_CLI_CACHE_SECONDS = 60
GIT_CACHE_LOCK = threading.RLock()
GIT_STATUS_CACHE: dict[str, tuple[float, dict]] = {}
GIT_REMOTE_CACHE: dict[str, tuple[float, dict]] = {}
GIT_DISCOVERY_CACHE: dict[str, tuple[float, list[dict]]] = {}
GIT_STATUS_LOCKS: dict[str, threading.Lock] = {}
GITHUB_CLI_CACHE: tuple[float, dict] | None = None
MAX_TEXT_FILE_BYTES = 512 * 1024
MOBILE_KEY_NAME = os.environ.get(
    'AGENT_REMOTE_9ROUTER_MOBILE_KEY_NAME', 'Agent Remote Mobile'
)
MOBILE_KEY_ENV = 'AGENT_REMOTE_9ROUTER_API_KEY'
NINE_ROUTER_BASE_URL = os.environ.get(
    'AGENT_REMOTE_9ROUTER_BASE_URL', 'http://127.0.0.1:20128/v1'
).strip()
AUTH_SUCCESS_LOG_WINDOW_SECONDS = 15 * 60
AUTH_FAILURE_LOG_WINDOW_SECONDS = 10
def _find_hermes_executable() -> Path | None:
    configured = os.environ.get("AGENT_REMOTE_HERMES_EXE", "").strip()
    candidates = [configured, shutil.which("hermes.exe"), shutil.which("hermes")]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return Path(candidate).resolve()
    return None


def _load_or_create_token() -> str:
    configured = (
        os.environ.get("AGENT_REMOTE_TOKEN")
        or os.environ.get("HERMES_REMOTE_TOKEN")
        or ""
    ).strip()
    if configured:
        return configured
    token_file = STATE_ROOT / "server-token.txt"
    try:
        saved = token_file.read_text(encoding="utf-8").strip()
    except OSError:
        saved = ""
    if saved:
        return saved
    token = secrets.token_urlsafe(32)
    STATE_ROOT.mkdir(parents=True, exist_ok=True)
    temporary = token_file.with_suffix(".tmp")
    temporary.write_text(token + "\n", encoding="utf-8")
    temporary.replace(token_file)
    return token


HERMES = _find_hermes_executable()
TOKEN = _load_or_create_token()
SKIP = {".git", ".dart_tool", "build", ".idea", ".vs", ".hermes-remote"}
GIT_DISCOVERY_SKIP = SKIP | {
    ".agent-remote",
    ".venv",
    "Binaries",
    "DerivedDataCache",
    "dist",
    "Intermediate",
    "node_modules",
    "Saved",
    "venv",
}


class FileConflictError(Exception):
    pass


def load_server_state() -> dict:
    try:
        value = json.loads(STATE_FILE.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {}


def save_server_state(workspace: Path, recent: list[str]):
    STATE_ROOT.mkdir(parents=True, exist_ok=True)
    temporary = STATE_FILE.with_suffix(".tmp")
    temporary.write_text(json.dumps({
        "last_workspace": str(workspace),
        "recent_workspaces": recent[:30],
        "permission_by_workspace": PERMISSION_BY_WORKSPACE,
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    temporary.replace(STATE_FILE)


def save_bridge_config():
    STATE_ROOT.mkdir(parents=True, exist_ok=True)
    temporary = BRIDGE_FILE.with_suffix(".tmp")
    temporary.write_text(json.dumps({
        "endpoint": f"http://127.0.0.1:{PORT}/api/codex-events",
        "token": TOKEN,
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    temporary.replace(BRIDGE_FILE)


def load_codex_tasks() -> list[dict]:
    try:
        value = json.loads(CODEX_TASKS_FILE.read_text(encoding="utf-8"))
        return [
            item for item in value if isinstance(item, dict) and item.get("id")
        ][:CODEX_TASK_HISTORY_LIMIT]
    except (FileNotFoundError, json.JSONDecodeError, OSError, TypeError):
        return []


CODEX_TASKS_LOCK = threading.RLock()
CODEX_TASKS = load_codex_tasks()
SECURITY_AUDIT_LOCK = threading.RLock()
SECURITY_AUDIT_LAST: dict[tuple[str, str], float] = {}


def save_codex_tasks():
    STATE_ROOT.mkdir(parents=True, exist_ok=True)
    temporary = CODEX_TASKS_FILE.with_suffix(".tmp")
    temporary.write_text(
        json.dumps(CODEX_TASKS[:CODEX_TASK_HISTORY_LIMIT], ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    temporary.replace(CODEX_TASKS_FILE)


def _safe_audit_value(value: object, limit: int) -> str:
    clean = "".join(
        character if character.isprintable() and character not in "\r\n" else " "
        for character in str(value or "")
    )
    return clean.strip()[:limit]


def record_security_audit(
    client_ip: str,
    authorized: bool,
    method: str,
    request_path: str,
    user_agent: str = "",
    *,
    current_time: float | None = None,
) -> bool:
    event = "access_granted" if authorized else "access_denied"
    ip_address = _safe_audit_value(client_ip, 64) or "unknown"
    now_value = time.monotonic() if current_time is None else current_time
    window = (
        AUTH_SUCCESS_LOG_WINDOW_SECONDS
        if authorized
        else AUTH_FAILURE_LOG_WINDOW_SECONDS
    )
    key = (event, ip_address)
    with SECURITY_AUDIT_LOCK:
        previous = SECURITY_AUDIT_LAST.get(key)
        if previous is not None and now_value - previous < window:
            return False
        try:
            STATE_ROOT.mkdir(parents=True, exist_ok=True)
            if (
                SECURITY_AUDIT_FILE.exists()
                and SECURITY_AUDIT_FILE.stat().st_size >= SECURITY_AUDIT_MAX_BYTES
            ):
                SECURITY_AUDIT_BACKUP_FILE.unlink(missing_ok=True)
                SECURITY_AUDIT_FILE.replace(SECURITY_AUDIT_BACKUP_FILE)
            row = {
                "timestamp": now_iso(),
                "event": event,
                "ip_address": ip_address,
                "method": _safe_audit_value(method, 12).upper(),
                "path": _safe_audit_value(urlparse(request_path).path, 180),
                "user_agent": _safe_audit_value(user_agent, 180),
            }
            with SECURITY_AUDIT_FILE.open("a", encoding="utf-8") as output:
                output.write(json.dumps(row, ensure_ascii=False) + "\n")
            SECURITY_AUDIT_LAST[key] = now_value
            return True
        except OSError:
            return False


def security_audit_rows(limit: int = 50) -> list[dict]:
    bounded_limit = max(1, min(limit, 200))
    rows: list[dict] = []
    with SECURITY_AUDIT_LOCK:
        for source in (SECURITY_AUDIT_BACKUP_FILE, SECURITY_AUDIT_FILE):
            try:
                lines = source.read_text(encoding="utf-8").splitlines()
            except OSError:
                continue
            for line in lines:
                try:
                    value = json.loads(line)
                except (json.JSONDecodeError, TypeError):
                    continue
                if isinstance(value, dict) and value.get("ip_address"):
                    rows.append(value)
    return rows[-bounded_limit:][::-1]


def record_codex_event(payload: dict) -> dict:
    event_type = str(payload.get("type") or "agent-turn-complete")
    if event_type not in {"agent-turn-complete", "turn.completed", "turn/completed"}:
        raise ValueError("unsupported Codex event")
    thread_id = str(
        payload.get("thread-id")
        or payload.get("thread_id")
        or payload.get("threadId")
        or payload.get("conversation-id")
        or ""
    )
    turn_id = str(payload.get("turn-id") or payload.get("turn_id") or payload.get("turnId") or "")
    fingerprint = hashlib.sha256(
        json.dumps(payload, sort_keys=True, ensure_ascii=False).encode("utf-8")
    ).hexdigest()[:20]
    task_id = f"codex_{turn_id or fingerprint}"
    input_messages = payload.get("input-messages") or payload.get("input_messages") or []
    title = next(
        (str(value).strip() for value in reversed(input_messages) if str(value).strip()),
        "Codex task",
    )[:120]
    detail = str(
        payload.get("last-assistant-message")
        or payload.get("last_assistant_message")
        or "Task Codex selesai"
    ).strip()
    timestamp = now_iso()
    task = {
        "id": task_id,
        "session_id": thread_id,
        "title": title,
        "status": "completed",
        "detail": detail[:500] or "Task Codex selesai",
        "agents": ["codex"],
        "mode": "single",
        "source": "codex_desktop",
        "permission": "",
        "workspace": str(payload.get("cwd") or payload.get("workspace") or ""),
        "changedFiles": int(payload.get("changed-files") or payload.get("changed_files") or 0),
        "elapsedSeconds": int(payload.get("elapsed-seconds") or payload.get("elapsed_seconds") or 0),
        "idleSeconds": 0,
        "createdAt": str(payload.get("started-at") or payload.get("started_at") or timestamp),
        "updatedAt": timestamp,
    }
    with CODEX_TASKS_LOCK:
        CODEX_TASKS[:] = [item for item in CODEX_TASKS if item.get("id") != task_id]
        CODEX_TASKS.insert(0, task)
        del CODEX_TASKS[CODEX_TASK_HISTORY_LIMIT:]
        save_codex_tasks()
    return task


def _clean_codex_path(value: str) -> Path:
    normalized = str(value or "")
    if normalized.startswith("\\\\?\\"):
        normalized = normalized[4:]
    return Path(normalized)


def _rollout_tail(path: Path, maximum_bytes: int = CODEX_ROLLOUT_TAIL_BYTES) -> list[dict]:
    try:
        with path.open("rb") as stream:
            size = stream.seek(0, os.SEEK_END)
            start = max(0, size - maximum_bytes)
            stream.seek(start)
            raw = stream.read()
    except OSError:
        return []
    if start > 0:
        newline = raw.find(b"\n")
        raw = raw[newline + 1:] if newline >= 0 else b""
    rows = []
    for line in raw.splitlines():
        try:
            value = json.loads(line)
        except (json.JSONDecodeError, UnicodeDecodeError, TypeError):
            continue
        if isinstance(value, dict):
            rows.append(value)
    return rows


def _codex_progress_detail(row: dict, previous: str) -> str:
    payload = row.get("payload") if isinstance(row.get("payload"), dict) else {}
    outer_type = str(row.get("type") or "")
    event_type = str(payload.get("type") or "")
    if outer_type == "response_item" and event_type == "function_call":
        name = str(payload.get("name") or "tool").replace("_", " ")
        return f"Menjalankan {name}"[:300]
    if outer_type == "response_item" and event_type == "function_call_output":
        return "Memeriksa hasil proses"
    if outer_type != "event_msg":
        return previous
    if event_type == "agent_reasoning":
        text = re.sub(r"[*_#]", "", str(payload.get("text") or "")).strip()
        return text[:300] or previous
    if event_type in {"mcp_tool_call_begin", "exec_command_begin"}:
        return "Menjalankan tool di PC"
    if event_type in {"mcp_tool_call_end", "exec_command_end"}:
        return "Memeriksa hasil tool"
    if event_type == "agent_message":
        return "Menyusun hasil task"
    return previous


def _parse_codex_rollout(rows: list[dict]) -> dict | None:
    turn = None
    for row in rows:
        payload = row.get("payload") if isinstance(row.get("payload"), dict) else {}
        event_type = str(payload.get("type") or "")
        if row.get("type") == "event_msg" and event_type == "task_started":
            turn = {
                "turn_id": str(payload.get("turn_id") or ""),
                "started_at": str(row.get("timestamp") or now_iso()),
                "title": "",
                "detail": "Menganalisis task", "status": "running",
                "updated_at": str(row.get("timestamp") or now_iso()),
                "has_agent_message": False,
            }
            continue
        if turn is None:
            continue
        if row.get("type") == "event_msg" and event_type == "user_message":
            message = str(payload.get("message") or "").strip()
            if message:
                turn["title"] = re.sub(r"\s+", " ", message)[:120]
        if row.get("type") == "event_msg" and event_type == "agent_message":
            turn["has_agent_message"] = True
        turn["detail"] = _codex_progress_detail(row, turn["detail"])
        if row.get("timestamp"):
            turn["updated_at"] = str(row["timestamp"])
        if row.get("type") == "event_msg" and event_type in {"task_complete", "turn_aborted"}:
            event_turn = str(payload.get("turn_id") or "")
            if not event_turn or event_turn == turn["turn_id"]:
                turn["status"] = "completed" if event_type == "task_complete" else "stopped"
    return turn


def _cached_codex_turn(path: Path) -> dict | None:
    try:
        before = path.stat()
    except OSError:
        return None
    key = str(path)
    signature = (before.st_mtime_ns, before.st_size)
    with CODEX_ROLLOUT_CACHE_LOCK:
        cached = CODEX_ROLLOUT_CACHE.get(key)
        if cached and cached[:2] == signature:
            return dict(cached[2]) if cached[2] is not None else None
    turn = _parse_codex_rollout(_rollout_tail(path))
    try:
        after = path.stat()
    except OSError:
        return turn
    if (after.st_mtime_ns, after.st_size) == signature:
        with CODEX_ROLLOUT_CACHE_LOCK:
            CODEX_ROLLOUT_CACHE[key] = (signature[0], signature[1], dict(turn) if turn else None)
            while len(CODEX_ROLLOUT_CACHE) > CODEX_ROLLOUT_CACHE_MAX_ENTRIES:
                CODEX_ROLLOUT_CACHE.pop(next(iter(CODEX_ROLLOUT_CACHE)))
    return turn


def list_codex_desktop_tasks(db_path: Path | None = None, *, now: datetime | None = None) -> list[dict]:
    path = db_path or CODEX_STATE_DB
    if not path.exists():
        return []
    current_time = now or datetime.now(timezone.utc)
    try:
        connection = sqlite3.connect(f"file:{path.as_posix()}?mode=ro", uri=True, timeout=1)
        connection.row_factory = sqlite3.Row
        rows = connection.execute(
            "SELECT id, rollout_path, cwd, title, model, model_provider FROM threads "
            "WHERE archived = 0 ORDER BY updated_at_ms DESC LIMIT ?",
            (CODEX_DESKTOP_THREAD_LIMIT,),
        ).fetchall()
        connection.close()
    except sqlite3.Error:
        return []
    tasks = []
    for thread in rows:
        turn = _cached_codex_turn(_clean_codex_path(thread["rollout_path"]))
        if not turn or not turn["turn_id"]:
            continue
        turn["title"] = turn["title"] or str(thread["title"] or "Codex task")[:120]
        try:
            started = datetime.fromisoformat(turn["started_at"].replace("Z", "+00:00"))
        except ValueError:
            started = current_time
        try:
            updated = datetime.fromisoformat(turn["updated_at"].replace("Z", "+00:00"))
        except ValueError:
            updated = started
        inactive = max(0, int((current_time - updated.astimezone(timezone.utc)).total_seconds()))
        if turn["status"] == "running" and (
            inactive >= CODEX_DESKTOP_ORPHAN_SECONDS
            or turn["has_agent_message"] and inactive >= CODEX_DESKTOP_STALE_SECONDS
        ):
            turn["status"] = "stopped"
            turn["detail"] = "Tracking ditutup - rollout Codex sudah tidak aktif"
        ended = current_time if turn["status"] == "running" else updated
        elapsed = max(0, int((ended - started.astimezone(timezone.utc)).total_seconds()))
        if turn["status"] != "running" and elapsed > 86400:
            continue
        provider = str(thread["model_provider"] or "codex")
        model = str(thread["model"] or "")
        detail = turn["detail"] + (f" • {model} via {provider}" if model else "")
        tasks.append({
            "id": f"codex_{turn['turn_id']}", "session_id": str(thread["id"] or ""),
            "title": turn["title"], "status": turn["status"], "detail": detail[:500],
            "agents": ["codex"], "activeAgent": "codex" if turn["status"] == "running" else "",
            "agentStates": [{"id": "codex", "name": "Codex", "status": turn["status"],
                "phase": "thinking" if turn["status"] == "running" else turn["status"],
                "detail": detail[:300], "role": "agent", "elapsedSeconds": elapsed,
                "idleSeconds": inactive, "startedAt": turn["started_at"], "updatedAt": turn["updated_at"],
                "completedAt": turn["updated_at"] if turn["status"] != "running" else None}],
            "mode": "single", "source": "codex_desktop", "permission": "",
            "workspace": str(_clean_codex_path(thread["cwd"])), "changedFiles": 0,
            "elapsedSeconds": elapsed, "idleSeconds": inactive,
            "createdAt": turn["started_at"], "updatedAt": turn["updated_at"],
        })
    return tasks


def _windows_process_rows() -> list[dict]:
    if os.name != "nt":
        return []
    try:
        from ctypes import wintypes

        class ProcessEntry(ctypes.Structure):
            _fields_ = [
                ("dwSize", wintypes.DWORD),
                ("cntUsage", wintypes.DWORD),
                ("th32ProcessID", wintypes.DWORD),
                ("th32DefaultHeapID", ctypes.c_size_t),
                ("th32ModuleID", wintypes.DWORD),
                ("cntThreads", wintypes.DWORD),
                ("th32ParentProcessID", wintypes.DWORD),
                ("pcPriClassBase", wintypes.LONG),
                ("dwFlags", wintypes.DWORD),
                ("szExeFile", wintypes.WCHAR * 260),
            ]

        class UnicodeString(ctypes.Structure):
            _fields_ = [
                ("Length", wintypes.USHORT),
                ("MaximumLength", wintypes.USHORT),
                ("Buffer", ctypes.c_void_p),
            ]

        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        ntdll = ctypes.WinDLL("ntdll")
        kernel32.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
        kernel32.OpenProcess.restype = wintypes.HANDLE
        snapshot = kernel32.CreateToolhelp32Snapshot(0x00000002, 0)
        if snapshot == ctypes.c_void_p(-1).value:
            return []
        rows = []
        entry = ProcessEntry()
        entry.dwSize = ctypes.sizeof(entry)
        found = kernel32.Process32FirstW(snapshot, ctypes.byref(entry))
        try:
            while found:
                executable = str(entry.szExeFile).lower()
                if executable in PC_AGENT_EXECUTABLES or executable in PC_AGENT_WRAPPERS:
                    handle = kernel32.OpenProcess(0x1000, False, entry.th32ProcessID)
                    if handle:
                        try:
                            command_line = ""
                            needed = wintypes.ULONG()
                            ntdll.NtQueryInformationProcess(handle, 60, None, 0, ctypes.byref(needed))
                            if 0 < needed.value <= 131072:
                                buffer = ctypes.create_string_buffer(needed.value)
                                status = ntdll.NtQueryInformationProcess(
                                    handle, 60, buffer, needed.value, ctypes.byref(needed)
                                )
                                if status == 0:
                                    value = ctypes.cast(
                                        buffer, ctypes.POINTER(UnicodeString)
                                    ).contents
                                    if value.Buffer and value.Length:
                                        command_line = ctypes.wstring_at(
                                            value.Buffer, value.Length // 2
                                        )
                            path_buffer = ctypes.create_unicode_buffer(32768)
                            path_size = wintypes.DWORD(len(path_buffer))
                            process_path = ""
                            if kernel32.QueryFullProcessImageNameW(
                                handle, 0, path_buffer, ctypes.byref(path_size)
                            ):
                                process_path = path_buffer.value
                            created = wintypes.FILETIME()
                            exited = wintypes.FILETIME()
                            kernel_time = wintypes.FILETIME()
                            user_time = wintypes.FILETIME()
                            created_at = ""
                            if kernel32.GetProcessTimes(
                                handle,
                                ctypes.byref(created),
                                ctypes.byref(exited),
                                ctypes.byref(kernel_time),
                                ctypes.byref(user_time),
                            ):
                                ticks = (created.dwHighDateTime << 32) | created.dwLowDateTime
                                created_at = datetime.fromtimestamp(
                                    ticks / 10_000_000 - 11_644_473_600,
                                    tz=timezone.utc,
                                ).isoformat()
                            rows.append({
                                "pid": int(entry.th32ProcessID),
                                "executable": executable,
                                "path": process_path,
                                "command_line": command_line,
                                "created_at": created_at,
                            })
                        finally:
                            kernel32.CloseHandle(handle)
                found = kernel32.Process32NextW(snapshot, ctypes.byref(entry))
        finally:
            kernel32.CloseHandle(snapshot)
        return rows
    except (AttributeError, OSError, ValueError):
        return []


def _process_agent_id(row: dict) -> str:
    executable = str(row.get("executable") or "").lower()
    command_line = str(row.get("command_line") or "").lower()
    process_path = str(row.get("path") or "").lower()
    agent_id = PC_AGENT_EXECUTABLES.get(executable, "")
    if agent_id == "codex" and (
        "windowsapps\\openai.codex_" in process_path or " app-server " in command_line
    ):
        return ""
    if agent_id:
        return agent_id
    if executable not in PC_AGENT_WRAPPERS:
        return ""
    for candidate, markers in PC_AGENT_COMMAND_MARKERS.items():
        if any(marker in command_line for marker in markers):
            return candidate
    return ""


def _pc_agent_task(agent_id: str, state: dict, status: str, timestamp: str) -> dict:
    name = PC_AGENT_DISPLAY_NAMES.get(agent_id, agent_id.replace("-", " ").title())
    started_at = str(state.get("created_at") or timestamp)
    try:
        started = datetime.fromisoformat(started_at.replace("Z", "+00:00"))
        ended = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
        elapsed = max(0, int((ended - started.astimezone(timezone.utc)).total_seconds()))
    except ValueError:
        elapsed = 0
    process_count = max(1, int(state.get("process_count") or 1))
    running = status == "running"
    detail = (
        f"{name} aktif di PC • {process_count} proses terdeteksi"
        if running
        else f"Proses {name} selesai atau ditutup"
    )
    task_id = f"pc_agent_{agent_id}" if running else f"pc_agent_{agent_id}_{int(time.time())}"
    return {
        "id": task_id,
        "session_id": "",
        "title": f"{name} aktif di PC" if running else f"{name} selesai",
        "status": status,
        "detail": detail,
        "agents": [agent_id],
        "activeAgent": agent_id if running else "",
        "agentStates": [{
            "id": agent_id,
            "name": name,
            "status": status,
            "phase": "running_command" if running else "completed",
            "detail": detail,
            "role": "agent",
            "elapsedSeconds": elapsed,
            "idleSeconds": 0,
            "startedAt": started_at,
            "updatedAt": timestamp,
            "completedAt": None if running else timestamp,
        }],
        "mode": "single",
        "source": "pc_process",
        "permission": "",
        "workspace": "",
        "changedFiles": 0,
        "elapsedSeconds": elapsed,
        "idleSeconds": 0,
        "createdAt": started_at,
        "updatedAt": timestamp,
    }


def list_pc_agent_tasks() -> list[dict]:
    global PC_AGENT_PROCESS_CACHE, PC_AGENT_ACTIVE
    current = time.monotonic()
    with PC_AGENT_PROCESS_LOCK:
        if (
            PC_AGENT_PROCESS_CACHE
            and current - PC_AGENT_PROCESS_CACHE[0] < PC_AGENT_PROCESS_CACHE_SECONDS
        ):
            return json.loads(json.dumps(PC_AGENT_PROCESS_CACHE[1]))
    detected: dict[str, dict] = {}
    for row in _windows_process_rows():
        agent_id = _process_agent_id(row)
        if not agent_id:
            continue
        state = detected.setdefault(agent_id, {
            "created_at": row.get("created_at") or now_iso(),
            "process_count": 0,
        })
        state["process_count"] += 1
        if row.get("created_at") and row["created_at"] < state["created_at"]:
            state["created_at"] = row["created_at"]
    timestamp = now_iso()
    with PC_AGENT_PROCESS_LOCK:
        for agent_id, previous in PC_AGENT_ACTIVE.items():
            if agent_id not in detected:
                completed = _pc_agent_task(agent_id, previous, "completed", timestamp)
                PC_AGENT_RECENT[:] = [
                    completed,
                    *[item for item in PC_AGENT_RECENT if item.get("agents") != [agent_id]],
                ][:TASK_LIST_MAX_ITEMS]
        PC_AGENT_ACTIVE = detected
        running = [
            _pc_agent_task(agent_id, state, "running", timestamp)
            for agent_id, state in detected.items()
        ]
        tasks = [*running, *PC_AGENT_RECENT][:TASK_LIST_MAX_ITEMS]
        PC_AGENT_PROCESS_CACHE = (current, json.loads(json.dumps(tasks)))
        return tasks


def _task_priority(item: dict) -> int:
    status = str(item.get("status") or "")
    if status in {"running", "queued", "generating"}:
        return 0
    if status in {
        "completed", "failed", "stopped", "error",
        "waiting_approval", "waiting_clarification",
    }:
        return 1
    return 2


def list_all_tasks() -> list[dict]:
    global TASK_LIST_CACHE
    current = time.monotonic()
    with TASK_LIST_CACHE_LOCK:
        if TASK_LIST_CACHE and current - TASK_LIST_CACHE[0] < TASK_LIST_CACHE_SECONDS:
            return json.loads(json.dumps(TASK_LIST_CACHE[1]))
    with CODEX_TASKS_LOCK:
        external = json.loads(json.dumps(CODEX_TASKS))
    combined = external + list_codex_desktop_tasks() + RUNTIME.list_tasks()
    covered_active_agents = {
        str(agent_id)
        for item in combined
        if str(item.get("status") or "") in {"running", "queued", "generating"}
        for agent_id in item.get("agents", [])
    }
    combined += [
        item for item in list_pc_agent_tasks()
        if item.get("status") != "running"
        or not covered_active_agents.intersection(item.get("agents", []))
    ]
    values = {str(item.get("id") or index): item for index, item in enumerate(combined)}
    tasks = sorted(values.values(), key=lambda item: item.get("updatedAt", ""), reverse=True)
    tasks.sort(key=_task_priority)
    tasks = tasks[:TASK_LIST_MAX_ITEMS]
    with TASK_LIST_CACHE_LOCK:
        TASK_LIST_CACHE = (current, json.loads(json.dumps(tasks)))
    return tasks


SERVER_STATE = load_server_state()
PERMISSION_BY_WORKSPACE = {
    str(path): mode
    for path, mode in SERVER_STATE.get("permission_by_workspace", {}).items()
    if mode in {"ask", "workspace", "full"}
}
RECENT_WORKSPACES = [
    str(Path(value).resolve())
    for value in SERVER_STATE.get("recent_workspaces", [])
    if isinstance(value, str) and Path(value).is_dir()
]
_last_workspace = Path(str(SERVER_STATE.get("last_workspace") or Path.home())).resolve()
WORKSPACE = _last_workspace if _last_workspace.is_dir() else Path.home().resolve()
if str(WORKSPACE) not in RECENT_WORKSPACES:
    RECENT_WORKSPACES.insert(0, str(WORKSPACE))


def resolve_child(workspace: Path, relative: str) -> Path:
    if Path(relative).is_absolute():
        raise ValueError("absolute paths are not allowed")
    child = (workspace / relative).resolve()
    if not child.is_relative_to(workspace):
        raise ValueError("path escapes workspace")
    return child


def parse_git_status(raw: str) -> list[dict]:
    files = []
    for row in filter(None, raw.split("\0")):
        code, path = row[:2], row[3:]
        status = (
            "untracked" if code == "??" else
            "added" if "A" in code else
            "deleted" if "D" in code else
            "modified"
        )
        files.append({"path": path, "status": status})
    return files


def _git(workspace: Path, *args: str, timeout: int = 15) -> subprocess.CompletedProcess:
    command = ["git", *args]
    try:
        return subprocess.run(
            command,
            cwd=workspace,
            text=True,
            capture_output=True,
            timeout=timeout,
            creationflags=CREATE_NO_WINDOW,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return subprocess.CompletedProcess(command, 124, "", str(error))


def _commit_rows(raw: str) -> list[dict]:
    commits = []
    for row in raw.splitlines():
        parts = row.split("\x1f", 2)
        if len(parts) == 3:
            commits.append({"hash": parts[0], "subject": parts[1], "author": parts[2]})
    return commits


def _git_line_changes(workspace: Path) -> tuple[int, int]:
    result = _git(workspace, "diff", "--numstat", "HEAD")
    if result.returncode != 0:
        result = _git(workspace, "diff", "--numstat")
    additions = deletions = 0
    for row in result.stdout.splitlines():
        parts = row.split("\t", 2)
        if len(parts) < 2:
            continue
        if parts[0].isdigit():
            additions += int(parts[0])
        if parts[1].isdigit():
            deletions += int(parts[1])
    return additions, deletions


def github_cli_status() -> dict:
    global GITHUB_CLI_CACHE
    now = time.monotonic()
    with GIT_CACHE_LOCK:
        if GITHUB_CLI_CACHE and now - GITHUB_CLI_CACHE[0] < GITHUB_CLI_CACHE_SECONDS:
            return json.loads(json.dumps(GITHUB_CLI_CACHE[1]))
    executable = shutil.which("gh")
    if not executable:
        value = {"installed": False, "authenticated": False, "user": ""}
        with GIT_CACHE_LOCK:
            GITHUB_CLI_CACHE = (now, value)
        return value
    try:
        result = subprocess.run(
            [executable, "auth", "status", "--hostname", "github.com"],
            text=True,
            capture_output=True,
            timeout=5,
            creationflags=CREATE_NO_WINDOW,
        )
    except (OSError, subprocess.TimeoutExpired):
        value = {"installed": True, "authenticated": False, "user": ""}
        with GIT_CACHE_LOCK:
            GITHUB_CLI_CACHE = (now, value)
        return value
    output = f"{result.stdout}\n{result.stderr}"
    match = re.search(r"account\s+([^\s(]+)", output, flags=re.IGNORECASE)
    value = {
        "installed": True,
        "authenticated": result.returncode == 0,
        "user": match.group(1) if match else "",
    }
    with GIT_CACHE_LOCK:
        GITHUB_CLI_CACHE = (now, value)
    return json.loads(json.dumps(value))


def _usage_cutoff(range_name: str, now: datetime) -> datetime:
    if range_name == "today":
        local_now = now.astimezone()
        return local_now.replace(hour=0, minute=0, second=0, microsecond=0).astimezone(
            timezone.utc
        )
    duration = {
        "24h": timedelta(hours=24),
        "7d": timedelta(days=7),
        "30d": timedelta(days=30),
        "60d": timedelta(days=60),
    }.get(range_name)
    if duration is None:
        raise ValueError("invalid usage range")
    return now - duration


def _token_breakdown(raw: str | None) -> dict:
    try:
        value = json.loads(raw or "{}")
    except json.JSONDecodeError:
        return {}
    return value if isinstance(value, dict) else {}


def _quota_reset_at(value: object) -> str | None:
    if isinstance(value, (int, float)):
        try:
            return datetime.fromtimestamp(value, timezone.utc).isoformat().replace("+00:00", "Z")
        except (OverflowError, OSError, ValueError):
            return None
    return value if isinstance(value, str) and value else None


def nine_router_mobile_key(db_path: Path | None = None) -> str:
    configured = os.environ.get('AGENT_REMOTE_9ROUTER_MOBILE_KEY', '').strip()
    if configured:
        return configured
    path = (db_path or NINE_ROUTER_DB).resolve()
    if not path.is_file():
        return ''
    try:
        connection = sqlite3.connect(
            f'file:{path.as_posix()}?mode=ro',
            uri=True,
            timeout=2,
        )
        row = connection.execute(
            '''
            SELECT key
            FROM apiKeys
            WHERE name = ? AND isActive = 1
            ORDER BY createdAt DESC
            LIMIT 1
            ''',
            [MOBILE_KEY_NAME],
        ).fetchone()
        connection.close()
    except sqlite3.Error:
        return ''
    return str(row[0]) if row and row[0] else ''


def _codex_quota(connection_id: str, data: dict) -> dict:
    cached = NINE_ROUTER_QUOTA_CACHE.get(connection_id)
    if cached and time.monotonic() - cached[0] < NINE_ROUTER_QUOTA_CACHE_SECONDS:
        return cached[1]
    access_token = str(data.get("accessToken") or "")
    if not access_token:
        return {"status": "unavailable", "quotas": [], "error": "Access token tidak tersedia"}
    request = urllib.request.Request(
        "https://chatgpt.com/backend-api/wham/usage",
        headers={"Authorization": f"Bearer {access_token}", "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=4) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except (OSError, urllib.error.URLError, urllib.error.HTTPError, json.JSONDecodeError) as error:
        result = {"status": "error", "quotas": [], "error": str(error)[:160]}
        NINE_ROUTER_QUOTA_CACHE[connection_id] = (time.monotonic(), result)
        return result

    def windows(value: object, prefix: str = "") -> list[dict]:
        rate = value.get("rate_limit", value) if isinstance(value, dict) else {}
        if not isinstance(rate, dict):
            return []
        rows = []
        for key, label in (("primary_window", "Sesi 5 jam"), ("secondary_window", "Mingguan")):
            window = rate.get(key)
            if not isinstance(window, dict):
                continue
            used = max(0.0, min(100.0, float(window.get("used_percent") or window.get("percent_used") or 0)))
            rows.append({
                "id": f"{prefix}{'session' if key == 'primary_window' else 'weekly'}",
                "label": f"{prefix.title() + ' ' if prefix else ''}{label}",
                "used_percent": used, "remaining_percent": max(0.0, 100.0 - used),
                "reset_at": _quota_reset_at(
                    window.get("reset_at") or window.get("resets_at") or window.get("resetAt")
                ),
            })
        return rows

    primary = payload.get("rate_limit") or payload.get("rate_limits") or {}
    review = payload.get("code_review_rate_limit") or payload.get("review_rate_limit") or {}
    result = {
        "status": "active", "plan": payload.get("plan_type") or "unknown",
        "limit_reached": bool(primary.get("limit_reached")) if isinstance(primary, dict) else False,
        "quotas": windows(primary) + windows(review, "review"), "error": "",
    }
    NINE_ROUTER_QUOTA_CACHE[connection_id] = (time.monotonic(), result)
    return result


def nine_router_quota_accounts(db_path: Path | None = None) -> list[dict]:
    path = (db_path or NINE_ROUTER_DB).resolve()
    if not path.is_file():
        return []
    try:
        connection = sqlite3.connect(f"file:{path.as_posix()}?mode=ro", uri=True, timeout=2)
        connection.row_factory = sqlite3.Row
        tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if "providerConnections" not in tables:
            connection.close()
            return []
        usage_columns = {
            row[1] for row in connection.execute("PRAGMA table_info(usageHistory)")
        } if "usageHistory" in tables else set()
        model_sql = (
            "(SELECT model FROM usageHistory u WHERE u.connectionId = p.id "
            "ORDER BY u.timestamp DESC LIMIT 1) AS latestModel"
            if {"connectionId", "model", "timestamp"}.issubset(usage_columns)
            else "NULL AS latestModel"
        )
        rows = connection.execute(
            f"SELECT p.id,p.provider,p.name,p.email,p.authType,p.isActive,p.data,{model_sql} "
            "FROM providerConnections p ORDER BY p.isActive DESC,p.provider,p.name"
        ).fetchall()
        connection.close()
    except sqlite3.Error:
        return []
    accounts = []
    for row in rows:
        try:
            data = json.loads(row["data"] or "{}")
        except json.JSONDecodeError:
            data = {}
        live = _codex_quota(str(row["id"]), data) if row["provider"] == "codex" and row["isActive"] else {
            "status": "inactive" if not row["isActive"] else str(data.get("testStatus") or "unavailable"),
            "quotas": [], "plan": "", "error": str(data.get("lastError") or "")[:160],
        }
        accounts.append({
            "id": row["id"], "provider": row["provider"],
            "name": row["name"] or row["email"] or row["provider"],
            "active": bool(row["isActive"]), "auth_type": row["authType"],
            "status": live.get("status", "unknown"), "plan": live.get("plan", ""),
            "model": row["latestModel"] or data.get("defaultModel") or "",
            "last_used_at": data.get("lastUsedAt"), "quotas": live.get("quotas", []),
            "limit_reached": bool(live.get("limit_reached")), "error": live.get("error", ""),
        })
    return accounts


def agent_environment(agent_id: str) -> dict[str, str]:
    if agent_id != 'codex':
        return {}
    mobile_key = nine_router_mobile_key()
    return {
        MOBILE_KEY_ENV: mobile_key,
        'NINE_ROUTER_API_KEY': mobile_key,
    } if mobile_key else {}


def provider_usage(
    range_name: str = "24h",
    provider: str = "",
    model: str = "",
    scope: str = 'all',
    limit: int = 50,
    db_path: Path | None = None,
    now: datetime | None = None,
) -> dict:
    path = (db_path or NINE_ROUTER_DB).resolve()
    now = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    cutoff = _usage_cutoff(range_name, now)
    safe_limit = max(1, min(limit, 100))
    if scope not in {'all', 'mobile'}:
        raise ValueError('invalid usage scope')
    mobile_key = nine_router_mobile_key(path)
    mobile_filter_available = bool(mobile_key)
    empty = {
        "available": False,
        "source": "9router",
        "range": range_name,
        "summary": {
            "requests": 0,
            "input_tokens": 0,
            "output_tokens": 0,
            "cached_tokens": 0,
            "estimated_cost": 0.0,
        },
        "active": None,
        "providers": [],
        "models": [],
        "recent": [],
        "quota_accounts": [],
        "attribution": "all_9router_requests_on_pc",
    }
    empty.update({
        'scope': scope,
        'mobile_filter_available': mobile_filter_available,
        'mobile_key_name': MOBILE_KEY_NAME,
        'attribution': (
            'agent_remote_mobile_key'
            if scope == 'mobile'
            else 'all_9router_requests_on_pc'
        ),
    })
    if not path.is_file():
        return {**empty, "reason": "9Router database not found"}
    clauses = ["timestamp >= ?"]
    parameters: list[object] = [cutoff.isoformat().replace("+00:00", "Z")]
    if scope == 'mobile':
        if not mobile_key:
            return {
                **empty,
                'available': True,
                'reason': (
                    f'Buat API key 9Router bernama {MOBILE_KEY_NAME} untuk '
                    'memisahkan konsumsi task HP.'
                ),
                'updated_at': now_iso(),
            }
        clauses.append('apiKey = ?')
        parameters.append(mobile_key)
    filter_clauses = list(clauses)
    filter_parameters = list(parameters)
    if provider:
        clauses.append("provider = ?")
        parameters.append(provider)
    if model:
        clauses.append("model = ?")
        parameters.append(model)
    where = " AND ".join(clauses)
    try:
        connection = sqlite3.connect(
            f"file:{path.as_posix()}?mode=ro",
            uri=True,
            timeout=2,
        )
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA query_only = ON")
        table = connection.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='usageHistory'"
        ).fetchone()
        if table is None:
            connection.close()
            return {**empty, "reason": "9Router usage schema unavailable"}
        summary_row = connection.execute(
            f"""
            SELECT COUNT(*) AS requests,
                   COALESCE(SUM(promptTokens), 0) AS input_tokens,
                   COALESCE(SUM(completionTokens), 0) AS output_tokens,
                   COALESCE(SUM(cost), 0) AS estimated_cost,
                   COALESCE(SUM(
                       CASE WHEN json_valid(tokens)
                            THEN CAST(json_extract(tokens, '$.cached_tokens') AS INTEGER)
                            ELSE 0 END
                   ), 0) AS cached_tokens
            FROM usageHistory
            WHERE {where}
            """,
            parameters,
        ).fetchone()
        rows = connection.execute(
            f"""
            SELECT timestamp, provider, model, endpoint, promptTokens,
                   completionTokens, cost, status, tokens
            FROM usageHistory
            WHERE {where}
            ORDER BY timestamp DESC
            LIMIT ?
            """,
            [*parameters, safe_limit],
        ).fetchall()
        filter_rows = connection.execute(
            f"""
            SELECT DISTINCT provider, model
            FROM usageHistory
            WHERE {' AND '.join(filter_clauses)}
            ORDER BY provider, model
            """,
            filter_parameters,
        ).fetchall()
        connection.close()
    except sqlite3.Error:
        return {**empty, "reason": "9Router database is busy or unreadable"}
    recent = []
    for row in rows:
        tokens = _token_breakdown(row["tokens"])
        cached = int(tokens.get("cached_tokens") or 0)
        prompt = int(row["promptTokens"] or 0)
        completion = int(row["completionTokens"] or 0)
        cost = float(row["cost"] or 0)
        recent.append(
            {
                "timestamp": row["timestamp"],
                "provider": row["provider"] or "unknown",
                "model": row["model"] or "unknown",
                "endpoint": row["endpoint"] or "",
                "input_tokens": prompt,
                "output_tokens": completion,
                "cached_tokens": cached,
                "cost": cost,
                "status": row["status"] or "unknown",
            }
        )
    active = recent[0] if recent else None
    if active:
        try:
            timestamp = datetime.fromisoformat(active["timestamp"].replace("Z", "+00:00"))
            active = {
                **active,
                "is_active": now - timestamp.astimezone(timezone.utc) <= timedelta(minutes=2),
            }
        except ValueError:
            active = {**active, "is_active": False}
    return {
        "available": True,
        "source": "9router",
        "range": range_name,
        "summary": {
            "requests": int(summary_row["requests"] or 0),
            "input_tokens": int(summary_row["input_tokens"] or 0),
            "output_tokens": int(summary_row["output_tokens"] or 0),
            "cached_tokens": int(summary_row["cached_tokens"] or 0),
            "estimated_cost": float(summary_row["estimated_cost"] or 0),
        },
        "active": active,
        "providers": sorted({row["provider"] for row in filter_rows if row["provider"]}),
        "models": sorted({row["model"] for row in filter_rows if row["model"]}),
        "recent": recent,
        "quota_accounts": nine_router_quota_accounts(path),
        "updated_at": now_iso(),
        'scope': scope,
        'mobile_filter_available': mobile_filter_available,
        'mobile_key_name': MOBILE_KEY_NAME,
        'attribution': (
            'agent_remote_mobile_key'
            if scope == 'mobile'
            else 'all_9router_requests_on_pc'
        ),
    }


def _git_cache_key(workspace: Path) -> str:
    return os.path.normcase(str(workspace.resolve()))


def _git_status_lock(workspace: Path) -> threading.Lock:
    key = _git_cache_key(workspace)
    with GIT_CACHE_LOCK:
        return GIT_STATUS_LOCKS.setdefault(key, threading.Lock())


def discover_nested_git_repositories(
    workspace: Path,
    max_depth: int = 3,
    limit: int = 20,
) -> list[dict]:
    key = _git_cache_key(workspace)
    now = time.monotonic()
    with GIT_CACHE_LOCK:
        cached = GIT_DISCOVERY_CACHE.get(key)
        if cached and now - cached[0] < GIT_DISCOVERY_CACHE_SECONDS:
            return json.loads(json.dumps(cached[1]))
    repositories = []
    pending = [(workspace, 0)]
    visited = 0
    while pending and len(repositories) < limit and visited < 400:
        current, depth = pending.pop(0)
        try:
            children = sorted(current.iterdir(), key=lambda path: path.name.casefold())
        except OSError:
            continue
        for child in children:
            if len(repositories) >= limit or visited >= 400:
                break
            if not child.is_dir() or child.is_symlink() or child.name in GIT_DISCOVERY_SKIP:
                continue
            visited += 1
            if (child / ".git").exists():
                repositories.append({"name": child.name, "path": str(child.resolve())})
            elif depth + 1 < max_depth:
                pending.append((child, depth + 1))
    with GIT_CACHE_LOCK:
        GIT_DISCOVERY_CACHE[key] = (now, repositories)
    return json.loads(json.dumps(repositories))


def _git_remote_status(workspace: Path, fetch: bool) -> dict:
    key = _git_cache_key(workspace)
    now = time.monotonic()
    with GIT_CACHE_LOCK:
        cached = GIT_REMOTE_CACHE.get(key)
        if not fetch and cached and now - cached[0] < GIT_REMOTE_CACHE_SECONDS:
            return json.loads(json.dumps(cached[1]))
    if fetch:
        _git(workspace, "fetch", "--quiet", "--prune", timeout=30)
    branch = _git(workspace, "branch", "--show-current").stdout.strip()
    remote_url = _git(workspace, "remote", "get-url", "origin").stdout.strip()
    upstream = _git(workspace, "rev-parse", "--abbrev-ref", "@{upstream}")
    upstream_ref = ""
    ahead = behind = 0
    incoming = []
    outgoing = []
    if upstream.returncode == 0:
        upstream_ref = upstream.stdout.strip()
        counts = _git(workspace, "rev-list", "--left-right", "--count", f"{upstream_ref}...HEAD")
        if counts.returncode == 0:
            values = counts.stdout.split()
            if len(values) == 2:
                behind, ahead = map(int, values)
        fmt = "--format=%h%x1f%s%x1f%an"
        outgoing = _commit_rows(_git(workspace, "log", fmt, "-n", "20", f"{upstream_ref}..HEAD").stdout)
        incoming = _commit_rows(_git(workspace, "log", fmt, "-n", "20", f"HEAD..{upstream_ref}").stdout)
    github_owner = ""
    github_repo = ""
    match = re.search(r"github\.com[/:]([^/]+)/([^/]+?)(?:\.git)?$", remote_url)
    if match:
        github_owner, github_repo = match.group(1), match.group(2)
    github_cli = github_cli_status()
    value = {
        "branch": branch,
        "remote_url": remote_url,
        "ahead": ahead,
        "behind": behind,
        "upstream": upstream_ref,
        "github_cli_installed": github_cli["installed"],
        "github_cli_authenticated": github_cli["authenticated"],
        "github_cli_user": github_cli["user"],
        "incoming": incoming,
        "outgoing": outgoing,
        "github_owner": github_owner,
        "github_repo": github_repo,
        "github_avatar_url": f"https://github.com/{github_owner}.png?size=128" if github_owner else "",
    }
    with GIT_CACHE_LOCK:
        GIT_REMOTE_CACHE[key] = (time.monotonic(), value)
    return json.loads(json.dumps(value))


def git_status(workspace: Path, fetch: bool = False) -> dict:
    key = _git_cache_key(workspace)
    with _git_status_lock(workspace):
        now = time.monotonic()
        with GIT_CACHE_LOCK:
            cached = GIT_STATUS_CACHE.get(key)
            if not fetch and cached and now - cached[0] < GIT_STATUS_CACHE_SECONDS:
                return json.loads(json.dumps(cached[1]))
        result = _git(workspace, "status", "--porcelain=v1", "-z")
        if result.returncode != 0:
            value = {
                "workspace_path": str(workspace),
                "is_git_repo": False,
                "files": [],
                "branch": "",
                "remote_url": "",
                "ahead": 0,
                "behind": 0,
                "upstream": "",
                "additions": 0,
                "deletions": 0,
                "github_cli_installed": shutil.which("gh") is not None,
                "github_cli_authenticated": False,
                "github_cli_user": "",
                "incoming": [],
                "outgoing": [],
                "github_owner": "",
                "github_repo": "",
                "github_avatar_url": "",
                "nested_repositories": discover_nested_git_repositories(workspace),
            }
        else:
            additions, deletions = _git_line_changes(workspace)
            value = {
                "workspace_path": str(workspace),
                "is_git_repo": True,
                "files": parse_git_status(result.stdout),
                "additions": additions,
                "deletions": deletions,
                "nested_repositories": [],
                **_git_remote_status(workspace, fetch),
            }
        with GIT_CACHE_LOCK:
            GIT_STATUS_CACHE[key] = (time.monotonic(), value)
        return json.loads(json.dumps(value))


def tree(workspace: Path, relative: str) -> dict:
    directory = resolve_child(workspace, relative)
    if not directory.is_dir():
        raise ValueError("directory not found")
    entries = []
    for child in sorted(directory.iterdir(), key=lambda p: (not p.is_dir(), p.name.lower()))[:500]:
        if child.name in SKIP or child.name.startswith("."):
            continue
        entries.append({
            "name": child.name,
            "path": child.relative_to(workspace).as_posix(),
            "kind": "directory" if child.is_dir() else "file",
        })
    return {"path": relative, "entries": entries}


def _read_text_bytes(raw: bytes) -> str:
    if len(raw) > MAX_TEXT_FILE_BYTES:
        raise ValueError('file exceeds 512 KB edit limit')
    if b'\x00' in raw[:8192]:
        raise ValueError('binary files cannot be previewed')
    try:
        return raw.decode('utf-8')
    except UnicodeDecodeError as error:
        raise ValueError('file is not valid UTF-8 text') from error


def _git_file_status(workspace: Path, relative: str) -> str:
    try:
        result = _git(
            workspace,
            'status',
            '--porcelain=v1',
            '-z',
            '--',
            relative,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ''
    rows = parse_git_status(result.stdout) if result.returncode == 0 else []
    return str(rows[0]['status']) if rows else ''


def _git_file_diff(workspace: Path, relative: str, content: str, exists: bool) -> str:
    try:
        result = _git(
            workspace,
            'diff',
            '--no-color',
            '--no-ext-diff',
            '--unified=3',
            'HEAD',
            '--',
            relative,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ''
    if result.returncode == 0 and result.stdout:
        return result.stdout
    if exists and _git_file_status(workspace, relative) == 'untracked':
        return '\n'.join(difflib.unified_diff(
            [],
            content.splitlines(),
            fromfile='/dev/null',
            tofile=f'b/{relative}',
            lineterm='',
        ))
    return ''


def workspace_file(workspace: Path, relative: str) -> dict:
    relative = relative.strip().replace('\\', '/')
    if not relative:
        raise ValueError('file path is required')
    path = resolve_child(workspace, relative)
    exists = path.is_file()
    status = _git_file_status(workspace, relative)
    if exists:
        raw = path.read_bytes()
        modified_at = datetime.fromtimestamp(
            path.stat().st_mtime, timezone.utc
        ).isoformat()
    elif status == 'deleted':
        result = _git(workspace, 'show', f'HEAD:{relative}')
        if result.returncode != 0:
            raise ValueError('file not found')
        raw = result.stdout.encode('utf-8')
        modified_at = None
    else:
        raise ValueError('file not found')
    content = _read_text_bytes(raw)
    return {
        'path': relative,
        'name': Path(relative).name,
        'content': content,
        'diff': _git_file_diff(workspace, relative, content, exists),
        'hash': hashlib.sha256(raw).hexdigest(),
        'size': len(raw),
        'line_count': content.count('\n') + 1,
        'modified_at': modified_at,
        'exists': exists,
        'editable': exists and os.access(path, os.W_OK),
        'git_status': status,
        'max_bytes': MAX_TEXT_FILE_BYTES,
    }


def save_workspace_file(
    workspace: Path,
    relative: str,
    content: str,
    base_hash: str,
) -> dict:
    path = resolve_child(workspace, relative.strip().replace('\\', '/'))
    if not path.is_file():
        raise ValueError('file not found')
    current = workspace_file(workspace, relative)
    if not base_hash or base_hash != current['hash']:
        raise FileConflictError('file changed on PC; reload before saving')
    encoded = content.encode('utf-8')
    if len(encoded) > MAX_TEXT_FILE_BYTES:
        raise ValueError('file exceeds 512 KB edit limit')
    mode = stat.S_IMODE(path.stat().st_mode)
    temporary_path = None
    try:
        with tempfile.NamedTemporaryFile(
            mode='wb',
            dir=path.parent,
            prefix=f'.{path.name}.',
            suffix='.agent-remote.tmp',
            delete=False,
        ) as temporary:
            temporary.write(encoded)
            temporary.flush()
            os.fsync(temporary.fileno())
            temporary_path = Path(temporary.name)
        os.chmod(temporary_path, mode)
        os.replace(temporary_path, path)
    finally:
        if temporary_path and temporary_path.exists():
            temporary_path.unlink(missing_ok=True)
    return workspace_file(workspace, relative)


def save_attachments(workspace: Path, attachments: list[dict]) -> list[Path]:
    root = workspace / ".agent-remote" / "uploads"
    root.mkdir(parents=True, exist_ok=True)
    saved = []
    for index, item in enumerate(attachments[:10]):
        name = Path(str(item.get("name") or f"attachment-{index}")).name
        data = base64.b64decode(str(item.get("data") or ""))
        path = resolve_child(root, name)
        path.write_bytes(data)
        saved.append(path)
    return saved


def prompt_command(
    text: str, model: str, attachments: list[Path], permission: str = "workspace"
) -> list[str]:
    if HERMES is None:
        raise ValueError("Hermes CLI is not installed")
    attachment_text = "".join(f"\n\nAttached file on PC: {path}" for path in attachments)
    command = [str(HERMES), "chat", "-q", text + attachment_text]
    if model:
        command += ["-m", model]
    return command


def codex_command(
    text: str, model: str, attachments: list[Path], permission: str = "workspace"
) -> list[str]:
    executable = shutil.which("codex.cmd") or shutil.which("codex.exe") or shutil.which("codex")
    if not executable:
        raise ValueError("Codex CLI is not installed")
    attachment_text = "".join(f"\n\nAttached file on PC: {path}" for path in attachments)
    command = [executable]
    if nine_router_mobile_key():
        command += [
            '-c',
            'model_provider="9router"',
            '-c',
            'model_providers.9router.name="9Router"',
            '-c',
            f'model_providers.9router.base_url={json.dumps(NINE_ROUTER_BASE_URL)}',
            '-c',
            f'model_providers.9router.env_key="{MOBILE_KEY_ENV}"',
            '-c',
            'model_providers.9router.requires_openai_auth=false',
        ]
    if permission == "ask":
        command += ["--ask-for-approval", "untrusted"]
    elif permission == "workspace":
        command += ["--ask-for-approval", "never"]
    command += [
        "exec",
        "--json",
        "--skip-git-repo-check",
        "-C",
        str(WORKSPACE),
    ]
    if permission == "full":
        command.append("--dangerously-bypass-approvals-and-sandbox")
    elif permission == "ask":
        command += ["--sandbox", "workspace-write"]
    else:
        command += ["--sandbox", "workspace-write"]
    if model:
        command += ["-m", model]
    command.append(text + attachment_text)
    return command


def available_agents() -> list[dict]:
    return discover_agents(HERMES)


def generic_agent_command(agent_id: str, text: str) -> list[str]:
    definitions = {
        "claude": (["claude.cmd", "claude.exe", "claude"], ["-p", text]),
        "gemini": (["gemini.cmd", "gemini.exe", "gemini"], ["-p", text]),
        "opencode": (["opencode.cmd", "opencode.exe", "opencode"], ["run", text]),
    }
    commands, arguments = definitions[agent_id]
    executable = next((shutil.which(command) for command in commands if shutil.which(command)), None)
    if not executable:
        raise ValueError(f"agent executable is unavailable: {agent_id}")
    return [executable, *arguments]


def agent_command(
    agent_id: str,
    text: str,
    model: str,
    attachments: list[Path],
    permission: str = "workspace",
) -> list[str]:
    if agent_id == "hermes":
        return prompt_command(text, model, attachments, permission)
    if agent_id == "codex":
        return codex_command(text, model, attachments, permission)
    if agent_id in {"claude", "gemini", "opencode"}:
        return generic_agent_command(agent_id, text)
    raise ValueError(f"unknown agent: {agent_id}")



def workspace_store(workspace: Path) -> SessionStore:
    path = workspace / ".agent-remote" / "sessions.json"
    legacy = workspace / ".hermes-remote" / "sessions.json"
    if not path.exists() and legacy.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(legacy, path)
    return SessionStore(path, workspace.name)


STORE = workspace_store(WORKSPACE)
RUNTIME = AgentRuntime(STORE, agent_command, WORKSPACE, agent_environment)


def folder_listing(path_value: str) -> dict:
    if not path_value:
        if os.name == "nt":
            folders = [
                {"name": f"Disk {letter}:", "path": f"{letter}:\\"}
                for letter in "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
                if Path(f"{letter}:\\").is_dir()
            ]
        else:
            folders = [{"name": "/", "path": "/"}]
        return {"path": "", "parent": None, "folders": folders}
    folder = Path(path_value).resolve()
    if not folder.is_dir():
        raise ValueError("folder not found")
    try:
        folders = [
            {"name": child.name, "path": str(child)}
            for child in sorted(folder.iterdir(), key=lambda item: item.name.lower())
            if child.is_dir() and not child.name.startswith(".")
        ][:200]
    except (OSError, PermissionError) as error:
        raise ValueError(f"folder cannot be opened: {error}") from error
    parent = folder.parent if folder.parent != folder else None
    return {
        "path": str(folder),
        "parent": str(parent) if parent else "",
        "folders": folders,
    }


def select_workspace(path_value: str) -> Path:
    global WORKSPACE, STORE, RECENT_WORKSPACES
    selected = Path(path_value).resolve()
    if not selected.is_dir():
        raise ValueError("workspace folder not found")
    WORKSPACE = selected
    STORE = workspace_store(selected)
    RUNTIME.workspace = selected
    RUNTIME.store = STORE
    RECENT_WORKSPACES = [
        str(selected),
        *[path for path in RECENT_WORKSPACES if path != str(selected)],
    ][:30]
    save_server_state(selected, RECENT_WORKSPACES)
    return selected


def workspace_rows() -> list[dict]:
    rows = []
    for value in RECENT_WORKSPACES:
        path = Path(value)
        if path.is_dir():
            rows.append({
                "id": str(path),
                "name": path.name or str(path),
                "path": str(path),
                "is_active": path == WORKSPACE,
            })
    return rows


def project_rows(limit: int = 20) -> list[dict]:
    rows = []
    for workspace in workspace_rows():
        path = Path(workspace["path"])
        key = _git_cache_key(path)
        with GIT_CACHE_LOCK:
            cached_status = GIT_STATUS_CACHE.get(key)
        is_git_repo = (path / ".git").exists() or bool(
            cached_status and cached_status[1].get("is_git_repo")
        )
        rows.append({
            **workspace,
            "is_git_repo": is_git_repo,
            "sessions": workspace_store(path).list_summaries(limit),
        })
    return rows


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def _json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        if not TOKEN:
            authorized = self.client_address[0] in {"127.0.0.1", "::1"}
        else:
            authorized = self.headers.get("Authorization") == f"Bearer {TOKEN}"
        record_security_audit(
            self.client_address[0],
            authorized,
            self.command,
            self.path,
            self.headers.get("User-Agent", ""),
        )
        return authorized

    def _stream_event(self, payload):
        self.wfile.write((json.dumps(payload) + "\n").encode())
        self.wfile.flush()

    def _payload(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length > 25 * 1024 * 1024:
            raise ValueError("request exceeds 25 MB")
        return json.loads(self.rfile.read(length) or b"{}")

    def _session_id(self, suffix=""):
        parts = urlparse(self.path).path.strip("/").split("/")
        if len(parts) >= 3 and parts[:2] == ["api", "sessions"]:
            if not suffix or parts[-1] == suffix:
                return parts[2]
        return None

    def do_GET(self):
        if not self._authorized():
            return self._json(HTTPStatus.UNAUTHORIZED, {"error": "unauthorized"})
        url = urlparse(self.path)
        query = parse_qs(url.query)
        try:
            if url.path == "/api/status":
                return self._json(HTTPStatus.OK, {
                    "ok": True,
                    "workspace": {"name": WORKSPACE.name, "path": str(WORKSPACE)},
                    "permission": PERMISSION_BY_WORKSPACE.get(str(WORKSPACE), "workspace"),
                    "max_concurrent_agents": RUNTIME.max_concurrent_agents,
                    "features": ["streaming", "sessions", "stop", "tools", "multi_agent", "coordinator", "security_audit", "provider_usage", "mobile_usage_filter", "file_preview", "file_edit"],
                })
            if url.path == "/api/security/audit":
                limit = int(query.get("limit", ["50"])[0])
                return self._json(HTTPStatus.OK, {
                    "entries": security_audit_rows(limit),
                    "peer_ip_only": True,
                    "success_window_seconds": AUTH_SUCCESS_LOG_WINDOW_SECONDS,
                    "failure_window_seconds": AUTH_FAILURE_LOG_WINDOW_SECONDS,
                })
            if url.path == "/api/workspaces":
                return self._json(HTTPStatus.OK, {"workspaces": workspace_rows()})
            if url.path == "/api/projects":
                limit = int(query.get("limit", ["20"])[0])
                return self._json(HTTPStatus.OK, {"projects": project_rows(limit)})
            if url.path == "/api/models":
                return self._json(HTTPStatus.OK, {"models": ["unreal-engine"]})
            if url.path == "/api/agents":
                return self._json(HTTPStatus.OK, {"agents": available_agents()})
            if url.path == "/api/tasks":
                return self._json(HTTPStatus.OK, {"tasks": list_all_tasks()})
            if url.path == "/api/provider-usage":
                return self._json(
                    HTTPStatus.OK,
                    provider_usage(
                        range_name=query.get("range", ["24h"])[0],
                        provider=query.get("provider", [""])[0],
                        model=query.get("model", [""])[0],
                        scope=query.get('scope', ['all'])[0],
                        limit=int(query.get("limit", ["50"])[0]),
                    ),
                )
            if url.path == "/api/folders":
                return self._json(
                    HTTPStatus.OK,
                    folder_listing(query.get("path", [""])[0]),
                )
            if url.path == "/api/sessions":
                limit = int(query.get("limit", ["200"])[0])
                return self._json(HTTPStatus.OK, {"sessions": STORE.list(limit)})
            if session_id := self._session_id():
                return self._json(HTTPStatus.OK, {"session": STORE.get(session_id)})
            if url.path == "/api/git-status":
                return self._json(
                    HTTPStatus.OK,
                    git_status(WORKSPACE, query.get("fetch", ["0"])[0] == "1"),
                )
            if url.path == "/api/tree":
                return self._json(HTTPStatus.OK, tree(WORKSPACE, query.get("path", [""])[0]))
            if url.path == '/api/file':
                return self._json(
                    HTTPStatus.OK,
                    {'file': workspace_file(WORKSPACE, query.get('path', [''])[0])},
                )
            self._json(HTTPStatus.NOT_FOUND, {"error": "not found"})
        except KeyError:
            self._json(HTTPStatus.NOT_FOUND, {"error": "session not found"})
        except ValueError as error:
            self._json(HTTPStatus.BAD_REQUEST, {"error": str(error)})

    def do_PUT(self):
        if not self._authorized():
            return self._json(HTTPStatus.UNAUTHORIZED, {'error': 'unauthorized'})
        if urlparse(self.path).path != '/api/file':
            return self._json(HTTPStatus.NOT_FOUND, {'error': 'not found'})
        try:
            payload = self._payload()
            relative = str(payload.get('path') or '')
            content = payload.get('content')
            if not isinstance(content, str):
                raise ValueError('content must be text')
            document = save_workspace_file(
                WORKSPACE,
                relative,
                content,
                str(payload.get('base_hash') or ''),
            )
            return self._json(HTTPStatus.OK, {'file': document})
        except FileConflictError as error:
            return self._json(HTTPStatus.CONFLICT, {'error': str(error)})
        except (ValueError, OSError) as error:
            return self._json(HTTPStatus.BAD_REQUEST, {'error': str(error)})

    def do_POST(self):
        if not self._authorized():
            return self._json(HTTPStatus.UNAUTHORIZED, {"error": "unauthorized"})
        try:
            if self.path == "/api/codex-events":
                return self._json(
                    HTTPStatus.CREATED,
                    {"task": record_codex_event(self._payload())},
                )
            if self.path == "/api/sessions":
                payload = self._payload()
                session = STORE.create(
                    str(payload.get("workspace_name") or ""),
                    str(payload.get("model_name") or ""),
                    str(WORKSPACE),
                )
                return self._json(HTTPStatus.CREATED, {"session": session})
            if self.path == "/api/workspace":
                payload = self._payload()
                selected = select_workspace(str(payload.get("path") or ""))
                return self._json(
                    HTTPStatus.OK,
                    {
                        "workspace": {
                            "id": str(selected),
                            "name": selected.name,
                            "path": str(selected),
                            "is_active": True,
                        }
                    },
                )
            if self.path == "/api/permission":
                payload = self._payload()
                permission = str(payload.get("permission") or "")
                if permission not in {"ask", "workspace", "full"}:
                    raise ValueError("invalid permission mode")
                PERMISSION_BY_WORKSPACE[str(WORKSPACE)] = permission
                save_server_state(WORKSPACE, RECENT_WORKSPACES)
                return self._json(HTTPStatus.OK, {"permission": permission})
            if session_id := self._session_id("stop"):
                return self._json(
                    HTTPStatus.OK,
                    {"stopped": RUNTIME.stop_session(session_id)},
                )
            if self.path != "/api/prompts/stream":
                return self._json(HTTPStatus.NOT_FOUND, {"error": "not found"})
            payload = self._payload()
            text = str(payload.get("text") or "").strip()
            session_id = str(payload.get("session_id") or "")
            if not text:
                raise ValueError("text is required")
            STORE.get(session_id)
            attachments = save_attachments(
                WORKSPACE,
                payload.get("attachments", []),
            )
            installed = {
                agent["id"] for agent in available_agents()
                if agent.get("installed")
            }
            agent_ids = list(dict.fromkeys(
                str(agent)
                for agent in payload.get("agents", [])
                if str(agent) in installed
            ))
            if not agent_ids:
                raise ValueError("no selected agent is available")
            mode = str(payload.get("mode") or "single")
            if mode not in {"single", "parallel", "coordinator"}:
                raise ValueError("invalid execution mode")
            concurrency = 1 if mode == "single" else max(
                1,
                min(
                    RUNTIME.max_concurrent_agents,
                    int(payload.get("concurrency") or 2),
                ),
            )
            model = str(payload.get("model") or "")
            coordinator = str(payload.get("coordinator") or agent_ids[0])
            permission = str(
                payload.get("permission")
                or PERMISSION_BY_WORKSPACE.get(str(WORKSPACE), "workspace")
            )
            if permission not in {"ask", "workspace", "full"}:
                raise ValueError("invalid permission mode")
        except KeyError:
            return self._json(
                HTTPStatus.NOT_FOUND,
                {"error": "session not found"},
            )
        except (
            ValueError,
            json.JSONDecodeError,
            base64.binascii.Error,
            OSError,
        ) as error:
            return self._json(HTTPStatus.BAD_REQUEST, {"error": str(error)})

        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        events = queue.Queue()
        worker = threading.Thread(
            target=RUNTIME.execute,
            args=(
                session_id,
                text,
                model,
                agent_ids,
                mode,
                coordinator,
                attachments,
                permission,
                events,
                concurrency,
            ),
            daemon=True,
        )
        worker.start()
        self._stream_event({
            "type": "started",
            "agents": agent_ids,
            "mode": mode,
            "concurrency": concurrency,
        })
        try:
            while True:
                event = events.get()
                if event["type"] == "runtime_done":
                    break
                self._stream_event(event)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_PATCH(self):
        if not self._authorized():
            return self._json(HTTPStatus.UNAUTHORIZED, {"error": "unauthorized"})
        session_id = self._session_id()
        if not session_id:
            return self._json(HTTPStatus.NOT_FOUND, {"error": "not found"})
        try:
            payload = self._payload()
            session = STORE.update(
                session_id,
                title=str(payload.get("title") or "Untitled"),
            )
            return self._json(HTTPStatus.OK, {"session": session})
        except KeyError:
            self._json(HTTPStatus.NOT_FOUND, {"error": "session not found"})

    def do_DELETE(self):
        if not self._authorized():
            return self._json(HTTPStatus.UNAUTHORIZED, {"error": "unauthorized"})
        session_id = self._session_id()
        if not session_id:
            return self._json(HTTPStatus.NOT_FOUND, {"error": "not found"})
        try:
            RUNTIME.stop_session(session_id)
            STORE.delete(session_id)
            return self._json(HTTPStatus.OK, {"deleted": True})
        except KeyError:
            self._json(HTTPStatus.NOT_FOUND, {"error": "session not found"})


def _forward_computer_use_notification(payload: str) -> None:
    runtime_root = Path(os.environ.get("LOCALAPPDATA", "")) / "OpenAI" / "Codex" / "runtimes" / "cua_node"
    candidates = list(runtime_root.glob(
        "*/bin/node_modules/@oai/sky/bin/windows/codex-computer-use.exe"
    ))
    if not candidates:
        return
    executable = max(candidates, key=lambda path: path.stat().st_mtime_ns)
    try:
        subprocess.run(
            [str(executable), "turn-ended", payload],
            capture_output=True,
            timeout=10,
            check=False,
            creationflags=CREATE_NO_WINDOW,
        )
    except (OSError, subprocess.SubprocessError):
        pass


def run_codex_notify_bridge(arguments: list[str]) -> None:
    if not arguments:
        return
    payload_text = arguments[-1]
    _forward_computer_use_notification(payload_text)
    try:
        payload = json.loads(payload_text)
        bridge = json.loads(BRIDGE_FILE.read_text(encoding="utf-8"))
        request = urllib.request.Request(
            str(bridge["endpoint"]),
            data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            headers={
                "Authorization": f"Bearer {bridge['token']}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=8):
            pass
    except (KeyError, TypeError, ValueError, OSError, json.JSONDecodeError):
        pass


def acquire_server_instance(name: str = SERVER_INSTANCE_MUTEX):
    if os.name != "nt":
        return True
    try:
        from ctypes import wintypes

        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.CreateMutexW.argtypes = [ctypes.c_void_p, wintypes.BOOL, wintypes.LPCWSTR]
        kernel32.CreateMutexW.restype = wintypes.HANDLE
        kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
        handle = kernel32.CreateMutexW(None, False, name)
        if not handle:
            return None
        if ctypes.get_last_error() == 183:
            kernel32.CloseHandle(handle)
            return None
        return handle
    except (AttributeError, OSError):
        return True


def release_server_instance(handle) -> None:
    if os.name != "nt" or handle is True or handle is None:
        return
    try:
        ctypes.WinDLL("kernel32", use_last_error=True).CloseHandle(handle)
    except (AttributeError, OSError):
        pass


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--codex-notify":
        run_codex_notify_bridge(sys.argv[2:])
        return
    instance = acquire_server_instance()
    if instance is None:
        return
    try:
        tailscale_result = set_tailscale_online(True)
        write_tailscale_log("ServerStart", tailscale_result)
        save_bridge_config()
        ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
    finally:
        release_server_instance(instance)


if __name__ == "__main__":
    main()

# ponytail: one fixed allowlisted workspace; add workspace registration only when needed.
