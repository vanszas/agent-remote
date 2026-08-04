import importlib.util
import io
import json
import queue
import sqlite3
import threading
import urllib.error
import urllib.request
from datetime import datetime, timezone
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


def test_computer_use_notification_runs_without_console(monkeypatch, tmp_path):
    executable = tmp_path / "codex-computer-use.exe"
    executable.write_bytes(b"stub")
    calls = []

    monkeypatch.setattr(remote_server.Path, "glob", lambda _self, _pattern: [executable])
    monkeypatch.setattr(
        remote_server.subprocess,
        "run",
        lambda *args, **kwargs: calls.append((args, kwargs)),
    )

    remote_server._forward_computer_use_notification('{"type":"turn-ended"}')

    assert calls[0][1]["creationflags"] == remote_server.CREATE_NO_WINDOW


def test_git_status_reuses_short_cache(monkeypatch, tmp_path):
    calls = []

    def fake_git(_workspace, *arguments, **_kwargs):
        calls.append(arguments)
        if arguments[:2] == ("status", "--porcelain=v1"):
            return remote_server.subprocess.CompletedProcess(arguments, 0, " M lib/a.dart\0", "")
        if arguments[:2] == ("diff", "--numstat"):
            return remote_server.subprocess.CompletedProcess(arguments, 0, "4\t2\tlib/a.dart\n", "")
        if arguments[:2] == ("branch", "--show-current"):
            return remote_server.subprocess.CompletedProcess(arguments, 0, "main\n", "")
        if arguments[:3] == ("remote", "get-url", "origin"):
            return remote_server.subprocess.CompletedProcess(
                arguments, 0, "https://github.com/example/repo.git\n", ""
            )
        return remote_server.subprocess.CompletedProcess(arguments, 1, "", "")

    monkeypatch.setattr(remote_server, "_git", fake_git)
    monkeypatch.setattr(
        remote_server,
        "github_cli_status",
        lambda: {"installed": True, "authenticated": True, "user": "example"},
    )
    remote_server.GIT_STATUS_CACHE.clear()
    remote_server.GIT_REMOTE_CACHE.clear()

    first = remote_server.git_status(tmp_path)
    first_call_count = len(calls)
    second = remote_server.git_status(tmp_path)

    assert first["is_git_repo"] is True
    assert second == first
    assert len(calls) == first_call_count


def test_non_repo_reports_nested_git_roots(monkeypatch, tmp_path):
    nested = tmp_path / "Apps" / "AgentRemote"
    (nested / ".git").mkdir(parents=True)
    monkeypatch.setattr(
        remote_server,
        "_git",
        lambda *_args, **_kwargs: remote_server.subprocess.CompletedProcess([], 1, "", ""),
    )
    remote_server.GIT_STATUS_CACHE.clear()
    remote_server.GIT_DISCOVERY_CACHE.clear()

    status = remote_server.git_status(tmp_path)

    assert status["is_git_repo"] is False
    assert status["nested_repositories"] == [
        {"name": "AgentRemote", "path": str(nested.resolve())}
    ]


def test_provider_usage_reads_9router_metrics_without_secrets(tmp_path):
    database = tmp_path / "data.sqlite"
    connection = sqlite3.connect(database)
    connection.execute(
        """
        CREATE TABLE usageHistory (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            provider TEXT,
            model TEXT,
            connectionId TEXT,
            apiKey TEXT,
            endpoint TEXT,
            promptTokens INTEGER DEFAULT 0,
            completionTokens INTEGER DEFAULT 0,
            cost REAL DEFAULT 0,
            status TEXT,
            tokens TEXT,
            meta TEXT
        )
        """
    )
    connection.executemany(
        """
        INSERT INTO usageHistory (
            timestamp, provider, model, endpoint, promptTokens,
            completionTokens, cost, status, tokens
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
            (
                "2026-07-18T12:00:00Z",
                "codex",
                "gpt-5.6-sol",
                "/v1/responses",
                100,
                20,
                0.25,
                "ok",
                json.dumps({"cached_tokens": 80}),
            ),
            (
                "2026-07-18T11:00:00Z",
                "claude",
                "opus",
                "/v1/messages",
                40,
                10,
                0.1,
                "ok",
                json.dumps({"cached_tokens": 5}),
            ),
        ],
    )
    connection.commit()
    connection.close()

    usage = remote_server.provider_usage(
        range_name="24h",
        provider="codex",
        db_path=database,
        now=datetime(2026, 7, 18, 13, tzinfo=timezone.utc),
    )

    assert usage["available"] is True
    assert usage["summary"] == {
        "requests": 1,
        "input_tokens": 100,
        "output_tokens": 20,
        "cached_tokens": 80,
        "estimated_cost": 0.25,
    }
    assert usage["active"]["model"] == "gpt-5.6-sol"
    assert usage["models"] == ["gpt-5.6-sol", "opus"]
    assert "apiKey" not in usage["recent"][0]
    assert "connectionId" not in usage["recent"][0]


def test_quota_reset_at_normalizes_unix_seconds():
    assert remote_server._quota_reset_at(1784961358) == "2026-07-25T06:35:58Z"
    assert remote_server._quota_reset_at("2026-07-25T06:35:58Z") == "2026-07-25T06:35:58Z"


def test_provider_usage_filters_agent_remote_mobile_key(tmp_path):
    database = tmp_path / 'data.sqlite'
    connection = sqlite3.connect(database)
    connection.executescript(
        '''
        CREATE TABLE apiKeys (
            id TEXT PRIMARY KEY,
            key TEXT NOT NULL,
            name TEXT,
            machineId TEXT,
            isActive INTEGER DEFAULT 1,
            createdAt TEXT NOT NULL
        );
        CREATE TABLE usageHistory (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            provider TEXT,
            model TEXT,
            connectionId TEXT,
            apiKey TEXT,
            endpoint TEXT,
            promptTokens INTEGER DEFAULT 0,
            completionTokens INTEGER DEFAULT 0,
            cost REAL DEFAULT 0,
            status TEXT,
            tokens TEXT,
            meta TEXT
        );
        '''
    )
    connection.execute(
        'INSERT INTO apiKeys VALUES (?, ?, ?, ?, ?, ?)',
        ('mobile', 'sk-mobile', 'Agent Remote Mobile', 'machine', 1, '2026-07-18'),
    )
    connection.executemany(
        '''
        INSERT INTO usageHistory (
            timestamp, provider, model, apiKey, endpoint,
            promptTokens, completionTokens, cost, status, tokens
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        [
            (
                '2026-07-18T12:00:00Z',
                'codex',
                'mobile-model',
                'sk-mobile',
                '/v1/responses',
                100,
                20,
                0.25,
                'ok',
                '{}',
            ),
            (
                '2026-07-18T12:30:00Z',
                'codex',
                'desktop-model',
                'sk-desktop',
                '/v1/responses',
                900,
                80,
                1.0,
                'ok',
                '{}',
            ),
        ],
    )
    connection.commit()
    connection.close()

    usage = remote_server.provider_usage(
        range_name='24h',
        scope='mobile',
        db_path=database,
        now=datetime(2026, 7, 18, 13, tzinfo=timezone.utc),
    )

    assert usage['mobile_filter_available'] is True
    assert usage['attribution'] == 'agent_remote_mobile_key'
    assert usage['summary']['requests'] == 1
    assert usage['summary']['input_tokens'] == 100
    assert usage['recent'][0]['model'] == 'mobile-model'
    assert 'apiKey' not in usage['recent'][0]


def test_agent_environment_uses_mobile_key_only_for_codex(monkeypatch):
    monkeypatch.setenv('AGENT_REMOTE_9ROUTER_MOBILE_KEY', 'sk-mobile')
    assert remote_server.agent_environment('codex') == {
        'AGENT_REMOTE_9ROUTER_API_KEY': 'sk-mobile',
        'NINE_ROUTER_API_KEY': 'sk-mobile'
    }
    assert remote_server.agent_environment('claude') == {}


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


def test_workspace_file_preview_and_atomic_save_with_conflict_guard(tmp_path):
    path = tmp_path / 'main.py'
    path.write_bytes(b'print(1)\n')

    preview = remote_server.workspace_file(tmp_path, 'main.py')
    assert preview['content'] == 'print(1)\n'
    assert preview['editable'] is True
    assert preview['line_count'] == 2

    saved = remote_server.save_workspace_file(
        tmp_path,
        'main.py',
        'print(2)\n',
        preview['hash'],
    )
    assert path.read_bytes() == b'print(2)\n'
    assert saved['hash'] != preview['hash']

    path.write_bytes(b'print(3)\n')
    try:
        remote_server.save_workspace_file(
            tmp_path,
            'main.py',
            'print(4)\n',
            saved['hash'],
        )
    except remote_server.FileConflictError:
        pass
    else:
        raise AssertionError('stale mobile edit overwrote newer PC file')


def test_workspace_file_rejects_binary_and_path_escape(tmp_path):
    (tmp_path / 'binary.bin').write_bytes(b'abc\x00def')
    for relative in ('binary.bin', '../outside.txt'):
        try:
            remote_server.workspace_file(tmp_path, relative)
        except ValueError:
            pass
        else:
            raise AssertionError(f'unsafe file accepted: {relative}')


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


def test_session_summaries_exclude_heavy_history(tmp_path):
    store = remote_server.SessionStore(tmp_path / "sessions.json", "Workspace")
    session = store.create(workspace_path=str(tmp_path))
    store.append_message(session["id"], "user", "Inspect repository")
    store.append_activity(
        session["id"],
        "run-1",
        "codex",
        "command",
        "completed",
        "git status",
        output="large output",
    )

    summary = store.list_summaries()[0]

    assert summary["messageCount"] == 1
    assert "messages" not in summary
    assert "activities" not in summary


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
    monkeypatch.setenv('AGENT_REMOTE_9ROUTER_MOBILE_KEY', 'sk-mobile')
    command = remote_server.codex_command("inspect", "", [])
    assert "--skip-git-repo-check" in command
    assert command[command.index("-C") + 1] == str(remote_server.WORKSPACE)
    assert 'model_provider="9router"' in command
    assert 'model_providers.9router.name="9Router"' in command
    assert (
        'model_providers.9router.base_url="http://127.0.0.1:20128/v1"'
        in command
    )
    assert (
        'model_providers.9router.env_key="AGENT_REMOTE_9ROUTER_API_KEY"'
        in command
    )


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


def test_codex_json_scalar_output_does_not_crash_event_stream():
    events = remote_server.normalize_codex_event(
        '"plain JSON string from command output"',
        'codex',
    )
    assert events == [{
        'type': 'delta',
        'agent_id': 'codex',
        'text': 'plain JSON string from command output\n',
        'task_text': 'plain JSON string from command output',
        'phase': 'responding',
    }]


def test_codex_plain_text_output_is_diagnostic_not_answer():
    events = remote_server.normalize_codex_event(
        'Reading additional input from stdin...',
        'codex',
    )
    assert events == [{
        'type': 'diagnostic',
        'agent_id': 'codex',
        'text': 'Reading additional input from stdin...',
    }]


def test_runtime_keeps_codex_stderr_out_of_assistant_response(
    monkeypatch,
    tmp_path,
):
    store = remote_server.SessionStore(tmp_path / 'sessions.json', 'Workspace')
    session = store.create()
    popen_kwargs = {}

    class FakeProcess:
        pid = 4242

        def __init__(self, *args, **kwargs):
            popen_kwargs.update(kwargs)
            self.stdout = io.StringIO(
                '{"type":"item.completed","item":'
                '{"type":"agent_message","text":"Jawaban bersih"}}\n'
            )
            self.stderr = io.StringIO(
                'Reading additional input from stdin...\n'
                '2026-07-18T17:17:37Z WARN codex_core::config: startup warning\n'
            )

        def wait(self, timeout):
            return 0

        def poll(self):
            return 0

    monkeypatch.setattr(remote_server.subprocess, 'Popen', FakeProcess)
    runtime = remote_server.AgentRuntime(store, lambda *_: ['codex'], tmp_path)
    runtime.tasks['run-1'] = {
        'id': 'run-1',
        'status': 'running',
        'createdAt': '2026-07-18T17:17:36+00:00',
        'updatedAt': '2026-07-18T17:17:36+00:00',
        'agentStates': [{'id': 'codex', 'status': 'queued'}],
    }

    result = runtime._run_agent(
        'run-1',
        session['id'],
        'codex',
        'Kerjakan task',
        '',
        [],
        'workspace',
        queue.Queue(),
    )

    assert result == 'Jawaban bersih'
    assert popen_kwargs['creationflags'] & 0x08000000
    assert 'WARN' not in result
    diagnostics = [
        activity
        for activity in store.get(session['id'])['activities']
        if activity['kind'] == 'diagnostic'
    ]
    assert len(diagnostics) == 1
    assert 'startup warning' in diagnostics[0]['output']


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


def test_runtime_queues_agents_above_global_limit(monkeypatch, tmp_path):
    store = remote_server.SessionStore(tmp_path / "sessions.json", "Workspace")
    runtime = remote_server.AgentRuntime(
        store,
        lambda *_: [],
        tmp_path,
        max_concurrent_agents=1,
    )
    for run_id, agent_id in (("run-1", "codex"), ("run-2", "claude")):
        runtime.tasks[run_id] = {
            "id": run_id,
            "status": "running",
            "createdAt": "2026-07-17T00:00:00+00:00",
            "updatedAt": "2026-07-17T00:00:00+00:00",
            "agentStates": [{"id": agent_id, "status": "queued"}],
        }

    lock = threading.Lock()
    release = threading.Event()
    entered = threading.Event()
    active = 0
    peak = 0
    results = []

    def fake_run(run_id, _session_id, agent_id, *_args):
        nonlocal active, peak
        with lock:
            active += 1
            peak = max(peak, active)
            entered.set()
        release.wait(timeout=2)
        with lock:
            active -= 1
        return agent_id

    monkeypatch.setattr(runtime, "_run_agent_process", fake_run)
    first = threading.Thread(
        target=lambda: results.append(
            runtime._run_agent("run-1", "session-1", "codex", "", "", [], "workspace", queue.Queue())
        )
    )
    second = threading.Thread(
        target=lambda: results.append(
            runtime._run_agent("run-2", "session-2", "claude", "", "", [], "workspace", queue.Queue())
        )
    )
    first.start()
    assert entered.wait(timeout=1)
    second.start()
    threading.Event().wait(0.1)

    assert second.is_alive()
    assert runtime.list_tasks()[1]["agentStates"][0]["phase"] == "queued"

    release.set()
    first.join(timeout=2)
    second.join(timeout=2)

    assert peak == 1
    assert sorted(results) == ["claude", "codex"]


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


def test_agent_states_track_agents_independently(tmp_path):
    store = remote_server.SessionStore(tmp_path / "sessions.json", "Workspace")
    runtime = remote_server.AgentRuntime(store, lambda *_: [], tmp_path)
    runtime.tasks["run-1"] = {
        "id": "run-1",
        "status": "running",
        "createdAt": "2026-07-17T00:00:00+00:00",
        "updatedAt": "2026-07-17T00:00:00+00:00",
        "agentStates": [],
    }
    runtime._update_agent_state(
        "run-1", "codex", status="running", phase="testing", detail="flutter test"
    )
    runtime._update_agent_state(
        "run-1", "claude", status="running", phase="editing", detail="Editing API"
    )
    states = {state["id"]: state for state in runtime.list_tasks()[0]["agentStates"]}
    assert states["codex"]["phase"] == "testing"
    assert states["claude"]["phase"] == "editing"
    assert states["codex"]["detail"] == "flutter test"
    assert states["claude"]["detail"] == "Editing API"


def test_stop_marks_all_pending_agent_states(tmp_path):
    store = remote_server.SessionStore(tmp_path / "sessions.json", "Workspace")
    session = store.create()
    runtime = remote_server.AgentRuntime(store, lambda *_: [], tmp_path)
    runtime.session_runs[session["id"]] = "run-1"
    runtime.tasks["run-1"] = {
        "id": "run-1",
        "status": "running",
        "createdAt": "2026-07-17T00:00:00+00:00",
        "updatedAt": "2026-07-17T00:00:00+00:00",
        "agentStates": [
            {"id": "codex", "status": "running"},
            {"id": "claude", "status": "queued"},
        ],
    }
    assert runtime.stop_session(session["id"]) is True
    states = runtime.tasks["run-1"]["agentStates"]
    assert {state["status"] for state in states} == {"stopped"}
    assert {state["phase"] for state in states} == {"stopped"}


def test_generic_output_phase_uses_local_heuristics_only():
    assert remote_server.infer_activity_phase("Running flutter test") == "testing"
    assert remote_server.infer_activity_phase("apply_patch lib/main.dart") == "editing"
    assert remote_server.infer_activity_phase("git status --short") == "running_command"


def test_coordinator_tracks_roles_without_extra_agent_processes(monkeypatch, tmp_path):
    store = remote_server.SessionStore(tmp_path / "sessions.json", "Workspace")
    session = store.create()
    commands = []

    class FakeProcess:
        next_pid = 100

        def __init__(self, command, **kwargs):
            commands.append(command)
            self.pid = FakeProcess.next_pid
            FakeProcess.next_pid += 1
            self.stdout = iter(["Working on assigned task\n"])

        def wait(self, timeout):
            return 0

        def poll(self):
            return 0

    monkeypatch.setattr(remote_server.subprocess, "Popen", FakeProcess)
    runtime = remote_server.AgentRuntime(
        store,
        lambda agent_id, *_: [agent_id],
        tmp_path,
    )
    monkeypatch.setattr(runtime, "_git_changed_state", lambda *_: {})
    runtime.execute(
        session["id"],
        "Inspect project",
        "",
        ["codex", "claude"],
        "coordinator",
        "codex",
        [],
        "workspace",
        remote_server.queue.Queue(),
        1,
    )
    task = runtime.list_tasks()[0]
    states = {state["id"]: state for state in task["agentStates"]}
    assert len(commands) == 2
    assert task["concurrency"] == 1
    assert states["codex"]["role"] == "coordinator"
    assert states["claude"]["role"] == "worker"
    assert {state["status"] for state in states.values()} == {"completed"}


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


def test_codex_rollout_running_task_is_visible_in_process_page(tmp_path):
    rollout = tmp_path / "rollout.jsonl"
    rollout.write_text("\n".join(json.dumps(row) for row in [
        {"timestamp": "2026-07-19T11:00:00Z", "type": "event_msg", "payload": {"type": "task_started", "turn_id": "turn-live"}},
        {"timestamp": "2026-07-19T11:00:01Z", "type": "event_msg", "payload": {"type": "user_message", "message": "Perbaiki backend"}},
        {"timestamp": "2026-07-19T11:00:05Z", "type": "event_msg", "payload": {"type": "agent_reasoning", "text": "Menganalisis source"}},
    ]), encoding="utf-8")
    database = tmp_path / "state.sqlite"
    connection = sqlite3.connect(database)
    connection.execute("CREATE TABLE threads (id TEXT, rollout_path TEXT, cwd TEXT, title TEXT, model TEXT, model_provider TEXT, archived INTEGER, updated_at_ms INTEGER)")
    connection.execute(
        "INSERT INTO threads VALUES (?,?,?,?,?,?,?,?)",
        ["thread-live", str(rollout), str(tmp_path), "Fallback", "gpt-5.6-sol", "9router", 0, 1],
    )
    connection.commit()
    connection.close()

    tasks = remote_server.list_codex_desktop_tasks(
        database,
        now=datetime(2026, 7, 19, 11, 1, tzinfo=timezone.utc),
    )

    assert tasks[0]["id"] == "codex_turn-live"
    assert tasks[0]["status"] == "running"
    assert tasks[0]["title"] == "Perbaiki backend"
    assert "gpt-5.6-sol via 9router" in tasks[0]["detail"]


def test_codex_rollout_cache_only_reads_changed_file(monkeypatch, tmp_path):
    rollout = tmp_path / "rollout.jsonl"
    rollout.write_text("\n".join(json.dumps(row) for row in [
        {"timestamp": "2026-07-19T11:00:00Z", "type": "event_msg", "payload": {"type": "task_started", "turn_id": "turn-cache"}},
        {"timestamp": "2026-07-19T11:00:01Z", "type": "event_msg", "payload": {"type": "agent_reasoning", "text": "Menganalisis source"}},
    ]), encoding="utf-8")
    original = remote_server._rollout_tail
    calls = []

    def tracked(path, maximum_bytes=remote_server.CODEX_ROLLOUT_TAIL_BYTES):
        calls.append(path)
        return original(path, maximum_bytes)

    remote_server.CODEX_ROLLOUT_CACHE.clear()
    monkeypatch.setattr(remote_server, "_rollout_tail", tracked)
    assert remote_server._cached_codex_turn(rollout)["detail"] == "Menganalisis source"
    assert remote_server._cached_codex_turn(rollout)["detail"] == "Menganalisis source"
    rollout.write_text(
        rollout.read_text(encoding="utf-8")
        + "\n"
        + json.dumps({"timestamp": "2026-07-19T11:00:02Z", "type": "event_msg", "payload": {"type": "agent_reasoning", "text": "Menjalankan test"}}),
        encoding="utf-8",
    )
    assert remote_server._cached_codex_turn(rollout)["detail"] == "Menjalankan test"
    assert len(calls) == 2


def test_codex_active_task_outside_previous_thirty_thread_window_is_visible(tmp_path):
    rollout = tmp_path / "active-rollout.jsonl"
    rollout.write_text("\n".join(json.dumps(row) for row in [
        {"timestamp": "2026-07-19T11:00:00Z", "type": "event_msg", "payload": {"type": "task_started", "turn_id": "turn-old-folder"}},
        {"timestamp": "2026-07-19T11:00:01Z", "type": "event_msg", "payload": {"type": "user_message", "message": "Task folder lain"}},
    ]), encoding="utf-8")
    database = tmp_path / "state.sqlite"
    connection = sqlite3.connect(database)
    connection.execute("CREATE TABLE threads (id TEXT, rollout_path TEXT, cwd TEXT, title TEXT, model TEXT, model_provider TEXT, archived INTEGER, updated_at_ms INTEGER)")
    for index in range(35):
        connection.execute(
            "INSERT INTO threads VALUES (?,?,?,?,?,?,?,?)",
            [f"newer-{index}", str(tmp_path / f"missing-{index}.jsonl"), str(tmp_path / f"folder-{index}"), "Newer", "gpt-5.6-sol", "9router", 0, 1000 - index],
        )
    connection.execute(
        "INSERT INTO threads VALUES (?,?,?,?,?,?,?,?)",
        ["thread-old-folder", str(rollout), str(tmp_path / "old-folder"), "Fallback", "gpt-5.6-sol", "9router", 0, 1],
    )
    connection.commit()
    connection.close()

    tasks = remote_server.list_codex_desktop_tasks(
        database,
        now=datetime(2026, 7, 19, 11, 1, tzinfo=timezone.utc),
    )

    assert [task["id"] for task in tasks] == ["codex_turn-old-folder"]
    assert tasks[0]["workspace"] == str(tmp_path / "old-folder")


def test_pc_agent_process_detection_handles_wrappers_and_ignores_idle_codex_app():
    assert remote_server._process_agent_id({
        "executable": "node.exe",
        "path": r"C:\Program Files\nodejs\node.exe",
        "command_line": r"node C:\npm\node_modules\@anthropic-ai\claude-code\cli.js",
    }) == "claude"
    assert remote_server._process_agent_id({
        "executable": "codex.exe",
        "path": r"C:\Tools\codex.exe",
        "command_line": r"codex.exe exec --json task",
    }) == "codex"
    assert remote_server._process_agent_id({
        "executable": "codex.exe",
        "path": r"C:\Program Files\WindowsApps\OpenAI.Codex_1.0\codex.exe",
        "command_line": r"codex.exe app-server",
    }) == ""


def test_pc_agent_process_becomes_recent_completion(monkeypatch):
    rows = [{
        "pid": 42,
        "executable": "node.exe",
        "path": r"C:\Program Files\nodejs\node.exe",
        "command_line": r"node C:\npm\node_modules\@google\gemini-cli\index.js",
        "created_at": "2026-07-19T11:00:00+00:00",
    }]
    monkeypatch.setattr(remote_server, "_windows_process_rows", lambda: list(rows))
    remote_server.PC_AGENT_ACTIVE.clear()
    remote_server.PC_AGENT_RECENT.clear()
    remote_server.PC_AGENT_PROCESS_CACHE = None

    running = remote_server.list_pc_agent_tasks()
    assert running[0]["agents"] == ["gemini"]
    assert running[0]["status"] == "running"

    rows.clear()
    remote_server.PC_AGENT_PROCESS_CACHE = None
    completed = remote_server.list_pc_agent_tasks()
    assert completed[0]["agents"] == ["gemini"]
    assert completed[0]["status"] == "completed"


def test_task_list_prioritizes_active_and_caps_history_at_ten(monkeypatch):
    completed = [{
        "id": f"completed-{index}",
        "status": "completed",
        "agents": ["codex"],
        "updatedAt": f"2026-07-19T11:{index:02d}:00+00:00",
    } for index in range(12)]
    running = {
        "id": "running-old-folder",
        "status": "running",
        "agents": ["claude"],
        "updatedAt": "2026-07-19T10:00:00+00:00",
    }
    previous = list(remote_server.CODEX_TASKS)
    remote_server.CODEX_TASKS.clear()
    remote_server.TASK_LIST_CACHE = None
    monkeypatch.setattr(remote_server, "list_codex_desktop_tasks", lambda: [*completed, running])
    monkeypatch.setattr(remote_server.RUNTIME, "list_tasks", lambda: [])
    monkeypatch.setattr(remote_server, "list_pc_agent_tasks", lambda: [])
    try:
        tasks = remote_server.list_all_tasks()
    finally:
        remote_server.CODEX_TASKS[:] = previous
        remote_server.TASK_LIST_CACHE = None

    assert len(tasks) == 10
    assert tasks[0]["id"] == "running-old-folder"


def test_server_instance_mutex_rejects_second_windows_server():
    if remote_server.os.name != "nt":
        return
    name = f"Local\\AgentRemoteTest-{remote_server.time.time_ns()}"
    first = remote_server.acquire_server_instance(name)
    try:
        assert first is not None
        assert remote_server.acquire_server_instance(name) is None
    finally:
        remote_server.release_server_instance(first)


def test_codex_rollout_without_terminal_event_stops_after_inactivity(tmp_path):
    rollout = tmp_path / "rollout.jsonl"
    rollout.write_text("\n".join(json.dumps(row) for row in [
        {"timestamp": "2026-07-19T11:00:00Z", "type": "event_msg", "payload": {"type": "task_started", "turn_id": "turn-stale"}},
        {"timestamp": "2026-07-19T11:00:05Z", "type": "event_msg", "payload": {"type": "agent_message", "message": "Hasil selesai"}},
    ]), encoding="utf-8")
    database = tmp_path / "state.sqlite"
    connection = sqlite3.connect(database)
    connection.execute("CREATE TABLE threads (id TEXT, rollout_path TEXT, cwd TEXT, title TEXT, model TEXT, model_provider TEXT, archived INTEGER, updated_at_ms INTEGER)")
    connection.execute(
        "INSERT INTO threads VALUES (?,?,?,?,?,?,?,?)",
        ["thread-stale", str(rollout), str(tmp_path), "Task stale", "gpt-5.6-sol", "9router", 0, 1],
    )
    connection.commit()
    connection.close()

    task = remote_server.list_codex_desktop_tasks(
        database,
        now=datetime(2026, 7, 19, 11, 20, tzinfo=timezone.utc),
    )[0]

    assert task["status"] == "stopped"
    assert task["activeAgent"] == ""
    assert task["agentStates"][0]["completedAt"] == "2026-07-19T11:00:05Z"


def test_runtime_recovers_generating_session_after_server_restart(tmp_path):
    store = remote_server.SessionStore(tmp_path / "sessions.json", "Workspace")
    session = store.create()
    store.update(session["id"], status="generating")

    remote_server.AgentRuntime(store, lambda *_: [], tmp_path)

    assert store.get(session["id"])["status"] == "stopped"


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


def test_security_audit_throttles_and_strips_query_secrets(monkeypatch, tmp_path):
    audit = tmp_path / "security_audit.jsonl"
    backup = tmp_path / "security_audit.jsonl.1"
    monkeypatch.setattr(remote_server, "STATE_ROOT", tmp_path)
    monkeypatch.setattr(remote_server, "SECURITY_AUDIT_FILE", audit)
    monkeypatch.setattr(remote_server, "SECURITY_AUDIT_BACKUP_FILE", backup)
    remote_server.SECURITY_AUDIT_LAST.clear()

    assert remote_server.record_security_audit(
        "100.64.0.5",
        True,
        "get",
        "/api/status?token=super-secret",
        "AgentRemote/0.3.0\nInjected",
        current_time=100,
    )
    assert not remote_server.record_security_audit(
        "100.64.0.5",
        True,
        "GET",
        "/api/tasks",
        current_time=101,
    )
    assert remote_server.record_security_audit(
        "192.168.1.9",
        False,
        "POST",
        "/api/sessions",
        current_time=100,
    )
    assert not remote_server.record_security_audit(
        "192.168.1.9",
        False,
        "POST",
        "/api/sessions",
        current_time=105,
    )
    assert remote_server.record_security_audit(
        "192.168.1.9",
        False,
        "POST",
        "/api/sessions",
        current_time=111,
    )

    rows = remote_server.security_audit_rows()
    assert len(rows) == 3
    assert rows[-1]["ip_address"] == "100.64.0.5"
    assert rows[-1]["path"] == "/api/status"
    stored = audit.read_text(encoding="utf-8")
    assert "super-secret" not in stored
    assert "Authorization" not in stored
    assert "\nInjected" not in stored


def test_security_audit_rotates_without_losing_recent_rows(monkeypatch, tmp_path):
    audit = tmp_path / "security_audit.jsonl"
    backup = tmp_path / "security_audit.jsonl.1"
    monkeypatch.setattr(remote_server, "STATE_ROOT", tmp_path)
    monkeypatch.setattr(remote_server, "SECURITY_AUDIT_FILE", audit)
    monkeypatch.setattr(remote_server, "SECURITY_AUDIT_BACKUP_FILE", backup)
    monkeypatch.setattr(remote_server, "SECURITY_AUDIT_MAX_BYTES", 1)
    remote_server.SECURITY_AUDIT_LAST.clear()

    assert remote_server.record_security_audit(
        "100.64.0.5", True, "GET", "/api/status", current_time=100
    )
    assert remote_server.record_security_audit(
        "100.64.0.6", True, "GET", "/api/status", current_time=101
    )

    assert backup.exists()
    assert [row["ip_address"] for row in remote_server.security_audit_rows()] == [
        "100.64.0.6",
        "100.64.0.5",
    ]


def test_handler_authorization_audits_direct_peer_ip(monkeypatch):
    calls = []
    monkeypatch.setattr(remote_server, "TOKEN", "strong-test-token")
    monkeypatch.setattr(
        remote_server,
        "record_security_audit",
        lambda *args, **kwargs: calls.append((args, kwargs)),
    )
    handler = object.__new__(remote_server.Handler)
    handler.client_address = ("100.64.0.8", 4242)
    handler.command = "GET"
    handler.path = "/api/status?ignored=1"
    handler.headers = {
        "Authorization": "Bearer strong-test-token",
        "User-Agent": "AgentRemote/0.3.0",
        "X-Forwarded-For": "203.0.113.99",
    }

    assert handler._authorized() is True
    assert calls[0][0] == (
        "100.64.0.8",
        True,
        "GET",
        "/api/status?ignored=1",
        "AgentRemote/0.3.0",
    )


def test_security_audit_endpoint_reports_success_and_failure(monkeypatch, tmp_path):
    monkeypatch.setattr(remote_server, "TOKEN", "strong-test-token")
    monkeypatch.setattr(remote_server, "STATE_ROOT", tmp_path)
    monkeypatch.setattr(
        remote_server, "SECURITY_AUDIT_FILE", tmp_path / "security_audit.jsonl"
    )
    monkeypatch.setattr(
        remote_server,
        "SECURITY_AUDIT_BACKUP_FILE",
        tmp_path / "security_audit.jsonl.1",
    )
    remote_server.SECURITY_AUDIT_LAST.clear()
    server = remote_server.ThreadingHTTPServer(("127.0.0.1", 0), remote_server.Handler)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    endpoint = f"http://127.0.0.1:{server.server_port}/api/security/audit"
    try:
        rejected = urllib.request.Request(
            endpoint,
            headers={"Authorization": "Bearer wrong-token"},
        )
        try:
            urllib.request.urlopen(rejected, timeout=2)
        except urllib.error.HTTPError as error:
            assert error.code == 401
        else:
            raise AssertionError("invalid token was accepted")

        accepted = urllib.request.Request(
            endpoint,
            headers={
                "Authorization": "Bearer strong-test-token",
                "User-Agent": "AgentRemote/0.3.0",
            },
        )
        with urllib.request.urlopen(accepted, timeout=2) as response:
            payload = json.loads(response.read())
        assert {entry["event"] for entry in payload["entries"]} == {
            "access_granted",
            "access_denied",
        }
        assert {entry["ip_address"] for entry in payload["entries"]} == {
            "127.0.0.1"
        }
    finally:
        server.shutdown()
        server.server_close()
        worker.join(timeout=2)

def test_personalization_override_replaces_global():
    global_prompt = remote_server.personalized_prompt(
        "Fix bug", "Jawab Indonesia", None
    )
    override_prompt = remote_server.personalized_prompt(
        "Fix bug", "Jawab Indonesia", "Answer in English"
    )

    assert "Jawab Indonesia" in global_prompt
    assert "Answer in English" in override_prompt
    assert "Jawab Indonesia" not in override_prompt
    assert remote_server.personalized_prompt("Fix bug", "", None) == "Fix bug"


def test_session_store_persists_personalization_override(tmp_path):
    store = remote_server.SessionStore(tmp_path / "sessions.json", "demo")
    session = store.create()

    updated = store.update(
        session["id"], personalizationOverride="Keep answers short"
    )

    assert updated["personalizationOverride"] == "Keep answers short"
    restored = remote_server.SessionStore(
        tmp_path / "sessions.json", "demo"
    ).get(session["id"])
    assert restored["personalizationOverride"] == "Keep answers short"
