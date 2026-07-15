import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'models.dart';

class LocalStore {
  LocalStore({this._directory});
  final Directory? _directory;
  Future<Directory> get directory async =>
      _directory ?? await getApplicationSupportDirectory();
  Future<File> get _file async =>
      File('${(await directory).path}${Platform.pathSeparator}sessions.json');
  Future<List<AgentSession>> load() async {
    final f = await _file;
    try {
      if (!await f.exists()) return [];
      final root = jsonDecode(await f.readAsString()) as Map;
      return (root['sessions'] as List? ?? [])
          .whereType<Map>()
          .map((e) => AgentSession.fromJson(Map<String, Object?>.from(e)))
          .toList();
    } catch (_) {
      final backup = File('${f.path}.bak');
      if (!await backup.exists()) return [];
      try {
        final root = jsonDecode(await backup.readAsString()) as Map;
        return (root['sessions'] as List? ?? [])
            .whereType<Map>()
            .map((e) => AgentSession.fromJson(Map<String, Object?>.from(e)))
            .toList();
      } catch (_) {
        return [];
      }
    }
  }

  Future<void> save(List<AgentSession> sessions) async {
    final f = await _file;
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp'), bak = File('${f.path}.bak');
    await tmp.writeAsString(
      jsonEncode({
        'schemaVersion': appSchemaVersion,
        'sessions': sessions.map((e) => e.toJson()).toList(),
      }),
      flush: true,
    );
    if (await f.exists()) {
      if (await bak.exists()) await bak.delete();
      await f.copy(bak.path);
    }
    try {
      if (await f.exists()) await f.delete();
      await tmp.rename(f.path);
    } catch (_) {
      if (!await f.exists() && await bak.exists()) await bak.copy(f.path);
      rethrow;
    }
  }

  Future<File> importAttachment({
    required String sessionId,
    required String sourcePath,
    required String generatedId,
  }) async {
    final source = File(sourcePath);
    final size = await source.length();
    final error = validateAttachmentSize(size);
    if (error != null) throw ArgumentError(error);
    final dir = Directory(
      '${(await directory).path}${Platform.pathSeparator}attachments${Platform.pathSeparator}$sessionId',
    );
    await dir.create(recursive: true);
    return source.copy(
      '${dir.path}${Platform.pathSeparator}${generatedId}_${sanitizeFilename(source.uri.pathSegments.last)}',
    );
  }
}
