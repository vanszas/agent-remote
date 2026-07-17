import concurrent.futures
import json
import queue
import shutil
import subprocess
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def new_id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex}"


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
    event_type = str(event.get("type") or "")
    item = event.get("item") if isinstance(event, dict) else None
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
        return [{"type": "delta", "agent_id": agent_id, "text": f"{text}\n"}] if text else []
    if item_type == "reasoning" and event_type in {"item.started", "item.updated", "item.completed"}:
        text = str(item.get("text") or item.get("summary") or "").strip()
        return [{
            "type": "reasoning",
            "agent_id": agent_id,
            "text": text or "Agent sedang menganalisis…",
            "status": "completed" if event_type == "item.completed" else "running",
        }]
    if item_type not in {"command_execution", "mcp_tool_call", "web_search"}:
        return []
    tool_id = str(item.get("id") or new_id("tool"))
    name = "shell" if item_type == "command_execution" else str(item.get("server") or item_type)
    if event_type == "item.started":
        detail = item.get("command") or item.get("query") or item.get("arguments") or ""
        return [{"type": "tool_started", "agent_id": agent_id, "tool_id": tool_id, "name": name, "text": str(detail)}]
    if event_type == "item.completed":
        detail = item.get("aggregated_output") or item.get("output") or item.get("result") or ""
        return [{"type": "tool_completed", "agent_id": agent_id, "tool_id": tool_id, "name": name, "text": str(detail)}]
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

    def delete(self, session_id: str):
        with self.lock:
            if session_id not in self.sessions:
                raise KeyError(session_id)
            del self.sessions[session_id]
            self._save()


class AgentRuntime:
    def __init__(self, store: SessionStore, command_factory, workspace: Path):
        self.store = store
        self.command_factory = command_factory
        self.workspace = workspace
        self.lock = threading.RLock()
        self.processes = {}
        self.session_runs = {}
        self.cancelled = set()
        self.tasks = {}

    def _register(self, run_id: str, session_id: str, process: subprocess.Popen):
        with self.lock:
            self.processes.setdefault(run_id, []).append(process)
            self.session_runs[session_id] = run_id

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
            return json.loads(json.dumps(values[:100]))

    def _update_task(self, run_id: str, **changes):
        with self.lock:
            task = self.tasks.get(run_id)
            if task is None:
                return
            task.update(changes)
            task["updatedAt"] = now_iso()

    def stop_session(self, session_id: str) -> bool:
        with self.lock:
            run_id = self.session_runs.get(session_id)
            if not run_id:
                return False
            self.cancelled.add(run_id)
            processes = list(self.processes.get(run_id, []))
        for process in processes:
            if process.poll() is None:
                process.terminate()
        self.store.update(session_id, status="stopped")
        self._update_task(run_id, status="stopped", detail="Dihentikan pengguna")
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
    ) -> str:
        output = []
        process = None
        try:
            process = subprocess.Popen(
                self.command_factory(agent_id, text, model, attachments, permission),
                cwd=self.workspace,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                encoding="utf-8",
                errors="replace",
                bufsize=1,
            )
            self._register(run_id, session_id, process)
            assert process.stdout is not None
            for raw in process.stdout:
                if run_id in self.cancelled:
                    break
                value = raw.rstrip()
                if not value:
                    continue
                normalized = normalize_codex_event(value, agent_id) if agent_id == "codex" else [
                    {"type": "delta", "agent_id": agent_id, "text": f"{value}\n"}
                ]
                for event in normalized:
                    if event["type"] == "delta":
                        output.append(event["text"])
                    self._update_task(
                        run_id,
                        detail=event.get("text") or event.get("name") or event["type"],
                        activeAgent=agent_id,
                    )
                    events.put(event)
            stderr = process.stderr.read().strip() if process.stderr else ""
            return_code = process.wait(timeout=10)
            if run_id in self.cancelled:
                events.put({"type": "agent_stopped", "agent_id": agent_id})
                return "".join(output).strip()
            if return_code != 0:
                raise RuntimeError(stderr or f"{agent_id} exited with {return_code}")
            events.put({"type": "agent_completed", "agent_id": agent_id})
            return "".join(output).strip()
        except Exception as error:
            events.put({"type": "agent_failed", "agent_id": agent_id, "error": str(error)})
            return ""
        finally:
            if process is not None:
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
        with self.lock:
            self.session_runs[session_id] = run_id
            self.tasks[run_id] = {
                "id": run_id,
                "session_id": session_id,
                "title": text.strip().splitlines()[0][:80] or "Agent task",
                "status": "running",
                "detail": "Menyiapkan agent…",
                "agents": agent_ids,
                "mode": mode,
                "permission": permission,
                "workspace": str(self.workspace),
                "createdAt": timestamp,
                "updatedAt": timestamp,
            }
        self.store.update(
            session_id,
            status="generating",
            activeModelName=" + ".join(agent_ids),
        )
        self.store.append_message(session_id, "user", text)
        results = {}
        try:
            if mode == "coordinator" and len(agent_ids) > 1:
                lead = coordinator if coordinator in agent_ids else agent_ids[0]
                workers = [agent for agent in agent_ids if agent != lead]
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
                    )
            else:
                selected = agent_ids[:1] if mode == "single" else agent_ids
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
            self.store.update(session_id, status="failed" if failed else "idle")
            final_status = "failed" if failed else "completed"
            self._update_task(
                run_id,
                status=final_status,
                detail="Task gagal" if failed else "Task selesai",
            )
            events.put({"type": "completed", "ok": not failed, "run_id": run_id})
        finally:
            with self.lock:
                self.cancelled.discard(run_id)
                if self.session_runs.get(session_id) == run_id:
                    self.session_runs.pop(session_id, None)
            events.put({"type": "runtime_done", "run_id": run_id})
