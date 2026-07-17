import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_remote/agent_connector.dart';
import 'package:hermes_remote/hermes_remote_connector.dart';

void main() {
  test('decodes git status and workspace tree', () {
    expect(
      decodeGitStatus({
        'files': [
          {'path': 'lib/a.dart', 'status': 'modified'},
          {'path': 'new.txt', 'status': 'untracked'},
        ],
      }).map((e) => (e.path, e.status)),
      [
        ('lib/a.dart', GitFileStatus.modified),
        ('new.txt', GitFileStatus.untracked),
      ],
    );
    expect(
      decodeWorkspaceEntries({
        'entries': [
          {'name': 'lib', 'path': 'lib', 'kind': 'directory'},
        ],
      }).single.isDirectory,
      isTrue,
    );
  });
}
