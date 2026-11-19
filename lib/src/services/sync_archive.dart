import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

/// Reads and writes only within the Git working tree. The tree is supplied by
/// a remote and can contain symlinks, even in a reserved sync directory.
class SyncArchive {
  SyncArchive(this.root);

  final Directory root;
  static const version = 2;

  Future<File> file(String relative) async {
    final parts = relative.split('/');
    if (parts.any(
      (part) => !_segment.hasMatch(part) || part == '.' || part == '..',
    )) {
      throw const FormatException('同步文件路径无效');
    }
    var path = root.path;
    for (final part in parts) {
      path = p.join(path, part);
      if (await FileSystemEntity.type(path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const FormatException('同步目录包含符号链接');
      }
    }
    return File(path);
  }

  static final _segment = RegExp(r'^[a-zA-Z0-9_.-]+$');

  Future<List<File>> jsonFiles(String relative) async {
    final directory = Directory((await file(relative)).path);
    if (!await directory.exists()) return [];
    return (await directory.list(followLinks: false).toList())
        .whereType<File>()
        .where((entry) => entry.path.endsWith('.json'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
  }

  Future<Map<String, dynamic>> readJson(
    File file, {
    int limit = 1024 * 1024,
  }) async {
    if (await file.length() > limit) {
      throw const FormatException('同步元数据文件超过大小限制');
    }
    return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  }

  Future<void> writeJson(String relative, Map<String, Object?> value) =>
      writeText(
        relative,
        '${const JsonEncoder.withIndent('  ').convert(value)}\n',
      );

  Future<void> writeText(String relative, String value) async {
    final target = await file(relative);
    if (await target.exists() &&
        await target.length() == utf8.encode(value).length &&
        await target.readAsString() == value) {
      return;
    }
    await _replace(
      target,
      (temporary) => temporary.writeAsString(value, flush: true),
    );
  }

  Future<void> writeBytes(String relative, List<int> value) async {
    final target = await file(relative);
    if (await target.exists() &&
        await target.length() == value.length &&
        _sameBytes(await target.readAsBytes(), value)) {
      return;
    }
    await _replace(
      target,
      (temporary) => temporary.writeAsBytes(value, flush: true),
    );
  }

  Future<void> copy(String relative, File source) async {
    final target = await file(relative);
    final length = await source.length();
    if (await target.exists() &&
        await target.length() == length &&
        await _sameFile(target, source)) {
      return;
    }
    await _replace(target, (temporary) => source.copy(temporary.path));
  }

  Future<void> remove(String relative) async {
    final target = await file(relative);
    if (await target.exists()) await target.delete();
  }

  Future<void> _replace(File target, Future<File> Function(File) write) async {
    await target.parent.create(recursive: true);
    // Keep staging files outside the tracked worktree, including after a crash.
    final gitDirectory = Directory((await file('.git')).path);
    final temporary = File(
      p.join(
        await gitDirectory.exists() ? gitDirectory.path : target.parent.path,
        'idreaml-write-${const Uuid().v4()}.tmp',
      ),
    );
    try {
      await write(temporary);
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static Future<bool> _sameFile(File a, File b) async {
    final first = await a.open();
    try {
      final second = await b.open();
      try {
        while (true) {
          final chunk = await first.read(64 * 1024);
          if (chunk.isEmpty) return true;
          final other = await second.read(chunk.length);
          if (chunk.length != other.length || !_sameBytes(chunk, other)) {
            return false;
          }
        }
      } finally {
        await second.close();
      }
    } finally {
      await first.close();
    }
  }
}
