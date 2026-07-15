import 'dart:async';
import 'package:flutter/foundation.dart';
import 'agent_connector.dart';
import 'local_store.dart';
import 'models.dart';

class AppController extends ChangeNotifier {
  AppController(this.connector, this.store);
  final AgentConnector connector;
  final LocalStore store;
  final sessions = <AgentSession>[];
  StreamSubscription<AgentEvent>? _sub;
  String? currentId;
  ThemeModeChoice theme = ThemeModeChoice.system;
  int page = 0;
  String search = '';
  AgentSession? get current =>
      sessions.where((s) => s.id == currentId).firstOrNull;
  Future<void> initialize() async {
    sessions.addAll(await store.load());
    _sub = connector.events.listen(_event);
    await connector.initialize();
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
          messages[messages.indexOf(ai)] = ai.copyWith(
            toolActivities: [
              ToolActivity(
                id: id,
                toolName: 'inspect',
                displayName: e.text,
                summary: 'Simulated only',
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
          messages[messages.indexOf(ai)] = ai.copyWith(
            toolActivities: [
              ToolActivity(
                id: t.id,
                toolName: t.toolName,
                displayName: t.displayName,
                summary: t.summary,
                status: ToolActivityStatus.running,
                startedAt: t.startedAt,
                progress: e.data['progress'] as double?,
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
        messages.add(
          ChatMessage(
            id: id,
            sessionId: s.id,
            role: MessageRole.system,
            content: 'APPROVAL: ${e.text}\nDemo only — no command runs.',
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
            status: MessageStatus.queued,
          ),
        );
        break;
      case AgentEventType.clarificationRequested:
        messages.add(
          ChatMessage(
            id: id,
            sessionId: s.id,
            role: MessageRole.system,
            content: 'CLARIFY: ${e.text}\nFast | Detailed',
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
            status: MessageStatus.queued,
          ),
        );
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

  void open(AgentSession s) {
    currentId = s.id;
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

String _titleFrom(String text) {
  final firstLine = text.trim().split('\n').first;
  return firstLine.substring(0, firstLine.length.clamp(0, 40));
}
