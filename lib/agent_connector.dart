import 'dart:async';
import 'models.dart';

enum AgentEventType {
  connectorReady,
  sessionCreated,
  sessionUpdated,
  messageStarted,
  messageDelta,
  messageCompleted,
  messageFailed,
  toolStarted,
  toolProgress,
  toolCompleted,
  approvalRequested,
  approvalResolved,
  clarificationRequested,
  clarificationResolved,
  generationStopped,
  connectorError,
}

class AgentEvent {
  const AgentEvent(
    this.type, {
    required this.sessionId,
    this.correlationId,
    this.text = '',
    this.data = const {},
  });
  final AgentEventType type;
  final String sessionId;
  final String? correlationId;
  final String text;
  final Map<String, Object?> data;
}

class AgentCapabilities {
  const AgentCapabilities({
    this.supportsImages = true,
    this.supportsFiles = true,
    this.supportsApprovals = true,
    this.supportsClarification = true,
    this.supportsToolStreaming = true,
    this.supportsSessionHistory = true,
    this.supportsSessionRename = true,
    this.supportsSessionDelete = true,
    this.supportsStop = true,
    this.supportsModelSelection = false,
    this.supportsWorkspaces = true,
  });
  final bool supportsImages,
      supportsFiles,
      supportsApprovals,
      supportsClarification,
      supportsToolStreaming,
      supportsSessionHistory,
      supportsSessionRename,
      supportsSessionDelete,
      supportsStop,
      supportsModelSelection,
      supportsWorkspaces;
}

abstract class AgentConnector {
  Stream<AgentEvent> get events;
  Future<void> initialize();
  Future<AgentCapabilities> getCapabilities();
  Future<List<AgentSession>> listSessions();
  Future<AgentSession> createSession({
    String? workspaceName,
    String? modelName,
  });
  Future<AgentSession> loadSession(String id);
  Future<void> sendPrompt({
    required String sessionId,
    required String text,
    required List<AgentAttachment> attachments,
  });
  Future<void> stopGeneration(String id);
  Future<void> respondToApproval({
    required String requestId,
    required ApprovalDecision decision,
  });
  Future<void> respondToClarification({
    required String requestId,
    required String answer,
  });
  Future<void> renameSession(String id, String title);
  Future<void> deleteSession(String id);
  Future<void> dispose();
}

class DemoAgentConnector implements AgentConnector {
  DemoAgentConnector({this.delay = const Duration(milliseconds: 80)});
  final Duration delay;
  final _events = StreamController<AgentEvent>.broadcast();
  final _sessions = <String, AgentSession>{};
  final _cancelled = <String>{};
  bool _closed = false;
  int _id = 0;
  @override
  Stream<AgentEvent> get events => _events.stream;
  void _emit(AgentEvent e) {
    if (!_closed) _events.add(e);
  }

  String _next() => '${DateTime.now().microsecondsSinceEpoch}_${_id++}';
  @override
  Future<void> initialize() async =>
      _emit(const AgentEvent(AgentEventType.connectorReady, sessionId: ''));
  @override
  Future<AgentCapabilities> getCapabilities() async =>
      const AgentCapabilities();
  @override
  Future<List<AgentSession>> listSessions() async => _sessions.values.toList();
  @override
  Future<AgentSession> createSession({
    String? workspaceName,
    String? modelName,
  }) async {
    final now = DateTime.now(),
        s = AgentSession(
          id: _next(),
          title: 'New chat',
          createdAt: now,
          updatedAt: now,
          workspaceName: workspaceName ?? 'Demo workspace',
          activeModelName: modelName ?? 'Demo Agent',
        );
    _sessions[s.id] = s;
    _emit(AgentEvent(AgentEventType.sessionCreated, sessionId: s.id));
    return s;
  }

  @override
  Future<AgentSession> loadSession(String id) async =>
      _sessions[id] ?? (throw StateError('Session not found'));
  @override
  Future<void> sendPrompt({
    required String sessionId,
    required String text,
    required List<AgentAttachment> attachments,
  }) async {
    _cancelled.remove(sessionId);
    final correlation = _next();
    _emit(
      AgentEvent(
        AgentEventType.messageStarted,
        sessionId: sessionId,
        correlationId: correlation,
      ),
    );
    if (text == '/demo error') {
      _emit(
        AgentEvent(
          AgentEventType.messageFailed,
          sessionId: sessionId,
          correlationId: correlation,
          text: 'Demo failure. Retry when ready.',
        ),
      );
      return;
    }
    if (text == '/demo approval') {
      _emit(
        AgentEvent(
          AgentEventType.approvalRequested,
          sessionId: sessionId,
          correlationId: correlation,
          text: 'Approve simulated action?',
        ),
      );
      return;
    }
    if (text == '/demo clarify') {
      _emit(
        AgentEvent(
          AgentEventType.clarificationRequested,
          sessionId: sessionId,
          correlationId: correlation,
          text: 'Which demo path?',
          data: {
            'choices': ['Fast', 'Detailed'],
          },
        ),
      );
      return;
    }
    if (text == '/demo tool') {
      _emit(
        AgentEvent(
          AgentEventType.toolStarted,
          sessionId: sessionId,
          correlationId: correlation,
          text: 'Inspect files',
        ),
      );
      await Future<void>.delayed(delay);
      _emit(
        AgentEvent(
          AgentEventType.toolProgress,
          sessionId: sessionId,
          correlationId: correlation,
          data: {'progress': .6},
        ),
      );
      await Future<void>.delayed(delay);
      _emit(
        AgentEvent(
          AgentEventType.toolCompleted,
          sessionId: sessionId,
          correlationId: correlation,
          text: '5 demo files inspected',
        ),
      );
    }
    final response = text == '/demo long'
        ? 'This is a long deterministic response that demonstrates streaming and can be stopped immediately without affecting another session.'
        : 'Demo response ready. The mobile UI is isolated from every real backend.';
    for (final chunk in response.split(' ')) {
      if (_cancelled.contains(sessionId)) return;
      _emit(
        AgentEvent(
          AgentEventType.messageDelta,
          sessionId: sessionId,
          correlationId: correlation,
          text: '$chunk ',
        ),
      );
      await Future<void>.delayed(delay);
    }
    _emit(
      AgentEvent(
        AgentEventType.messageCompleted,
        sessionId: sessionId,
        correlationId: correlation,
      ),
    );
  }

  @override
  Future<void> stopGeneration(String id) async {
    _cancelled.add(id);
    _emit(AgentEvent(AgentEventType.generationStopped, sessionId: id));
  }

  @override
  Future<void> respondToApproval({
    required String requestId,
    required ApprovalDecision decision,
  }) async => _emit(
    AgentEvent(
      AgentEventType.approvalResolved,
      sessionId: '',
      correlationId: requestId,
      text: decision.name,
    ),
  );
  @override
  Future<void> respondToClarification({
    required String requestId,
    required String answer,
  }) async => _emit(
    AgentEvent(
      AgentEventType.clarificationResolved,
      sessionId: '',
      correlationId: requestId,
      text: answer,
    ),
  );
  @override
  Future<void> renameSession(String id, String title) async {
    final s = _sessions[id];
    if (s != null) _sessions[id] = s.copyWith(title: title);
  }

  @override
  Future<void> deleteSession(String id) async {
    _sessions.remove(id);
  }

  @override
  Future<void> dispose() async {
    _closed = true;
    _cancelled.addAll(_sessions.keys);
    await _events.close();
  }
}
