import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'models.dart';

class LocalStore {
  LocalStore({this._directory});
  final Directory? _directory;
  Future<void> _writes = Future.value();
  Future<Directory> get directory async =>
      _directory ?? await getApplicationSupportDirectory();
  Future<File> get _file async =>
      File('${(await directory).path}${Platform.pathSeparator}sessions.json');
  Future<File> get _uiFile async =>
      File('${(await directory).path}${Platform.pathSeparator}ui-state.json');

  Future<AppUiState> loadUiState() async {
    try {
      final file = await _uiFile;
      if (!await file.exists()) return const AppUiState();
      return AppUiState.fromJson(
        Map<String, Object?>.from(jsonDecode(await file.readAsString()) as Map),
      );
    } catch (_) {
      return const AppUiState();
    }
  }

  Future<void> saveUiState(AppUiState state) async {
    final file = await _uiFile;
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(state.toJson()), flush: true);
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

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

  Future<void> save(List<AgentSession> sessions) {
    final snapshot = List<AgentSession>.from(sessions);
    return _writes = _writes.then((_) => _save(snapshot));
  }

  Future<void> _save(List<AgentSession> sessions) async {
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

class AppUiState {
  const AppUiState({this.sessionId, this.workspacePath, this.page = 0});
  final String? sessionId, workspacePath;
  final int page;

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'workspacePath': workspacePath,
    'page': page,
  };

  factory AppUiState.fromJson(Map<String, Object?> json) => AppUiState(
    sessionId: json['sessionId'] as String?,
    workspacePath: json['workspacePath'] as String?,
    page: (json['page'] as num?)?.toInt() ?? 0,
  );
}
