import concurrent.futures
import json
import os
import queue
import re
import signal
import shutil
import subprocess
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path


AGENT_DISPLAY_NAMES = {
    "codex": "Codex",
    "claude": "Claude Code",
    "gemini": "Gemini CLI",
    "opencode": "OpenCode",
    "hermes": "Hermes",
}
TERMINAL_AGENT_STATUSES = {"completed", "failed", "stopped"}
ANSI_ESCAPE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def new_id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex}"


def elapsed_seconds(started_at: str, ended_at: str | None = None) -> int:
    try:
        started = datetime.fromisoformat(started_at)
        ended = datetime.fromisoformat(ended_at) if ended_at else datetime.now(timezone.utc)
        if started.tzinfo is None:
            started = started.replace(tzinfo=timezone.utc)
        if ended.tzinfo is None:
            ended = ended.replace(tzinfo=timezone.utc)
        return max(0, int((ended - started).total_seconds()))
    except (TypeError, ValueError):
        return 0


def concise_activity_detail(value: str, limit: int = 240) -> str:
    cleaned = ANSI_ESCAPE.sub("", value).replace("\r", " ").replace("\n", " ")
    cleaned = " ".join(cleaned.split())
    return cleaned if len(cleaned) <= limit else f"{cleaned[:limit - 1]}…"


def infer_activity_phase(value: str) -> str:
    lowered = value.lower()
    if any(word in lowered for word in (
        "pytest", "flutter test", "npm test", "pnpm test", "dart test",
        "flutter analyze", "build apk", "gradle", "compile", "test suite",
    )):
        return "testing"
    if any(word in lowered for word in (
        "apply_patch", "patching", "updated file", "writing file", "editing",
        "modified:", "created file", "deleted file",
    )):
        return "editing"
    if any(word in lowered for word in (
        "powershell", "cmd.exe", "running command", "executing", "git status",
        "git diff", "git commit", "git push",
    )):
        return "running_command"
    if any(word in lowered for word in (
        "analyzing", "analysing", "menganalisis", "reasoning", "thinking",
        "inspecting", "checking files", "reading ",
    )):
        return "thinking"
    return "responding"


def available_agents(hermes: Path) -> list[dict]:
    definitions = [
        ("codex", "Codex", "OpenAI Codex CLI", ("codex.cmd", "codex.exe", "codex"), True, True),
        ("claude", "Claude Code", "Anthropic Claude Code CLI", ("claude.cmd", "claude.exe", "claude"), True, False),
        ("gemini", "Gemini CLI", "Google Gemini CLI", ("gemini.cmd", "gemini.exe", "gemini"), True, False),
        ("opencode", "OpenCode", "OpenCode CLI", ("opencode.cmd", "opencode.exe", "opencode"), True, False),
    ]
    agents = []
    for agent_id, name, description, commands, streaming, tools in definitions:
        executable = next((shutil.which(command) for command in commands if shutil.which(command)), None)
        agents.append({
            "id": agent_id,
            "name": name,
            "description": description,
            "command": executable or "",
            "installed": executable is not None,
            "supports_streaming": streaming,
            "supports_tools": tools,
        })
    agents.append({
        "id": "hermes",
        "name": "Hermes",
        "description": "Hermes Agent CLI",
        "command": str(hermes) if hermes.exists() else "",
        "installed": hermes.exists(),
        "supports_streaming": False,
        "supports_tools": True,
    })
    return agents


def normalize_codex_event(line: str, agent_id: str) -> list[dict]:
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        return [{"type": "delta", "agent_id": agent_id, "text": f"{line}\n"}]
    if not isinstance(event, dict):
        text = str(event).strip()
        return [{
            'type': 'delta',
            'agent_id': agent_id,
            'text': f'{text}\n',
            'task_text': concise_activity_detail(text),
            'phase': infer_activity_phase(text),
        }] if text else []
    event_type = str(event.get("type") or "")
    item = event.get("item")
    if not isinstance(item, dict):
        if event_type in {"turn.failed", "error"}:
            return [{
                "type": "agent_failed",
                "agent_id": agent_id,
                "error": str(event.get("error") or event),
            }]
        return []
    item_type = str(item.get("type") or "")
    if item_type == "agent_message" and event_type in {"item.completed", "item.updated"}:
        text = str(item.get("text") or "")
        return [{
            "type": "delta",
            "agent_id": agent_id,
            "text": f"{text}\n",
            "task_text": "Menyusun respons akhir",
        }] if text else []
    if item_type == "reasoning" and event_type in {"item.started", "item.updated", "item.completed"}:
        completed = event_type == "item.completed"
        return [{
            "type": "reasoning",
            "agent_id": agent_id,
            "text": "Analisis tahap selesai" if completed else "Menganalisis task",
            "task_text": "Menunggu langkah agent berikutnya" if completed else "Menganalisis task",
            "status": "completed" if completed else "running",
        }]
    if item_type not in {"command_execution", "mcp_tool_call", "web_search"}:
        return []
    tool_id = str(item.get("id") or new_id("tool"))
    name = "shell" if item_type == "command_execution" else str(item.get("server") or item_type)
    if event_type == "item.started":
        detail = item.get("command") or item.get("query") or item.get("arguments") or ""
        return [{
            "type": "tool_started",
            "agent_id": agent_id,
            "tool_id": tool_id,
            "name": name,
            "text": str(detail),
            "task_text": str(detail) or f"Menjalankan {name}",
        }]
    if event_type == "item.completed":
        output = item.get("aggregated_output") or item.get("output") or item.get("result") or ""
        return [{
            "type": "tool_completed",
            "agent_id": agent_id,
            "tool_id": tool_id,
            "name": name,
            "text": f"{name} selesai",
            "task_text": f"{name} selesai, menunggu langkah berikutnya",
            "output": str(output),
        }]
    return []


class SessionStore:
    def __init__(self, path: Path, workspace_name: str):
        self.path = path
        self.workspace_name = workspace_name
        self.lock = threading.RLock()
        self.sessions = {}
        self._load()

    def _load(self):
        try:
            payload = json.loads(self.path.read_text(encoding="utf-8"))
            self.sessions = {
                str(item["id"]): item
                for item in payload
                if isinstance(item, dict) and item.get("id")
            }
            for session in self.sessions.values():
                session.setdefault("activities", [])
                if session.get("activeModelName") in {"Hermes PC", "Hermes Agent"}:
                    session["activeModelName"] = "PC Agent"
        except (FileNotFoundError, json.JSONDecodeError, OSError, TypeError):
            self.sessions = {}

    def _save(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_suffix(".tmp")
        temporary.write_text(
            json.dumps(list(self.sessions.values()), ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        temporary.replace(self.path)

    def list(self, limit: int = 200) -> list[dict]:
        with self.lock:
            values = sorted(
                self.sessions.values(),
                key=lambda item: item.get("updatedAt", ""),
                reverse=True,
            )
            return json.loads(json.dumps(values[:limit]))

    def get(self, session_id: str) -> dict:
        with self.lock:
            if session_id not in self.sessions:
                raise KeyError(session_id)
            return json.loads(json.dumps(self.sessions[session_id]))

    def create(
        self,
        workspace_name: str = "",
        model_name: str = "",
        workspace_path: str = "",
    ) -> dict:
        timestamp = now_iso()
        session = {
            "id": new_id("session"),
            "title": "New task",
            "createdAt": timestamp,
            "updatedAt": timestamp,
            "isPinned": False,
            "isArchived": False,
            "workspaceName": workspace_name or self.workspace_name,
            "workspacePath": workspace_path,
            "connectionProfileId": None,
            "activeModelName": model_name or "PC Agent",
            "messages": [],
            "draftText": "",
            "status": "idle",
            "preview": "",
            "messageCount": 0,
            "activities": [],
        }
        with self.lock:
            self.sessions[session["id"]] = session
            self._save()
        return self.get(session["id"])

    def update(self, session_id: str, **changes) -> dict:
        with self.lock:
            if session_id not in self.sessions:
                raise KeyError(session_id)
            allowed = {"title", "status", "activeModelName", "preview"}
            self.sessions[session_id].update({
                key: value for key, value in changes.items() if key in allowed
            })
            self.sessions[session_id]["updatedAt"] = now_iso()
            self._save()
        return self.get(session_id)

    def append_message(self, session_id: str, role: str, content: str) -> dict:
        with self.lock:
            session = self.sessions[session_id]
            timestamp = now_iso()
            message = {
                "id": new_id("message"),
                "sessionId": session_id,
                "role": role,
                "content": content,
                "createdAt": timestamp,
                "updatedAt": timestamp,
                "status": "complete",
                "attachments": [],
                "toolActivities": [],
            }
            session["messages"].append(message)
            session["messageCount"] = len(session["messages"])
            session["preview"] = content[:240]
            session["updatedAt"] = timestamp
            if role == "user" and session["title"] == "New task" and content.strip():
                session["title"] = content.strip().splitlines()[0][:60]
            self._save()
            return json.loads(json.dumps(message))

    def append_activity(
        self,
        session_id: str,
        run_id: str,
        agent_id: str,
        kind: str,
        status: str,
        detail: str,
        tool_id: str = "",
        tool_name: str = "",
        output: str = "",
    ) -> dict:
        timestamp = now_iso()
        activity = {
            "id": new_id("activity"),
            "runId": run_id,
            "sessionId": session_id,
            "agentId": agent_id,
            "kind": kind,
            "status": status,
            "detail": detail[:4000],
            "toolId": tool_id,
            "toolName": tool_name,
            "output": output[:12000],
            "createdAt": timestamp,
        }
        with self.lock:
            session = self.sessions[session_id]
            session.setdefault("activities", []).append(activity)
            session["activities"] = session["activities"][-300:]
            session["updatedAt"] = timestamp
            self._save()
        return json.loads(json.dumps(activity))

    def delete(self, session_id: str):
        with self.lock:
            if session_id not in self.sessions:
                raise KeyError(session_id)
            del self.sessions[session_id]
            self._save()


class AgentRuntime:
    def __init__(
        self,
        store: SessionStore,
        command_factory,
        workspace: Path,
        environment_factory=None,
    ):
        self.store = store
        self.command_factory = command_factory
        self.workspace = workspace
        self.environment_factory = environment_factory
        self.lock = threading.RLock()
        self.processes = {}
        self.session_runs = {}
        self.cancelled = set()
        self.tasks = {}

    def _register(self, run_id: str, session_id: str, process: subprocess.Popen):
        with self.lock:
            self.processes.setdefault(run_id, []).append(process)
            self.session_runs[session_id] = run_id
            cancelled = run_id in self.cancelled
        if cancelled:
            self._terminate_process_tree(process)

    def _unregister(self, run_id: str, session_id: str, process: subprocess.Popen):
        with self.lock:
            if process in self.processes.get(run_id, []):
                self.processes[run_id].remove(process)
            if not self.processes.get(run_id):
                self.processes.pop(run_id, None)

    def list_tasks(self) -> list[dict]:
        with self.lock:
            values = sorted(
                self.tasks.values(),
                key=lambda item: item.get("updatedAt", ""),
                reverse=True,
            )
            snapshot = json.loads(json.dumps(values[:100]))
        for task in snapshot:
            ended_at = None if task.get("status") == "running" else task.get("updatedAt")
            task["elapsedSeconds"] = elapsed_seconds(task.get("createdAt", ""), ended_at)
            task["idleSeconds"] = elapsed_seconds(task.get("updatedAt", ""))
            for state in task.get("agentStates", []):
                state_ended_at = (
                    None
                    if state.get("status") not in TERMINAL_AGENT_STATUSES
                    else state.get("completedAt") or state.get("updatedAt")
                )
                state["elapsedSeconds"] = elapsed_seconds(
                    state.get("startedAt") or state.get("updatedAt", ""),
                    state_ended_at,
                )
                state["idleSeconds"] = elapsed_seconds(state.get("updatedAt", ""))
        return snapshot

    def _update_task(self, run_id: str, **changes):
        with self.lock:
            task = self.tasks.get(run_id)
            if task is None:
                return
            task.update(changes)
            task["updatedAt"] = now_iso()

    def _update_agent_state(
        self,
        run_id: str,
        agent_id: str,
        *,
        status: str | None = None,
        phase: str | None = None,
        detail: str | None = None,
    ) -> None:
        timestamp = now_iso()
        with self.lock:
            task = self.tasks.get(run_id)
            if task is None:
                return
            states = task.setdefault("agentStates", [])
            state = next(
                (item for item in states if item.get("id") == agent_id),
                None,
            )
            if state is None:
                state = {
                    "id": agent_id,
                    "name": AGENT_DISPLAY_NAMES.get(agent_id, agent_id),
                    "role": "agent",
                    "status": "queued",
                    "phase": "preparing",
                    "detail": "Menunggu eksekusi",
                    "startedAt": None,
                    "updatedAt": timestamp,
                    "completedAt": None,
                }
                states.append(state)
            if status is not None:
                state["status"] = status
                if status == "running" and not state.get("startedAt"):
                    state["startedAt"] = timestamp
                if status in TERMINAL_AGENT_STATUSES:
                    state["completedAt"] = timestamp
            if phase is not None:
                state["phase"] = phase
            if detail is not None:
                state["detail"] = concise_activity_detail(detail)
                task["detail"] = state["detail"]
            state["updatedAt"] = timestamp
            if state.get("status") == "running":
                task["activeAgent"] = agent_id
            task["updatedAt"] = timestamp

    def _finish_pending_agent_states(
        self,
        run_id: str,
        status: str,
        phase: str,
        detail: str,
    ) -> None:
        with self.lock:
            task = self.tasks.get(run_id)
            agent_ids = [
                state.get("id", "")
                for state in task.get("agentStates", [])
                if state.get("status") not in TERMINAL_AGENT_STATUSES
            ] if task else []
        for agent_id in agent_ids:
            if agent_id:
                self._update_agent_state(
                    run_id,
                    agent_id,
                    status=status,
                    phase=phase,
                    detail=detail,
                )

    def _terminate_process_tree(
        self,
        process: subprocess.Popen,
        platform_name: str | None = None,
    ) -> None:
        if process.poll() is not None:
            return
        platform_name = platform_name or os.name
        try:
            if platform_name == "nt":
                subprocess.run(
                    ["taskkill", "/PID", str(process.pid), "/T", "/F"],
                    capture_output=True,
                    timeout=10,
                    check=False,
                )
            else:
                os.killpg(os.getpgid(process.pid), signal.SIGTERM)
            process.wait(timeout=5)
        except (OSError, ProcessLookupError, subprocess.SubprocessError):
            if process.poll() is None:
                try:
                    if platform_name == "nt":
                        process.kill()
                    else:
                        os.killpg(os.getpgid(process.pid), signal.SIGKILL)
                except (OSError, ProcessLookupError):
                    pass

    def _git_changed_state(self, workspace: Path) -> dict[bytes, tuple[bool, int, int]]:
        try:
            changed = subprocess.run(
                ["git", "-C", str(workspace), "diff", "--name-only", "-z", "HEAD"],
                capture_output=True,
                timeout=5,
                check=False,
            )
            untracked = subprocess.run(
                [
                    "git",
                    "-C",
                    str(workspace),
                    "ls-files",
                    "--others",
                    "--exclude-standard",
                    "-z",
                ],
                capture_output=True,
                timeout=5,
                check=False,
            )
            if changed.returncode != 0 or untracked.returncode != 0:
                return {}
            paths = {
                value
                for value in (changed.stdout + untracked.stdout).split(b"\0")
                if value
            }
            state = {}
            for value in paths:
                path = workspace / value.decode("utf-8", errors="replace")
                try:
                    stat = path.stat()
                    state[value] = (True, stat.st_size, stat.st_mtime_ns)
                except OSError:
                    state[value] = (False, 0, 0)
            return state
        except (OSError, subprocess.SubprocessError):
            return {}

    def stop_session(self, session_id: str) -> bool:
        with self.lock:
            run_id = self.session_runs.get(session_id)
            if not run_id:
                return False
            self.cancelled.add(run_id)
            processes = list(self.processes.get(run_id, []))
        for process in processes:
            self._terminate_process_tree(process)
        self.store.update(session_id, status="stopped")
        self.store.append_activity(
            session_id, run_id, "system", "stopped", "stopped", "Dihentikan pengguna"
        )
        self._update_task(run_id, status="stopped", detail="Dihentikan pengguna")
        self._finish_pending_agent_states(
            run_id, "stopped", "stopped", "Dihentikan pengguna"
        )
        return True

    def _run_agent(
        self,
        run_id: str,
        session_id: str,
        agent_id: str,
        text: str,
        model: str,
        attachments: list[Path],
        permission: str,
        events: queue.Queue,
        initial_phase: str = "preparing",
        initial_detail: str = "Menyiapkan agent",
    ) -> str:
        output = []
        process = None
        try:
            self._update_agent_state(
                run_id,
                agent_id,
                status="running",
                phase=initial_phase,
                detail=initial_detail,
            )
            self.store.append_activity(
                session_id, run_id, agent_id, initial_phase, "running", initial_detail
            )
            process_environment = os.environ.copy()
            if self.environment_factory:
                process_environment.update(self.environment_factory(agent_id))
            process_environment['GIT_TERMINAL_PROMPT'] = '0'
            process_environment['GCM_INTERACTIVE'] = 'Never'
            process_group = (
                {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP}
                if os.name == "nt"
                else {"start_new_session": True}
            )
            process = subprocess.Popen(
                self.command_factory(agent_id, text, model, attachments, permission),
                cwd=self.workspace,
                stdin=subprocess.DEVNULL,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                encoding="utf-8",
                errors="replace",
                bufsize=1,
                env=process_environment,
                **process_group,
            )
            self._register(run_id, session_id, process)
            assert process.stdout is not None
            for raw in process.stdout:
                if run_id in self.cancelled:
                    break
                value = raw.rstrip()
                if not value:
                    continue
                if agent_id == "codex":
                    normalized = normalize_codex_event(value, agent_id)
                else:
                    detail = concise_activity_detail(value)
                    normalized = [{
                        "type": "delta",
                        "agent_id": agent_id,
                        "text": f"{value}\n",
                        "task_text": detail,
                        "phase": infer_activity_phase(detail),
                    }]
                for event in normalized:
                    if event["type"] == "delta":
                        output.append(event["text"])
                        self._update_agent_state(
                            run_id,
                            agent_id,
                            status="running",
                            phase=str(event.get("phase") or "responding"),
                            detail=str(event.get("task_text") or event["text"]),
                        )
                    elif event["type"] == "reasoning":
                        self.store.append_activity(
                            session_id,
                            run_id,
                            agent_id,
                            "thinking",
                            event.get("status", "running"),
                            event.get("text", "Menganalisis task"),
                        )
                        self._update_agent_state(
                            run_id,
                            agent_id,
                            status="running",
                            phase="thinking",
                            detail=str(event.get("task_text") or "Menganalisis task"),
                        )
                    elif event["type"] in {"tool_started", "tool_completed"}:
                        detail = str(event.get("text") or event.get("name") or "Menjalankan tool")
                        lowered = detail.lower()
                        kind = (
                            "testing"
                            if any(word in lowered for word in (" test", "pytest", "analyze", "build"))
                            else "editing"
                            if any(word in lowered for word in ("apply_patch", "write", "edit"))
                            else "running_command"
                        )
                        self.store.append_activity(
                            session_id,
                            run_id,
                            agent_id,
                            kind,
                            "completed" if event["type"] == "tool_completed" else "running",
                            detail,
                            str(event.get("tool_id") or ""),
                            str(event.get("name") or ""),
                            str(event.get("output") or ""),
                        )
                        self._update_agent_state(
                            run_id,
                            agent_id,
                            status="running",
                            phase=kind,
                            detail=str(event.get("task_text") or detail),
                        )
                    elif event["type"] == "agent_failed":
                        raise RuntimeError(str(event.get("error") or "Agent gagal"))
                    events.put(event)
            return_code = process.wait(timeout=10)
            if run_id in self.cancelled:
                self._update_agent_state(
                    run_id,
                    agent_id,
                    status="stopped",
                    phase="stopped",
                    detail="Dihentikan pengguna",
                )
                events.put({"type": "agent_stopped", "agent_id": agent_id})
                return "".join(output).strip()
            if return_code != 0:
                error_output = "".join(output).strip()
                raise RuntimeError(error_output[-2000:] or f"{agent_id} exited with {return_code}")
            events.put({"type": "agent_completed", "agent_id": agent_id})
            self._update_agent_state(
                run_id,
                agent_id,
                status="completed",
                phase="completed",
                detail="Agent selesai",
            )
            self.store.append_activity(
                session_id, run_id, agent_id, "verifying", "completed", "Agent selesai"
            )
            return "".join(output).strip()
        except Exception as error:
            if process is not None:
                self._terminate_process_tree(process)
            if run_id in self.cancelled:
                self._update_agent_state(
                    run_id,
                    agent_id,
                    status="stopped",
                    phase="stopped",
                    detail="Dihentikan pengguna",
                )
                events.put({"type": "agent_stopped", "agent_id": agent_id})
                return "".join(output).strip()
            self._update_agent_state(
                run_id,
                agent_id,
                status="failed",
                phase="failed",
                detail=str(error),
            )
            events.put({"type": "agent_failed", "agent_id": agent_id, "error": str(error)})
            self.store.append_activity(
                session_id, run_id, agent_id, "failed", "failed", str(error)
            )
            return ""
        finally:
            if process is not None:
                if run_id in self.cancelled:
                    self._terminate_process_tree(process)
                self._unregister(run_id, session_id, process)

    def execute(
        self,
        session_id: str,
        text: str,
        model: str,
        agent_ids: list[str],
        mode: str,
        coordinator: str,
        attachments: list[Path],
        permission: str,
        events: queue.Queue,
    ):
        run_id = new_id("run")
        timestamp = now_iso()
        task_workspace = self.workspace
        baseline_git_state = self._git_changed_state(task_workspace)
        effective_agent_ids = agent_ids[:1] if mode == "single" else agent_ids
        lead = (
            coordinator if coordinator in effective_agent_ids else effective_agent_ids[0]
        ) if effective_agent_ids else ""
        agent_states = []
        for agent_id in effective_agent_ids:
            role = (
                "coordinator" if mode == "coordinator" and agent_id == lead
                else "worker" if mode == "coordinator"
                else "agent"
            )
            detail = (
                "Menunggu hasil agent lain"
                if role == "coordinator" and len(effective_agent_ids) > 1
                else "Menunggu eksekusi"
            )
            agent_states.append({
                "id": agent_id,
                "name": AGENT_DISPLAY_NAMES.get(agent_id, agent_id),
                "role": role,
                "status": "queued",
                "phase": "coordinating" if role == "coordinator" else "preparing",
                "detail": detail,
                "startedAt": None,
                "updatedAt": timestamp,
                "completedAt": None,
            })
        with self.lock:
            self.session_runs[session_id] = run_id
            self.tasks[run_id] = {
                "id": run_id,
                "session_id": session_id,
                "title": text.strip().splitlines()[0][:80] or "Agent task",
                "status": "running",
                "detail": "Menyiapkan agent…",
                "agents": effective_agent_ids,
                "agentStates": agent_states,
                "activeAgent": "",
                "mode": mode,
                "source": "agent_remote",
                "permission": permission,
                "workspace": str(self.workspace),
                "changedFiles": 0,
                "createdAt": timestamp,
                "updatedAt": timestamp,
            }
        self.store.update(
            session_id,
            status="generating",
            activeModelName=" + ".join(effective_agent_ids),
        )
        self.store.append_message(session_id, "user", text)
        self.store.append_activity(
            session_id,
            run_id,
            "+".join(effective_agent_ids),
            "queued",
            "completed",
            "Task diterima dan masuk antrean",
        )
        results = {}
        try:
            if mode == "coordinator" and len(effective_agent_ids) > 1:
                workers = [agent for agent in effective_agent_ids if agent != lead]
                with concurrent.futures.ThreadPoolExecutor(
                    max_workers=len(workers)
                ) as executor:
                    futures = {
                        agent: executor.submit(
                            self._run_agent,
                            run_id,
                            session_id,
                            agent,
                            "Analyze this task as a specialist. Return findings and "
                            f"recommended implementation.\n\n{text}",
                            model,
                            attachments,
                            permission,
                            events,
                        )
                        for agent in workers
                    }
                    for agent, future in futures.items():
                        results[agent] = future.result()
                if run_id not in self.cancelled:
                    evidence = "\n\n".join(
                        f"Worker {agent}:\n{result}"
                        for agent, result in results.items()
                    )
                    coordinator_prompt = (
                        "You are coordinator. Complete the user task using worker "
                        "findings. Verify conflicts and produce the final useful result."
                        f"\n\nUser task:\n{text}\n\nWorker findings:\n{evidence}"
                    )
                    results[lead] = self._run_agent(
                        run_id,
                        session_id,
                        lead,
                        coordinator_prompt,
                        model,
                        attachments,
                        permission,
                        events,
                        initial_phase="coordinating",
                        initial_detail="Menggabungkan hasil agent dan menyelesaikan task",
                    )
            else:
                selected = effective_agent_ids
                with concurrent.futures.ThreadPoolExecutor(
                    max_workers=len(selected)
                ) as executor:
                    futures = {
                        agent: executor.submit(
                            self._run_agent,
                            run_id,
                            session_id,
                            agent,
                            text,
                            model,
                            attachments,
                            permission,
                            events,
                        )
                        for agent in selected
                    }
                    for agent, future in futures.items():
                        results[agent] = future.result()
            if run_id in self.cancelled:
                events.put({"type": "stopped", "run_id": run_id})
                return
            combined = "\n\n".join(
                f"**{agent}**\n\n{result}"
                for agent, result in results.items()
                if result
            )
            if combined:
                self.store.append_message(session_id, "assistant", combined)
            failed = not any(results.values())
            current_git_state = self._git_changed_state(task_workspace)
            changed_files = sum(
                1
                for path in baseline_git_state.keys() | current_git_state.keys()
                if baseline_git_state.get(path) != current_git_state.get(path)
            )
            completion_detail = (
                "Task gagal" if failed else f"Task selesai • {changed_files} file berubah"
            )
            self.store.update(session_id, status="failed" if failed else "idle")
            final_status = "failed" if failed else "completed"
            self._finish_pending_agent_states(
                run_id,
                "failed" if failed else "completed",
                "failed" if failed else "completed",
                completion_detail,
            )
            self._update_task(
                run_id,
                status=final_status,
                detail=completion_detail,
                changedFiles=changed_files,
            )
            self.store.append_activity(
                session_id,
                run_id,
                "+".join(effective_agent_ids),
                "failed" if failed else "completed",
                "failed" if failed else "completed",
                completion_detail,
            )
            events.put({"type": "completed", "ok": not failed, "run_id": run_id})
        finally:
            with self.lock:
                self.cancelled.discard(run_id)
                if self.session_runs.get(session_id) == run_id:
                    self.session_runs.pop(session_id, None)
            events.put({"type": "runtime_done", "run_id": run_id})
