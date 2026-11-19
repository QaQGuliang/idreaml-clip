import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/clipboard_content.dart';
import 'data_storage.dart';

class ImageStore {
  ImageStore(this.storage);
  final DataStorage storage;
  static const prefix = '@idreaml-image/';

  Future<String> persist(ClipboardContent content, {String? hash}) async {
    if (!content.isImage) return content.content;
    return _persist(
      content.type,
      hash ?? content.hash,
      (file) => file.writeAsBytes(content.imageBytes, flush: true),
    );
  }

  Future<String> persistFile(File source, String type, String hash) =>
      _persist(type, hash, (file) => source.copy(file.path));

  Future<String> _persist(
    String type,
    String hash,
    Future<File> Function(File) write,
  ) async {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
      throw const FormatException('图片内容标识无效');
    }
    final extension = switch (type) {
      'image/png' => 'png',
      'image/jpeg' => 'jpg',
      'image/gif' => 'gif',
      'image/webp' => 'webp',
      'image/bmp' => 'bmp',
      _ => 'bin',
    };
    final name = '$hash.$extension';
    final file = File(p.join(storage.images.path, name));
    if (!await file.exists()) {
      final temporary = File('${file.path}.${const Uuid().v4()}.tmp');
      try {
        await write(temporary);
        await temporary.rename(file.path);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    }
    return '$prefix$name';
  }

  File? fileFor(String type, String value) {
    if (!type.startsWith('image/') || !value.startsWith(prefix)) return null;
    final name = value.substring(prefix.length);
    if (!RegExp(r'^[a-f0-9]{64}\.(png|jpg|gif|webp|bmp|bin)$').hasMatch(name)) {
      throw const FormatException('图片存储路径无效');
    }
    return File(p.join(storage.images.path, name));
  }

  Future<Map<String, Object?>> hydrate(Map<String, Object?> row) async {
    final file = fileFor(row['type'] as String, row['content'] as String);
    if (file == null) return row;
    return {...row, 'content': base64Encode(await file.readAsBytes())};
  }
}
