import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_remote/agent_connector.dart';
import 'package:hermes_remote/app_controller.dart';
import 'package:hermes_remote/local_store.dart';

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
}
