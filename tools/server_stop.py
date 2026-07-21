from __future__ import annotations

import ctypes
import os
import subprocess
import sys
import time
from ctypes import wintypes
from pathlib import Path

from tailscale_control import set_tailscale_online, write_tailscale_log


TH32CS_SNAPPROCESS = 0x00000002
PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value
CREATE_NO_WINDOW = 0x08000000


class PROCESSENTRY32W(ctypes.Structure):
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


kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
kernel32.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
kernel32.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
kernel32.Process32FirstW.argtypes = [wintypes.HANDLE, ctypes.POINTER(PROCESSENTRY32W)]
kernel32.Process32FirstW.restype = wintypes.BOOL
kernel32.Process32NextW.argtypes = [wintypes.HANDLE, ctypes.POINTER(PROCESSENTRY32W)]
kernel32.Process32NextW.restype = wintypes.BOOL
kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
kernel32.OpenProcess.restype = wintypes.HANDLE
kernel32.QueryFullProcessImageNameW.argtypes = [
    wintypes.HANDLE,
    wintypes.DWORD,
    wintypes.LPWSTR,
    ctypes.POINTER(wintypes.DWORD),
]
kernel32.QueryFullProcessImageNameW.restype = wintypes.BOOL
kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
kernel32.CloseHandle.restype = wintypes.BOOL


def canonical_path(path: str | Path) -> str:
    return os.path.normcase(os.path.abspath(os.fspath(path)))


def process_image_path(process_id: int) -> str | None:
    handle = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, process_id)
    if not handle:
        return None
    try:
        size = wintypes.DWORD(32768)
        buffer = ctypes.create_unicode_buffer(size.value)
        if not kernel32.QueryFullProcessImageNameW(handle, 0, buffer, ctypes.byref(size)):
            return None
        return canonical_path(buffer.value)
    finally:
        kernel32.CloseHandle(handle)


def matching_processes(target: Path) -> dict[int, int]:
    snapshot = kernel32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
    if snapshot == INVALID_HANDLE_VALUE:
        return {}
    matches: dict[int, int] = {}
    entry = PROCESSENTRY32W()
    entry.dwSize = ctypes.sizeof(PROCESSENTRY32W)
    target_path = canonical_path(target)
    target_name = target.name.casefold()
    try:
        available = kernel32.Process32FirstW(snapshot, ctypes.byref(entry))
        while available:
            if entry.szExeFile.casefold() == target_name:
                process_id = int(entry.th32ProcessID)
                if process_image_path(process_id) == target_path:
                    matches[process_id] = int(entry.th32ParentProcessID)
            available = kernel32.Process32NextW(snapshot, ctypes.byref(entry))
    finally:
        kernel32.CloseHandle(snapshot)
    return matches


def stop_process_tree(process_id: int) -> bool:
    result = subprocess.run(
        ["taskkill", "/PID", str(process_id), "/T", "/F"],
        capture_output=True,
        text=True,
        check=False,
        creationflags=CREATE_NO_WINDOW,
    )
    return result.returncode == 0


def show_message(message: str, *, error: bool = False) -> None:
    if "--silent" in sys.argv:
        return
    flags = 0x10 if error else 0x40
    ctypes.windll.user32.MessageBoxW(None, message, "Agent Remote", flags)


def launcher_path() -> Path:
    source = Path(sys.executable) if getattr(sys, "frozen", False) else Path(__file__)
    return source.resolve()


def stop_server(target: Path) -> tuple[bool, bool, list[int]]:
    found = False
    for _ in range(4):
        matches = matching_processes(target)
        if not matches:
            return True, found, []
        found = True
        roots = [process_id for process_id, parent_id in matches.items() if parent_id not in matches]
        for process_id in roots or list(matches):
            stop_process_tree(process_id)
        time.sleep(0.35)

    return False, found, sorted(matching_processes(target))


def main() -> int:
    target = launcher_path().with_name("ServerStart.exe")
    if not target.is_file():
        show_message("ServerStart.exe tidak ditemukan di folder yang sama.", error=True)
        return 2

    server_stopped, server_found, remaining = stop_server(target)
    tailscale_result = set_tailscale_online(False)
    write_tailscale_log("ServerStop", tailscale_result)

    if server_stopped and tailscale_result.success:
        server_text = (
            "Server Agent Remote dihentikan."
            if server_found
            else "Server Agent Remote sudah tidak aktif."
        )
        if tailscale_result.state == "Disabled":
            tailscale_text = "Kontrol Tailscale dinonaktifkan lewat konfigurasi."
        elif tailscale_result.changed:
            tailscale_text = "Tailscale dimatikan."
        else:
            tailscale_text = "Tailscale sudah nonaktif."
        show_message(
            f"{server_text}\n{tailscale_text}\n\nTidak ada notifikasi dikirim ke HP."
        )
        return 0

    problems = []
    if not server_stopped:
        problems.append(f"Server gagal dihentikan. PID tersisa: {', '.join(map(str, remaining))}")
    if not tailscale_result.success:
        problems.append(f"Tailscale gagal dimatikan: {tailscale_result.detail}")
    show_message(
        "\n".join(problems) + "\n\nCoba jalankan ServerStop.exe sebagai Administrator.",
        error=True,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
