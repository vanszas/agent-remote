import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'agent_connector.dart';
import 'models.dart';

/// Profile credentials are supplied at runtime; never persist them in profiles.
class HermesGatewayConfig {
  const HermesGatewayConfig({
    required this.baseUrl,
    this.provider,
    this.username,
    this.password,
    this.workspacePath,
  });
  final Uri baseUrl;
  final String? provider, username, password, workspacePath;

  Uri api(String path) {
    final root = baseUrl.path.endsWith('/')
        ? baseUrl
        : baseUrl.replace(path: '${baseUrl.path}/');
    return root.resolve(path.replaceFirst(RegExp(r'^/'), ''));
  }

  Uri get websocket =>
      api('api/ws').replace(scheme: baseUrl.scheme == 'https' ? 'wss' : 'ws');
}

class HermesGatewayConnector implements AgentConnector {
  HermesGatewayConnector(this.config, {HttpClient? http})
    : _workspacePath = config.workspacePath,
      _http = http ?? HttpClient();
  final HermesGatewayConfig config;
  String? _workspacePath;
  final HttpClient _http;
  final _events = StreamController<AgentEvent>.broadcast();
  final _cookies = <Cookie>[];
  final _pending = <int, Completer<Map<String, Object?>>>{};
  final _sessions = <String, AgentSession>{};
  final _liveSessionIds = <String, String>{};
  final _storedSessionIds = <String, String>{};
  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  int _nextId = 1;
  bool _closed = false;

  @override
  Stream<AgentEvent> get events => _events.stream;

  void _emit(AgentEvent event) {
    if (!_closed) _events.add(event);
  }

  @override
  Future<void> initialize() async {
    if (config.baseUrl.scheme != 'http' && config.baseUrl.scheme != 'https') {
      throw ArgumentError('Gateway URL must use HTTP or HTTPS.');
    }
    if (config.baseUrl.host.isEmpty) {
      throw ArgumentError('Gateway host is required.');
    }
    if (config.baseUrl.host != 'localhost' &&
        config.baseUrl.host != '127.0.0.1' &&
        config.baseUrl.host != '10.0.2.2' &&
        config.baseUrl.scheme != 'https') {
      throw ArgumentError('Remote gateways require HTTPS.');
    }
    if (config.password != null) await _passwordLogin();
    await _connect(await _ticket());
    await listSessions();
    _emit(const AgentEvent(AgentEventType.connectorReady, sessionId: ''));
  }

  Future<void> _passwordLogin() async {
    if (config.provider == null ||
        config.username == null ||
        config.password == null) {
      throw ArgumentError('Provider, username, and password are required.');
    }
    final result = await _httpJson(
      'POST',
      '/auth/password-login',
      body: {
        'provider': config.provider,
        'username': config.username,
        'password': config.password,
        'next': '',
      },
    );
    if (result['ok'] != true) throw StateError('Gateway login failed.');
  }

  Future<String> _ticket() async {
    final result = await _httpJson('POST', '/api/auth/ws-ticket');
    final ticket = result['ticket'];
    if (ticket is! String || ticket.isEmpty) {
      throw StateError('Gateway ticket was unavailable.');
    }
    return ticket;
  }

  Future<Map<String, Object?>> _httpJson(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final request = await _http.openUrl(method, config.api(path));
    request.headers.contentType = ContentType.json;
    if (_cookies.isNotEmpty) {
      request.headers.set(
        HttpHeaders.cookieHeader,
        _cookies.map((c) => '${c.name}=${c.value}').join('; '),
      );
    }
    if (body != null) request.write(jsonEncode(body));
    final response = await request.close().timeout(const Duration(seconds: 15));
    for (final cookie in response.cookies) {
      _cookies.removeWhere((existing) => existing.name == cookie.name);
      _cookies.add(cookie);
    }
    final text = await utf8.decodeStream(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Gateway HTTP ${response.statusCode}.');
    }
    final value = jsonDecode(text);
    if (value is! Map) throw StateError('Gateway returned malformed JSON.');
    return Map<String, Object?>.from(value);
  }

  Future<void> _connect(String ticket) async {
    final uri = config.websocket.replace(queryParameters: {'ticket': ticket});
    _socket = await WebSocket.connect(
      uri.toString(),
    ).timeout(const Duration(seconds: 15));
    _subscription = _socket!.listen(
      _onFrame,
      onError: _onSocketError,
      onDone: _onSocketDone,
    );
  }

  void _onSocketError(Object _) => _emit(
    const AgentEvent(
      AgentEventType.connectorError,
      sessionId: '',
      text: 'Gateway WebSocket failed.',
    ),
  );
  void _onSocketDone() {
    if (!_closed) {
      _emit(
        const AgentEvent(
          AgentEventType.connectorError,
          sessionId: '',
          text: 'Gateway WebSocket closed.',
        ),
      );
    }
  }

  void _onFrame(dynamic raw) {
    try {
      final message = jsonDecode(raw as String);
      if (message is! Map) throw const FormatException();
      final map = Map<String, Object?>.from(message);
      final id = map['id'];
      if (id is int && _pending.containsKey(id)) {
        final completer = _pending.remove(id)!;
        if (map['error'] != null) {
          completer.completeError(StateError('Gateway RPC failed.'));
        } else {
          completer.complete(
            Map<String, Object?>.from(map['result'] as Map? ?? {}),
          );
        }
        return;
      }
      final params = map['params'];
      if (map['method'] == 'event' && params is Map) {
        _onEvent(Map<String, Object?>.from(params));
      }
    } catch (_) {
      _emit(
        const AgentEvent(
          AgentEventType.connectorError,
          sessionId: '',
          text: 'Gateway sent malformed data.',
        ),
      );
    }
  }

  void _onEvent(Map<String, Object?> params) {
    final type = params['type'] as String? ?? '';
    if (type == 'sessions.changed') {
      _emit(const AgentEvent(AgentEventType.sessionUpdated, sessionId: ''));
      return;
    }
    final liveId = params['session_id'] as String? ?? '';
    // ponytail: fallback chain — mapped stored ID, then direct session lookup
    final sid =
        _storedSessionIds[liveId] ??
        (_sessions.containsKey(liveId) ? liveId : liveId);
    final payload = Map<String, Object?>.from(params['payload'] as Map? ?? {});
    final text =
        payload['text'] as String? ?? payload['message'] as String? ?? '';
    final correlation =
        payload['request_id'] as String? ?? payload['message_id'] as String?;
    final event = switch (type) {
      'gateway.ready' => AgentEventType.connectorReady,
      'message.start' => AgentEventType.messageStarted,
      'message.delta' => AgentEventType.messageDelta,
      'message.complete' => AgentEventType.messageCompleted,
      'tool.start' || 'subagent.start' => AgentEventType.toolStarted,
      'subagent.progress' => AgentEventType.toolProgress,
      'tool.complete' || 'subagent.complete' => AgentEventType.toolCompleted,
      'approval.request' => AgentEventType.approvalRequested,
      'clarify.request' => AgentEventType.clarificationRequested,
      'error' => AgentEventType.messageFailed,
      _ => null,
    };
    if (event != null) {
      _emit(
        AgentEvent(
          event,
          sessionId: sid,
          correlationId: correlation,
          text: text,
          data: payload,
        ),
      );
    }
  }

  Future<Map<String, Object?>> _rpc(
    String method, [
    Map<String, Object?> params = const {},
  ]) {
    final socket = _socket;
    if (socket == null) {
      return Future.error(StateError('Gateway is disconnected.'));
    }
    final id = _nextId++;
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    socket.add(
      '${jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params})}\n',
    );
    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('Gateway request timed out.');
      },
    );
  }

  @override
  Future<AgentCapabilities> getCapabilities() async => const AgentCapabilities(
    supportsImages: false,
    supportsFiles: false,
    supportsSessionRename: true,
    supportsSessionDelete: true,
  );

  @override
  Future<List<AgentSession>> listSessions({int limit = 200}) async {
    final result = await _rpc('session.list', {'limit': limit});
    final rows = result['sessions'] as List? ?? const [];
    _sessions.clear();
    for (final row in rows.whereType<Map>()) {
      final map = Map<String, Object?>.from(row);
      final id = map['id'] as String? ?? '';
      final cwd = map['cwd'] as String? ?? '';
      if (id.isEmpty) continue;
      // ponytail: allow sessions with empty cwd (legacy) to appear everywhere
      // If workspace is 'all', show everything.
      if (_workspacePath != 'all' &&
          (_workspacePath?.isNotEmpty ?? false) &&
          cwd.isNotEmpty &&
          cwd != _workspacePath) {
        continue;
      }
      final at = DateTime.fromMillisecondsSinceEpoch(
        (((map['started_at'] as num?)?.toDouble() ?? 0) * 1000).toInt(),
      );
      // ponytail: use server preview for tile subtitle instead of "Empty session"
      final preview = map['preview'] as String? ?? '';
      final msgCount = (map['message_count'] as num?)?.toInt() ?? 0;
      _sessions[id] = AgentSession(
        id: id,
        title: map['title'] as String? ?? 'Untitled',
        createdAt: at,
        updatedAt: at,
        workspaceName: 'Hermes gateway',
        activeModelName: 'Hermes',
        preview: preview,
        messageCount: msgCount,
      );
    }
    return _sessions.values.toList();
  }

  @override
  Future<AgentSession> createSession({
    String? workspaceName,
    String? modelName,
  }) async {
    final result = await _rpc('session.create', {
      'source': 'desktop',
      if (_workspacePath != 'all' && (_workspacePath?.isNotEmpty ?? false))
        'cwd': _workspacePath,
    });
    final id = result['session_id'] as String?;
    if (id == null || id.isEmpty) {
      throw StateError('Gateway did not create a session.');
    }
    final storedId = result['stored_session_id'] as String? ?? id;
    _liveSessionIds[storedId] = id;
    _storedSessionIds[id] = storedId;
    final now = DateTime.now();
    final session = AgentSession(
      id: storedId,
      title: 'New chat',
      createdAt: now,
      updatedAt: now,
      workspaceName: workspaceName ?? 'Hermes gateway',
      activeModelName: modelName ?? 'Hermes',
    );
    _sessions[storedId] = session;
    _emit(AgentEvent(AgentEventType.sessionCreated, sessionId: storedId));
    return session;
  }

  @override
  Future<List<AgentWorkspace>> listWorkspaces() async {
    final listed = await _rpc('projects.list');
    final tree = await _rpc('projects.tree', {'preview_limit': 0});
    final active = listed['active_id'] as String?;

    // ponytail: insert 'All Workspaces' virtual option at the top
    final all = const AgentWorkspace(
      id: 'all',
      name: 'All Workspaces',
      path: 'all',
      isActive: false,
    );

    final explicit = (listed['projects'] as List? ?? const [])
        .whereType<Map>()
        .map((raw) {
          final p = Map<String, Object?>.from(raw);
          return AgentWorkspace(
            id: p['id'] as String? ?? '',
            name: p['name'] as String? ?? 'Project',
            path: p['primary_path'] as String? ?? '',
            isActive: p['id'] == active,
          );
        })
        .toList();
    final known = explicit.map((x) => x.path).toSet();
    final discovered = (tree['projects'] as List? ?? const [])
        .whereType<Map>()
        .map((raw) {
          final p = Map<String, Object?>.from(raw);
          final path = p['path'] as String? ?? '';
          return AgentWorkspace(
            id: p['id'] as String? ?? path,
            name: p['label'] as String? ?? path.split(RegExp(r'[\\/]')).last,
            path: path,
          );
        })
        .where((x) => x.path.isNotEmpty && !known.contains(x.path));
    return [
      all,
      ...explicit,
      ...discovered,
    ].where((x) => x.path.isNotEmpty).toList();
  }

  @override
  Future<List<AgentTask>> listTasks() async {
    final result = await _rpc('delegation.status');
    return (result['active'] as List? ?? const []).whereType<Map>().map((raw) {
      final task = Map<String, Object?>.from(raw);
      return AgentTask(
        id: '${task['id'] ?? task['task_id'] ?? ''}',
        title:
            '${task['goal'] ?? task['title'] ?? task['prompt'] ?? 'Background task'}',
        status: '${task['status'] ?? 'running'}',
      );
    }).toList();
  }

  @override
  void selectWorkspace(String path) => _workspacePath = path;

  Future<Map<String, Object?>> _resume(String storedId) async {
    final liveId = _liveSessionIds[storedId];
    if (liveId != null) return {'session_id': liveId};
    final result = await _rpc('session.resume', {
      'session_id': storedId,
      'source': 'desktop',
    });
    final resumedId = result['session_id'] as String?;
    if (resumedId == null || resumedId.isEmpty) {
      throw StateError('Gateway did not resume the session.');
    }
    _liveSessionIds[storedId] = resumedId;
    _storedSessionIds[resumedId] = storedId;
    return result;
  }

  @override
  Future<AgentSession> loadSession(String id) async {
    final result = await _resume(id);
    final liveId = result['session_id'] as String? ?? id;

    // ponytail: resume doesn't return full history for existing sessions; fetch it explicitly
    final historyResult = await _rpc('session.history', {'session_id': liveId});

    final rows = (historyResult['messages'] as List? ?? const [])
        .whereType<Map>()
        .map((raw) => Map<String, Object?>.from(raw))
        .where((item) {
          final role = item['role'];
          final text = item['text'] as String? ?? '';
          return (role == 'user' || role == 'assistant') && text.isNotEmpty;
        })
        .toList();
    final visible = rows.length > 50 ? rows.sublist(rows.length - 50) : rows;
    final remote = visible.indexed.map((entry) {
      final index = entry.$1;
      final item = entry.$2;
      return ChatMessage(
        id: '${id}_history_$index',
        sessionId: id,
        role: item['role'] == 'assistant'
            ? MessageRole.assistant
            : MessageRole.user,
        content: item['text'] as String,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        status: MessageStatus.complete,
      );
    }).toList();
    final current =
        _sessions[id] ??
        AgentSession(
          id: id,
          title: 'Untitled',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          workspaceName: 'Hermes gateway',
          activeModelName: 'Hermes',
        );
    // ponytail: merge — keep local messages that are newer than DB snapshot
    final remoteIds = remote.map((m) => m.id).toSet();
    final localOnly = current.messages
        .where(
          (m) =>
              !remoteIds.contains(m.id) && m.status != MessageStatus.complete,
        )
        .toList();
    final session = current.copyWith(
      messages: [...remote, ...localOnly],
      updatedAt: DateTime.now(),
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
    if (attachments.isNotEmpty) {
      throw UnsupportedError('Gateway attachments are not implemented yet.');
    }
    final live = await _resume(sessionId);
    await _rpc('prompt.submit', {
      'session_id': live['session_id'],
      'text': text,
    });
  }

  @override
  Future<void> stopGeneration(String id) async {
    await _rpc('session.interrupt', {'session_id': id});
    _emit(AgentEvent(AgentEventType.generationStopped, sessionId: id));
  }

  @override
  Future<void> respondToApproval({
    required String requestId,
    required ApprovalDecision decision,
  }) async {
    await _rpc('approval.respond', {
      'request_id': requestId,
      'choice': decision == ApprovalDecision.approve ? 'once' : 'deny',
    });
  }

  @override
  Future<void> respondToClarification({
    required String requestId,
    required String answer,
  }) async {
    if (answer.trim().isEmpty) throw ArgumentError('Answer is required.');
    await _rpc('clarify.respond', {'request_id': requestId, 'answer': answer});
  }

  @override
  Future<void> renameSession(String id, String title) async {
    await _rpc('session.title', {'session_id': id, 'title': title});
  }

  @override
  Future<void> deleteSession(String id) async {
    await _rpc('session.delete', {'session_id': id});
    _sessions.remove(id);
  }

  @override
  Future<void> dispose() async {
    _closed = true;
    await _subscription?.cancel();
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError('Gateway disposed.'));
    }
    _pending.clear();
    await _socket?.close();
    await _events.close();
    _http.close(force: true);
  }
}
