import 'package:flutter/services.dart';

class ClipboardImage {
  const ClipboardImage({
    required this.path,
    required this.name,
    required this.mimeType,
  });
  final String path, name, mimeType;
}

const _clipboardChannel = MethodChannel('agent_remote/clipboard');

Future<ClipboardImage?> readClipboardImage() async {
  final value = await _clipboardChannel.invokeMapMethod<String, Object?>(
    'getImage',
  );
  if (value == null) return null;
  final path = value['path'] as String? ?? '';
  if (path.isEmpty) return null;
  return ClipboardImage(
    path: path,
    name: value['name'] as String? ?? 'clipboard-image.png',
    mimeType: value['mimeType'] as String? ?? 'image/png',
  );
}
