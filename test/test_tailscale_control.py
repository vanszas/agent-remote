import importlib.util
import subprocess
import sys
from pathlib import Path


MODULE = Path(__file__).parents[1] / "tools" / "tailscale_control.py"
spec = importlib.util.spec_from_file_location("tailscale_control", MODULE)
tailscale_control = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = tailscale_control
spec.loader.exec_module(tailscale_control)
set_tailscale_online = tailscale_control.set_tailscale_online


def completed(arguments, stdout="", stderr="", returncode=0):
    return subprocess.CompletedProcess(arguments, returncode, stdout, stderr)


def test_start_preserves_registered_configuration():
    calls = []
    statuses = iter(
        [
            '{"BackendState":"Stopped","HaveNodeKey":true}',
            '{"BackendState":"Running","HaveNodeKey":true}',
        ]
    )

    def runner(arguments, **_kwargs):
        calls.append(arguments[1:])
        if arguments[1:] == ["status", "--json"]:
            return completed(arguments, next(statuses))
        return completed(arguments)

    result = set_tailscale_online(True, executable=Path("tailscale.exe"), runner=runner)

    assert result.success is True
    assert result.changed is True
    assert ["up", "--unattended=true", "--accept-dns=false"] in calls
    assert all("--reset" not in call for call in calls)


def test_start_does_not_trigger_login_for_unregistered_device():
    calls = []

    def runner(arguments, **_kwargs):
        calls.append(arguments[1:])
        return completed(arguments, '{"BackendState":"NeedsLogin","HaveNodeKey":false}')

    result = set_tailscale_online(True, executable=Path("tailscale.exe"), runner=runner)

    assert result.success is False
    assert calls == [["status", "--json"]]


def test_stop_disconnects_running_tailscale():
    calls = []
    statuses = iter(
        [
            '{"BackendState":"Running","HaveNodeKey":true}',
            '{"BackendState":"Stopped","HaveNodeKey":true}',
        ]
    )

    def runner(arguments, **_kwargs):
        calls.append(arguments[1:])
        if arguments[1:] == ["status", "--json"]:
            return completed(arguments, next(statuses))
        return completed(arguments)

    result = set_tailscale_online(False, executable=Path("tailscale.exe"), runner=runner)

    assert result.success is True
    assert result.changed is True
    assert ["down"] in calls


def test_start_reports_logged_out_state_clearly():
    payload = (
        '{"BackendState":"NoState","HaveNodeKey":true,'
        '"Health":["You are logged out. Please login again."]}'
    )

    def runner(arguments, **_kwargs):
        return completed(arguments, payload)

    result = set_tailscale_online(True, executable=Path("tailscale.exe"), runner=runner)

    assert result.success is False
    assert result.state == "NoState"
    assert "login kembali" in result.detail
