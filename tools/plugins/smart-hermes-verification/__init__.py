"""Pass bounded telemetry using Hermes middleware; never rewrite conversation history."""
import threading
import time
from collections import OrderedDict
from .evidence import tool_failure

_states = OrderedDict()
_lock = threading.RLock()
VERIFY_PREFIX = '[System: You edited code in this turn, but the workspace does not have '


def _session(session_id='', task_id='', **kwargs):
    return str(session_id or task_id or '').removeprefix('session:')


def _find_state(sid, turn_id=''):
    if turn_id:
        return _states.get((sid, str(turn_id)))
    matches = [value for (session, _), value in _states.items() if session == sid]
    # Missing turn IDs are usable only when ownership is unambiguous.
    return matches[0] if len(matches) == 1 else None


def observe_tool(result=None, status=None, tool_name='', **kwargs):
    sid = _session(**kwargs)
    with _lock:
        state = _find_state(sid, kwargs.get('turn_id', ''))
        if state is None:
            return
        failed = tool_failure(result, tool_name, kwargs.get('args'), status) is not None
        if failed:
            state['failures'] += 1
            state['failure_total'] += 1
        elif tool_name != 'execute_code':
            # A wrapper can succeed after a nested tool failed; preserve that evidence.
            state['failures'] = 0


def observe_api(usage=None, **kwargs):
    with _lock:
        state = _find_state(_session(**kwargs), kwargs.get('turn_id', ''))
        if state is not None:
            usage = usage if isinstance(usage, dict) else {}
            for field, fallback in [('output_tokens', 'completion_tokens'), ('input_tokens', 'prompt_tokens'),
                                    ('cache_read_tokens', 'cache_read_tokens')]:
                try:
                    value = usage.get('prompt_tokens') if field == 'input_tokens' else usage.get(field)
                    if value is None:
                        value = usage.get(field) if field == 'input_tokens' else usage.get(fallback)
                    state[field] += max(0, int(value or 0))
                except (ValueError, TypeError, OverflowError):
                    pass


def request(request=None, model='', turn_id='', **kwargs):
    if model != 'SmartHermes' or not isinstance(request, dict):
        return None
    sid = _session(**kwargs)
    if not sid or not turn_id:
        return None
    with _lock:
        scope = (sid, str(turn_id))
        state = _states.get(scope)
        if state is None:
            state = {'turn': str(turn_id), 'started': time.monotonic(), 'failures': 0, 'failure_total': 0,
                     'output_tokens': 0, 'input_tokens': 0, 'cache_read_tokens': 0}
            _states[scope] = state
        _states.move_to_end(scope)
        while len(_states) > 128:
            _states.popitem(last=False)
        updated = dict(request)
        headers = dict(updated.get('extra_headers') or {})
        headers.update({'X-SmartHermes-Session': sid, 'X-SmartHermes-Turn': str(turn_id),
                        'X-SmartHermes-Work-Scope': 'background' if threading.current_thread().name == 'bg-review' else 'foreground',
                        'X-SmartHermes-Failures': str(state['failures']),
                        'X-SmartHermes-Output-Tokens': str(state['output_tokens']),
                        'X-SmartHermes-Input-Tokens': str(state['input_tokens']),
                        'X-SmartHermes-Cache-Read-Tokens': str(state['cache_read_tokens']),
                        'X-SmartHermes-Failure-Total': str(state['failure_total']),
                        'X-SmartHermes-Elapsed': str(int(time.monotonic() - state['started']))})
        updated['extra_headers'] = headers
        return {'request': updated, 'source': 'smart-hermes', 'reason': 'session-scoped routing telemetry'}


def check(*, session_id='', model='', attempt=0, changed_paths=None, **kwargs):
    if model != 'SmartHermes' or not changed_paths or attempt >= 2:
        return None
    from agent.verification_stop import build_verify_on_stop_nudge
    nudge = build_verify_on_stop_nudge(session_id=session_id, changed_paths=changed_paths, attempts=0, max_attempts=1)
    if not nudge:
        return None
    if attempt == 0:
        return {'action': 'continue', 'message': nudge}
    return {'action': 'continue', 'message': (
        '[SmartHermes: verification attempt budget exhausted]\n'
        'Stop repair attempts. Report FAIL or BLOCKED with actual evidence and remaining blocker. '
        'Do not claim PASS or completion without fresh passing evidence.')}


def register(ctx):
    ctx.register_middleware('llm_request', request)
    ctx.register_hook('post_tool_call', observe_tool)
    ctx.register_hook('post_api_request', observe_api)
    ctx.register_hook('pre_verify', check)
