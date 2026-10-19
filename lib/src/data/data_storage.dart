import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'storage_access.dart';
import 'managed_file_cleanup.dart';

class StorageException implements Exception {
  const StorageException(this.message);
  final String message;
  @override
  String toString() => message;
}

class StorageMoveResult {
  const StorageMoveResult({this.warning});
  final String? warning;
}

/// Only the bootstrap locator lives outside the managed directory. It contains
/// a path, never application settings, clipboard content or credentials.
class DataStorage {
  DataStorage({this.installationDirectory, this.supportDirectory});

  final Directory? installationDirectory;
  final Directory? supportDirectory;
  final access = StorageAccess();
  late Directory root;
  late String defaultPath;
  late File _locator;
  Map<String, String>? _pendingCleanup;
  static const markerName = '.idreaml-clip-data';
  bool needsLegacyMigration = false;

  String get databasePath => p.join(root.path, 'database', 'clipboard.db');
  String get locatorPath => _locator.path;
  String get settingsPath => p.join(root.path, 'config', 'settings.db');
  Directory get images => Directory(p.join(root.path, 'images'));
  Directory get credentials => Directory(p.join(root.path, 'credentials'));
  Directory get sync => Directory(p.join(root.path, 'sync'));

  Future<void> initialize({String? initialPath, String? locatorPath}) async {
    final support = supportDirectory ?? await getApplicationSupportDirectory();
    var installation =
        installationDirectory ?? File(Platform.resolvedExecutable).parent;
    if (installationDirectory == null &&
        Platform.isMacOS &&
        p.basename(installation.path) == 'MacOS') {
      // Keep mutable data outside the signed .app bundle.
      installation = installation.parent.parent.parent;
    }
    // Flutter already owns installation/data; use a dedicated child so moving
    // user data can never remove flutter_assets or icudtl.dat.
    defaultPath = p.join(installation.path, 'data', 'idreaml_clip');
    if (locatorPath != null && !p.isAbsolute(locatorPath)) {
      throw const StorageException('数据目录定位文件必须使用完整路径。');
    }
    _locator = File(
      locatorPath ?? p.join(support.path, 'storage-location.json'),
    );
    if (locatorPath != null && !await _locator.exists()) {
      throw const StorageException('无法找到重启前的数据目录配置，已停止启动以避免创建空历史。');
    }
    if (await _locator.exists()) {
      if (initialPath != null) {
        throw const StorageException('已有数据目录配置，请先恢复原目录的连接和访问权限，再启动应用迁移数据。');
      }
      try {
        final saved = jsonDecode(await _locator.readAsString()) as Map;
        root = Directory(saved['path'] as String);
        if (!p.isAbsolute(root.path) ||
            !await File(p.join(root.path, markerName)).exists() ||
            !await File(databasePath).exists() ||
            !await File(settingsPath).exists()) {
          throw const FormatException();
        }
        root = Directory(await _canonical(root.path));
        if (saved['cleanup'] != null) {
          _pendingCleanup = Map<String, String>.from(saved['cleanup'] as Map);
        }
      } catch (_) {
        throw const StorageException('无法访问已设置的数据目录，请检查磁盘连接和目录权限后重试。');
      }
    } else {
      final legacy = Directory(p.join(support.path, 'idreaml_clip'));
      needsLegacyMigration =
          await legacy.exists() && !samePath(legacy.path, defaultPath);
      root = Directory(
        await _canonical(needsLegacyMigration ? legacy.path : defaultPath),
      );
      if (initialPath != null) {
        if (needsLegacyMigration || await File(databasePath).exists()) {
          throw const StorageException('检测到已有数据，请先恢复原目录的访问权限，再在设置中迁移数据。');
        }
        root = Directory(await validateDestination(initialPath));
      }
    }
    await prepare();
  }

  Future<void> rememberLocation() => _saveLocation(root.path);

  /// The committed locator retains cleanup work across an interrupted exit.
  /// Call only after the destination databases have opened successfully.
  Future<String?> cleanupPreviousDirectory() async {
    final pending = _pendingCleanup;
    if (pending == null) return null;
    final old = Directory(pending['path']!);
    try {
      final source = await _canonical(old.path);
      if (!p.isAbsolute(old.path) ||
          samePath(source, root.path) ||
          _contains(source, root.path) ||
          _contains(root.path, source) ||
          pending['identity'] !=
              await File(p.join(root.path, markerName)).readAsString()) {
        throw const StorageException('旧目录身份校验失败。');
      }
      if (await old.exists()) await _removeOwned(old, pending['identity']!);
      _pendingCleanup = null;
      await _saveLocation(root.path);
      return null;
    } catch (_) {
      _pendingCleanup = pending;
      return '新目录已生效，但旧目录清理尚未完成：${old.path}。解除文件占用后重启应用将自动重试。';
    }
  }

  Future<void> prepare() async {
    for (final name in [
      'database',
      'config',
      'images',
      'credentials',
      'sync',
    ]) {
      await Directory(p.join(root.path, name)).create(recursive: true);
    }
    final marker = File(p.join(root.path, markerName));
    if (!await marker.exists()) {
      await marker.writeAsString(const Uuid().v4(), flush: true);
    }
  }

  bool samePath(String first, String second) {
    String normalize(String value) {
      final normalized = p.normalize(p.absolute(value));
      return Platform.isWindows ? normalized.toLowerCase() : normalized;
    }

    return normalize(first) == normalize(second);
  }

  bool _contains(String parent, String child) => p.isWithin(
    Platform.isWindows ? parent.toLowerCase() : parent,
    Platform.isWindows ? child.toLowerCase() : child,
  );

  Future<String> validateDestination(String input) async {
    final value = input.trim();
    if (value.isEmpty || !p.isAbsolute(value)) {
      throw const StorageException('请输入完整的绝对目录路径。');
    }
    final destination = await _canonical(value);
    final source = await _canonical(root.path);
    if (samePath(source, destination)) return source;
    if (samePath(destination, p.dirname(destination)) ||
        _contains(source, destination) ||
        _contains(destination, source) ||
        _contains(destination, _locator.path)) {
      throw const StorageException('新旧目录不能互相包含，请选择独立的数据目录。');
    }
    final type = await FileSystemEntity.type(destination, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      throw const StorageException('目标路径不是文件夹。');
    }
    if (type == FileSystemEntityType.directory &&
        !await Directory(destination).list().isEmpty) {
      throw const StorageException('目标目录必须为空，以免覆盖已有文件。请新建一个专用文件夹。');
    }
    return destination;
  }

  /// Resolves existing ancestors too, detecting containment through symlinks.
  Future<String> _canonical(String value) async {
    var current = p.normalize(p.absolute(value));
    final missing = <String>[];
    while (await FileSystemEntity.type(current, followLinks: false) ==
        FileSystemEntityType.notFound) {
      missing.insert(0, p.basename(current));
      final parent = p.dirname(current);
      if (parent == current) break;
      current = parent;
    }
    final resolved = await Directory(current).resolveSymbolicLinks();
    return p.normalize(p.joinAll([resolved, ...missing]));
  }

  Future<void> _saveLocation(String value) async {
    await _locator.parent.create(recursive: true);
    final temporary = File('${_locator.path}.${const Uuid().v4()}.tmp');
    try {
      await temporary.writeAsString(
        jsonEncode({
          'version': 1,
          'path': value,
          if (_pendingCleanup != null) 'cleanup': _pendingCleanup,
        }),
        flush: true,
      );
      await temporary.rename(_locator.path);
    } finally {
      // Once rename commits, a temporary-file cleanup error must not roll back
      // the data directory while the locator already points to the new copy.
      try {
        if (await temporary.exists()) await temporary.delete();
      } catch (_) {
        /* Never invalidate an already committed locator. */
      }
    }
  }

  Future<StorageMoveResult> moveTo(
    String input, {
    required Future<void> Function() close,
    required Future<void> Function() open,
  }) => access.exclusive(() async {
    final cleanupWarning = await cleanupPreviousDirectory();
    if (cleanupWarning != null) throw StorageException(cleanupWarning);
    final destination = await validateDestination(input);
    if (samePath(root.path, destination)) return const StorageMoveResult();
    final source = root;
    final identity = await File(p.join(source.path, markerName)).readAsString();
    final target = Directory(destination);
    final staging = Directory(
      p.join(p.dirname(destination), '.idreaml-migration-${const Uuid().v4()}'),
    );
    var installed = false;
    var closed = false;
    try {
      await close();
      closed = true;
      await staging.create(recursive: true);
      await _copyVerified(source, staging);
      // Revalidate after copying: never replace a directory populated meanwhile.
      await validateDestination(destination);
      if (await target.exists()) await target.delete(); // empty only
      await staging.rename(destination);
      installed = true;
      root = target;
      await open();
      _pendingCleanup = {'path': source.path, 'identity': identity};
      await _saveLocation(destination); // commit before touching the old data
    } catch (error) {
      _pendingCleanup = null;
      if (closed) {
        await close();
        root = source;
        await open();
      }
      // Only remove copies created by this attempt; the source stays intact.
      try {
        if (installed) await _removeOwned(target, identity);
        if (await staging.exists()) await _removeStaging(staging);
      } catch (_) {
        /* A leftover copy is safer than deleting unknown content. */
      }
      if (error is StorageException) rethrow;
      if (error is FileSystemException) {
        final code = error.osError?.errorCode;
        final detail = error.osError?.message ?? error.message;
        throw StorageException(
          '迁移失败，已保留原目录。\n原因：$detail${code == null ? '' : '（错误码 $code）'}'
          '${error.path == null ? '' : '\n文件：${error.path}'}',
        );
      }
      throw const StorageException('迁移失败，已保留原目录。请检查可用空间和目录读写权限后重试。');
    }
    needsLegacyMigration = false;
    return StorageMoveResult(warning: await cleanupPreviousDirectory());
  });

  Future<void> _copyVerified(Directory source, Directory target) async {
    await for (final entity in source.list(followLinks: false)) {
      final path = p.join(target.path, p.basename(entity.path));
      if (entity is Directory) {
        final directory = await Directory(path).create();
        await _copyVerified(entity, directory);
      } else if (entity is File) {
        // Copy bytes into a new writable file. File.copy also copies Windows'
        // read-only flag, which prevents opening copied Git objects to flush.
        final copied = File(path);
        final handle = await copied.open(mode: FileMode.write);
        try {
          await for (final bytes in entity.openRead()) {
            await handle.writeFrom(bytes);
          }
          await handle.flush();
        } finally {
          await handle.close();
        }
        final before = await sha256.bind(entity.openRead()).first;
        final after = await sha256.bind(copied.openRead()).first;
        if (before != after) throw const StorageException('文件校验失败，原数据已保留。');
      } else {
        throw const StorageException('数据目录中存在符号链接，无法安全迁移。请先移除链接后重试。');
      }
    }
  }

  Future<void> _removeOwned(Directory directory, String identity) async {
    final resolved = await directory.resolveSymbolicLinks();
    if (!samePath(resolved, directory.path)) {
      throw const StorageException('目录身份发生变化，已停止清理。');
    }
    final marker = File(p.join(directory.path, markerName));
    if (!await marker.exists() && await directory.list().isEmpty) {
      // Recovery after a crash between deleting the marker and empty folder.
      await directory.delete();
      return;
    }
    if (await marker.readAsString() != identity) {
      throw const StorageException('目录身份发生变化，已停止清理。');
    }
    // Keep the ownership marker until last so partial cleanup is resumable.
    await for (final entry in directory.list(followLinks: false)) {
      if (p.basename(entry.path) != markerName) {
        await removeManagedEntity(entry);
      }
    }
    await marker.delete();
    await directory.delete();
  }

  Future<void> _removeStaging(Directory directory) async {
    if (!p.basename(directory.path).startsWith('.idreaml-migration-') ||
        !samePath(await directory.resolveSymbolicLinks(), directory.path)) {
      throw const StorageException('临时目录身份发生变化。');
    }
    await removeManagedEntity(directory);
  }
}
