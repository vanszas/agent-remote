import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_remote/connection.dart';

void main() {
  const source =
      '''{"schemaVersion":1,"providers":[{"id":"remote","mode":"remoteGateway","displayName":"Remote","description":"Remote","iconKey":"remote","sortOrder":1,"enabled":true,"integrationStatus":"deferred","supportsProfiles":true,"supportsAuthentication":false,"capabilities":["chat","futureCapability"],"configurationFields":[{"id":"transport","type":"select","label":"Transport","required":true,"options":["usb","custom"],"secret":false}]}]}''';
  test('unknown capabilities are skipped and field IDs validated', () {
    final catalog = ConnectionCatalog.parse(source);
    expect(catalog.providers.single.capabilities, [ConnectionCapability.chat]);
    expect(
      () => ConnectionCatalog.parse(
        source.replaceFirst(
          '"transport","type"',
          '"transport","type":"text"},{"id":"transport","type"',
        ),
      ),
      throwsFormatException,
    );
  });
  test('schema 1 profile migrates to schema 2 values', () {
    final p = ConnectionProfile.fromJson({
      'schemaVersion': 1,
      'id': 'p',
      'providerId': 'remote',
      'displayName': 'Office',
      'transportType': 'usb',
      'endpoint': 'draft',
      'createdAt': '2026-01-01T00:00:00Z',
      'updatedAt': '2026-01-01T00:00:00Z',
    });
    expect(p.schemaVersion, 2);
    expect(p.values, {'transportType': 'usb', 'endpoint': 'draft'});
  });
  test('snapshot persists selected provider and CRUD/default', () async {
    final dir = await Directory.systemTemp.createTemp();
    final store = ConnectionProfileStore(directory: dir);
    final controller = ConnectionSettingsController(
      ConnectionCatalog.parse(source),
      store,
    );
    await controller.initialize();
    controller.selectProvider('remote');
    await controller.addProfile('Office', {'transport': 'usb'});
    final id = controller.profiles.single.id;
    await controller.updateProfile(id, 'Office 2', {'transport': 'custom'});
    await controller.setDefaultProfile(id);
    await controller.reload();
    expect(controller.selectedProviderId, 'remote');
    expect(controller.defaultProfile?.displayName, 'Office 2');
    await controller.toggleProfile(id);
    expect(controller.defaultProfile, isNull);
    await controller.deleteProfile(id);
    expect(controller.profiles, isEmpty);
  });
  test('required fields and secrets are rejected', () async {
    final dir = await Directory.systemTemp.createTemp();
    final store = ConnectionProfileStore(directory: dir);
    final controller = ConnectionSettingsController(
      ConnectionCatalog.parse(source),
      store,
    );
    await controller.initialize();
    expect(() => controller.addProfile('Office', {}), throwsArgumentError);
  });

  test('failed write does not poison later saves', () async {
    final root = await Directory.systemTemp.createTemp();
    final blocked = File('${root.path}${Platform.pathSeparator}blocked');
    await blocked.writeAsString('file');
    final store = ConnectionProfileStore(directory: Directory(blocked.path));
    await expectLater(
      store.save(const ConnectionSettingsSnapshot()),
      throwsA(anything),
    );
    await blocked.delete();
    await Directory(blocked.path).create();
    await store.save(
      const ConnectionSettingsSnapshot(selectedProviderId: 'remote'),
    );
    expect((await store.load()).selectedProviderId, 'remote');
  });
}
