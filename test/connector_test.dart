import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_remote/agent_connector.dart';
import 'package:hermes_remote/app_controller.dart';
import 'package:hermes_remote/local_store.dart';
import 'package:hermes_remote/models.dart';

class _WorkspaceConnector extends DemoAgentConnector {
  String? selected;

  @override
  Future<List<AgentWorkspace>> listWorkspaces() async => const [
    AgentWorkspace(id: 'all', name: 'All Workspaces', path: 'all'),
    AgentWorkspace(id: 'old', name: 'Old', path: 'old'),
    AgentWorkspace(id: 'pc', name: 'PC', path: 'pc', isActive: true),
  ];

  @override
  void selectWorkspace(String path) => selected = path;
}

class _TaskConnector extends DemoAgentConnector {
  _TaskConnector(this.tasks);
  final List<AgentTask> tasks;

  @override
  Future<List<AgentTask>> listTasks() async => tasks;
}

class _EventConnector extends DemoAgentConnector {
  final controller = StreamController<AgentEvent>.broadcast();

  @override
  Stream<AgentEvent> get events => controller.stream;

  void emit(AgentEvent event) => controller.add(event);

  @override
  Future<void> dispose() async {
    await controller.close();
    await super.dispose();
  }
}

void main() {
  test('demo streams and completes simple response', () async {
    final c = DemoAgentConnector(delay: Duration.zero);
    await c.initialize();
    final s = await c.createSession();
    final events = <AgentEvent>[];
    final sub = c.events.listen(events.add);
    await c.sendPrompt(sessionId: s.id, text: 'hello', attachments: const []);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(events.any((e) => e.type == AgentEventType.messageDelta), isTrue);
    expect(
      events.any((e) => e.type == AgentEventType.messageCompleted),
      isTrue,
    );
    await sub.cancel();
    await c.dispose();
  });
  test('stop affects target session', () async {
    final c = DemoAgentConnector(delay: const Duration(milliseconds: 20));
    await c.initialize();
    final s = await c.createSession();
    final events = <AgentEvent>[];
    c.events.listen(events.add);
    c.sendPrompt(sessionId: s.id, text: '/demo long', attachments: const []);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await c.stopGeneration(s.id);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      events.any((e) => e.type == AgentEventType.generationStopped),
      isTrue,
    );
    await c.dispose();
  });
  test('rename of persistence-only session is a safe no-op', () async {
    final c = DemoAgentConnector(delay: Duration.zero);
    await c.initialize();
    await c.renameSession('loaded-after-restart', 'Renamed');
    await c.dispose();
  });
  test('active PC workspace overrides stale mobile selection', () async {
    final connector = _WorkspaceConnector();
    final controller = AppController(
      connector,
      LocalStore(directory: await Directory.systemTemp.createTemp()),
    );
    await controller.loadWorkspaces('old');
    expect(controller.workspacePath, 'pc');
    expect(connector.selected, 'pc');
    controller.dispose();
  });

  test(
    'task polling clears stale generating session but keeps active one',
    () async {
      final directory = await Directory.systemTemp.createTemp();
      addTearDown(() => directory.delete(recursive: true));
      final connector = _TaskConnector(const [
        AgentTask(
          id: 'run-active',
          title: 'Active',
          status: 'running',
          sessionId: 'session-active',
        ),
      ]);
      final controller = AppController(
        connector,
        LocalStore(directory: directory),
      )..connected = true;
      final old = DateTime.now().subtract(const Duration(minutes: 1));
      controller.sessions.addAll([
        AgentSession(
          id: 'session-stale',
          title: 'Stale',
          createdAt: old,
          updatedAt: old,
          status: SessionStatus.generating,
        ),
        AgentSession(
          id: 'session-active',
          title: 'Active',
          createdAt: old,
          updatedAt: old,
          status: SessionStatus.generating,
        ),
      ]);

      await controller.reloadTasks();

      expect(
        controller.sessions
            .firstWhere((value) => value.id == 'session-stale')
            .status,
        SessionStatus.idle,
      );
      expect(
        controller.sessions
            .firstWhere((value) => value.id == 'session-active')
            .status,
        SessionStatus.generating,
      );
      controller.dispose();
    },
  );

  test('stream deltas batch UI notifications', () async {
    final directory = await Directory.systemTemp.createTemp();
    addTearDown(() => directory.delete(recursive: true));
    final connector = _EventConnector();
    final controller = AppController(
      connector,
      LocalStore(directory: directory),
    );
    await controller.initialize();
    await controller.newSession();
    final sessionId = controller.current!.id;
    var notifications = 0;
    controller.addListener(() => notifications++);
    connector.emit(
      AgentEvent(
        AgentEventType.messageStarted,
        sessionId: sessionId,
        correlationId: 'run',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    notifications = 0;

    for (var index = 0; index < 20; index++) {
      connector.emit(
        AgentEvent(
          AgentEventType.messageDelta,
          sessionId: sessionId,
          correlationId: 'run',
          text: '$index',
        ),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(notifications, 0);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(notifications, 1);
    controller.dispose();
  });
}
