import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class GatewayCredentials {
  const GatewayCredentials(this.username, this.password);
  final String username, password;
}

class CredentialStore {
  static const _storage = FlutterSecureStorage();
  String _key(String profileId, String field) => 'gateway.$profileId.$field';

  Future<GatewayCredentials?> load(String profileId) async {
    final username = await _storage.read(key: _key(profileId, 'username'));
    final password = await _storage.read(key: _key(profileId, 'password'));
    return username == null || password == null
        ? null
        : GatewayCredentials(username, password);
  }

  Future<void> save(String profileId, GatewayCredentials value) => Future.wait([
    _storage.write(key: _key(profileId, 'username'), value: value.username),
    _storage.write(key: _key(profileId, 'password'), value: value.password),
  ]);
}

class DeviceIdentityStore {
  static const _storage = FlutterSecureStorage();
  static const _key = 'agent_remote.device_id';
  static String? _cached;

  static Future<String> getOrCreate() async {
    if (_cached != null && _cached!.isNotEmpty) return _cached!;
    try {
      final saved = await _storage.read(key: _key);
      if (saved != null && saved.trim().isNotEmpty) {
        _cached = saved.trim();
        return _cached!;
      }
    } catch (_) {}

    final now = DateTime.now().millisecondsSinceEpoch.toRadixString(16);
    final rand = (100000 + (DateTime.now().microsecond * 97) % 900000).toRadixString(16);
    final newId = 'device-$now-$rand';
    _cached = newId;
    try {
      await _storage.write(key: _key, value: newId);
    } catch (_) {}
    return newId;
  }

  static String? get cached => _cached;

  static void setCached(String id) {
    if (id.trim().isNotEmpty) {
      _cached = id.trim();
    }
  }
}
