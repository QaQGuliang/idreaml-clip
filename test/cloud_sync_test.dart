import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:idreaml_clip/src/models/clipboard_content.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:git2dart/git2dart.dart';
import 'package:idreaml_clip/src/data/clipboard_database.dart';
import 'package:idreaml_clip/src/data/clipboard_repository.dart';
import 'package:idreaml_clip/src/models/sync_models.dart';
import 'package:idreaml_clip/src/services/embedded_git_service.dart';
import 'package:idreaml_clip/src/services/credential_service.dart';
import 'package:idreaml_clip/src/services/sync_format_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('图片同步保留格式和内容，大量记录分文件且清理过期分片', () async {
    final root = await Directory.systemTemp.createTemp('idreaml-image-sync-');
    addTearDown(() => root.delete(recursive: true));
    final database = ClipboardDatabase.withFactory(databaseFactoryFfi);
    await database.open(path: inMemoryDatabasePath);
    addTearDown(database.close);
    final repository = ClipboardRepository(database);
    await repository.initializeDevice();
    final image = ClipboardContent.image(
      img.encodePng(img.Image(width: 2, height: 2)),
      'image/png',
    );
    final saved = await repository.capture(image);
    for (var i = 0; i < 5; i++) {
      await repository.captureText('record $i ${'long text ' * 35}');
    }
    final format = SyncFormatService(maxFileBytes: 1400);
    Future<void> export() => format
        .exportDevice(
          repository: root,
          deviceId: repository.deviceId,
          deviceName: 'Test',
          items: const [],
        )
        .then((_) {});
    // Export real repository records, retaining the normal monthly JSONL format.
    await format.exportDevice(
      repository: root,
      deviceId: repository.deviceId,
      deviceName: 'Test',
      items: await repository.listForSync(),
    );
    final files = Directory('${root.path}/records')
        .listSync(recursive: true)
        .whereType<File>()
        .toList();
    expect(files.length, greaterThan(1));
    for (final file in files) {
      expect(await file.length(), lessThanOrEqualTo(1400));
    }
    final imported = await format.readAll(root);
    final record = imported.records.singleWhere(
      (record) => record.type == 'image/png',
    );
    expect(record.content, saved!.content);
    expect(record.contentHash, saved.contentHash);
    final second = ClipboardDatabase.withFactory(databaseFactoryFfi);
    await second.open(path: inMemoryDatabasePath);
    addTearDown(second.close);
    final target = ClipboardRepository(second);
    await target.initializeDevice();
    await target.mergeSyncData(
      records: imported.records,
      tombstones: imported.tombstones,
    );
    expect(
      (await target.list())
          .singleWhere((item) => item.isImage)
          .payload
          .imageBytes,
      image.imageBytes,
    );
    await export();
    expect(
      Directory('${root.path}/records')
          .listSync(recursive: true)
          .whereType<File>(),
      isEmpty,
    );
  });

  test('远端较新的收藏与删除状态能合并到本地', () async {
    final database = ClipboardDatabase.withFactory(databaseFactoryFfi);
    await database.open(path: inMemoryDatabasePath);
    final repository = ClipboardRepository(database);
    await repository.initializeDevice();
    final item = (await repository.captureText('sync me'))!;
    final newer = DateTime.now()
        .add(const Duration(minutes: 1))
        .millisecondsSinceEpoch;

    await repository.mergeSyncData(
      records: [
        SyncRecord(
          id: 'remote-id',
          type: 'text',
          content: item.content,
          contentHash: item.contentHash,
          createdAt: item.createdAt.millisecondsSinceEpoch,
          updatedAt: newer,
          lastUsedAt: newer,
          copyCount: 4,
          favorite: true,
          deleted: false,
          deviceId: 'remote-device',
        ),
      ],
      tombstones: const [],
    );
    expect((await repository.list()).single.favorite, isTrue);

    await repository.mergeSyncData(
      records: const [],
      tombstones: [
        SyncTombstone(
          id: item.id,
          contentHash: item.contentHash,
          deletedAt: newer + 1,
          deviceId: 'remote-device',
        ),
      ],
    );
    expect(await repository.list(), isEmpty);
    await database.close();
  });

  test('JSONL 导出后可以完整读取记录和 tombstone', () async {
    final root = await Directory.systemTemp.createTemp('idreaml-format-');
    addTearDown(() => root.delete(recursive: true));
    final database = ClipboardDatabase.withFactory(databaseFactoryFfi);
    await database.open(path: inMemoryDatabasePath);
    final repository = ClipboardRepository(database);
    await repository.initializeDevice();
    await repository.captureText('visible');
    final deleted = await repository.captureText('deleted');
    await repository.softDelete(deleted!.id);

    final format = SyncFormatService();
    await format.exportDevice(
      repository: root,
      deviceId: repository.deviceId,
      deviceName: 'Test device',
      items: await repository.listForSync(),
    );
    final imported = await format.readAll(root);
    expect(imported.records.single.content, 'visible');
    expect(imported.tombstones.single.contentHash, deleted.contentHash);
    await database.close();
  });

  test('内置 Git 可在两个工作目录之间推送与拉取', () async {
    final root = await Directory.systemTemp.createTemp('idreaml-git-');
    addTearDown(() => root.delete(recursive: true));
    final barePath = '${root.path}${Platform.pathSeparator}remote.git';
    Repository.init(path: barePath, bare: true).free();
    final first = Directory('${root.path}${Platform.pathSeparator}first');
    final second = Directory('${root.path}${Platform.pathSeparator}second');
    const config = SyncConfig(
      provider: SyncProvider.custom,
      remoteUrl: 'unused',
      username: 'test',
    );
    final localConfig = SyncConfig(
      provider: config.provider,
      remoteUrl: barePath,
      username: config.username,
    );
    final git = EmbeddedGitService();

    await git.synchronize<void>(
      directory: first,
      config: localConfig,
      token: 'not-used',
      reconcile: () async {
        await File('${first.path}${Platform.pathSeparator}state.txt')
            .writeAsString('from first');
      },
    );
    await git.synchronize<void>(
      directory: second,
      config: localConfig,
      token: 'not-used',
      reconcile: () async {
        final state = File('${second.path}${Platform.pathSeparator}state.txt');
        expect(await state.readAsString(), 'from first');
        await state.writeAsString('from second');
      },
    );
    await git.synchronize<void>(
      directory: first,
      config: localConfig,
      token: 'not-used',
      reconcile: () async {
        final state = File('${first.path}${Platform.pathSeparator}state.txt');
        expect(await state.readAsString(), 'from second');
      },
    );
  });

  test('访问令牌由 Windows DPAPI 加密且可删除', () async {
    if (!Platform.isWindows) return;
    final root = await Directory.systemTemp.createTemp('idreaml-token-');
    addTearDown(() => root.delete(recursive: true));
    final credentials = SecureCredentialService(
      supportDirectory: () async => root,
    );
    const token = 'private-token-for-test';
    await credentials.writeToken(token);
    final protectedFile = File(
      '${root.path}${Platform.pathSeparator}idreaml_clip'
      '${Platform.pathSeparator}credentials${Platform.pathSeparator}git_token.dpapi',
    );
    expect(
      String.fromCharCodes(await protectedFile.readAsBytes()),
      isNot(contains(token)),
    );
    expect(await credentials.readToken(), token);
    await credentials.deleteToken();
    expect(await credentials.readToken(), isNull);
  });
}
