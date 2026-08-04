import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_remote/agent_connector.dart';
import 'package:hermes_remote/app_controller.dart';
import 'package:hermes_remote/local_store.dart';
import 'package:hermes_remote/models.dart';

void main() {
  test('session serialization tolerates unknown fields and enum fallback', () {
    final session = AgentSession.fromJson({
      'id': 's1',
      'title': 'Demo',
      'createdAt': '2026-01-01T00:00:00Z',
      'updatedAt': '2026-01-01T00:00:00Z',
      'status': 'futureStatus',
      'messages': <Object?>[],
      'future': true,
    });
    expect(session.status, SessionStatus.idle);
    expect(AgentSession.fromJson(session.toJson()).id, 's1');
  });

  test('session personalization override survives serialization', () {
    final session = AgentSession.fromJson({
      'id': 's1',
      'title': 'Demo',
      'createdAt': '2026-01-01T00:00:00Z',
      'updatedAt': '2026-01-01T00:00:00Z',
      'personalizationOverride': 'Answer in English',
    });

    expect(session.personalizationOverride, 'Answer in English');
    expect(
      AgentSession.fromJson(session.toJson()).personalizationOverride,
      'Answer in English',
    );
  });

  test('attachment filename sanitization and size validation', () {
    expect(sanitizeFilename('../a:b?.txt'), 'a_b_.txt');
    expect(validateAttachmentSize(15 * 1024 * 1024), isNull);
    expect(validateAttachmentSize(15 * 1024 * 1024 + 1), isNotNull);
  });

  test('elapsed duration scales from seconds to minutes and hours', () {
    expect(formatElapsedDuration(59), '59 detik');
    expect(formatElapsedDuration(60), '1 menit');
    expect(formatElapsedDuration(125), '2 menit 5 detik');
    expect(formatElapsedDuration(3600), '1 jam');
    expect(formatElapsedDuration(7325), '2 jam 2 menit');
  });

  test('activity clock follows device timezone', () {
    final value = DateTime.utc(2026, 7, 18, 8, 30).toLocal();
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    expect(
      formatLocalClock(DateTime.utc(2026, 7, 18, 8, 30)),
      '$hour:$minute ${value.timeZoneName}',
    );
  });

  test('multiline prompt uses first line as title', () async {
    final dir = await Directory.systemTemp.createTemp();
    final connector = DemoAgentConnector(delay: Duration.zero);
    final controller = AppController(connector, LocalStore(directory: dir));
    await controller.initialize();
    await controller.newSession();
    await controller.send('Hi\nThis second line is longer than the first');
    expect(controller.current?.title, 'Hi');
    await connector.dispose();
  });
}
