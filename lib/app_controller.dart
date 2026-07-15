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
  String? currentId;
  ThemeModeChoice theme = ThemeModeChoice.system;
  int page = 0;
  String search = '';
  AgentCapabilities capabilities = const AgentCapabilities();
  String? connectorError;
  bool loadingSession = false;
  List<AgentWorkspace> workspaces = const [];
  List<AgentTask> tasks = const [];
  String? workspacePath;
  bool get isDemo => connector is DemoAgentConnector;
  String get connectorLabel => isDemo ? 'Demo Mode' : 'Hermes Connected';
  AgentSession? get current =>
      sessions.where((s) => s.id == currentId).firstOrNull;
  Future<void> initialize() async {
    sessions.addAll(await store.load());
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
      connectorError = null;
    } catch (error) {
      await nextEvents.cancel();
      await next.dispose();
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
        status: SessionStatus.generating,
        updatedAt: now,
      ),
    );
    await _save();
    notifyListeners();
    await connector.sendPrompt(
      sessionId: s.id,
      text: text.trim(),
      attachments: attachments,
    );
  }

  void _event(AgentEvent e) {
    if (e.type == AgentEventType.sessionUpdated && e.sessionId.isEmpty) {
      reloadSessions();
      return;
    }
    // Gateway connector translates live IDs before emitting; never guess a session.
    final s = sessions.where((x) => x.id == e.sessionId).firstOrNull;
    if (s == null) return;
    var messages = [...s.messages];
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
    _save();
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
    tasks = await connector.listTasks();
    notifyListeners();
  }

  Future<void> reloadSessions() async {
    final remote = await connector.listSessions(limit: listLimit);
    sessions
      ..clear()
      ..addAll(remote);
    await _save();
    notifyListeners();
  }

  Future<void> loadWorkspaces([String? preferred]) async {
    workspaces = await connector.listWorkspaces();
    final selected =
        workspaces.where((x) => x.path == preferred).firstOrNull ??
        workspaces.where((x) => x.isActive).firstOrNull ??
        workspaces.firstOrNull;
    if (selected != null) await selectWorkspace(selected.path);
  }

  Future<void> selectWorkspace(String path) async {
    connector.selectWorkspace(path);
    workspacePath = path;
    await reloadSessions();
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
  }

  void setPage(int v) {
    page = v;
    notifyListeners();
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
  @override
  void dispose() {
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
