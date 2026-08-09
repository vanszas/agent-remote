import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'agent_connector.dart';
import 'background_task_monitor.dart';
import 'models.dart';

GitRepositoryStatus decodeGitRepositoryStatus(Map<String, Object?> data) {
  List<GitCommit> commits(String key) =>
      (data[key] as List? ?? const []).whereType<Map>().map((item) {
        final value = Map<String, Object?>.from(item);
        return GitCommit(
          hash: value['hash'] as String? ?? '',
          subject: value['subject'] as String? ?? '',
          author: value['author'] as String? ?? '',
        );
      }).toList();
  return GitRepositoryStatus(
    isGitRepository: data['is_git_repo'] == true,
    branch: data['branch'] as String? ?? '',
    remoteUrl: data['remote_url'] as String? ?? '',
    ahead: data['ahead'] as int? ?? 0,
    behind: data['behind'] as int? ?? 0,
    upstream: data['upstream'] as String? ?? '',
    additions: data['additions'] as int? ?? 0,
    deletions: data['deletions'] as int? ?? 0,
    githubCliInstalled: data['github_cli_installed'] == true,
    githubCliAuthenticated: data['github_cli_authenticated'] == true,
    githubCliUser: data['github_cli_user'] as String? ?? '',
    githubOwner: data['github_owner'] as String? ?? '',
    githubRepository: data['github_repo'] as String? ?? '',
    githubAvatarUrl: data['github_avatar_url'] as String? ?? '',
    incoming: commits('incoming'),
    outgoing: commits('outgoing'),
    nestedRepositories: (data['nested_repositories'] as List? ?? const [])
        .whereType<Map>()
        .map((item) {
          final value = Map<String, Object?>.from(item);
          return GitNestedRepository(
            name: value['name'] as String? ?? '',
            path: value['path'] as String? ?? '',
          );
        })
        .where((item) => item.path.isNotEmpty)
        .toList(),
  );
}

ProviderUsageEntry _decodeProviderUsageEntry(Map<String, Object?> value) =>
    ProviderUsageEntry(
      timestamp:
          DateTime.tryParse(value['timestamp'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      provider: value['provider'] as String? ?? 'unknown',
      model: value['model'] as String? ?? 'unknown',
      endpoint: value['endpoint'] as String? ?? '',
      inputTokens: (value['input_tokens'] as num?)?.toInt() ?? 0,
      outputTokens: (value['output_tokens'] as num?)?.toInt() ?? 0,
      cachedTokens: (value['cached_tokens'] as num?)?.toInt() ?? 0,
      cost: (value['cost'] as num?)?.toDouble() ?? 0,
      status: value['status'] as String? ?? 'unknown',
      isActive: value['is_active'] == true,
    );

DateTime? _decodeDateTime(Object? value) {
  if (value is String) return DateTime.tryParse(value);
  if (value is num) {
    final milliseconds = value.abs() < 100000000000 ? value * 1000 : value;
    return DateTime.fromMillisecondsSinceEpoch(
      milliseconds.toInt(),
      isUtc: true,
    );
  }
  return null;
}

ProviderUsageSnapshot decodeProviderUsage(Map<String, Object?> data) {
  final summary = Map<String, Object?>.from(
    data['summary'] as Map? ?? const {},
  );
  final active = data['active'];
  return ProviderUsageSnapshot(
    available: data['available'] == true,
    source: data['source'] as String? ?? '9router',
    range: data['range'] as String? ?? '24h',
    summary: ProviderUsageSummary(
      requests: (summary['requests'] as num?)?.toInt() ?? 0,
      inputTokens: (summary['input_tokens'] as num?)?.toInt() ?? 0,
      outputTokens: (summary['output_tokens'] as num?)?.toInt() ?? 0,
      cachedTokens: (summary['cached_tokens'] as num?)?.toInt() ?? 0,
      estimatedCost: (summary['estimated_cost'] as num?)?.toDouble() ?? 0,
    ),
    active: active is Map
        ? _decodeProviderUsageEntry(Map<String, Object?>.from(active))
        : null,
    providers: (data['providers'] as List? ?? const [])
        .whereType<String>()
        .toList(),
    models: (data['models'] as List? ?? const []).whereType<String>().toList(),
    recent: (data['recent'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (item) => _decodeProviderUsageEntry(Map<String, Object?>.from(item)),
        )
        .toList(),
    quotaComplete: data['quota_complete'] == true,
    quotaAccounts: (data['quota_accounts'] as List? ?? const [])
        .whereType<Map>()
        .map((item) {
          final account = Map<String, Object?>.from(item);
          return ProviderQuotaAccount(
            id: account['id'] as String? ?? '',
            provider: account['provider'] as String? ?? 'unknown',
            name: account['name'] as String? ?? 'Account',
            active: account['active'] == true,
            status: account['status'] as String? ?? 'unknown',
            plan: account['plan'] as String? ?? '',
            model: account['model'] as String? ?? '',
            lastUsedAt: _decodeDateTime(account['last_used_at']),
            limitReached: account['limit_reached'] == true,
            error: account['error'] as String? ?? '',
            quotas: (account['quotas'] as List? ?? const [])
                .whereType<Map>()
                .map((item) {
                  final quota = Map<String, Object?>.from(item);
                  return ProviderQuotaWindow(
                    id: quota['id'] as String? ?? '',
                    label: quota['label'] as String? ?? 'Quota',
                    usedPercent: (quota['used_percent'] as num?)?.toDouble(),
                    remainingPercent: (quota['remaining_percent'] as num?)
                        ?.toDouble(),
                    resetAt: _decodeDateTime(quota['reset_at']),
                  );
                })
                .toList(),
          );
        })
        .toList(),
    attribution: data['attribution'] as String? ?? '',
    reason: data['reason'] as String? ?? '',
    scope: data['scope'] as String? ?? 'all',
    mobileFilterAvailable: data['mobile_filter_available'] == true,
    mobileKeyName: data['mobile_key_name'] as String? ?? '',
    updatedAt: DateTime.tryParse(data['updated_at'] as String? ?? ''),
  );
}

List<GitStatusEntry> decodeGitStatus(Map<String, Object?> json) =>
    (json['files'] as List? ?? []).whereType<Map>().map((item) {
      final value = Map<String, Object?>.from(item);
      return GitStatusEntry(
        value['path'] as String? ?? '',
        GitFileStatus.values.firstWhere(
          (status) => status.name == value['status'],
          orElse: () => GitFileStatus.modified,
        ),
      );
    }).toList();

List<WorkspaceEntry> decodeWorkspaceEntries(Map<String, Object?> json) =>
    (json['entries'] as List? ?? []).whereType<Map>().map((item) {
      final value = Map<String, Object?>.from(item);
      return WorkspaceEntry(
        value['name'] as String? ?? '',
        value['path'] as String? ?? '',
        value['kind'] == 'directory',
      );
    }).toList();

WorkspaceFileDocument decodeWorkspaceFile(Map<String, Object?> json) {
  final value = Map<String, Object?>.from(json['file'] as Map? ?? json);
  return WorkspaceFileDocument(
    path: value['path'] as String? ?? '',
    name: value['name'] as String? ?? '',
    content: value['content'] as String? ?? '',
    diff: value['diff'] as String? ?? '',
    hash: value['hash'] as String? ?? '',
    size: (value['size'] as num?)?.toInt() ?? 0,
    lineCount: (value['line_count'] as num?)?.toInt() ?? 0,
    exists: value['exists'] != false,
    editable: value['editable'] == true,
    gitStatus: value['git_status'] as String? ?? '',
    maxBytes: (value['max_bytes'] as num?)?.toInt() ?? 0,
    modifiedAt: DateTime.tryParse(value['modified_at'] as String? ?? ''),
  );
}

SecurityAuditSnapshot decodeSecurityAudit(Map<String, Object?> json) {
  final entries = (json['entries'] as List? ?? const []).whereType<Map>().map((
    item,
  ) {
    final value = Map<String, Object?>.from(item);
    return SecurityAuditEntry(
      timestamp:
          DateTime.tryParse(value['timestamp'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      event: value['event'] as String? ?? 'access_denied',
      ipAddress: value['ip_address'] as String? ?? 'unknown',
      method: value['method'] as String? ?? '',
      path: value['path'] as String? ?? '',
      userAgent: value['user_agent'] as String? ?? '',
    );
  }).toList();
  return SecurityAuditSnapshot(
    entries: entries,
    peerIpOnly: json['peer_ip_only'] != false,
    successWindowSeconds:
        (json['success_window_seconds'] as num?)?.toInt() ?? 900,
    failureWindowSeconds:
        (json['failure_window_seconds'] as num?)?.toInt() ?? 10,
  );
}

bool isTransientRemoteConnectionError(Object error) {
  if (error is TimeoutException) return true;
  if (error is! SocketException) return false;
  return const {54, 103, 104, 10053, 10054}.contains(error.osError?.errorCode);
}

enum RemoteExecutionMode { single, parallel, coordinator }

enum RemotePermissionMode { ask, workspace, full }

class RemoteAgentInfo {
  const RemoteAgentInfo({
    required this.id,
    required this.name,
    required this.description,
    required this.supportsStreaming,
    required this.installed,
    required this.command,
  });
  factory RemoteAgentInfo.fromJson(Map<String, Object?> json) =>
      RemoteAgentInfo(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        description: json['description'] as String? ?? '',
        supportsStreaming: json['supports_streaming'] == true,
        installed: json['installed'] == true,
        command: json['command'] as String? ?? '',
      );
  final String id;
  final String name;
  final String description;
  final bool supportsStreaming, installed;
  final String command;
}

class PcFolderListing {
  const PcFolderListing({
    required this.path,
    required this.parent,
    required this.folders,
  });
  final String path;
  final String? parent;
  final List<AgentWorkspace> folders;
}

class AgentRemoteConnector
    implements
        AgentConnector,
        WorkspaceMonitor,
        GitWorkspaceMonitor,
        WorkspaceCatalog,
        PersonalizationConnector,
        SecurityMonitor,
        ProviderUsageMonitor,
        WorkspaceFileEditor {
  AgentRemoteConnector(this.baseUrl, this.token) : _http = HttpClient() {
    _http.connectionTimeout = const Duration(seconds: 10);
  }
  final Uri baseUrl;
  final String token;
  final HttpClient _http;
  final _events = StreamController<AgentEvent>.broadcast();
  final _sessions = <String, AgentSession>{};
  String _workspace = '';
  String model = '';
  List<RemoteAgentInfo> availableAgents = const [];
  Set<String> selectedAgentIds = {};
  RemoteExecutionMode executionMode = RemoteExecutionMode.single;
  RemotePermissionMode permissionMode = RemotePermissionMode.workspace;
  String coordinatorAgentId = '';
  int maxConcurrentAgents = 2;
  int concurrencyLimit = 2;

  @override
  Stream<AgentEvent> get events => _events.stream;
  Map<String, String> get _headers => {
    'Authorization': 'Bearer $token',
    HttpHeaders.userAgentHeader: 'AgentRemote/0.3.0',
  };
  Uri _url(String path, [Map<String, String>? query]) =>
      baseUrl.replace(path: path, queryParameters: query);

  Future<Map<String, Object?>> _get(
    String path, [
    Map<String, String>? query,
  ]) async {
    final uri = _url(path, query);
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final request = await _http
            .getUrl(uri)
            .timeout(const Duration(seconds: 12));
        _headers.forEach(request.headers.set);
        final response = await request.close().timeout(
          const Duration(seconds: 15),
        );
        final body = await utf8
            .decodeStream(response)
            .timeout(const Duration(seconds: 15));
        if (response.statusCode ~/ 100 != 2) {
          throw HttpException('HTTP ${response.statusCode}: $body', uri: uri);
        }
        return Map<String, Object?>.from(jsonDecode(body) as Map);
      } catch (error) {
        if (attempt > 0 || !isTransientRemoteConnectionError(error)) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }
    }
    throw StateError('Remote GET retry exhausted.');
  }

  Future<Map<String, Object?>> _request(
    String method,
    String path, [
    Map<String, Object?> payload = const {},
  ]) async {
    final uri = _url(path);
    final request = await _http
        .openUrl(method, uri)
        .timeout(const Duration(seconds: 12));
    _headers.forEach(request.headers.set);
    request.headers.contentType = ContentType.json;
    if (payload.isNotEmpty) {
      final body = utf8.encode(jsonEncode(payload));
      request.contentLength = body.length;
      request.add(body);
    }
    final response = await request.close().timeout(const Duration(seconds: 15));
    final body = await utf8
        .decodeStream(response)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode ~/ 100 != 2) {
      throw HttpException('HTTP ${response.statusCode}: $body', uri: uri);
    }
    return body.isEmpty
        ? const {}
        : Map<String, Object?>.from(jsonDecode(body) as Map);
  }

  @override
  Future<void> initialize() async {
    final status = await _get('/api/status');
    permissionMode = RemotePermissionMode.values.firstWhere(
      (value) => value.name == status['permission'],
      orElse: () => RemotePermissionMode.workspace,
    );
    maxConcurrentAgents =
        ((status['max_concurrent_agents'] as num?)?.toInt() ?? 2).clamp(1, 8);
    concurrencyLimit = concurrencyLimit.clamp(1, maxConcurrentAgents);
    final data = await _get('/api/agents');
    availableAgents = (data['agents'] as List? ?? [])
        .whereType<Map>()
        .map(
          (item) => RemoteAgentInfo.fromJson(Map<String, Object?>.from(item)),
        )
        .where((agent) => agent.id.isNotEmpty)
        .toList();
    final installedAgents = availableAgents.where((agent) => agent.installed);
    selectedAgentIds = selectedAgentIds
        .where((id) => installedAgents.any((agent) => agent.id == id))
        .toSet();
    if (selectedAgentIds.isEmpty && installedAgents.isNotEmpty) {
      final preferred = installedAgents
          .where((agent) => agent.id == 'codex')
          .firstOrNull;
      selectedAgentIds = {preferred?.id ?? installedAgents.first.id};
    }
    coordinatorAgentId = selectedAgentIds.firstOrNull ?? '';
    await BackgroundTaskMonitor.startCodexSync(
      tasksUrl: _url('/api/tasks').toString(),
      token: token,
    );
    _events.add(const AgentEvent(AgentEventType.connectorReady, sessionId: ''));
  }

  @override
  Future<AgentCapabilities> getCapabilities() async => const AgentCapabilities(
    supportsImages: true,
    supportsFiles: true,
    supportsModelSelection: true,
    supportsApprovals: false,
    supportsClarification: false,
    supportsToolStreaming: true,
    supportsSessionHistory: true,
    supportsSessionRename: true,
    supportsSessionDelete: true,
    supportsStop: true,
  );
  @override
  Future<List<AgentWorkspace>> listWorkspaces() async {
    final data = await _get('/api/workspaces');
    return (data['workspaces'] as List? ?? []).whereType<Map>().map((item) {
      final value = Map<String, Object?>.from(item);
      return AgentWorkspace(
        id: value['id'] as String,
        name: value['name'] as String,
        path: value['path'] as String,
        isActive: value['is_active'] == true,
      );
    }).toList();
  }

  Future<PcFolderListing> browsePcFolders([String path = '']) async {
    final data = await _get('/api/folders', {'path': path});
    final folders = (data['folders'] as List? ?? []).whereType<Map>().map((
      item,
    ) {
      final value = Map<String, Object?>.from(item);
      final folderPath = value['path'] as String? ?? '';
      return AgentWorkspace(
        id: folderPath,
        name: value['name'] as String? ?? folderPath,
        path: folderPath,
      );
    }).toList();
    return PcFolderListing(
      path: data['path'] as String? ?? '',
      parent: data['parent'] as String?,
      folders: folders,
    );
  }

  Future<AgentWorkspace> selectPcWorkspace(String path) async {
    final data = await _request('POST', '/api/workspace', {'path': path});
    final value = Map<String, Object?>.from(data['workspace'] as Map);
    final workspace = AgentWorkspace(
      id: value['id'] as String? ?? path,
      name: value['name'] as String? ?? path,
      path: value['path'] as String? ?? path,
      isActive: true,
    );
    _workspace = workspace.path;
    return workspace;
  }

  @override
  Future<AgentWorkspace> activateWorkspace(String path) async {
    final workspace = await selectPcWorkspace(path);
    final status = await _get('/api/status');
    permissionMode = RemotePermissionMode.values.firstWhere(
      (value) => value.name == status['permission'],
      orElse: () => RemotePermissionMode.workspace,
    );
    return workspace;
  }

  Future<void> setPermissionMode(RemotePermissionMode mode) async {
    await _request('POST', '/api/permission', {'permission': mode.name});
    permissionMode = mode;
  }

  @override
  Future<List<AgentProject>> listProjects({int limit = 20}) async {
    final data = await _get('/api/projects', {'limit': '$limit'});
    return (data['projects'] as List? ?? const []).whereType<Map>().map((item) {
      final value = Map<String, Object?>.from(item);
      final path = value['path'] as String? ?? '';
      return AgentProject(
        workspace: AgentWorkspace(
          id: value['id'] as String? ?? path,
          name: value['name'] as String? ?? path,
          path: path,
          isActive: value['is_active'] == true,
        ),
        sessions: (value['sessions'] as List? ?? const [])
            .whereType<Map>()
            .map(
              (session) =>
                  AgentSession.fromJson(Map<String, Object?>.from(session)),
            )
            .toList(),
        isGitRepository: value['is_git_repo'] == true,
      );
    }).toList();
  }

  @override
  Future<List<GitStatusEntry>> getGitStatus({bool fetch = false}) async =>
      decodeGitStatus(
        await _get('/api/git-status', {'fetch': fetch ? '1' : '0'}),
      );
  @override
  Future<GitRepositoryStatus> getGitRepositoryStatus({
    bool fetch = false,
  }) async => decodeGitRepositoryStatus(
    await _get('/api/git-status', {'fetch': fetch ? '1' : '0'}),
  );
  @override
  Future<GitWorkspaceSnapshot> getGitWorkspaceSnapshot({
    bool fetch = false,
  }) async {
    final data = await _get('/api/git-status', {'fetch': fetch ? '1' : '0'});
    return GitWorkspaceSnapshot(
      files: decodeGitStatus(data),
      repository: decodeGitRepositoryStatus(data),
    );
  }

  @override
  Future<ProviderUsageSnapshot> getProviderUsage({
    String range = '24h',
    String provider = '',
    String model = '',
    String scope = 'all',
    int limit = 50,
  }) async => decodeProviderUsage(
    await _get('/api/provider-usage', {
      'range': range,
      'provider': provider,
      'model': model,
      'scope': scope,
      'limit': '$limit',
    }),
  );
  @override
  Future<List<WorkspaceEntry>> listWorkspace(String path) async =>
      decodeWorkspaceEntries(await _get('/api/tree', {'path': path}));
  @override
  Future<WorkspaceFileDocument> getWorkspaceFile(String path) async =>
      decodeWorkspaceFile(await _get('/api/file', {'path': path}));
  @override
  Future<WorkspaceFileDocument> saveWorkspaceFile({
    required String path,
    required String content,
    required String baseHash,
  }) async => decodeWorkspaceFile(
    await _request('PUT', '/api/file', {
      'path': path,
      'content': content,
      'base_hash': baseHash,
    }),
  );
  @override
  void selectWorkspace(String path) => _workspace = path;
  @override
  Future<List<AgentSession>> listSessions({int limit = 50}) async {
    final data = await _get('/api/sessions', {'limit': '$limit'});
    final sessions = (data['sessions'] as List? ?? [])
        .whereType<Map>()
        .map((item) => AgentSession.fromJson(Map<String, Object?>.from(item)))
        .toList();
    _sessions
      ..clear()
      ..addEntries(sessions.map((session) => MapEntry(session.id, session)));
    return sessions;
  }

  @override
  Future<AgentSession> createSession({
    String? workspaceName,
    String? modelName,
  }) async {
    final data = await _request('POST', '/api/sessions', {
      'workspace_name': workspaceName ?? _workspace,
      'model_name': modelName ?? model,
    });
    final session = AgentSession.fromJson(
      Map<String, Object?>.from(data['session'] as Map),
    );
    _sessions[session.id] = session;
    return session;
  }

  @override
  Future<AgentSession> loadSession(String id) async {
    final data = await _get('/api/sessions/$id');
    final session = AgentSession.fromJson(
      Map<String, Object?>.from(data['session'] as Map),
    );
    _sessions[id] = session;
    return session;
  }

  @override
  Future<void> sendPrompt({
    required String sessionId,
    required String text,
    required List<AgentAttachment> attachments,
  }) async {
    final agents = executionMode == RemoteExecutionMode.single
        ? selectedAgentIds.take(1).toList()
        : selectedAgentIds.toList();
    if (agents.isEmpty) throw StateError('Select at least one PC agent');
    final correlationId = 'remote_${DateTime.now().microsecondsSinceEpoch}';
    _events.add(
      AgentEvent(
        AgentEventType.messageStarted,
        sessionId: sessionId,
        correlationId: correlationId,
      ),
    );
    final request = await _http.postUrl(_url('/api/prompts/stream'));
    _headers.forEach(request.headers.set);
    request.headers.contentType = ContentType.json;
    final uploaded = await Future.wait(
      attachments.map(
        (attachment) async => {
          'name': attachment.originalName,
          'data': base64Encode(await File(attachment.localPath).readAsBytes()),
        },
      ),
    );
    final body = utf8.encode(
      jsonEncode({
        'session_id': sessionId,
        'text': text,
        'attachments': uploaded,
        'model': model,
        'agents': agents,
        'mode': executionMode.name,
        'concurrency': executionMode == RemoteExecutionMode.single
            ? 1
            : concurrencyLimit,
        'coordinator': coordinatorAgentId,
        'permission': permissionMode.name,
      }),
    );
    request.contentLength = body.length;
    request.add(body);
    await BackgroundTaskMonitor.start(
      tasksUrl: _url('/api/tasks').toString(),
      stopUrl: _url('/api/sessions/$sessionId/stop').toString(),
      token: token,
      sessionId: sessionId,
      title: text.trim().split('\n').first,
      agents: agents.join(' + '),
    );
    final response = await request.close();
    if (response.statusCode != 200) {
      throw StateError(await utf8.decodeStream(response));
    }
    final announced = <String>{};
    await for (final line
        in response.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      final event = Map<String, Object?>.from(jsonDecode(line) as Map);
      final type = event['type'] as String? ?? '';
      final agentId = event['agent_id'] as String? ?? '';
      if (type == 'delta') {
        final label =
            availableAgents
                .where((agent) => agent.id == agentId)
                .firstOrNull
                ?.name ??
            agentId;
        final prefix = announced.add(agentId) && agents.length > 1
            ? '**$label**\n\n'
            : '';
        _events.add(
          AgentEvent(
            AgentEventType.messageDelta,
            sessionId: sessionId,
            correlationId: correlationId,
            text: '$prefix${event['text'] as String? ?? ''}',
          ),
        );
      } else if (type == 'agent_failed') {
        _events.add(
          AgentEvent(
            AgentEventType.messageDelta,
            sessionId: sessionId,
            correlationId: correlationId,
            text: '\n\n**$agentId gagal:** ${event['error']}',
          ),
        );
      } else if (type == 'reasoning') {
        final completed = event['status'] == 'completed';
        _events.add(
          AgentEvent(
            completed
                ? AgentEventType.toolCompleted
                : AgentEventType.toolStarted,
            sessionId: sessionId,
            correlationId: correlationId,
            text: event['text'] as String? ?? 'Agent sedang menganalisis…',
            data: const {'name': 'reasoning'},
          ),
        );
      } else if (type == 'tool_started') {
        _events.add(
          AgentEvent(
            AgentEventType.toolStarted,
            sessionId: sessionId,
            correlationId: correlationId,
            text: event['text'] as String? ?? '',
            data: {
              'name': event['name'] as String? ?? 'tool',
              'agent_id': agentId,
              'tool_id': event['tool_id'],
            },
          ),
        );
      } else if (type == 'tool_completed') {
        _events.add(
          AgentEvent(
            AgentEventType.toolCompleted,
            sessionId: sessionId,
            correlationId: correlationId,
            text: event['text'] as String? ?? '',
            data: {
              'name': event['name'] as String? ?? 'tool',
              'agent_id': agentId,
              'tool_id': event['tool_id'],
            },
          ),
        );
      } else if (type == 'stopped') {
        _events.add(
          AgentEvent(
            AgentEventType.generationStopped,
            sessionId: sessionId,
            correlationId: correlationId,
          ),
        );
        return;
      } else if (type == 'completed' && event['ok'] != true) {
        _events.add(
          AgentEvent(
            AgentEventType.messageFailed,
            sessionId: sessionId,
            correlationId: correlationId,
            text: 'Semua agent gagal menyelesaikan task.',
          ),
        );
        return;
      }
    }
    _events.add(
      AgentEvent(
        AgentEventType.messageCompleted,
        sessionId: sessionId,
        correlationId: correlationId,
      ),
    );
  }

  @override
  Future<List<AgentTask>> listTasks() async {
    final data = await _get('/api/tasks');
    return (data['tasks'] as List? ?? const [])
        .whereType<Map>()
        .map(decodeAgentTask)
        .toList();
  }

  @override
  Future<SecurityAuditSnapshot> getSecurityAudit({int limit = 50}) async {
    final data = await _get('/api/security/audit', {'limit': '$limit'});
    return decodeSecurityAudit(data);
  }

  @override
  Future<String> getGlobalPersonalization() async {
    final data = await _get('/api/personalization');
    return data['global'] as String? ?? '';
  }

  @override
  Future<void> setGlobalPersonalization(String value) async {
    await _request('POST', '/api/personalization', {'global': value});
  }

  @override
  Future<AgentSession> setSessionPersonalization(
    String sessionId,
    String? value,
  ) async {
    final data = await _request('PATCH', '/api/sessions/$sessionId', {
      'personalization_override': value,
    });
    final session = AgentSession.fromJson(
      Map<String, Object?>.from(data['session'] as Map),
    );
    _sessions[sessionId] = session;
    return session;
  }

  @override
  Future<void> stopGeneration(String id) async {
    await _request('POST', '/api/sessions/$id/stop');
  }

  @override
  Future<void> respondToApproval({
    required String requestId,
    required ApprovalDecision decision,
  }) async {}
  @override
  Future<void> respondToClarification({
    required String requestId,
    required String answer,
  }) async {}
  @override
  Future<void> renameSession(String id, String title) async {
    final data = await _request('PATCH', '/api/sessions/$id', {'title': title});
    _sessions[id] = AgentSession.fromJson(
      Map<String, Object?>.from(data['session'] as Map),
    );
  }

  @override
  Future<void> deleteSession(String id) async {
    await _request('DELETE', '/api/sessions/$id');
    _sessions.remove(id);
  }

  @override
  Future<void> dispose() async {
    _http.close(force: true);
    await _events.close();
  }
}

AgentTask decodeAgentTask(Map item) {
  final value = Map<String, Object?>.from(item);
  final agents = (value['agents'] as List? ?? const [])
      .whereType<String>()
      .toList();
  final states = (value['agentStates'] as List? ?? const [])
      .whereType<Map>()
      .map((item) {
        final state = Map<String, Object?>.from(item);
        return AgentTaskAgentState(
          id: state['id'] as String? ?? '',
          name: state['name'] as String? ?? state['id'] as String? ?? 'Agent',
          status: state['status'] as String? ?? 'unknown',
          phase: state['phase'] as String? ?? 'preparing',
          detail: state['detail'] as String? ?? '',
          role: state['role'] as String? ?? 'agent',
          elapsedSeconds: (state['elapsedSeconds'] as num?)?.toInt() ?? 0,
          idleSeconds: (state['idleSeconds'] as num?)?.toInt() ?? 0,
          startedAt: DateTime.tryParse(state['startedAt'] as String? ?? ''),
          updatedAt: DateTime.tryParse(state['updatedAt'] as String? ?? ''),
          completedAt: DateTime.tryParse(state['completedAt'] as String? ?? ''),
        );
      })
      .toList();
  final status = value['status'] as String? ?? 'unknown';
  final detail = value['detail'] as String? ?? '';
  final agentStates = states.isNotEmpty
      ? states
      : agents
            .map(
              (id) => AgentTaskAgentState(
                id: id,
                name: id,
                status: status,
                phase: status == 'running' ? 'thinking' : status,
                detail: detail,
              ),
            )
            .toList();
  return AgentTask(
    id: value['id'] as String? ?? '',
    title: value['title'] as String? ?? 'Agent task',
    status: status,
    sessionId: value['session_id'] as String? ?? '',
    detail: detail,
    agents: agents,
    agentStates: agentStates,
    activeAgent: value['activeAgent'] as String? ?? '',
    mode: value['mode'] as String? ?? 'single',
    workspace: value['workspace'] as String? ?? '',
    permission: value['permission'] as String? ?? '',
    source: value['source'] as String? ?? 'agent_remote',
    elapsedSeconds: (value['elapsedSeconds'] as num?)?.toInt() ?? 0,
    idleSeconds: (value['idleSeconds'] as num?)?.toInt() ?? 0,
    concurrency: (value['concurrency'] as num?)?.toInt() ?? 1,
    createdAt: DateTime.tryParse(value['createdAt'] as String? ?? ''),
    updatedAt: DateTime.tryParse(value['updatedAt'] as String? ?? ''),
    changedFiles: (value['changedFiles'] as num?)?.toInt() ?? 0,
  );
}

// ponytail: HTTP-only; add WebSocket when Hermes CLI output streaming is exposed by server.
