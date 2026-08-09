import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))

import agent_remote_setup


def test_nine_router_command_uses_background_windows_flags(monkeypatch, tmp_path):
    executable = tmp_path / "9router.cmd"
    monkeypatch.setattr(agent_remote_setup.shutil, "which", lambda _command: str(executable))

    assert agent_remote_setup.nine_router_command() == [
        "cmd.exe",
        "/d",
        "/c",
        str(executable),
        "--no-browser",
        "--skip-update",
        "--tray",
    ]
def test_start_pc_mode_starts_router_before_pet(monkeypatch, tmp_path):
    pet = tmp_path / "PetUsage.exe"
    pet.touch()
    calls = []
    monkeypatch.setattr(agent_remote_setup, "launcher_dir", lambda: tmp_path)
    monkeypatch.setattr(
        agent_remote_setup,
        "nine_router_command",
        lambda: ["9router", "--no-browser", "--skip-update", "--tray"],
    )
    monkeypatch.setattr(agent_remote_setup, "run_hidden", lambda command: calls.append(command))

    assert agent_remote_setup.SetupApp._start_pc_mode() == "Mode PC aktif | PET + 9Router berjalan"
    assert calls == [
        ["9router", "--no-browser", "--skip-update", "--tray"],
        [str(pet)],
    ]