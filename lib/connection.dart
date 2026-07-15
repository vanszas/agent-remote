import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

enum ConnectionMode { localGateway, hermesCloud, remoteGateway, unknown }

enum RemoteTransportType { emulator, usb, tailscaleServe, custom, unknown }

enum ConnectionIntegrationStatus {
  deferred,
  available,
  unavailable,
  experimental,
  unknown,
}

enum ConnectionCapability {
  sessions,
  chat,
  images,
  files,
  approvals,
  clarification,
  toolStreaming,
  stop,
  modelSelection,
  workspaceAccess,
}

T _enum<T extends Enum>(List<T> values, Object? value, T fallback) =>
    values.where((e) => e.name == value).firstOrNull ?? fallback;

class ConnectionField {
  const ConnectionField({
    required this.id,
    required this.type,
    required this.label,
    this.description = '',
    this.required = false,
    this.placeholder = '',
    this.options = const [],
    this.secret = false,
  });
  final String id, type, label, description, placeholder;
  final bool required, secret;
  final List<String> options;
  factory ConnectionField.fromJson(Map<String, Object?> j) => ConnectionField(
    id: j['id'] as String? ?? '',
    type: j['type'] as String? ?? 'text',
    label: j['label'] as String? ?? '',
    description: j['description'] as String? ?? '',
    required: j['required'] as bool? ?? false,
    placeholder: j['placeholder'] as String? ?? '',
    options: (j['options'] as List? ?? []).whereType<String>().toList(),
    secret: j['secret'] as bool? ?? false,
  );
}

class ConnectionProviderDefinition {
  const ConnectionProviderDefinition({
    required this.id,
    required this.mode,
    required this.displayName,
    required this.description,
    required this.iconKey,
    required this.sortOrder,
    required this.enabled,
    required this.integrationStatus,
    required this.supportsProfiles,
    required this.supportsAuthentication,
    required this.capabilities,
    required this.configurationFields,
  });
  final String id, displayName, description, iconKey;
  final ConnectionMode mode;
  final int sortOrder;
  final bool enabled, supportsProfiles, supportsAuthentication;
  final ConnectionIntegrationStatus integrationStatus;
  final List<ConnectionCapability> capabilities;
  final List<ConnectionField> configurationFields;
  factory ConnectionProviderDefinition.fromJson(Map<String, Object?> j) =>
      ConnectionProviderDefinition(
        id: j['id'] as String? ?? '',
        mode: _enum(ConnectionMode.values, j['mode'], ConnectionMode.unknown),
        displayName: j['displayName'] as String? ?? 'Unknown provider',
        description: j['description'] as String? ?? '',
        iconKey: j['iconKey'] as String? ?? 'fallback',
        sortOrder: j['sortOrder'] as int? ?? 999,
        enabled: j['enabled'] as bool? ?? false,
        integrationStatus: _enum(
          ConnectionIntegrationStatus.values,
          j['integrationStatus'],
          ConnectionIntegrationStatus.unknown,
        ),
        supportsProfiles: j['supportsProfiles'] as bool? ?? false,
        supportsAuthentication: j['supportsAuthentication'] as bool? ?? false,
        capabilities: (j['capabilities'] as List? ?? [])
            .map(
              (x) => ConnectionCapability.values
                  .where((e) => e.name == x)
                  .firstOrNull,
            )
            .whereType<ConnectionCapability>()
            .toSet()
            .toList(),
        configurationFields: (j['configurationFields'] as List? ?? [])
            .whereType<Map>()
            .map((x) => ConnectionField.fromJson(Map<String, Object?>.from(x)))
            .toList(),
      );
}

class ConnectionCatalog {
  const ConnectionCatalog(this.schemaVersion, this.providers);
  final int schemaVersion;
  final List<ConnectionProviderDefinition> providers;
  static ConnectionCatalog parse(String source) {
    try {
      final root = jsonDecode(source) as Map;
      final providers =
          (root['providers'] as List? ?? [])
              .whereType<Map>()
              .map(
                (x) => ConnectionProviderDefinition.fromJson(
                  Map<String, Object?>.from(x),
                ),
              )
              .toList()
            ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
      final ids = <String>{};
      for (final p in providers) {
        if (p.id.isEmpty || !ids.add(p.id)) {
          throw const FormatException('Provider IDs must be unique.');
        }
        final fields = <String>{};
        for (final field in p.configurationFields) {
          if (field.id.isEmpty || !fields.add(field.id)) {
            throw const FormatException('Field IDs must be unique.');
          }
          if (field.type == 'select' && field.options.isEmpty) {
            throw const FormatException('Select fields require options.');
          }
        }
      }
      return ConnectionCatalog(root['schemaVersion'] as int? ?? 1, providers);
    } catch (e) {
      if (e is FormatException) rethrow;
      throw const FormatException('Connection catalog is invalid.');
    }
  }

  static Future<ConnectionCatalog> loadAsset() => rootBundle
      .loadString('assets/config/connection_providers.json')
      .then(parse);
}

class ConnectionProfile {
  const ConnectionProfile({
    required this.id,
    required this.providerId,
    required this.displayName,
    this.values = const {},
    this.isDefault = false,
    this.isEnabled = true,
    required this.createdAt,
    required this.updatedAt,
    this.lastConnectedAt,
    this.metadata = const {},
    this.schemaVersion = 2,
  });
  final String id, providerId, displayName;
  final Map<String, Object?> values;
  final bool isDefault, isEnabled;
  final DateTime createdAt, updatedAt;
  final DateTime? lastConnectedAt;
  final Map<String, Object?> metadata;
  final int schemaVersion;
  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'id': id,
    'providerId': providerId,
    'displayName': displayName,
    'values': values,
    'isDefault': isDefault,
    'isEnabled': isEnabled,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'lastConnectedAt': lastConnectedAt?.toIso8601String(),
    'metadata': metadata,
  };
  factory ConnectionProfile.fromJson(
    Map<String, Object?> j,
  ) => ConnectionProfile(
    id: j['id'] as String? ?? '',
    providerId: j['providerId'] as String? ?? '',
    displayName: j['displayName'] as String? ?? '',
    values: j['values'] is Map
        ? Map<String, Object?>.from(j['values'] as Map)
        : {
            if (j['transportType'] != null) 'transportType': j['transportType'],
            if (j['endpoint'] != null) 'endpoint': j['endpoint'],
          },
    isDefault: j['isDefault'] as bool? ?? false,
    isEnabled: j['isEnabled'] as bool? ?? true,
    createdAt:
        DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
    updatedAt:
        DateTime.tryParse(j['updatedAt'] as String? ?? '') ?? DateTime.now(),
    lastConnectedAt: DateTime.tryParse(j['lastConnectedAt'] as String? ?? ''),
    metadata: Map<String, Object?>.from(j['metadata'] as Map? ?? {}),
    schemaVersion: 2,
  );
}

class ConnectionSettingsSnapshot {
  const ConnectionSettingsSnapshot({
    this.selectedProviderId,
    this.profiles = const [],
  });
  final String? selectedProviderId;
  final List<ConnectionProfile> profiles;
  Map<String, Object?> toJson() => {
    'schemaVersion': 2,
    'selectedProviderId': selectedProviderId,
    'profiles': profiles.map((e) => e.toJson()).toList(),
  };
  factory ConnectionSettingsSnapshot.fromJson(Map<String, Object?> j) =>
      ConnectionSettingsSnapshot(
        selectedProviderId: j['selectedProviderId'] as String?,
        profiles: (j['profiles'] as List? ?? [])
            .whereType<Map>()
            .map(
              (e) => ConnectionProfile.fromJson(Map<String, Object?>.from(e)),
            )
            .toList(),
      );
}

class ConnectionProfileStore {
  ConnectionProfileStore({this._directory});
  final Directory? _directory;
  Future<void> _writes = Future.value();
  Future<File> get _file async {
    final d = _directory ?? await getApplicationSupportDirectory();
    return File('${d.path}${Platform.pathSeparator}connection_profiles.json');
  }

  Future<ConnectionSettingsSnapshot> load() async {
    final f = await _file;
    if (!await f.exists()) return const ConnectionSettingsSnapshot();
    try {
      return _decode(await f.readAsString());
    } on FormatException {
      final backup = File('${f.path}.bak');
      if (!await backup.exists()) rethrow;
      return _decode(await backup.readAsString());
    }
  }

  ConnectionSettingsSnapshot _decode(String source) {
    try {
      return ConnectionSettingsSnapshot.fromJson(
        Map<String, Object?>.from(jsonDecode(source) as Map),
      );
    } catch (_) {
      throw const FormatException('Connection settings are invalid.');
    }
  }

  Future<void> save(ConnectionSettingsSnapshot snapshot) {
    final copy = ConnectionSettingsSnapshot(
      selectedProviderId: snapshot.selectedProviderId,
      profiles: List.unmodifiable(snapshot.profiles),
    );
    final write = _writes.catchError((_) {}).then((_) => _save(copy));
    _writes = write;
    return write;
  }

  Future<void> _save(ConnectionSettingsSnapshot snapshot) async {
    final f = await _file;
    await f.parent.create(recursive: true);
    final t = File('${f.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
    await t.writeAsString(jsonEncode(snapshot.toJson()), flush: true);
    final backup = File('${f.path}.bak');
    if (await f.exists()) await f.copy(backup.path);
    try {
      if (await f.exists()) await f.delete();
      await t.rename(f.path);
    } catch (_) {
      if (!await f.exists() && await backup.exists()) await backup.copy(f.path);
      rethrow;
    }
  }
}

class ConnectionSettingsController extends ChangeNotifier {
  ConnectionSettingsController(this.catalog, this.store, {this.error});
  final ConnectionCatalog catalog;
  final ConnectionProfileStore store;
  final String? error;
  final List<ConnectionProfile> profiles = [];
  String? selectedProviderId;
  ConnectionProviderDefinition? get selectedProvider =>
      catalog.providers.where((p) => p.id == selectedProviderId).firstOrNull;
  String get summary => profiles.where((x) => x.isEnabled).isEmpty
      ? 'No connection profile configured'
      : '${profiles.where((x) => x.isEnabled).length} connection profile';
  String get providerSummary =>
      '${catalog.providers.where((x) => x.enabled).length} providers available';
  Future<void> initialize() async {
    final snapshot = await store.load();
    profiles
      ..clear()
      ..addAll(snapshot.profiles);
    selectedProviderId = snapshot.selectedProviderId;
    selectedProviderId ??=
        catalog.providers
            .where((p) => p.enabled && p.supportsProfiles)
            .firstOrNull
            ?.id ??
        catalog.providers.where((p) => p.enabled).firstOrNull?.id;
    notifyListeners();
  }

  Future<void> reload() => initialize();
  Future<void> save() => store.save(
    ConnectionSettingsSnapshot(
      selectedProviderId: selectedProviderId,
      profiles: profiles,
    ),
  );
  Future<void> selectProvider(String id) async {
    selectedProviderId = id;
    await save();
    notifyListeners();
  }

  void select(String id) => selectProvider(id);
  List<ConnectionProfile> profilesForProvider(String id) =>
      profiles.where((p) => p.providerId == id).toList();
  ConnectionProfile? get defaultProfile =>
      profiles.where((p) => p.isDefault && p.isEnabled).firstOrNull;
  Future<void> addProfile(String name, Map<String, Object?> values) async {
    _validate(name, values);
    final now = DateTime.now();
    profiles.add(
      ConnectionProfile(
        id: 'p${now.microsecondsSinceEpoch}',
        providerId: selectedProviderId ?? '',
        displayName: name.trim(),
        values: values,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await save();
    notifyListeners();
  }

  Future<void> updateProfile(
    String id,
    String name,
    Map<String, Object?> values,
  ) async {
    _validate(name, values);
    final i = profiles.indexWhere((p) => p.id == id);
    if (i < 0) throw StateError('Profile not found');
    final old = profiles[i];
    profiles[i] = ConnectionProfile(
      id: old.id,
      providerId: old.providerId,
      displayName: name.trim(),
      values: values,
      isDefault: old.isDefault,
      isEnabled: old.isEnabled,
      createdAt: old.createdAt,
      updatedAt: DateTime.now(),
      metadata: old.metadata,
    );
    await save();
    notifyListeners();
  }

  Future<void> deleteProfile(String id) async {
    profiles.removeWhere((p) => p.id == id);
    await save();
    notifyListeners();
  }

  Future<void> setDefaultProfile(String id) async {
    for (var i = 0; i < profiles.length; i++) {
      final p = profiles[i];
      profiles[i] = ConnectionProfile(
        id: p.id,
        providerId: p.providerId,
        displayName: p.displayName,
        values: p.values,
        isDefault: p.id == id,
        isEnabled: p.id == id ? true : p.isEnabled,
        createdAt: p.createdAt,
        updatedAt: DateTime.now(),
        metadata: p.metadata,
      );
    }
    await save();
    notifyListeners();
  }

  Future<void> toggleProfile(String id) async {
    final i = profiles.indexWhere((p) => p.id == id);
    final p = profiles[i];
    profiles[i] = ConnectionProfile(
      id: p.id,
      providerId: p.providerId,
      displayName: p.displayName,
      values: p.values,
      isDefault: false,
      isEnabled: !p.isEnabled,
      createdAt: p.createdAt,
      updatedAt: DateTime.now(),
      metadata: p.metadata,
    );
    await save();
    notifyListeners();
  }

  void _validate(String name, Map<String, Object?> values) {
    if (name.trim().isEmpty) throw ArgumentError('Display name is required');
    final provider = catalog.providers
        .where((p) => p.id == selectedProviderId)
        .firstOrNull;
    for (final f in provider?.configurationFields ?? const []) {
      if (f.secret && values.containsKey(f.id)) {
        throw ArgumentError('Secret fields are deferred');
      }
      if (f.required && (values[f.id] == null || values[f.id] == '')) {
        throw ArgumentError('${f.label} is required');
      }
    }
  }

  void legacySelect(String id) {
    selectedProviderId = id;
    notifyListeners();
  }
}
