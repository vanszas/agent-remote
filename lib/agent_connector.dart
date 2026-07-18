import 'dart:async';
import 'models.dart';

class AgentWorkspace {
  const AgentWorkspace({
    required this.id,
    required this.name,
    required this.path,
    this.isActive = false,
  });
  final String id, name, path;
  final bool isActive;
}

class AgentProject {
  const AgentProject({required this.workspace, this.sessions = const []});
  final AgentWorkspace workspace;
  final List<AgentSession> sessions;
}

abstract interface class WorkspaceCatalog {
  Future<List<AgentProject>> listProjects({int limit = 20});
  Future<AgentWorkspace> activateWorkspace(String path);
}

class AgentTaskAgentState {
  const AgentTaskAgentState({
    required this.id,
    required this.name,
    required this.status,
    required this.phase,
    required this.detail,
    this.role = 'agent',
    this.elapsedSeconds = 0,
    this.idleSeconds = 0,
    this.startedAt,
    this.updatedAt,
    this.completedAt,
  });

  final String id, name, status, phase, detail, role;
  final int elapsedSeconds, idleSeconds;
  final DateTime? startedAt, updatedAt, completedAt;

  bool get isActive => status == 'running' || status == 'queued';
}

class AgentTask {
  const AgentTask({
    required this.id,
    required this.title,
    required this.status,
    this.sessionId = '',
    this.detail = '',
    this.agents = const [],
    this.agentStates = const [],
    this.activeAgent = '',
    this.mode = 'single',
    this.workspace = '',
    this.permission = '',
    this.source = 'agent_remote',
    this.elapsedSeconds = 0,
    this.idleSeconds = 0,
    this.createdAt,
    this.updatedAt,
    this.changedFiles = 0,
  });
  final String id,
      title,
      status,
      sessionId,
      detail,
      activeAgent,
      mode,
      workspace,
      permission,
      source;
  final List<String> agents;
  final List<AgentTaskAgentState> agentStates;
  final int elapsedSeconds, idleSeconds;
  final int changedFiles;
  final DateTime? createdAt, updatedAt;

  AgentTaskAgentState? get activeAgentState {
    for (final state in agentStates) {
      if (state.id == activeAgent && state.isActive) return state;
    }
    for (final state in agentStates) {
      if (state.status == 'running') return state;
    }
    for (final state in agentStates) {
      if (state.status == 'queued') return state;
    }
    return agentStates.firstOrNull;
  }
}

enum GitFileStatus { added, modified, deleted, untracked }

class GitStatusEntry {
  const GitStatusEntry(this.path, this.status);
  final String path;
  final GitFileStatus status;
}

class GitCommit {
  const GitCommit({
    required this.hash,
    required this.subject,
    required this.author,
  });
  final String hash, subject, author;
}

class GitRepositoryStatus {
  const GitRepositoryStatus({
    this.isGitRepository = false,
    this.branch = '',
    this.remoteUrl = '',
    this.ahead = 0,
    this.behind = 0,
    this.upstream = '',
    this.additions = 0,
    this.deletions = 0,
    this.githubCliInstalled = false,
    this.githubCliAuthenticated = false,
    this.githubCliUser = '',
    this.githubOwner = '',
    this.githubRepository = '',
    this.githubAvatarUrl = '',
    this.incoming = const [],
    this.outgoing = const [],
  });
  final bool isGitRepository;
  final bool githubCliInstalled, githubCliAuthenticated;
  final String branch,
      remoteUrl,
      upstream,
      githubOwner,
      githubRepository,
      githubAvatarUrl,
      githubCliUser;
  final int ahead, behind, additions, deletions;
  final List<GitCommit> incoming, outgoing;
}

class ProviderUsageSummary {
  const ProviderUsageSummary({
    this.requests = 0,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cachedTokens = 0,
    this.estimatedCost = 0,
  });
  final int requests, inputTokens, outputTokens, cachedTokens;
  final double estimatedCost;
}

class ProviderUsageEntry {
  const ProviderUsageEntry({
    required this.timestamp,
    required this.provider,
    required this.model,
    required this.endpoint,
    required this.inputTokens,
    required this.outputTokens,
    required this.cachedTokens,
    required this.cost,
    required this.status,
    this.isActive = false,
  });
  final DateTime timestamp;
  final String provider, model, endpoint, status;
  final int inputTokens, outputTokens, cachedTokens;
  final double cost;
  final bool isActive;
}

class ProviderUsageSnapshot {
  const ProviderUsageSnapshot({
    required this.available,
    required this.source,
    required this.range,
    required this.summary,
    required this.providers,
    required this.models,
    required this.recent,
    required this.attribution,
    this.active,
    this.reason = '',
    this.scope = 'all',
    this.mobileFilterAvailable = false,
    this.mobileKeyName = '',
    this.updatedAt,
  });
  final bool available;
  final String source, range, attribution, reason, scope, mobileKeyName;
  final bool mobileFilterAvailable;
  final ProviderUsageSummary summary;
  final ProviderUsageEntry? active;
  final List<String> providers, models;
  final List<ProviderUsageEntry> recent;
  final DateTime? updatedAt;
}

class WorkspaceEntry {
  const WorkspaceEntry(this.name, this.path, this.isDirectory);
  final String name, path;
  final bool isDirectory;
}

class WorkspaceFileDocument {
  const WorkspaceFileDocument({
    required this.path,
    required this.name,
    required this.content,
    required this.diff,
    required this.hash,
    required this.size,
    required this.lineCount,
    required this.exists,
    required this.editable,
    required this.gitStatus,
    required this.maxBytes,
    this.modifiedAt,
  });
  final String path, name, content, diff, hash, gitStatus;
  final int size, lineCount, maxBytes;
  final bool exists, editable;
  final DateTime? modifiedAt;
}

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
    this.supportsAgentExecution = true,
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
      supportsWorkspaces,
      supportsAgentExecution;
}

abstract interface class WorkspaceMonitor {
  Future<List<GitStatusEntry>> getGitStatus({bool fetch = false});
  Future<GitRepositoryStatus> getGitRepositoryStatus({bool fetch = false});
  Future<List<WorkspaceEntry>> listWorkspace(String path);
}

class SecurityAuditEntry {
  const SecurityAuditEntry({
    required this.timestamp,
    required this.event,
    required this.ipAddress,
    required this.method,
    required this.path,
    required this.userAgent,
  });
  final DateTime timestamp;
  final String event, ipAddress, method, path, userAgent;
  bool get authorized => event == 'access_granted';
}

class SecurityAuditSnapshot {
  const SecurityAuditSnapshot({
    required this.entries,
    required this.peerIpOnly,
    required this.successWindowSeconds,
    required this.failureWindowSeconds,
  });
  final List<SecurityAuditEntry> entries;
  final bool peerIpOnly;
  final int successWindowSeconds, failureWindowSeconds;
}

abstract interface class SecurityMonitor {
  Future<SecurityAuditSnapshot> getSecurityAudit({int limit = 50});
}

abstract interface class ProviderUsageMonitor {
  Future<ProviderUsageSnapshot> getProviderUsage({
    String range = '24h',
    String provider = '',
    String model = '',
    String scope = 'all',
    int limit = 50,
  });
}

abstract interface class WorkspaceFileEditor {
  Future<WorkspaceFileDocument> getWorkspaceFile(String path);
  Future<WorkspaceFileDocument> saveWorkspaceFile({
    required String path,
    required String content,
    required String baseHash,
  });
}

abstract class AgentConnector {
  Stream<AgentEvent> get events;
  Future<void> initialize();
  Future<AgentCapabilities> getCapabilities();
  Future<List<AgentSession>> listSessions({int limit = 200});
  Future<AgentSession> createSession({
    String? workspaceName,
    String? modelName,
  });
  Future<List<AgentWorkspace>> listWorkspaces();
  Future<List<AgentTask>> listTasks();
  void selectWorkspace(String path);
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
  final _pendingApprovals = <String, String>{};
  final _pendingClarifications = <String, String>{};
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
  @override
  Future<AgentCapabilities> getCapabilities() async =>
      const AgentCapabilities();
  @override
  Future<List<AgentSession>> listSessions({int limit = 200}) async =>
      _sessions.values.toList();
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
  Future<List<AgentWorkspace>> listWorkspaces() async => const [];
  @override
  Future<List<AgentTask>> listTasks() async => const [];
  @override
  void selectWorkspace(String path) {}

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
      _pendingApprovals[correlation] = sessionId;
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
      _pendingClarifications[correlation] = sessionId;
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
    _pendingApprovals.removeWhere((_, sessionId) => sessionId == id);
    _pendingClarifications.removeWhere((_, sessionId) => sessionId == id);
    _emit(AgentEvent(AgentEventType.generationStopped, sessionId: id));
  }

  @override
  Future<void> respondToApproval({
    required String requestId,
    required ApprovalDecision decision,
  }) async {
    final sessionId = _pendingApprovals.remove(requestId);
    if (sessionId == null) throw StateError('Approval request is not pending');
    _emit(
      AgentEvent(
        AgentEventType.approvalResolved,
        sessionId: sessionId,
        correlationId: requestId,
        text: decision.name,
      ),
    );
    _emit(
      AgentEvent(
        AgentEventType.messageCompleted,
        sessionId: sessionId,
        correlationId: requestId,
      ),
    );
  }

  @override
  Future<void> respondToClarification({
    required String requestId,
    required String answer,
  }) async {
    final sessionId = _pendingClarifications[requestId];
    if (sessionId == null) {
      throw StateError('Clarification request is not pending');
    }
    if (answer.trim().isEmpty) throw ArgumentError('Answer is required');
    _pendingClarifications.remove(requestId);
    _emit(
      AgentEvent(
        AgentEventType.clarificationResolved,
        sessionId: sessionId,
        correlationId: requestId,
        text: answer,
      ),
    );
    _emit(
      AgentEvent(
        AgentEventType.messageCompleted,
        sessionId: sessionId,
        correlationId: requestId,
      ),
    );
  }

  @override
  Future<void> renameSession(String id, String title) async {
    final s = _sessions[id];
    if (s != null) _sessions[id] = s.copyWith(title: title);
  }

  @override
  Future<void> deleteSession(String id) async {
    _sessions.remove(id);
    _pendingApprovals.removeWhere((_, sessionId) => sessionId == id);
    _pendingClarifications.removeWhere((_, sessionId) => sessionId == id);
    _cancelled.add(id);
  }

  @override
  Future<void> dispose() async {
    _closed = true;
    _cancelled.addAll(_sessions.keys);
    _pendingApprovals.clear();
    _pendingClarifications.clear();
    await _events.close();
  }
}
