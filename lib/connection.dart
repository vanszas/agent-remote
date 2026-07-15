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
              (x) => _enum(
                ConnectionCapability.values,
                x,
                ConnectionCapability.sessions,
              ),
            )
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
    this.transportType,
    this.endpoint,
    this.isDefault = false,
    this.isEnabled = true,
    required this.createdAt,
    required this.updatedAt,
    this.lastConnectedAt,
    this.metadata = const {},
    this.schemaVersion = 1,
  });
  final String id, providerId, displayName;
  final RemoteTransportType? transportType;
  final String? endpoint;
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
    'transportType': transportType?.name,
    'endpoint': endpoint,
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
    transportType: j['transportType'] == null
        ? null
        : _enum(
            RemoteTransportType.values,
            j['transportType'],
            RemoteTransportType.unknown,
          ),
    endpoint: j['endpoint'] as String?,
    isDefault: j['isDefault'] as bool? ?? false,
    isEnabled: j['isEnabled'] as bool? ?? true,
    createdAt:
        DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
    updatedAt:
        DateTime.tryParse(j['updatedAt'] as String? ?? '') ?? DateTime.now(),
    lastConnectedAt: DateTime.tryParse(j['lastConnectedAt'] as String? ?? ''),
    metadata: Map<String, Object?>.from(j['metadata'] as Map? ?? {}),
    schemaVersion: j['schemaVersion'] as int? ?? 1,
  );
}

class ConnectionProfileStore {
  ConnectionProfileStore({this._directory});
  final Directory? _directory;
  Future<File> get _file async {
    final d = _directory ?? await getApplicationSupportDirectory();
    return File('${d.path}${Platform.pathSeparator}connection_profiles.json');
  }

  Future<List<ConnectionProfile>> load() async {
    try {
      final f = await _file;
      if (!await f.exists()) return [];
      final j = jsonDecode(await f.readAsString()) as Map;
      return (j['profiles'] as List? ?? [])
          .whereType<Map>()
          .map((x) => ConnectionProfile.fromJson(Map<String, Object?>.from(x)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> save(List<ConnectionProfile> profiles) async {
    final f = await _file;
    await f.parent.create(recursive: true);
    final t = File('${f.path}.tmp');
    await t.writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'profiles': profiles.map((x) => x.toJson()).toList(),
      }),
      flush: true,
    );
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
  ConnectionSettingsController(this.catalog, this.profiles);
  final ConnectionCatalog catalog;
  final List<ConnectionProfile> profiles;
  String? selectedProviderId;
  String get summary => profiles.where((x) => x.isEnabled).isEmpty
      ? 'No connection profile configured'
      : '${profiles.where((x) => x.isEnabled).length} connection profile';
  String get providerSummary =>
      '${catalog.providers.where((x) => x.enabled).length} providers available';
  void select(String id) {
    selectedProviderId = id;
    notifyListeners();
  }
}
