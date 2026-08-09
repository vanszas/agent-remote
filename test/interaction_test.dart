import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:agent_remote/agent_connector.dart';
import 'package:agent_remote/app_controller.dart';
import 'package:agent_remote/local_store.dart';
import 'package:agent_remote/models.dart';

Future<AgentEvent> eventOf(Stream<AgentEvent> stream, AgentEventType type) =>
    stream.firstWhere((event) => event.type == type);

void main() {
  test('approval resolution keeps session ID and rejects duplicate', () async {
    final connector = DemoAgentConnector(delay: Duration.zero);
    await connector.initialize();
    final session = await connector.createSession();
    final requested = eventOf(
      connector.events,
      AgentEventType.approvalRequested,
    );
    await connector.sendPrompt(
      sessionId: session.id,
      text: '/demo approval',
      attachments: const [],
    );
    final request = await requested;
    final resolved = eventOf(connector.events, AgentEventType.approvalResolved);
    await connector.respondToApproval(
      requestId: request.correlationId!,
      decision: ApprovalDecision.approve,
    );
    expect((await resolved).sessionId, session.id);
    expect(
      () => connector.respondToApproval(
        requestId: request.correlationId!,
        decision: ApprovalDecision.deny,
      ),
      throwsStateError,
    );
    await connector.dispose();
  });

  test(
    'clarification resolution keeps session ID and rejects duplicate',
    () async {
      final connector = DemoAgentConnector(delay: Duration.zero);
      await connector.initialize();
      final session = await connector.createSession();
      final requested = eventOf(
        connector.events,
        AgentEventType.clarificationRequested,
      );
      await connector.sendPrompt(
        sessionId: session.id,
        text: '/demo clarify',
        attachments: const [],
      );
      final request = await requested;
      final resolved = eventOf(
        connector.events,
        AgentEventType.clarificationResolved,
      );
      await connector.respondToClarification(
        requestId: request.correlationId!,
        answer: 'Fast',
      );
      expect((await resolved).sessionId, session.id);
      expect(
        () => connector.respondToClarification(
          requestId: request.correlationId!,
          answer: 'Detailed',
        ),
        throwsStateError,
      );
      await connector.dispose();
    },
  );

  test(
    'controller stores typed requests and resolves through actions',
    () async {
      final connector = DemoAgentConnector(delay: Duration.zero);
      final dir = await Directory.systemTemp.createTemp();
      final controller = AppController(connector, LocalStore(directory: dir));
      await controller.initialize();
      await controller.send('/demo approval');
      await Future<void>.delayed(Duration.zero);
      final approval = controller.current!.messages
          .where((message) => message.approvalRequest != null)
          .single;
      expect(approval.approvalRequest!.status, ApprovalStatus.pending);
      await controller.approveRequest(approval.approvalRequest!.id);
      await Future<void>.delayed(Duration.zero);
      expect(
        controller.current!.messages
            .where((message) => message.id == approval.id)
            .single
            .approvalRequest!
            .status,
        ApprovalStatus.approved,
      );
      expect(controller.current!.status, SessionStatus.idle);
      controller.dispose();
    },
  );

  test('empty clarification keeps request pending', () async {
    final connector = DemoAgentConnector(delay: Duration.zero);
    await connector.initialize();
    final session = await connector.createSession();
    final requested = eventOf(
      connector.events,
      AgentEventType.clarificationRequested,
    );
    await connector.sendPrompt(
      sessionId: session.id,
      text: '/demo clarify',
      attachments: const [],
    );
    final id = (await requested).correlationId!;
    await expectLater(
      connector.respondToClarification(requestId: id, answer: ' '),
      throwsArgumentError,
    );
    await connector.respondToClarification(requestId: id, answer: 'Fast');
    await connector.dispose();
  });

  test('stop cancels pending approval', () async {
    final connector = DemoAgentConnector(delay: Duration.zero);
    await connector.initialize();
    final session = await connector.createSession();
    final requested = eventOf(
      connector.events,
      AgentEventType.approvalRequested,
    );
    await connector.sendPrompt(
      sessionId: session.id,
      text: '/demo approval',
      attachments: const [],
    );
    final id = (await requested).correlationId!;
    await connector.stopGeneration(session.id);
    await expectLater(
      connector.respondToApproval(
        requestId: id,
        decision: ApprovalDecision.approve,
      ),
      throwsStateError,
    );
    await connector.dispose();
  });

  test('typed requests serialize with unknown enum fallback', () {
    final now = DateTime.utc(2026);
    final approval = ApprovalRequest(
      id: 'a',
      sessionId: 's',
      correlationId: 'c',
      title: 'Approve',
      description: 'Demo',
      riskLevel: ApprovalRiskLevel.medium,
      createdAt: now,
      status: ApprovalStatus.pending,
      isDemo: true,
    );
    final clarification = ClarificationRequest(
      id: 'q',
      sessionId: 's',
      correlationId: 'c2',
      question: 'Which?',
      choices: const ['Fast'],
      allowFreeText: true,
      createdAt: now,
      status: ClarificationStatus.pending,
      isDemo: true,
    );
    final message = ChatMessage(
      id: 'm',
      sessionId: 's',
      role: MessageRole.system,
      content: '',
      createdAt: now,
      updatedAt: now,
      status: MessageStatus.queued,
      approvalRequest: approval,
      clarificationRequest: clarification,
    );
    final json = message.toJson();
    (json['approvalRequest'] as Map<String, Object?>)['riskLevel'] = 'future';
    final restored = ChatMessage.fromJson(json);
    expect(restored.approvalRequest!.riskLevel, ApprovalRiskLevel.unknown);
    expect(restored.clarificationRequest!.choices, ['Fast']);
  });
}
