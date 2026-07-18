import 'dart:async';
import 'package:flutter/foundation.dart';
import 'agent_connector.dart';
import 'local_store.dart';
import 'models.dart';

class AppController extends ChangeNotifier {
  AppController(this.connector, this.store);
  AgentConnector connector;
  final LocalStore store;
  final sessions = <AgentSession>[];
  StreamSubscription<AgentEvent>? _sub;
  Timer? _taskTimer;
  Timer? _saveTimer;
  AppUiState _restoredUiState = const AppUiState();
  String? currentId;
  ThemeModeChoice theme = ThemeModeChoice.system;
  int page = 0;
  String search = '';
  AgentCapabilities capabilities = const AgentCapabilities();
  String? connectorError;
  bool connected = false;
  bool _connectedNotice = false;
  bool loadingSession = false;
  List<AgentWorkspace> workspaces = const [];
  List<AgentProject> projects = const [];
  List<AgentTask> tasks = const [];
  List<GitStatusEntry> gitStatus = const [];
  GitRepositoryStatus gitRepository = const GitRepositoryStatus();
  List<WorkspaceEntry> workspaceEntries = const [];
  String workspaceFolder = '';
  String? workspacePath;
  bool get isDemo => connector is DemoAgentConnector;
  String get connectorLabel => connected ? 'PC connected' : 'Disconnected';
  bool takeConnectedNotice() {
    final value = _connectedNotice;
    _connectedNotice = false;
    return value;
  }

  AgentSession? get current =>
      sessions.where((s) => s.id == currentId).firstOrNull;
  Future<void> initialize() async {
    _restoredUiState = await store.loadUiState();
    page = _restoredUiState.page.clamp(0, 3);
    workspacePath = _restoredUiState.workspacePath;
    sessions.addAll(await store.load());
    if (sessions.any((session) => session.id == _restoredUiState.sessionId)) {
      currentId = _restoredUiState.sessionId;
    }
    _sub = connector.events.listen(_event);
    try {
      await connector.initialize();
      capabilities = await connector.getCapabilities();
    } catch (_) {
      connectorError = 'Demo connector could not be initialized.';
      await _sub?.cancel();
      _sub = null;
    }
    notifyListeners();
  }

  Future<void> connect(AgentConnector next) async {
    final nextEvents = next.events.listen(_event);
    try {
      await next.initialize();
      final nextCapabilities = await next.getCapabilities();
      final nextSessions = await next.listSessions();
      await _sub?.cancel();
      await connector.dispose();
      connector = next;
      _sub = nextEvents;
      capabilities = nextCapabilities;
      sessions
        ..clear()
        ..addAll(nextSessions);
      currentId = null;
      connected = true;
      _connectedNotice = true;
      connectorError = null;
      _taskTimer?.cancel();
      await reloadTasks();
      _taskTimer = Timer.periodic(
        const Duration(seconds: 3),
        (_) => reloadTasks(),
      );
    } catch (error) {
      await nextEvents.cancel();
      await next.dispose();
      connected = false;
      connectorError = _connectionError(error);
    }
    notifyListeners();
  }

  Future<void> newSession() async {
    final s = await connector.createSession();
    sessions.insert(0, s);
    currentId = s.id;
    await _save();
    notifyListeners();
  }

  Future<void> send(
    String text, {
    List<AgentAttachment> attachments = const [],
  }) async {
    var s = current;
    if (s == null) {
      await newSession();
      s = current;
    }
    if (s == null || text.trim().isEmpty && attachments.isEmpty) return;
    final now = DateTime.now();
    final user = ChatMessage(
      id: 'm${now.microsecondsSinceEpoch}',
      sessionId: s.id,
      role: MessageRole.user,
      content: text.trim(),
      createdAt: now,
      updatedAt: now,
      status: MessageStatus.complete,
      attachments: attachments,
    );
    _replace(
      s.copyWith(
        title: s.title == 'New chat' && text.trim().isNotEmpty
            ? _titleFrom(text)
            : s.title,
        messages: [...s.messages, user],
        status: capabilities.supportsAgentExecution
            ? SessionStatus.generating
            : SessionStatus.idle,
        updatedAt: now,
      ),
    );
    await _save();
    notifyListeners();
    try {
      await connector.sendPrompt(
        sessionId: s.id,
        text: text.trim(),
        attachments: attachments,
      );
    } catch (error) {
      connectorError = _connectionError(error);
      final currentSession = current;
      if (currentSession != null) {
        _replace(
          currentSession.copyWith(
            status: SessionStatus.failed,
            updatedAt: DateTime.now(),
          ),
        );
      }
      await _save();
      notifyListeners();
    }
  }

  void _event(AgentEvent e) {
    if (e.type == AgentEventType.connectorReady) {
      notifyListeners();
      return;
    }
    if (e.type == AgentEventType.connectorError) {
      connected = false;
      connectorError = e.text;
      notifyListeners();
      return;
    }
    if (e.type == AgentEventType.sessionUpdated && e.sessionId.isEmpty) {
      reloadSessions();
      return;
    }
    // Gateway connector translates live IDs before emitting; never guess a session.
    final s = sessions.where((x) => x.id == e.sessionId).firstOrNull;
    if (s == null) return;
    var messages = [...s.messages];
    var activities = [...s.activities];
    final id = e.correlationId ?? 'demo';
    var ai = messages.where((m) => m.id == id).firstOrNull;
    switch (e.type) {
      case AgentEventType.messageStarted:
        ai = ChatMessage(
          id: id,
          sessionId: s.id,
          role: MessageRole.assistant,
          content: '',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          status: MessageStatus.streaming,
        );
        messages.add(ai);
        break;
      case AgentEventType.messageDelta:
        if (ai != null) {
          messages[messages.indexOf(ai)] = ai.copyWith(
            content: ai.content + e.text,
          );
        }
        break;
      case AgentEventType.toolStarted:
        activities.add(
          AgentActivity(
            id: '${id}_${DateTime.now().microsecondsSinceEpoch}',
            runId: id,
            sessionId: s.id,
            agentId: e.data['agent_id'] as String? ?? '',
            kind: e.data['name'] == 'reasoning'
                ? 'thinking'
                : 'running_command',
            status: 'running',
            detail: e.text.isEmpty ? 'Agent sedang bekerja' : e.text,
            createdAt: DateTime.now(),
            toolName: e.data['name'] as String? ?? '',
          ),
        );
        if (ai != null) {
          final isSubagent = e.data['child_session_id'] != null;
          final toolName =
              e.data['name'] as String? ?? (isSubagent ? 'subagent' : 'tool');
          messages[messages.indexOf(ai)] = ai.copyWith(
            toolActivities: [
              ToolActivity(
                id: id,
                toolName: toolName,
                displayName: isSubagent
                    ? 'Running background task'
                    : 'Running $toolName',
                summary: e.text.isNotEmpty ? e.text : 'Running...',
                status: ToolActivityStatus.running,
                startedAt: DateTime.now(),
              ),
            ],
          );
        }
        break;
      case AgentEventType.toolProgress:
        if (ai != null && ai.toolActivities.isNotEmpty) {
          final t = ai.toolActivities.first;
          final pct = e.data['progress'] as double?;
          messages[messages.indexOf(ai)] = ai.copyWith(
            toolActivities: [
              ToolActivity(
                id: t.id,
                toolName: t.toolName,
                displayName: t.displayName,
                summary: e.text.isNotEmpty ? e.text : t.summary,
                status: ToolActivityStatus.running,
                startedAt: t.startedAt,
                progress: pct,
              ),
            ],
          );
        }
        break;
      case AgentEventType.toolCompleted:
        if (ai != null && ai.toolActivities.isNotEmpty) {
          final t = ai.toolActivities.first;
          messages[messages.indexOf(ai)] = ai.copyWith(
            toolActivities: [
              ToolActivity(
                id: t.id,
                toolName: t.toolName,
                displayName: t.displayName,
                summary: t.summary,
                status: ToolActivityStatus.success,
                startedAt: t.startedAt,
                completedAt: DateTime.now(),
                progress: 1,
                outputPreview: e.text,
              ),
            ],
          );
        }
        break;
      case AgentEventType.approvalRequested:
        final requestMessage = ChatMessage(
          id: id,
          sessionId: s.id,
          role: MessageRole.system,
          content: '',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          status: MessageStatus.queued,
          approvalRequest: ApprovalRequest(
            id: id,
            sessionId: s.id,
            correlationId: id,
            title: 'Approval required',
            description: e.text,
            riskLevel: ApprovalRiskLevel.low,
            createdAt: DateTime.now(),
            status: ApprovalStatus.pending,
            isDemo: true,
          ),
        );
        ai == null
            ? messages.add(requestMessage)
            : messages[messages.indexOf(ai)] = requestMessage;
        break;
      case AgentEventType.clarificationRequested:
        final requestMessage = ChatMessage(
          id: id,
          sessionId: s.id,
          role: MessageRole.system,
          content: '',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          status: MessageStatus.queued,
          clarificationRequest: ClarificationRequest(
            id: id,
            sessionId: s.id,
            correlationId: id,
            question: e.text,
            choices: (e.data['choices'] as List? ?? [])
                .whereType<String>()
                .toList(),
            allowFreeText: true,
            createdAt: DateTime.now(),
            status: ClarificationStatus.pending,
            isDemo: true,
          ),
        );
        ai == null
            ? messages.add(requestMessage)
            : messages[messages.indexOf(ai)] = requestMessage;
        break;
      case AgentEventType.approvalResolved:
        if (ai?.approvalRequest != null) {
          messages[messages.indexOf(ai!)] = ai.copyWith(
            approvalRequest: ai.approvalRequest!.copyWith(
              status: e.text == ApprovalDecision.approve.name
                  ? ApprovalStatus.approved
                  : ApprovalStatus.denied,
            ),
            status: MessageStatus.complete,
          );
        }
        break;
      case AgentEventType.clarificationResolved:
        if (ai?.clarificationRequest != null) {
          messages[messages.indexOf(ai!)] = ai.copyWith(
            clarificationRequest: ai.clarificationRequest!.copyWith(
              status: ClarificationStatus.answered,
              selectedAnswer: e.text,
            ),
            status: MessageStatus.complete,
          );
        }
        break;
      case AgentEventType.messageCompleted:
        activities.add(
          AgentActivity(
            id: '${id}_completed',
            runId: id,
            sessionId: s.id,
            agentId: s.activeModelName ?? '',
            kind: 'completed',
            status: 'completed',
            detail: 'Task selesai',
            createdAt: DateTime.now(),
          ),
        );
        if (ai != null) {
          messages[messages.indexOf(ai)] = ai.copyWith(
            status: MessageStatus.complete,
          );
        }
        break;
      case AgentEventType.messageFailed:
        if (ai != null) {
          messages[messages.indexOf(ai)] = ai.copyWith(
            status: MessageStatus.failed,
            errorMessage: e.text,
          );
        }
        break;
      case AgentEventType.generationStopped:
        for (var i = messages.length - 1; i >= 0; i--) {
          if (messages[i].role == MessageRole.assistant &&
              messages[i].status == MessageStatus.streaming) {
            messages[i] = messages[i].copyWith(status: MessageStatus.stopped);
            break;
          }
        }
        break;
      default:
        break;
    }
    _replace(
      s.copyWith(
        messages: messages,
        activities: activities.length > 300
            ? activities.sublist(activities.length - 300)
            : activities,
        status: e.type == AgentEventType.messageCompleted
            ? SessionStatus.idle
            : e.type == AgentEventType.messageFailed
            ? SessionStatus.failed
            : e.type == AgentEventType.approvalRequested
            ? SessionStatus.waitingApproval
            : e.type == AgentEventType.clarificationRequested
            ? SessionStatus.waitingClarification
            : e.type == AgentEventType.approvalResolved ||
                  e.type == AgentEventType.clarificationResolved
            ? SessionStatus.idle
            : e.type == AgentEventType.generationStopped
            ? SessionStatus.stopped
            : s.status,
        updatedAt: DateTime.now(),
      ),
    );
    if (e.type == AgentEventType.messageCompleted ||
        e.type == AgentEventType.messageFailed ||
        e.type == AgentEventType.generationStopped) {
      _saveTimer?.cancel();
      _save();
    } else {
      _saveTimer?.cancel();
      _saveTimer = Timer(const Duration(milliseconds: 350), _save);
    }
    notifyListeners();
  }

  Future<void> stop() =>
      currentId == null ? Future.value() : connector.stopGeneration(currentId!);
  Future<void> stopSession(String id) => connector.stopGeneration(id);
  Future<void> approveRequest(String id) => connector.respondToApproval(
    requestId: id,
    decision: ApprovalDecision.approve,
  );
  Future<void> denyRequest(String id) => connector.respondToApproval(
    requestId: id,
    decision: ApprovalDecision.deny,
  );
  Future<void> answerClarification(String id, String answer) =>
      connector.respondToClarification(requestId: id, answer: answer);
  Future<void> pin(AgentSession s) async {
    _replace(s.copyWith(isPinned: !s.isPinned));
    await _save();
    notifyListeners();
  }

  Future<void> rename(AgentSession s, String title) async {
    _replace(s.copyWith(title: title));
    await connector.renameSession(s.id, title);
    await _save();
    notifyListeners();
  }

  Future<void> delete(AgentSession s) async {
    sessions.removeWhere((x) => x.id == s.id);
    if (currentId == s.id) currentId = null;
    await connector.deleteSession(s.id);
    await _save();
    notifyListeners();
  }

  int listLimit = 200;

  Future<void> loadMore() async {
    listLimit += 200;
    await reloadSessions();
  }

  Future<void> reloadTasks() async {
    if (!connected) return;
    try {
      tasks = await connector.listTasks();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> reloadSessions() async {
    final remote = await connector.listSessions(limit: listLimit);
    sessions
      ..clear()
      ..addAll(remote);
    await _save();
    notifyListeners();
  }

  Future<void> reloadProjects() async {
    if (connector case final WorkspaceCatalog catalog) {
      projects = await catalog.listProjects(limit: 20);
      notifyListeners();
    }
  }

  Future<void> loadWorkspaces([String? preferred]) async {
    workspaces = await connector.listWorkspaces();
    final selected =
        workspaces.where((x) => x.isActive).firstOrNull ??
        workspaces.where((x) => x.path == preferred).firstOrNull ??
        workspaces.firstOrNull;
    if (selected != null) await selectWorkspace(selected.path);
  }

  Future<void> selectWorkspace(String path) async {
    if (connector case final WorkspaceCatalog catalog) {
      final selected = await catalog.activateWorkspace(path);
      path = selected.path;
      workspaces = await connector.listWorkspaces();
    }
    connector.selectWorkspace(path);
    workspacePath = path;
    workspaceFolder = '';
    await reloadSessions();
    await reloadProjects();
    await reloadWorkspaceData();
    await _persistUiState();
  }

  Future<void> openProjectSession(
    AgentProject project,
    AgentSession session,
  ) async {
    if (workspacePath != project.workspace.path) {
      await selectWorkspace(project.workspace.path);
    }
    final loaded = sessions.where((item) => item.id == session.id).firstOrNull;
    if (loaded != null) await open(loaded);
  }

  Future<void> reloadWorkspaceData({bool fetchGit = false}) async {
    if (connector case final WorkspaceMonitor monitor) {
      final results = await Future.wait([
        monitor.getGitStatus(fetch: fetchGit),
        monitor.getGitRepositoryStatus(fetch: false),
        monitor.listWorkspace(workspaceFolder),
      ]);
      gitStatus = results[0] as List<GitStatusEntry>;
      gitRepository = results[1] as GitRepositoryStatus;
      workspaceEntries = results[2] as List<WorkspaceEntry>;
      notifyListeners();
    }
  }

  Future<void> syncGitHub() => reloadWorkspaceData(fetchGit: true);

  Future<void> openWorkspaceFolder(String path) async {
    workspaceFolder = path;
    await reloadWorkspaceData();
  }

  Future<void> openTask(AgentTask task) async {
    if (task.sessionId.isEmpty) return;
    var session = sessions
        .where((item) => item.id == task.sessionId)
        .firstOrNull;
    if (session == null) {
      await reloadSessions();
      session = sessions.where((item) => item.id == task.sessionId).firstOrNull;
    }
    if (session != null) await open(session);
  }

  Future<void> open(AgentSession s) async {
    currentId = s.id;
    loadingSession = true;
    notifyListeners();
    try {
      _replace(await connector.loadSession(s.id));
    } catch (error) {
      connectorError = _connectionError(error);
    } finally {
      loadingSession = false;
    }
    notifyListeners();
    await _persistUiState();
  }

  Future<void> closeCurrentSession() async {
    currentId = null;
    await reloadProjects();
    notifyListeners();
    await _persistUiState();
  }

  Future<void> restoreLastSession([String? requestedSessionId]) async {
    final target = requestedSessionId ?? _restoredUiState.sessionId;
    if (target == null || target.isEmpty) return;
    final session = sessions.where((item) => item.id == target).firstOrNull;
    if (session != null) await open(session);
  }

  void setPage(int v) {
    page = v;
    notifyListeners();
    _persistUiState();
  }

  void setTheme(ThemeModeChoice v) {
    theme = v;
    notifyListeners();
  }

  void refresh() => notifyListeners();

  List<AgentSession> get filtered => sessions
      .where(
        (s) =>
            ('$search ${s.title} ${s.messages.map((m) => m.content).join(' ')} ${s.messages.expand((m) => m.attachments).map((a) => a.originalName).join(' ')}')
                .toLowerCase()
                .contains(search.toLowerCase()),
      )
      .toList();
  void _replace(AgentSession s) {
    final i = sessions.indexWhere((x) => x.id == s.id);
    if (i >= 0) sessions[i] = s;
  }

  Future<void> _save() => store.save(sessions);
  Future<void> _persistUiState() => store.saveUiState(
    AppUiState(sessionId: currentId, workspacePath: workspacePath, page: page),
  );
  @override
  void dispose() {
    _taskTimer?.cancel();
    _saveTimer?.cancel();
    _sub?.cancel();
    connector.dispose();
    super.dispose();
  }
}

enum ThemeModeChoice { system, light, dark }

String _connectionError(Object error) {
  final text = error.toString();
  if (text.contains('HTTP 401')) {
    return 'Login rejected. Check username or password.';
  }
  if (text.contains('HTTP 403')) return 'Gateway rejected this connection.';
  if (text.contains('timed out')) {
    return 'Connection timed out. Check endpoint and Tailscale.';
  }
  if (text.contains('HandshakeException')) {
    return 'HTTPS certificate or Tailscale connection failed.';
  }
  return 'Gateway connection failed: ${text.length > 120 ? text.substring(0, 120) : text}';
}

String _titleFrom(String text) {
  final firstLine = text.trim().split('\n').first;
  return firstLine.substring(0, firstLine.length.clamp(0, 40));
}
