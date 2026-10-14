import json
import logging
import os
import re
import socket
import sys
import threading
import time
import urllib.error
import urllib.request
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] [SmartRouter] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
logger = logging.getLogger("SmartRouter")

STATE_ROOT = Path(
    os.environ.get("LOCALAPPDATA", Path.home() / ".agent-remote")
) / "AgentRemote"
CONFIG_FILE = STATE_ROOT / "router_config.json"
ROUTER_MUTEX_NAME = "Local\\AgentRemoteSmartRouterProxy"

DEFAULT_CONFIG: dict[str, Any] = {
    "enabled": True,
    "mode": "auto",  # "auto", "simple_only", "complex_only", "off"
    "simple_model": "ag/gemini-3.8-flash-high",
    "complex_model": "x-kiro/anthropic/claude-opus-5.5",
    "fallback_models": [
        "ag/gemini-3.7-flash-high",
        "ag/claude-sonnet-4-6",
        "x-kiro/anthropic/claude-sonnet-4.6",
        "free-model",
    ],
    "complexity_threshold": 35,
    "listen_host": "127.0.0.1",
    "listen_port": 20130,
    "upstream_url": "http://localhost:20128/v1",
}

_CONFIG_LOCK = threading.RLock()
_CURRENT_CONFIG: dict[str, Any] = {}
_LAST_CONFIG_MTIME: float = 0.0
_LAST_ROUTING_HISTORY: list[dict[str, Any]] = []
_HISTORY_LOCK = threading.Lock()
_MAX_HISTORY = 30


def load_config() -> dict[str, Any]:
    global _CURRENT_CONFIG, _LAST_CONFIG_MTIME
    with _CONFIG_LOCK:
        STATE_ROOT.mkdir(parents=True, exist_ok=True)
        if not CONFIG_FILE.is_file():
            save_config(DEFAULT_CONFIG)
            _CURRENT_CONFIG = dict(DEFAULT_CONFIG)
            return _CURRENT_CONFIG

        try:
            mtime = CONFIG_FILE.stat().st_mtime
            with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                loaded = json.load(f)
            cfg = dict(DEFAULT_CONFIG)
            cfg.update(loaded)
            _CURRENT_CONFIG = cfg
            _LAST_CONFIG_MTIME = mtime
            return _CURRENT_CONFIG
        except Exception as e:
            logger.error(f"Failed to load config, using default: {e}")
            _CURRENT_CONFIG = dict(DEFAULT_CONFIG)
            return _CURRENT_CONFIG


def save_config(cfg: dict[str, Any]) -> None:
    global _CURRENT_CONFIG, _LAST_CONFIG_MTIME
    with _CONFIG_LOCK:
        STATE_ROOT.mkdir(parents=True, exist_ok=True)
        temp_file = CONFIG_FILE.with_suffix(".tmp")
        with open(temp_file, "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=2, ensure_ascii=False)
        temp_file.replace(CONFIG_FILE)
        _CURRENT_CONFIG = dict(cfg)
        try:
            _LAST_CONFIG_MTIME = CONFIG_FILE.stat().st_mtime
        except Exception:
            pass


def get_config() -> dict[str, Any]:
    global _LAST_CONFIG_MTIME
    with _CONFIG_LOCK:
        try:
            if CONFIG_FILE.is_file() and CONFIG_FILE.stat().st_mtime != _LAST_CONFIG_MTIME:
                return load_config()
        except Exception:
            pass
        if not _CURRENT_CONFIG:
            return load_config()
        return dict(_CURRENT_CONFIG)


def record_routing_event(event: dict[str, Any]) -> None:
    with _HISTORY_LOCK:
        _LAST_ROUTING_HISTORY.insert(0, event)
        if len(_LAST_ROUTING_HISTORY) > _MAX_HISTORY:
            _LAST_ROUTING_HISTORY.pop()


def get_routing_history() -> list[dict[str, Any]]:
    with _HISTORY_LOCK:
        return list(_LAST_ROUTING_HISTORY)


def calculate_prompt_complexity(messages: list[dict[str, Any]], tools: list[Any] | None = None) -> tuple[int, list[str]]:
    score = 0
    reasons: list[str] = []

    if not messages:
        return 0, ["empty_messages"]

    # Focus on the last 3 messages and latest user message
    last_user_content = ""
    total_chars = 0
    for m in reversed(messages):
        content = m.get("content") or ""
        if isinstance(content, list):
            # multi-part content
            text_parts = []
            for part in content:
                if isinstance(part, dict) and part.get("type") == "text":
                    text_parts.append(part.get("text", ""))
            content = " ".join(text_parts)
        elif not isinstance(content, str):
            content = str(content)

        total_chars += len(content)
        if m.get("role") == "user" and not last_user_content:
            last_user_content = content

    # 1. Length scoring
    user_len = len(last_user_content)
    if user_len > 2500 or total_chars > 20000:
        score += 35
        reasons.append("long_prompt")
    elif user_len > 800 or total_chars > 8000:
        score += 20
        reasons.append("medium_prompt")
    elif user_len < 100 and total_chars < 500:
        score -= 15
        reasons.append("short_prompt")

    # 2. Code presence
    code_blocks = len(re.findall(r"```[\s\S]*?```", last_user_content))
    if code_blocks > 0:
        score += min(code_blocks * 15, 30)
        reasons.append(f"{code_blocks}_code_blocks")

    # 3. Stack trace / Errors
    error_patterns = [
        r"Traceback \(most recent call last\)",
        r"(?:Exception|Error|Fatal|panic):",
        r"Failed to (?:build|compile|start|connect|bind)",
        r"exit code [1-9]",
        r"NullReferenceException|NullPointerException",
    ]
    for pat in error_patterns:
        if re.search(pat, last_user_content, re.IGNORECASE):
            score += 25
            reasons.append("error_or_stacktrace")
            break

    # 4. High complexity keywords (ID & EN)
    complex_keywords = [
        r"\b(?:refactor|architecture|arsitektur|debug|debugging|investigate|investigasi)\b",
        r"\b(?:optimize|optimasi|optimization|memory leak|deadlock|race condition)\b",
        r"\b(?:deep reasoning|step by step|audit|security vulnerability|concurrency)\b",
        r"\b(?:slate|unreal engine|c\+\+|subsystem|pipeline|assembly|kernel)\b",
        r"\b(?:algoritma|algorithm|kompleks|multi-thread|profiling|benchmark)\b",
    ]
    for pat in complex_keywords:
        matches = re.findall(pat, last_user_content, re.IGNORECASE)
        if matches:
            score += 15
            reasons.append(f"kw_{matches[0].lower()}")

    # 5. Low complexity keywords (penurunan skor)
    simple_keywords = [
        r"\b(?:halo|hai|hi|hello|ping|test|tes|pagi|siang|malam)\b",
        r"\b(?:terima kasih|makasih|thanks|thank you|ok|oke|sip|siap)\b",
        r"\b(?:jam berapa|cuaca|siapa kamu|who are you|bantu singkat)\b",
    ]
    for pat in simple_keywords:
        if re.search(pat, last_user_content, re.IGNORECASE) and user_len < 200:
            score -= 20
            reasons.append("casual_conversation")
            break

    # 6. Tools richness
    if tools and len(tools) > 8:
        score += 10
        reasons.append("large_toolset")

    # Clamp score to [0, 100]
    final_score = max(0, min(100, score))
    return final_score, reasons


def get_upstream_api_key() -> str:
    db = Path(os.environ.get("APPDATA", Path.home())) / "9router" / "db" / "data.sqlite"
    if not db.is_file():
        return ""
    try:
        import sqlite3
        conn = sqlite3.connect(f"file:{db.as_posix()}?mode=ro", uri=True, timeout=2)
        cur = conn.cursor()
        cur.execute("SELECT key FROM apiKeys WHERE isActive = 1 ORDER BY createdAt DESC LIMIT 1")
        row = cur.fetchone()
        conn.close()
        return str(row[0]) if row and row[0] else ""
    except Exception:
        return ""


DEGRADED_MODELS: dict[str, float] = {}  # model_name -> cooldown_expiry
DEGRADED_LOCK = threading.Lock()
DEGRADED_COOLDOWN_SEC = 45.0


def is_model_degraded(model_name: str) -> bool:
    with DEGRADED_LOCK:
        expiry = DEGRADED_MODELS.get(model_name)
        if expiry is None:
            return False
        if time.time() > expiry:
            DEGRADED_MODELS.pop(model_name, None)
            return False
        return True


def mark_model_degraded(model_name: str) -> None:
    with DEGRADED_LOCK:
        DEGRADED_MODELS[model_name] = time.time() + DEGRADED_COOLDOWN_SEC
        logger.warning(f"Model '{model_name}' marked degraded (cooldown {DEGRADED_COOLDOWN_SEC}s)")


def determine_model_candidates(
    requested_model: str,
    messages: list[dict[str, Any]],
    tools: list[Any] | None,
    cfg: dict[str, Any],
) -> tuple[str, list[str], int, list[str]]:
    mode = cfg.get("mode", "auto")
    simple_model = cfg.get("simple_model", "ag/gemini-3.8-flash-high")
    complex_model = cfg.get("complex_model", "ag/claude-opus-4-6-thinking")
    fallbacks = list(cfg.get("fallback_models") or [])
    threshold = int(cfg.get("complexity_threshold", 35))

    score, reasons = calculate_prompt_complexity(messages, tools)

    is_dynamic_target = (
        not requested_model
        or requested_model in ("smart-router", "auto", "default", "gemini-model")
    )

    if not cfg.get("enabled", True) or mode == "off":
        primary = requested_model if requested_model and requested_model != "smart-router" else simple_model
    elif mode == "simple_only":
        primary = simple_model
    elif mode == "complex_only":
        primary = complex_model
    else:  # mode == "auto"
        if is_dynamic_target:
            primary = complex_model if score >= threshold else simple_model
        else:
            primary = requested_model

    candidates = [primary]
    if primary == complex_model and simple_model not in candidates:
        candidates.append(simple_model)
    for m in fallbacks:
        if m and m not in candidates:
            candidates.append(m)

    # Sort candidates so degraded/hanging models are moved to the end
    healthy_candidates = [m for m in candidates if not is_model_degraded(m)]
    degraded_candidates = [m for m in candidates if is_model_degraded(m)]
    sorted_candidates = healthy_candidates + degraded_candidates
    if sorted_candidates:
        primary = sorted_candidates[0]

    return primary, sorted_candidates, score, reasons


class SmartRouterHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *args: Any) -> None:
        pass  # Suppress default noisy stdlib HTTP logs

    def _send_json(self, status: int, data: Any) -> None:
        payload = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.end_headers()
        self.wfile.write(payload)

    def do_OPTIONS(self) -> None:
        self.send_response(HTTPStatus.NO_CONTENT)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.end_headers()

    def do_GET(self) -> None:
        path = self.path.split("?")[0]
        cfg = get_config()
        upstream = cfg.get("upstream_url", "http://localhost:20128/v1").rstrip("/")

        if path in ("/health", "/api/status", "/v1/health"):
            self._send_json(
                HTTPStatus.OK,
                {
                    "status": "ok",
                    "service": "SmartRouterProxy",
                    "port": cfg.get("listen_port", 20130),
                    "upstream": upstream,
                    "mode": cfg.get("mode", "auto"),
                    "simple_model": cfg.get("simple_model"),
                    "complex_model": cfg.get("complex_model"),
                    "history": get_routing_history()[:5],
                },
            )
            return

        if path in ("/v1/models", "/models"):
            # Fetch models from upstream 9router and inject 'smart-router'
            try:
                req = urllib.request.Request(f"{upstream}/models")
                auth = self.headers.get("Authorization")
                if not auth or auth.strip() in ("Bearer", "Bearer undefined", "Bearer null"):
                    upstream_key = get_upstream_api_key()
                    if upstream_key:
                        auth = f"Bearer {upstream_key}"
                if auth:
                    req.add_header("Authorization", auth)
                with urllib.request.urlopen(req, timeout=8) as res:
                    data = json.loads(res.read().decode("utf-8"))
                    models_list = data.get("data", [])
                    # Inject smart-router as top entry
                    smart_entry = {
                        "id": "smart-router",
                        "object": "model",
                        "created": int(time.time()),
                        "owned_by": "smart-router",
                        "description": "Auto Dynamic Complexity Router (LiteLLM Heuristic + 9Router Fallback)",
                    }
                    data["data"] = [smart_entry] + [m for m in models_list if m.get("id") != "smart-router"]
                    self._send_json(HTTPStatus.OK, data)
                    return
            except Exception as e:
                logger.error(f"Failed to proxy /v1/models: {e}")
                self._send_json(
                    HTTPStatus.OK,
                    {
                        "object": "list",
                        "data": [
                            {"id": "smart-router", "object": "model", "owned_by": "smart-router"},
                            {"id": cfg.get("simple_model"), "object": "model", "owned_by": "fallback"},
                            {"id": cfg.get("complex_model"), "object": "model", "owned_by": "fallback"},
                        ],
                    },
                )
                return

        self._send_json(HTTPStatus.NOT_FOUND, {"error": "Not found"})

    def do_POST(self) -> None:
        path = self.path.split("?")[0]
        cfg = get_config()
        upstream = cfg.get("upstream_url", "http://localhost:20128/v1").rstrip("/")

        if path not in ("/v1/chat/completions", "/chat/completions"):
            self._send_json(HTTPStatus.NOT_FOUND, {"error": "Endpoint not supported"})
            return

        content_length = int(self.headers.get("Content-Length", 0))
        body_bytes = self.rfile.read(content_length)

        try:
            body = json.loads(body_bytes.decode("utf-8"))
        except Exception as e:
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": f"Invalid JSON: {e}"})
            return

        requested_model = body.get("model", "")
        messages = body.get("messages", [])
        tools = body.get("tools")
        is_stream = bool(body.get("stream", False))

        primary_model, candidates, score, reasons = determine_model_candidates(
            requested_model, messages, tools, cfg
        )

        auth_header = self.headers.get("Authorization", "")
        if not auth_header or auth_header.strip() in ("Bearer", "Bearer undefined", "Bearer null"):
            upstream_key = get_upstream_api_key()
            if upstream_key:
                auth_header = f"Bearer {upstream_key}"
        last_error_code = HTTPStatus.BAD_GATEWAY
        last_error_body = b'{"error":"All fallback models failed"}'

        for attempt_idx, model_target in enumerate(candidates):
            attempt_payload = dict(body)
            attempt_payload["model"] = model_target
            payload_data = json.dumps(attempt_payload, ensure_ascii=False).encode("utf-8")

            req = urllib.request.Request(
                f"{upstream}/chat/completions",
                data=payload_data,
                method="POST",
            )
            req.add_header("Content-Type", "application/json")
            if auth_header:
                req.add_header("Authorization", auth_header)

            try:
                upstream_resp = urllib.request.urlopen(req, timeout=25)
                # Success HTTP 200
                logger.info(
                    f"Routed prompt [score={score}, reasons={reasons}] -> '{model_target}' (attempt {attempt_idx+1}/{len(candidates)}) [OK 200]"
                )

                record_routing_event({
                    "timestamp": time.time(),
                    "requested": requested_model,
                    "routed": model_target,
                    "score": score,
                    "reasons": reasons,
                    "attempts": attempt_idx + 1,
                    "status": "success",
                })

                # Stream or return response
                self.send_response(HTTPStatus.OK)
                for header_name, header_val in upstream_resp.getheaders():
                    if header_name.lower() in ("content-type", "cache-control", "connection"):
                        self.send_header(header_name, header_val)
                self.send_header("X-Accel-Buffering", "no")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("X-SmartRouter-Selected-Model", model_target)
                self.send_header("X-SmartRouter-Complexity-Score", str(score))
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()

                try:
                    while True:
                        chunk = upstream_resp.read(4096)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        self.wfile.flush()
                except (ConnectionResetError, BrokenPipeError):
                    pass
                return

            except urllib.error.HTTPError as e:
                err_data = e.read()
                last_error_code = e.code
                last_error_body = err_data
                err_summary = err_data.decode("utf-8", errors="ignore")[:160]

                logger.warning(
                    f"Model '{model_target}' failed with HTTP {e.code} ({err_summary}). Checking fallback..."
                )
                mark_model_degraded(model_target)

                # If quota exhausted (429), unauthorized (401/403), or provider error (500/502/503/504), continue to next fallback
                if e.code in (429, 401, 403, 500, 502, 503, 504) or "quota" in err_summary.lower() or "rate" in err_summary.lower() or "wait" in err_summary.lower():
                    continue
                else:
                    self.send_response(e.code)
                    self.send_header("Content-Type", "application/json")
                    self.end_headers()
                    self.wfile.write(err_data)
                    return

            except Exception as e:
                logger.warning(f"Connection/Timeout to upstream for '{model_target}': {e}. Marking degraded & falling back...")
                mark_model_degraded(model_target)
                continue

        # If all candidates failed
        logger.error(f"All candidates failed for request: {candidates}")
        record_routing_event({
            "timestamp": time.time(),
            "requested": requested_model,
            "routed": candidates[0] if candidates else "",
            "score": score,
            "reasons": reasons,
            "attempts": len(candidates),
            "status": "failed",
        })
        self.send_response(last_error_code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(last_error_body)


def run_server(host: str = "127.0.0.1", port: int = 20130) -> None:
    cfg = load_config()
    server_port = int(cfg.get("listen_port", port))
    server_host = str(cfg.get("listen_host", host))

    server = ThreadingHTTPServer((server_host, server_port), SmartRouterHandler)
    logger.info(f"SmartRouter proxy listening on http://{server_host}:{server_port}")
    logger.info(f"Upstream 9Router: {cfg.get('upstream_url')}")
    logger.info(f"Simple Model: {cfg.get('simple_model')} | Complex Model: {cfg.get('complex_model')}")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("Stopping SmartRouter proxy...")
    finally:
        server.server_close()


if __name__ == "__main__":
    port_arg = int(sys.argv[1]) if len(sys.argv) > 1 else 20130
    run_server(port=port_arg)
