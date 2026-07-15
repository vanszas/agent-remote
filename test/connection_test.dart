import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_remote/connection.dart';

void main() {
  const catalogJson = '''{"schemaVersion":1,"providers":[
    {"id":"remote","mode":"remoteGateway","displayName":"Remote","description":"Remote agent","iconKey":"remote","sortOrder":20,"enabled":true,"integrationStatus":"deferred","supportsProfiles":true,"supportsAuthentication":false,"capabilities":[],"configurationFields":[]},
    {"id":"local","mode":"localGateway","displayName":"Local","description":"Local agent","iconKey":"desktop","sortOrder":10,"enabled":true,"integrationStatus":"deferred","supportsProfiles":false,"supportsAuthentication":false,"capabilities":[],"configurationFields":[],"future":true}
  ]}''';

  test('catalog sorts, ignores unknown fields, rejects duplicate IDs', () {
    final catalog = ConnectionCatalog.parse(catalogJson);
    expect(catalog.providers.map((e) => e.id), ['local', 'remote']);
    expect(
      () => ConnectionCatalog.parse(
        catalogJson.replaceFirst('"remote"', '"local"'),
      ),
      throwsFormatException,
    );
  });

  test('unknown enum falls back safely and corrupt JSON is controlled', () {
    final catalog = ConnectionCatalog.parse(
      catalogJson.replaceFirst('localGateway', 'futureMode'),
    );
    expect(catalog.providers.first.mode, ConnectionMode.unknown);
    expect(() => ConnectionCatalog.parse('{bad'), throwsFormatException);
  });

  test('profile store persists CRUD/default without credentials', () async {
    final dir = await Directory.systemTemp.createTemp();
    final store = ConnectionProfileStore(directory: dir);
    final now = DateTime.utc(2026);
    final profile = ConnectionProfile(
      id: 'p1',
      providerId: 'remote',
      displayName: 'Office',
      values: const {'transportType': 'custom', 'endpoint': 'draft.example'},
      createdAt: now,
      updatedAt: now,
    );
    await store.save(ConnectionSettingsSnapshot(profiles: [profile]));
    final loaded = await store.load();
    expect(loaded.profiles.single.displayName, 'Office');
    expect(
      (await File(
        '${dir.path}${Platform.pathSeparator}connection_profiles.json',
      ).readAsString()).toLowerCase(),
      isNot(contains('password')),
    );
  });

  test('summary provider count is computed from catalog', () async {
    final dir = await Directory.systemTemp.createTemp();
    final c = ConnectionSettingsController(
      ConnectionCatalog.parse(catalogJson),
      ConnectionProfileStore(directory: dir),
    );
    expect(c.summary, 'No connection profile configured');
    expect(c.providerSummary, '2 providers available');
  });
}
