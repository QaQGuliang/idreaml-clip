import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ffi/ffi.dart';
import 'package:idreaml_clip/src/app_controller.dart';
import 'package:idreaml_clip/src/data/clipboard_database.dart';
import 'package:idreaml_clip/src/data/clipboard_repository.dart';
import 'package:idreaml_clip/src/data/data_storage.dart';
import 'package:idreaml_clip/src/data/image_store.dart';
import 'package:idreaml_clip/src/data/storage_access.dart';
import 'package:idreaml_clip/src/models/clipboard_content.dart';
import 'package:idreaml_clip/src/models/sync_models.dart';
import 'package:idreaml_clip/src/services/credential_service.dart';
import 'package:idreaml_clip/src/services/embedded_git_service.dart';
import 'package:idreaml_clip/src/services/sync_service.dart';
import 'package:idreaml_clip/src/services/sync_format_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:win32/win32.dart' as win32;

class _Git extends EmbeddedGitService {
  Directory? directory;
  final started = Completer<void>();
  final finish = Completer<void>();
  @override
  Future<T> synchronize<T>({
    required Directory directory,
    required SyncConfig config,
    required String token,
    required Future<T> Function() reconcile,
  }) async {
    this.directory = directory;
    await directory.create(recursive: true);
    started.complete();
    await finish.future;
    return reconcile();
  }
}

class _Token implements CredentialStore {
  @override
  Future<String?> readToken() async => 'test-token';
  @override
  Future<void> writeToken(String token) async {}
  @override
  Future<void> deleteToken() async {}
}

void main() {
  late Directory sandbox;
  late Directory install;
  late Directory support;
  late DataStorage storage;
  late ClipboardDatabase database;
  late ClipboardRepository repository;
  final picture = ClipboardContent.image(
    Uint8List.fromList([1, 2, 3, 4]),
    'image/png',
  );

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('idreaml-storage-');
    install = Directory(p.join(sandbox.path, '安装 目录'));
    support = Directory(p.join(sandbox.path, 'support'));
    storage = DataStorage(
      installationDirectory: install,
      supportDirectory: support,
    );
    await storage.initialize();
    database = ClipboardDatabase.withFactory(
      databaseFactoryFfi,
      storage: storage,
    );
    await database.open();
    repository = ClipboardRepository(database);
    await repository.initializeDevice();
  });
  tearDown(() async {
    await database.close();
    await sandbox.delete(recursive: true);
  });

  test('列表仅读取图片引用，迁移后从当前目录复制，丢失的图片不阻塞列表', () async {
    final saved = (await repository.capture(picture))!;
    final before = (await repository.list(loadImages: false)).single;
    expect(before.imagePath, isNotNull);
    expect(before.content, startsWith(ImageStore.prefix));
    await repository.moveStorage(p.join(sandbox.path, 'moved-images'));
    expect(
      (await repository.readPayload(before)).imageBytes,
      picture.imageBytes,
    );
    final after = (await repository.list(loadImages: false)).single;
    expect(after.imagePath, isNot(before.imagePath));
    await File(after.imagePath!).delete();
    expect((await repository.list(loadImages: false)).single.id, before.id);
    await expectLater(
      repository.readPayload(after),
      throwsA(isA<FileSystemException>()),
    );
    await repository.mergeSyncData(
      records: [SyncRecord.fromItem(saved)],
      tombstones: [],
    );
    expect(
      (await repository.readPayload(after)).imageBytes,
      picture.imageBytes,
    );
  });

  test('只读 Git 对象可迁移并清理旧目录，无需管理员权限', () async {
    final object = File(
      p.join(storage.sync.path, 'repo', '.git', 'objects', 'ab', 'object'),
    );
    await object.parent.create(recursive: true);
    await object.writeAsString('readonly git object');
    void readOnly(File file, bool enabled) => using((arena) {
      final name = file.path.toNativeUtf16(allocator: arena);
      final attributes = win32.GetFileAttributes(name);
      final updated = enabled
          ? attributes | win32.FILE_ATTRIBUTE_READONLY
          : attributes & ~win32.FILE_ATTRIBUTE_READONLY;
      if (win32.SetFileAttributes(name, updated) == 0) {
        throw win32.WindowsException(win32.GetLastError());
      }
    });
    readOnly(object, true);
    final old = storage.root.path;
    final destination = p.join(sandbox.path, 'readonly-move');
    try {
      final result = await repository.moveStorage(destination);
      expect(result.warning, isNull);
      expect(Directory(old).existsSync(), isFalse);
      expect(
        await File(
          p.join(storage.sync.path, 'repo', '.git', 'objects', 'ab', 'object'),
        ).readAsString(),
        'readonly git object',
      );
    } finally {
      await for (final entity in sandbox.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) readOnly(entity, false);
      }
    }
  }, skip: !Platform.isWindows);

  test('统一目录分类存储，迁移所有内容并删除旧目录，重启保留配置和历史', () async {
    expect(storage.root.path, p.join(install.path, 'data', 'idreaml_clip'));
    final item = (await repository.captureText('文字与收藏'))!;
    await repository.toggleFavorite(item.id);
    await repository.captureScreenshot('receipt', picture);
    await repository.setSetting('quick_count', '50');
    expect(File(storage.settingsPath).existsSync(), isTrue);
    expect(await database.database.query('app_setting'), isEmpty);
    final imageRow = (await database.database.query(
      'clipboard_item',
      where: "type = 'image/png'",
    )).single;
    expect(imageRow['content'], startsWith(ImageStore.prefix));
    expect(
      await File(p.join(storage.images.path, '${picture.hash}.png'))
          .readAsBytes(),
      picture.imageBytes,
    );
    await File(p.join(storage.credentials.path, 'encrypted'))
        .writeAsBytes([8, 9]);
    await File(p.join(storage.sync.path, 'state')).writeAsString('sync-cache');
    // Flutter's runtime assets are siblings and must survive migration.
    final runtime = File(p.join(install.path, 'data', 'icudtl.dat'));
    await runtime.writeAsString('runtime');
    final old = storage.root;
    final destination = p.join(sandbox.path, '新 数据');
    final result = await repository.moveStorage(destination);
    expect(result.warning, isNull);
    expect(old.existsSync(), isFalse);
    expect(await runtime.readAsString(), 'runtime');
    expect(await repository.getSetting('quick_count'), '50');
    expect((await repository.list(favoritesOnly: true)).single.id, item.id);
    expect(
      (await repository.list(query: '图片')).single.payload.imageBytes,
      picture.imageBytes,
    );
    expect(
      await File(p.join(storage.credentials.path, 'encrypted')).readAsBytes(),
      [8, 9],
    );
    expect(
      await File(p.join(storage.sync.path, 'state')).readAsString(),
      'sync-cache',
    );
    await repository.captureScreenshot('receipt', picture);
    expect((await repository.list(query: '图片')).single.copyCount, 1);
    await repository.captureText('迁移后仍可写入');
    await database.close();
    storage = DataStorage(
      installationDirectory: install,
      supportDirectory: support,
    );
    await storage.initialize();
    expect(storage.root.path, destination);
    database = ClipboardDatabase.withFactory(
      databaseFactoryFfi,
      storage: storage,
    );
    await database.open();
    repository = ClipboardRepository(database);
    await repository.initializeDevice();
    expect(await repository.getSetting('quick_count'), '50');
    expect(await repository.list(), hasLength(3));
    // Replacing an existing bootstrap locator must also work on Windows.
    await repository.moveStorage(p.join(sandbox.path, '第三个目录'));
    expect(Directory(destination).existsSync(), isFalse);
    expect(await repository.list(), hasLength(3));
  });

  test('同目录不关闭数据库，拒绝相互包含、非空、文件及相对路径', () async {
    final old = storage.root.path;
    var closes = 0;
    await storage.moveTo(
      p.join(old, '.'),
      close: () async {
        closes++;
      },
      open: () async {},
    );
    expect(closes, 0);
    final occupied = await Directory(p.join(sandbox.path, 'occupied')).create();
    final file = await File(p.join(occupied.path, 'keep')).writeAsString('保留');
    for (final candidate in [
      '',
      'relative/path',
      p.join(old, 'child'),
      p.dirname(old),
      occupied.path,
      file.path,
      p.rootPrefix(old),
    ]) {
      await expectLater(
        repository.moveStorage(candidate),
        throwsA(isA<StorageException>()),
      );
    }
    expect(await file.readAsString(), '保留');
    expect(storage.root.path, old);
    await repository.captureText('still writable');
  });

  test('新目录打开失败回退原数据库，原数据及配置完整保留', () async {
    await repository.captureText('不能丢失');
    final old = storage.root.path;
    final destination = p.join(sandbox.path, 'failed');
    await expectLater(
      storage.moveTo(
        destination,
        close: database.close,
        open: () async {
          if (storage.root.path == destination) {
            throw const FileSystemException('simulated open failure');
          }
          await database.open();
        },
      ),
      throwsA(isA<StorageException>()),
    );
    expect(storage.root.path, old);
    expect((await repository.list()).single.content, '不能丢失');
    expect(Directory(destination).existsSync(), isFalse);
    await repository.captureText('失败后继续写入');
  });

  test('位置配置提交失败保留原目录且可继续写入', () async {
    await repository.captureText('locator failure');
    await support.create(recursive: true);
    await Directory(p.join(support.path, 'storage-location.json')).create();
    final old = storage.root.path;
    final destination = p.join(sandbox.path, 'cannot-commit');
    await expectLater(
      repository.moveStorage(destination),
      throwsA(isA<StorageException>()),
    );
    expect(storage.root.path, old);
    expect(Directory(old).existsSync(), isTrue);
    expect(Directory(destination).existsSync(), isFalse);
    expect((await repository.list()).single.content, 'locator failure');
    await repository.setSetting('test', 'still writable');
  });

  test('复制期间目标目录新增文件时拒绝覆盖', () async {
    await repository.captureText('source');
    final old = storage.root.path;
    final target = Directory(p.join(sandbox.path, 'occupied-later'));
    final other = File(p.join(target.path, 'other.txt'));
    await expectLater(
      storage.moveTo(
        target.path,
        close: () async {
          await database.close();
          await target.create(recursive: true);
          await other.writeAsString('must survive');
        },
        open: () => database.open(),
      ),
      throwsA(isA<StorageException>()),
    );
    expect(await other.readAsString(), 'must survive');
    expect(storage.root.path, old);
    expect((await repository.list()).single.content, 'source');
  });

  test('提交后清理失败保留恢复记录，重启后继续清理旧目录', () async {
    await repository.captureText('committed');
    final old = storage.root.path;
    final marker = File(p.join(old, DataStorage.markerName));
    final identity = await marker.readAsString();
    final destination = p.join(sandbox.path, 'committed-copy');
    final result = await storage.moveTo(
      destination,
      close: database.close,
      open: () async {
        await database.open();
        // Simulate an old directory that cannot be safely removed this run.
        await marker.writeAsString('temporarily-unavailable');
      },
    );
    expect(result.warning, contains('旧目录清理尚未完成'));
    expect(storage.root.path, destination);
    expect(Directory(old).existsSync(), isTrue);
    await repository.captureText('new writes');
    await marker.writeAsString(identity);
    await database.close();
    storage = DataStorage(
      installationDirectory: install,
      supportDirectory: support,
    );
    await storage.initialize();
    database = ClipboardDatabase.withFactory(
      databaseFactoryFfi,
      storage: storage,
    );
    await database.open();
    expect(await storage.cleanupPreviousDirectory(), isNull);
    expect(Directory(old).existsSync(), isFalse);
    repository = ClipboardRepository(database);
    expect(await repository.list(), hasLength(2));
  });

  test('迁移等待当前操作结束，新到达的读取和写入使用新目录', () async {
    final entered = Completer<void>();
    final finish = Completer<void>();
    final active = repository.access(() async {
      entered.complete();
      await finish.future;
      await repository.captureText('迁移前完成');
    });
    await entered.future;
    final destination = p.join(sandbox.path, 'queued');
    final moving = repository.moveStorage(destination);
    var readFinished = false;
    final read = repository.list().then((items) {
      readFinished = true;
      return items;
    });
    final write = repository.captureText('迁移后完成');
    await Future<void>.delayed(Duration.zero);
    expect(readFinished, isFalse);
    finish.complete();
    await active;
    await moving;
    await write;
    await read;
    expect(storage.root.path, destination);
    expect(await repository.list(), hasLength(2));
  });

  test('升级旧版内联图片和设置，迁移旧同步和凭证目录', () async {
    await database.close();
    final legacy = Directory(p.join(support.path, 'idreaml_clip'));
    final legacyPath = p.join(legacy.path, 'database', 'clipboard.db');
    await Directory(p.dirname(legacyPath)).create(recursive: true);
    database = ClipboardDatabase.withFactory(databaseFactoryFfi);
    await database.open(path: legacyPath);
    repository = ClipboardRepository(database);
    await repository.initializeDevice();
    final originalId = repository.deviceId;
    await repository.captureText('旧版文字');
    await repository.capture(picture);
    await repository.setSetting('quick_count', '40');
    await database.close();
    // The default test database is empty and only exists as fixture setup.
    await storage.root.delete(recursive: true);
    storage = DataStorage(
      installationDirectory: install,
      supportDirectory: support,
    );
    await storage.initialize();
    expect(storage.needsLegacyMigration, isTrue);
    database = ClipboardDatabase.withFactory(
      databaseFactoryFfi,
      storage: storage,
    );
    await database.open();
    repository = ClipboardRepository(database);
    await repository.initializeDevice();
    expect(repository.deviceId, originalId);
    expect(await repository.getSetting('quick_count'), '40');
    expect(
      (await repository.list(query: '图片')).single.content,
      picture.content,
    );
    await repository.moveStorage(storage.defaultPath);
    expect(legacy.existsSync(), isFalse);
    expect(await repository.list(), hasLength(2));
  });

  test('同步刷新与排队的列表查询能完成，迁移后使用新目录', () async {
    final git = _Git();
    final sync = SyncService(repository, _Token(), git: git);
    final controller = AppController(repository, sync);
    addTearDown(controller.dispose);
    await repository.captureText('同步记录');
    await sync.saveConfig(
      const SyncConfig(
        provider: SyncProvider.custom,
        remoteUrl: 'https://example.com/repo.git',
        username: 'test',
        branch: 'main',
      ),
    );
    final syncing = sync.syncNow();
    await git.started.future;
    final old = storage.root.path;
    final destination = p.join(sandbox.path, 'after-sync');
    final moving = controller.changeStoragePath(destination);
    await Future<void>.delayed(Duration.zero);
    final history = controller.setHistorySearch('同步');
    final quick = controller.setQuickSearch('同步');
    expect(storage.root.path, old);
    expect(p.isWithin(storage.sync.path, git.directory!.path), isTrue);
    git.finish.complete();
    expect(await syncing.timeout(const Duration(seconds: 5)), isNotNull);
    await Future.wait<void>([moving.then((_) {}), history, quick])
        .timeout(const Duration(seconds: 5));
    expect(controller.history.single.content, '同步记录');
    expect(controller.quickItems.single.content, '同步记录');
    final nextGit = _Git()..finish.complete();
    final nextSync = SyncService(repository, _Token(), git: nextGit);
    addTearDown(nextSync.dispose);
    await nextSync.initialize();
    await nextSync.syncNow();
    expect(p.isWithin(storage.sync.path, nextGit.directory!.path), isTrue);
    expect(p.isWithin(destination, nextGit.directory!.path), isTrue);
  });

  test('迁移保留 DPAPI 令牌并在新目录继续读写', () async {
    final credentials = SecureCredentialService(storage: storage);
    await credentials.writeToken('original-token');
    await repository.moveStorage(p.join(sandbox.path, 'encrypted-data'));
    expect(await credentials.readToken(), 'original-token');
    await credentials.writeToken('next-token');
    expect(await credentials.readToken(), 'next-token');
    await credentials.deleteToken();
    expect(await credentials.readToken(), isNull);
  }, skip: !Platform.isWindows);

  test('不可访问的已配置路径不被静默重建为空历史', () async {
    await storage.rememberLocation();
    final path = storage.root.path;
    await database.close();
    await storage.root.rename('$path.offline');
    final restarted = DataStorage(
      installationDirectory: install,
      supportDirectory: support,
    );
    await expectLater(restarted.initialize(), throwsA(isA<StorageException>()));
    expect(Directory(path).existsSync(), isFalse);
    final saved = jsonDecode(
      await File(p.join(support.path, 'storage-location.json')).readAsString(),
    ) as Map;
    expect(saved['path'], path);
  });

  test('管理员重启使用原定位文件，保持数据目录与设置不变', () async {
    await repository.captureText('重启前历史');
    await storage.rememberLocation();
    final restarted = DataStorage(
      installationDirectory: Directory(p.join(sandbox.path, 'other-install')),
      supportDirectory: Directory(p.join(sandbox.path, 'other-user-support')),
    );
    await restarted.initialize(locatorPath: storage.locatorPath);
    expect(restarted.root.path, storage.root.path);
    expect(restarted.locatorPath, storage.locatorPath);
    expect(
      Directory(p.join(sandbox.path, 'other-user-support')).existsSync(),
      isFalse,
    );
  });

  test('存储锁允许并发读取和嵌套调用，并在异常后释放', () async {
    final access = StorageAccess();
    final started = Completer<void>();
    final second = Completer<void>();
    await Future.wait([
      access.run(() async {
        started.complete();
        await second.future;
        await access.run(() async {});
      }),
      access.run(() async {
        await started.future;
        second.complete();
      }),
    ]);
    await expectLater(
      access.exclusive(() async {
        throw StateError('test');
      }),
      throwsStateError,
    );
    expect(await access.run(() async => 42), 42);
  });

  test('外置图片同步导出原始内容，在另一数据目录导入后仍可复制', () async {
    await repository.capture(picture);
    final export = Directory(p.join(sandbox.path, 'sync-export'));
    final format = SyncFormatService();
    await format.exportDevice(
      repository: export,
      deviceId: repository.deviceId,
      deviceName: 'Test',
      items: await repository.listForSync(loadImages: false),
    );
    final imported = await format.readAll(export);
    expect(imported.records.single.content, picture.content);
    final otherStorage = DataStorage(
      installationDirectory: Directory(p.join(sandbox.path, 'second-install')),
      supportDirectory: Directory(p.join(sandbox.path, 'second-support')),
    );
    await otherStorage.initialize();
    final otherDb = ClipboardDatabase.withFactory(
      databaseFactoryFfi,
      storage: otherStorage,
    );
    await otherDb.open();
    try {
      final other = ClipboardRepository(otherDb);
      await other.initializeDevice();
      await other.mergeSyncData(
        records: imported.records,
        tombstones: imported.tombstones,
      );
      expect(
        (await other.list()).single.payload.imageBytes,
        picture.imageBytes,
      );
      expect(
        (await otherDb.database.query('clipboard_item')).single['content'],
        startsWith(ImageStore.prefix),
      );
      expect(otherStorage.images.listSync().whereType<File>(), hasLength(1));
    } finally {
      await otherDb.close();
    }
  });
}
