import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

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

  test('原文和原图按北京日期归档，清空与取消收藏只移除对应文件', () async {
    final root = await Directory.systemTemp.createTemp('idreaml-sync-files-');
    addTearDown(() => _cleanup(root, 'idreaml-sync-files-'));
    final database = ClipboardDatabase.withFactory(databaseFactoryFfi);
    await database.open(path: inMemoryDatabasePath);
    addTearDown(database.close);
    final repository = ClipboardRepository(database);
    await repository.initializeDevice();
    final png = img.encodePng(img.Image(width: 2, height: 2));
    final image = (await repository.capture(
      ClipboardContent.image(png, 'image/png'),
    ))!;
    const raw = '\ufeff原文\r\n  第二行\n';
    final text = (await repository.captureText(raw))!;
    await database.database.update('clipboard_item', {
      'created_at': DateTime.utc(2026, 11, 13, 16, 30).millisecondsSinceEpoch,
    });
    await repository.toggleFavorite(image.id);
    final format = SyncFormatService();
    Future<void> export() async {
      await format.exportDevice(
        repository: root,
        deviceId: repository.deviceId,
        deviceName: 'Test',
        items: await repository.listForSync(),
      );
    }

    final history = Directory(p.join(root.path, 'history', '2026-11-14'));
    final favorite = File(
      p.join(root.path, 'favorites', '${image.contentHash}.png'),
    );
    await export();
    expect(
      await File(p.join(history.path, '003000-${text.contentHash}.txt'))
          .readAsBytes(),
      utf8.encode(raw),
    );
    expect(
      await File(p.join(history.path, '003000-${image.contentHash}.png'))
          .readAsBytes(),
      png,
    );
    expect(await favorite.readAsBytes(), png);
    await favorite.writeAsBytes([0, ...png.skip(1)]);
    await expectLater(format.readAll(root), throwsFormatException);
    await favorite.writeAsBytes(png);

    final second = ClipboardDatabase.withFactory(databaseFactoryFfi);
    await second.open(path: inMemoryDatabasePath);
    addTearDown(second.close);
    final target = ClipboardRepository(second);
    await target.initializeDevice();
    await target.mergeSyncData(
      records: (await format.readAll(root)).records,
      tombstones: [],
    );
    expect(
      (await target.list()).singleWhere((item) => !item.isImage).content,
      raw,
    );

    await repository.clearHistory();
    await export();
    expect(await history.list().toList(), isEmpty);
    expect(await favorite.readAsBytes(), png);
    final data = await format.readAll(root);
    await target.mergeSyncData(
      records: data.records,
      tombstones: data.tombstones,
    );
    expect(await target.list(), isEmpty);
    expect(
      (await target.list(favoritesOnly: true)).single.payload.imageBytes,
      png,
    );

    await repository.toggleFavorite(image.id);
    await export();
    expect(await favorite.exists(), isFalse);
    final changed = await format.readAll(root);
    await target.mergeSyncData(
      records: changed.records,
      tombstones: changed.tombstones,
    );
    expect(await target.list(favoritesOnly: true), isEmpty);
  });

  test('复制使用、清空历史和收藏变更各自合并，旧快照不会恢复已取消的收藏', () async {
    final database = ClipboardDatabase.withFactory(databaseFactoryFfi);
    await database.open(path: inMemoryDatabasePath);
    addTearDown(database.close);
    final repository = ClipboardRepository(database);
    await repository.initializeDevice();
    final item = (await repository.captureText('sync me'))!;
    final start = item.historyChangedAt;
    SyncRecord remote({
      required int updated,
      required int history,
      required int favoriteTime,
      bool favorite = false,
      bool deleted = false,
    }) => SyncRecord(
      id: 'remote-id',
      type: 'text',
      content: item.content,
      contentHash: item.contentHash,
      createdAt: start,
      updatedAt: updated,
      lastUsedAt: updated,
      copyCount: 4,
      favorite: favorite,
      deleted: deleted,
      deviceId: 'remote-device',
      historyChangedAt: history,
      favoriteChangedAt: favoriteTime,
    );
    Future<void> merge(SyncRecord record) async {
      await repository.mergeSyncData(records: [record], tombstones: const []);
    }

    await merge(
      remote(
        updated: start + 10,
        history: start,
        favoriteTime: start + 10,
        favorite: true,
      ),
    );
    await merge(
      remote(
        updated: start + 20,
        history: start + 20,
        favoriteTime: 0,
        deleted: true,
      ),
    );
    await merge(remote(updated: start + 30, history: start, favoriteTime: 0));
    expect(await repository.list(), isEmpty);
    expect((await repository.list(favoritesOnly: true)).single.copyCount, 4);

    await merge(
      remote(updated: start + 40, history: start, favoriteTime: start + 40),
    );
    await merge(
      remote(
        updated: start + 50,
        history: start,
        favoriteTime: start + 10,
        favorite: true,
      ),
    );
    expect(await repository.list(favoritesOnly: true), isEmpty);
  });

  test('旧 JSONL 保留收藏与删除状态，读取不修改旧仓库', () async {
    final root = await Directory.systemTemp.createTemp('idreaml-legacy-jsonl-');
    addTearDown(() => _cleanup(root, 'idreaml-legacy-jsonl-'));
    final database = ClipboardDatabase.withFactory(databaseFactoryFfi);
    await database.open(path: inMemoryDatabasePath);
    addTearDown(database.close);
    final repository = ClipboardRepository(database);
    await repository.initializeDevice();
    final payload = ClipboardContent.text('legacy favorite');
    final file = File(
      p.join(root.path, 'records', 'old-device', '2026-11.jsonl'),
    );
    final deleted = File(
      p.join(root.path, 'tombstones', 'old-device', 'events.jsonl'),
    );
    final row = SyncRecord(
      id: 'legacy-favorite',
      type: 'text',
      content: payload.content,
      contentHash: payload.hash,
      createdAt: 100,
      updatedAt: 120,
      lastUsedAt: 110,
      copyCount: 1,
      favorite: true,
      deleted: false,
      deviceId: 'old-device',
    );
    final original = '${jsonEncode(row.toJson())}\n';
    await file.parent.create(recursive: true);
    await file.writeAsString(original);
    await deleted.parent.create(recursive: true);
    await deleted.writeAsString(
      jsonEncode(
        SyncTombstone(
          id: row.id,
          contentHash: row.contentHash,
          deletedAt: 130,
          deviceId: row.deviceId,
        ).toJson(),
      ),
    );
    final format = SyncFormatService();
    expect(await format.isLegacy(root), isTrue);
    await for (final data in format.readLegacy(root)) {
      await repository.mergeSyncData(
        records: data.records,
        tombstones: data.tombstones,
      );
    }
    expect(await repository.list(), isEmpty);
    expect(
      (await repository.list(favoritesOnly: true)).single.content,
      payload.content,
    );
    expect(await file.readAsString(), original);
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

Future<void> _cleanup(Directory root, String prefix) async {
  final resolved = await root.resolveSymbolicLinks();
  final temp = await Directory.systemTemp.resolveSymbolicLinks();
  expect(p.isWithin(temp, resolved), isTrue);
  expect(p.basename(resolved), startsWith(prefix));
  await Directory(resolved).delete(recursive: true);
}
