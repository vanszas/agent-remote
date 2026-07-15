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
