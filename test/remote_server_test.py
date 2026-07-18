import importlib.util
from pathlib import Path

MODULE = Path(__file__).parents[1] / "tools" / "hermes_remote_server.py"
spec = importlib.util.spec_from_file_location("remote_server", MODULE)
remote_server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(remote_server)


def test_parse_git_status_maps_core_states():
    raw = " M lib/a.dart\0A  lib/new.dart\0 D old.txt\0?? note.txt\0"
    assert remote_server.parse_git_status(raw) == [
        {"path": "lib/a.dart", "status": "modified"},
        {"path": "lib/new.dart", "status": "added"},
        {"path": "old.txt", "status": "deleted"},
        {"path": "note.txt", "status": "untracked"},
    ]


def test_resolve_child_rejects_workspace_escape(tmp_path):
    workspace = tmp_path / "repo"
    workspace.mkdir()
    assert remote_server.resolve_child(workspace, "lib").is_relative_to(workspace)
    try:
        remote_server.resolve_child(workspace, "../secret")
    except ValueError:
        pass
    else:
        raise AssertionError("workspace escape accepted")


def test_save_attachments_keeps_uploads_inside_workspace(tmp_path):
    saved = remote_server.save_attachments(
        tmp_path,
        [{"name": "photo.png", "data": "aGVsbG8="}],
    )
    assert saved[0].read_bytes() == b"hello"
    assert saved[0].is_relative_to(tmp_path / ".agent-remote" / "uploads")


def test_workspace_store_keeps_sessions_separate(tmp_path):
    first = tmp_path / "first"
    second = tmp_path / "second"
    first.mkdir()
    second.mkdir()
    first_store = remote_server.workspace_store(first)
    second_store = remote_server.workspace_store(second)
    first_store.create(workspace_name="first", workspace_path=str(first))
    assert len(first_store.list()) == 1
    assert second_store.list() == []
    assert (first / ".agent-remote" / "sessions.json").exists()
    assert not (second / ".agent-remote" / "sessions.json").exists()


def test_workspace_selection_accepts_arbitrary_folder_and_lists_projects(
    monkeypatch, tmp_path
):
    previous_workspace = remote_server.WORKSPACE
    previous_store = remote_server.STORE
    previous_recent = list(remote_server.RECENT_WORKSPACES)
    monkeypatch.setattr(remote_server, "save_server_state", lambda *_: None)
    try:
        selected = remote_server.select_workspace(str(tmp_path))
        remote_server.STORE.create(workspace_path=str(tmp_path))
        assert selected == tmp_path.resolve()
        assert remote_server.workspace_rows()[0]["path"] == str(tmp_path.resolve())
        assert len(remote_server.project_rows()[0]["sessions"]) == 1
    finally:
        remote_server.WORKSPACE = previous_workspace
        remote_server.STORE = previous_store
        remote_server.RUNTIME.workspace = previous_workspace
        remote_server.RUNTIME.store = previous_store
        remote_server.RECENT_WORKSPACES = previous_recent


def test_prompt_command_includes_requested_model_and_files(tmp_path):
    command = remote_server.prompt_command("fix it", "unreal-engine", [tmp_path / "x.png"])
    assert command[-2:] == ["-m", "unreal-engine"]
    assert any("x.png" in value for value in command)


def test_session_store_persists_history(tmp_path):
    path = tmp_path / "sessions.json"
    store = remote_server.SessionStore(path, "Workspace")
    session = store.create(model_name="Codex")
    store.append_message(session["id"], "user", "Fix the backend")
    restored = remote_server.SessionStore(path, "Workspace").get(session["id"])
    assert restored["title"] == "Fix the backend"
    assert restored["messages"][0]["content"] == "Fix the backend"


def test_codex_command_allows_non_git_workspace(monkeypatch):
    monkeypatch.setattr(remote_server.shutil, "which", lambda _: "codex.exe")
    command = remote_server.codex_command("inspect", "", [])
    assert "--skip-git-repo-check" in command
    assert command[command.index("-C") + 1] == str(remote_server.WORKSPACE)


def test_codex_command_applies_selected_permission(monkeypatch):
    monkeypatch.setattr(remote_server.shutil, "which", lambda _: "codex.exe")
    ask = remote_server.codex_command("inspect", "", [], "ask")
    workspace = remote_server.codex_command("inspect", "", [], "workspace")
    full = remote_server.codex_command("inspect", "", [], "full")
    assert ask[ask.index("--ask-for-approval") + 1] == "untrusted"
    assert workspace[workspace.index("--ask-for-approval") + 1] == "never"
    assert "--dangerously-bypass-approvals-and-sandbox" in full


def test_codex_tool_events_are_normalized():
    started = remote_server.normalize_codex_event(
        '{"type":"item.started","item":{"id":"tool-1","type":"command_execution","command":"git status"}}',
        "codex",
    )
    completed = remote_server.normalize_codex_event(
        '{"type":"item.completed","item":{"id":"tool-1","type":"command_execution","aggregated_output":"clean"}}',
        "codex",
    )
    assert started[0]["type"] == "tool_started"
    assert completed[0]["type"] == "tool_completed"
    assert completed[0]["text"] == "shell selesai"
    assert completed[0]["output"] == "clean"


def test_completed_reasoning_does_not_claim_task_is_finished():
    events = remote_server.normalize_codex_event(
        '{"type":"item.completed","item":{"id":"reason-1","type":"reasoning"}}',
        "codex",
    )
    assert events[0]["text"] == "Analisis tahap selesai"
    assert events[0]["task_text"] == "Menunggu langkah agent berikutnya"


def test_reasoning_events_are_normalized():
    events = remote_server.normalize_codex_event(
        '{"type":"item.updated","item":{"id":"r1","type":"reasoning","text":"Checking files"}}',
        "codex",
    )
    assert events == [{
        "type": "reasoning",
        "agent_id": "codex",
        "text": "Menganalisis task",
        "task_text": "Menganalisis task",
        "status": "running",
    }]


def test_runtime_lists_tracked_tasks(tmp_path):
    store = remote_server.SessionStore(tmp_path / "sessions.json", "Workspace")
    session = store.create()
    runtime = remote_server.AgentRuntime(store, lambda *_: [], tmp_path)
    runtime.tasks["run-1"] = {
        "id": "run-1",
        "session_id": session["id"],
        "title": "Inspect project",
        "status": "running",
        "createdAt": "2026-07-17T00:00:00+00:00",
        "updatedAt": "2026-07-17T00:00:00+00:00",
    }
    assert runtime.list_tasks()[0]["session_id"] == session["id"]


def test_completed_task_reports_frozen_elapsed_seconds(tmp_path):
    store = remote_server.SessionStore(tmp_path / "sessions.json", "Workspace")
    runtime = remote_server.AgentRuntime(store, lambda *_: [], tmp_path)
    runtime.tasks["run-1"] = {
        "id": "run-1",
        "status": "completed",
        "createdAt": "2026-07-17T00:00:00+00:00",
        "updatedAt": "2026-07-17T01:02:03+00:00",
    }
    assert runtime.list_tasks()[0]["elapsedSeconds"] == 3723


def test_codex_completion_event_becomes_persistent_external_task(monkeypatch, tmp_path):
    previous = list(remote_server.CODEX_TASKS)
    monkeypatch.setattr(remote_server, "CODEX_TASKS_FILE", tmp_path / "codex_tasks.json")
    remote_server.CODEX_TASKS.clear()
    try:
        task = remote_server.record_codex_event({
            "type": "agent-turn-complete",
            "thread-id": "thread-1",
            "turn-id": "turn-1",
            "cwd": str(tmp_path),
            "input-messages": ["Commit dan push perubahan"],
            "last-assistant-message": "Push selesai",
        })
        assert task["id"] == "codex_turn-1"
        assert task["source"] == "codex_desktop"
        assert task["session_id"] == "thread-1"
        assert task["title"] == "Commit dan push perubahan"
        assert task["detail"] == "Push selesai"
        restored = remote_server.load_codex_tasks()
        assert restored[0]["id"] == task["id"]
    finally:
        remote_server.CODEX_TASKS[:] = previous


def test_windows_stop_kills_entire_process_tree(monkeypatch, tmp_path):
    store = remote_server.SessionStore(tmp_path / "sessions.json", "Workspace")
    runtime = remote_server.AgentRuntime(store, lambda *_: [], tmp_path)
    calls = []

    class FakeProcess:
        pid = 4242

        def __init__(self):
            self.done = False

        def poll(self):
            return 0 if self.done else None

        def wait(self, timeout):
            self.done = True
            return 0

        def kill(self):
            raise AssertionError("taskkill tree fallback should not be needed")

    monkeypatch.setattr(
        remote_server.subprocess,
        "run",
        lambda command, **kwargs: calls.append((command, kwargs)),
    )
    process = FakeProcess()
    runtime._terminate_process_tree(process, platform_name="nt")
    assert calls[0][0] == ["taskkill", "/PID", "4242", "/T", "/F"]
    assert process.done is True


def test_agent_catalog_includes_uninstalled_supported_agents(monkeypatch, tmp_path):
    monkeypatch.setattr(remote_server.shutil, "which", lambda name: "codex.exe" if name == "codex.exe" else None)
    agents = remote_server.discover_agents(tmp_path / "missing-hermes.exe")
    indexed = {agent["id"]: agent for agent in agents}
    assert indexed["codex"]["installed"] is True
    assert indexed["claude"]["installed"] is False
    assert indexed["gemini"]["installed"] is False
    assert indexed["opencode"]["installed"] is False


def test_stop_marks_session_before_process_registration(tmp_path):
    store = remote_server.SessionStore(tmp_path / "sessions.json", "Workspace")
    session = store.create()
    runtime = remote_server.AgentRuntime(store, lambda *_: [], tmp_path)
    runtime.session_runs[session["id"]] = "run-1"
    assert runtime.stop_session(session["id"]) is True
    assert store.get(session["id"])["status"] == "stopped"
