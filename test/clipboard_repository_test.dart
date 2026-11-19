import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/data/clipboard_database.dart';
import 'package:idreaml_clip/src/data/clipboard_repository.dart';
import 'package:idreaml_clip/src/models/clipboard_content.dart';
import 'package:idreaml_clip/src/models/sync_models.dart';
import 'package:idreaml_clip/src/services/device_identity.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late ClipboardDatabase database;
  late ClipboardRepository repository;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    database = ClipboardDatabase.withFactory(databaseFactoryFfi);
    await database.open(path: inMemoryDatabasePath);
    repository = ClipboardRepository(database, machineIdentity: () => null);
    await repository.initializeDevice();
  });

  tearDown(() => database.close());

  test('相同文本通过 hash 去重并增加复制次数', () async {
    await repository.captureText('hello Idreaml');
    await repository.captureText('hello Idreaml');

    final items = await repository.list();
    expect(items, hasLength(1));
    expect(items.single.copyCount, 2);
    expect(items.single.content, 'hello Idreaml');
  });

  test('软删除记录不会展示，再次复制相同内容时恢复', () async {
    final item = await repository.captureText('restore me');
    await repository.softDelete(item!.id);
    expect(await repository.list(), isEmpty);

    await repository.captureText('restore me');
    final restored = await repository.list();
    expect(restored, hasLength(1));
    expect(restored.single.deleted, isFalse);
    expect(restored.single.copyCount, 2);
  });

  test('搜索、收藏和清空历史遵循本地业务规则', () async {
    final kept = await repository.captureText('important token-free note');
    await repository.captureText('temporary content');
    await repository.toggleFavorite(kept!.id);

    final matches = await repository.list(query: 'IMPORTANT');
    expect(matches, hasLength(1));
    expect(matches.single.favorite, isTrue);

    await repository.clearHistory();
    expect(await repository.list(), isEmpty);
    final remaining = await repository.list(favoritesOnly: true);
    expect(remaining.map((item) => item.id), [kept.id]);
    expect(remaining.single.favorite, isTrue);
  });

  test('清空全部历史但保留文字、图片和仅收藏的条目', () async {
    final text = await repository.captureText('保留的文字收藏');
    final image = await repository.capture(
      ClipboardContent.image(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII=',
        ),
        'image/png',
      ),
    );
    final ordinary = await repository.captureText('需要清空的普通记录');
    final deleted = await repository.captureText('此前已单独删除的收藏');
    for (final item in [text!, image!, deleted!]) {
      await repository.toggleFavorite(item.id);
    }
    await repository.softDelete(deleted.id);
    await repository.markAllSynced();
    // Fixed earlier timestamps make unintended rewrites observable without sleeps.
    await database.database.update('clipboard_item', {'updated_at': 1000});
    final before = await database.database.query(
      'clipboard_item',
      orderBy: 'id',
    );

    await repository.clearHistory();

    final remaining = await repository.list(favoritesOnly: true);
    expect(
      remaining.map((item) => item.id),
      unorderedEquals([text.id, image.id, deleted.id]),
    );
    expect(
      remaining.singleWhere((item) => item.isImage).content,
      image.content,
    );
    final after = await database.database.query(
      'clipboard_item',
      orderBy: 'id',
    );
    expect(
      after.map((row) => row['favorite_changed_at']),
      before.map((row) => row['favorite_changed_at']),
    );
    final syncItems = await repository.listForSync();
    final cleared = syncItems.singleWhere((item) => item.id == ordinary!.id);
    expect(cleared.deleted, isTrue);
    expect(cleared.syncState, 'dirty');
    expect(cleared.updatedAt.millisecondsSinceEpoch, greaterThan(1000));
    expect(
      syncItems
          .where((item) => item.syncState == 'dirty')
          .map((item) => item.id),
      unorderedEquals([ordinary!.id, text.id, image.id]),
    );
    expect(await repository.list(), isEmpty);
    expect((await repository.stats()).favorites, 3);

    // Repeating the action must neither rewrite favorites nor existing tombstones.
    await repository.clearHistory();
    expect(
      await database.database.query('clipboard_item', orderBy: 'id'),
      after,
    );
  });

  test('删除历史只隐藏历史，取消收藏后从收藏列表移除', () async {
    final deleted = (await repository.captureText('单独删除的收藏'))!;
    final unfavorited = (await repository.captureText('先取消收藏再清空'))!;
    await repository.toggleFavorite(deleted.id);
    await repository.toggleFavorite(unfavorited.id);
    await repository.softDelete(deleted.id);
    expect((await repository.list()).single.id, unfavorited.id);
    await repository.clearHistory();
    expect(await repository.list(), isEmpty);
    expect(await repository.list(favoritesOnly: true), hasLength(2));

    await repository.toggleFavorite(unfavorited.id);
    expect((await repository.list(favoritesOnly: true)).single.id, deleted.id);
    expect(await repository.list(), isEmpty);
    expect(
      (await repository.listForSync()).every((item) => item.deleted),
      isTrue,
    );
  });

  test('设置能够持久化并覆盖', () async {
    await repository.setSetting('quick_count', '20');
    await repository.setSetting('quick_count', '50');
    expect(await repository.getSetting('quick_count'), '50');
  });

  test('设备按完整编号合并，保留不同编号的同名设备与无法确认的旧设备', () async {
    final machine = List.filled(64, 'a').join();
    final other = '${machine.substring(0, 63)}b';
    repository = ClipboardRepository(database, machineIdentity: () => machine);
    await repository.initializeDevice();
    final seen = DateTime.now()
        .add(const Duration(days: 1))
        .millisecondsSinceEpoch;
    await repository.mergeSyncData(
      records: [],
      tombstones: [],
      devices: [
        SyncDevice(
          id: 'renamed',
          name: '同名电脑',
          platform: 'windows',
          lastSeenAt: seen,
          machineId: machine,
        ),
        SyncDevice(
          id: 'second',
          name: '同名电脑',
          platform: 'windows',
          lastSeenAt: seen,
          machineId: other,
        ),
        SyncDevice(
          id: 'old',
          name: '同名电脑',
          platform: 'windows',
          lastSeenAt: seen,
        ),
      ],
    );
    final devices = await repository.listDevices();
    expect(devices, hasLength(3));
    expect(devices.first.isCurrent, isTrue);
    expect(devices.first.name, '同名电脑');
    expect(
      devices.map((device) => device.machineId),
      unorderedEquals([machine, other, null]),
    );
    expect(devices.first.shortMachineId, 'AAAA-AAAA-AAAA');
  });

  test('Windows 固件 UUID 转换为稳定设备编号，拒绝占位 UUID', () {
    final table = List.filled(8 + 24 + 2, 0);
    table[8] = 1;
    table[9] = 24;
    expect(machineIdFromSmbios(table), isNull);
    table[16] = 42;
    final id = machineIdFromSmbios(table);
    expect(id, matches(r'^[a-f0-9]{64}$'));
    expect(machineIdFromSmbios(table), id);
    table[16] = 43;
    expect(machineIdFromSmbios(table), isNot(id));
  });
}
