import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'agent_connector.dart';
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
    githubOwner: data['github_owner'] as String? ?? '',
    githubRepository: data['github_repo'] as String? ?? '',
    githubAvatarUrl: data['github_avatar_url'] as String? ?? '',
    incoming: commits('incoming'),
    outgoing: commits('outgoing'),
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

class HermesRemoteConnector
    implements AgentConnector, WorkspaceMonitor, WorkspaceCatalog {
  HermesRemoteConnector(this.baseUrl, this.token) : _http = HttpClient();
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

  @override
  Stream<AgentEvent> get events => _events.stream;
  Map<String, String> get _headers => {'Authorization': 'Bearer $token'};
  Uri _url(String path, [Map<String, String>? query]) =>
      baseUrl.replace(path: path, queryParameters: query);

  Future<Map<String, Object?>> _get(
    String path, [
    Map<String, String>? query,
  ]) async {
    final request = await _http.getUrl(_url(path, query));
    _headers.forEach(request.headers.set);
    final response = await request.close();
    final body = await utf8.decodeStream(response);
    if (response.statusCode ~/ 100 != 2) throw StateError(body);
    return Map<String, Object?>.from(jsonDecode(body) as Map);
  }

  Future<Map<String, Object?>> _request(
    String method,
    String path, [
    Map<String, Object?> payload = const {},
  ]) async {
    final request = await _http.openUrl(method, _url(path));
    _headers.forEach(request.headers.set);
    request.headers.contentType = ContentType.json;
    if (payload.isNotEmpty) {
      final body = utf8.encode(jsonEncode(payload));
      request.contentLength = body.length;
      request.add(body);
    }
    final response = await request.close();
    final body = await utf8.decodeStream(response);
    if (response.statusCode ~/ 100 != 2) throw StateError(body);
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
  Future<List<WorkspaceEntry>> listWorkspace(String path) async =>
      decodeWorkspaceEntries(await _get('/api/tree', {'path': path}));
  @override
  void selectWorkspace(String path) => _workspace = path;
  @override
  Future<List<AgentSession>> listSessions({int limit = 200}) async {
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
        'coordinator': coordinatorAgentId,
        'permission': permissionMode.name,
      }),
    );
    request.contentLength = body.length;
    request.add(body);
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
    return (data['tasks'] as List? ?? const []).whereType<Map>().map((item) {
      final value = Map<String, Object?>.from(item);
      return AgentTask(
        id: value['id'] as String? ?? '',
        title: value['title'] as String? ?? 'Agent task',
        status: value['status'] as String? ?? 'unknown',
        sessionId: value['session_id'] as String? ?? '',
        detail: value['detail'] as String? ?? '',
        agents: (value['agents'] as List? ?? const [])
            .whereType<String>()
            .toList(),
        workspace: value['workspace'] as String? ?? '',
        permission: value['permission'] as String? ?? '',
        createdAt: DateTime.tryParse(value['createdAt'] as String? ?? ''),
        updatedAt: DateTime.tryParse(value['updatedAt'] as String? ?? ''),
      );
    }).toList();
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

// ponytail: HTTP-only; add WebSocket when Hermes CLI output streaming is exposed by server.
