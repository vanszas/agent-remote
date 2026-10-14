"""Shared, bounded interpretation of tool results; no provider dependencies."""
import ast
import json
import re

EXECUTION_TOOLS = {'terminal', 'execute_code', 'exec_command', 'write_stdin'}
TRACEBACK = re.compile(
    r'Traceback \(most recent call last\):[\s\S]*?^\s*(?:LogPython:\s*Error:\s*)?'
    r'((?:[A-Z][\w.]*(?:Error|Exception)|Exception):[^\n]*)', re.M)
SYNTAX_ERROR = re.compile(r'^\s*LogPython:\s*Error:\s*((?:SyntaxError|IndentationError|TabError):[^\n]*)', re.M)


def read_command(command):
    parts = [p.strip() for p in re.split(r';|&&|\||\n', command) if p.strip()]
    return bool(parts) and all(re.match(r'(?i)^(rg|grep|cat|tail|head|Get-Content|Select-String)\b', p) for p in parts)


def reading_output(tool_name, arguments):
    if tool_name not in EXECUTION_TOOLS:
        return True
    try:
        args = json.loads(arguments) if isinstance(arguments, str) else arguments
    except (ValueError, TypeError):
        args = None
    args = args if isinstance(args, dict) else {}
    command = str(args.get('command') or args.get('cmd') or '').strip()
    if read_command(command):
        return True
    code = str(args.get('code') or '')
    try:
        tree = ast.parse(code)
    except SyntaxError:
        return False
    commands = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        name = node.func.id if isinstance(node.func, ast.Name) else getattr(node.func, 'attr', '')
        if name != 'terminal':
            continue
        values = [k.value for k in node.keywords if k.arg in ('command', 'cmd')]
        for value in node.args:
            if isinstance(value, ast.Dict):
                values += [v for k, v in zip(value.keys, value.values)
                           if isinstance(k, ast.Constant) and k.value in ('command', 'cmd')]
        if not values:
            return False
        for value in values:
            if isinstance(value, ast.Constant) and isinstance(value.value, str):
                commands.append(value.value.strip())
            elif isinstance(value, ast.JoinedStr):
                commands.append(''.join(v.value if isinstance(v, ast.Constant) and isinstance(v.value, str)
                                        else '_dynamic_' for v in value.values).strip())
            else:
                return False
    if commands:
        return all(read_command(c) for c in commands)
    # Allow only simple read/print statements, never arbitrary Python containing a read.
    calls = [n for n in ast.walk(tree) if isinstance(n, ast.Call)]
    names = [n.func.id if isinstance(n.func, ast.Name) else getattr(n.func, 'attr', '') for n in calls]
    return (any(n in ('read_file', 'search_files', 'read_text') for n in names)
            and all(n in ('Path', 'print', 'read_file', 'search_files', 'read_text') for n in names)
            and all(isinstance(n, (ast.Import, ast.ImportFrom, ast.Expr, ast.Assign)) for n in tree.body))


def tool_failure(content, tool_name='', arguments=None, status=None, depth=0):
    # ponytail: four wrapper levels, eight children and 64KB trace scan; deeper formats need adapters.
    if depth > 4:
        return None
    result = content
    if isinstance(content, str):
        try:
            result = json.loads(content)
        except ValueError:
            pass
    if isinstance(result, dict):
        if 'not an error' in str(result.get('exit_code_meaning', '')).lower():
            return None
        if (result.get('error') or result.get('status') in ('error', 'failed', 'cancelled')
                or isinstance(result.get('exit_code'), int) and result['exit_code'] != 0):
            return {'kind': 'reported', 'detail': str(result.get('error') or result.get('status') or
                                                     'nonzero exit code')[:240]}
        for key in ('output', 'stdout', 'stderr', 'result', 'results'):
            nested = result.get(key)
            if nested is not None:
                failure = tool_failure(nested, tool_name, arguments, depth=depth+1)
                if failure:
                    return failure
    elif isinstance(result, list):
        for nested in result[:8]:
            failure = tool_failure(nested, tool_name, arguments, depth=depth+1)
            if failure:
                return failure
    elif isinstance(result, str) and not reading_output(tool_name, arguments):
        failure = TRACEBACK.search(result[-65536:]) or SYNTAX_ERROR.search(result[-65536:])
        if failure:
            return {'kind': 'execution', 'detail': failure.group(1).strip()[:240]}
        for line in result.splitlines()[:32]:
            if line.strip().startswith('{'):
                try:
                    nested = json.loads(line)
                except ValueError:
                    continue
                failure = tool_failure(nested, tool_name, arguments, depth=depth+1)
                if failure:
                    return failure
    if status in ('error', 'failed', 'cancelled'):
        return {'kind': 'reported', 'detail': status}
    return None
