import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_remote/agent_connector.dart';
import 'package:hermes_remote/app_controller.dart';
import 'package:hermes_remote/hermes_remote_connector.dart';

void main() {
  test('decodes git status and workspace tree', () {
    expect(
      decodeGitStatus({
        'files': [
          {'path': 'lib/a.dart', 'status': 'modified'},
          {'path': 'new.txt', 'status': 'untracked'},
        ],
      }).map((e) => (e.path, e.status)),
      [
        ('lib/a.dart', GitFileStatus.modified),
        ('new.txt', GitFileStatus.untracked),
      ],
    );
    expect(
      decodeWorkspaceEntries({
        'entries': [
          {'name': 'lib', 'path': 'lib', 'kind': 'directory'},
        ],
      }).single.isDirectory,
      isTrue,
    );
    final repository = decodeGitRepositoryStatus({
      'is_git_repo': true,
      'branch': 'main',
      'upstream': 'origin/main',
      'additions': 81,
      'deletions': 55,
      'github_cli_installed': true,
      'github_cli_authenticated': true,
      'github_cli_user': 'ivan',
    });
    expect(repository.upstream, 'origin/main');
    expect(repository.additions, 81);
    expect(repository.deletions, 55);
    expect(repository.githubCliAuthenticated, isTrue);
  });

  test('decodes per-agent task state and legacy payload', () {
    final task = decodeAgentTask({
      'id': 'run-1',
      'title': 'Upgrade backend',
      'status': 'running',
      'agents': ['codex', 'claude'],
      'activeAgent': 'claude',
      'agentStates': [
        {
          'id': 'codex',
          'name': 'Codex',
          'status': 'running',
          'phase': 'testing',
          'detail': 'flutter test',
        },
        {
          'id': 'claude',
          'name': 'Claude Code',
          'status': 'running',
          'phase': 'editing',
          'detail': 'Editing API',
        },
      ],
    });
    expect(task.agentStates, hasLength(2));
    expect(task.activeAgentState?.name, 'Claude Code');
    expect(task.activeAgentState?.phase, 'editing');

    final legacy = decodeAgentTask({
      'id': 'run-old',
      'status': 'running',
      'detail': 'Thinking',
      'agents': ['codex'],
    });
    expect(legacy.agentStates.single.id, 'codex');
    expect(legacy.agentStates.single.detail, 'Thinking');
  });

  test('decodes security audit without credentials', () {
    final audit = decodeSecurityAudit({
      'peer_ip_only': true,
      'success_window_seconds': 900,
      'failure_window_seconds': 10,
      'entries': [
        {
          'timestamp': '2026-07-18T13:00:00Z',
          'event': 'access_granted',
          'ip_address': '100.64.0.5',
          'method': 'GET',
          'path': '/api/status',
          'user_agent': 'AgentRemote/0.3.0',
        },
      ],
    });
    expect(audit.peerIpOnly, isTrue);
    expect(audit.successWindowSeconds, 900);
    expect(audit.failureWindowSeconds, 10);
    expect(audit.entries.single.authorized, isTrue);
    expect(audit.entries.single.ipAddress, '100.64.0.5');
    expect(audit.entries.single.path, '/api/status');
  });

  test('classifies error 103 and shows actionable connection guidance', () {
    final error = SocketException(
      'Software caused connection abort',
      osError: const OSError('Software caused connection abort', 103),
    );

    expect(isTransientRemoteConnectionError(error), isTrue);
    expect(connectionErrorMessage(error), contains('Tailscale HP aktif'));
    expect(
      connectionErrorMessage(
        const HttpException('HTTP 401: {"error":"unauthorized"}'),
      ),
      'Login ditolak. Periksa username atau password.',
    );
  });

  test('decodes provider usage filters and recent token flow', () {
    final usage = decodeProviderUsage({
      'available': true,
      'source': '9router',
      'range': '24h',
      'summary': {
        'requests': 3,
        'input_tokens': 1200,
        'output_tokens': 45,
        'cached_tokens': 900,
        'estimated_cost': 0.42,
      },
      'providers': ['codex'],
      'models': ['gpt-5.6-sol'],
      'active': {
        'timestamp': '2026-07-18T13:00:00Z',
        'provider': 'codex',
        'model': 'gpt-5.6-sol',
        'endpoint': '/v1/responses',
        'input_tokens': 1000,
        'output_tokens': 40,
        'cached_tokens': 800,
        'cost': 0.4,
        'status': 'ok',
        'is_active': true,
      },
      'recent': [],
      'attribution': 'all_9router_requests_on_pc',
      'scope': 'mobile',
      'mobile_filter_available': true,
      'mobile_key_name': 'Agent Remote Mobile',
    });

    expect(usage.summary.inputTokens, 1200);
    expect(usage.summary.cachedTokens, 900);
    expect(usage.active?.model, 'gpt-5.6-sol');
    expect(usage.active?.isActive, isTrue);
    expect(usage.models, ['gpt-5.6-sol']);
    expect(usage.scope, 'mobile');
    expect(usage.mobileFilterAvailable, isTrue);
    expect(usage.mobileKeyName, 'Agent Remote Mobile');
  });

  test('decodes workspace file preview and edit metadata', () {
    final file = decodeWorkspaceFile({
      'file': {
        'path': 'lib/main.dart',
        'name': 'main.dart',
        'content': 'void main() {}\n',
        'diff': '+void main() {}',
        'hash': 'abc123',
        'size': 15,
        'line_count': 2,
        'exists': true,
        'editable': true,
        'git_status': 'modified',
        'max_bytes': 524288,
        'modified_at': '2026-07-18T13:00:00Z',
      },
    });

    expect(file.path, 'lib/main.dart');
    expect(file.editable, isTrue);
    expect(file.gitStatus, 'modified');
    expect(file.lineCount, 2);
    expect(file.modifiedAt, DateTime.utc(2026, 7, 18, 13));
  });
}
