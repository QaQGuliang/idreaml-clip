import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:idreaml_clip/src/app_controller.dart';
import 'package:idreaml_clip/src/data/clipboard_database.dart';
import 'package:idreaml_clip/src/data/clipboard_repository.dart';
import 'package:idreaml_clip/src/models/clipboard_content.dart';
import 'package:idreaml_clip/src/models/quick_shortcut.dart';
import 'package:idreaml_clip/src/services/clipboard_service.dart';
import 'package:idreaml_clip/src/services/credential_service.dart';
import 'package:idreaml_clip/src/services/sync_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Clipboard extends ClipboardService {
  @override
  int sequence = 0;
  List<ClipboardContent> contents = [];
  ClipboardContent? written;
  bool locked = false;
  int reads = 0;
  Completer<void>? readGate;
  void change(List<ClipboardContent> values) {
    contents = values;
    sequence++;
  }

  @override
  Future<List<ClipboardContent>> read() async {
    reads++;
    if (locked) throw PlatformException(code: 'locked');
    final snapshot = contents;
    if (readGate != null) await readGate!.future;
    return snapshot;
  }

  @override
  Future<void> write(ClipboardContent content) async {
    if (locked) throw PlatformException(code: 'locked');
    written = content;
    change([content]);
  }
}

class _Credentials implements CredentialStore {
  @override
  Future<String?> readToken() async => null;
  @override
  Future<void> writeToken(String token) async {}
  @override
  Future<void> deleteToken() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ClipboardDatabase database;
  late ClipboardRepository repository;
  late AppController controller;
  late _Clipboard clipboard;
  final png = ClipboardContent.image(
    img.encodePng(img.Image(width: 2, height: 2)),
    'image/png',
  );

  setUp(() async {
    sqfliteFfiInit();
    database = ClipboardDatabase.withFactory(databaseFactoryFfi);
    await database.open(path: inMemoryDatabasePath);
    repository = ClipboardRepository(database);
    clipboard = _Clipboard();
    controller = AppController(
      repository,
      SyncService(repository, _Credentials()),
      clipboard: clipboard,
    );
    await controller.initialize(startMonitor: false);
  });
  tearDown(() async {
    controller.dispose();
    await database.close();
  });

  test('系统剪切板改变即可采集文本和图片，不依赖按键事件', () async {
    clipboard.change([const ClipboardContent.text('{"a": 1}')]);
    await controller.pollClipboard();
    clipboard.change([png]);
    await controller.pollClipboard();
    expect(controller.history, hasLength(2));
    expect(
      controller.history.map((item) => item.typeLabel),
      containsAll(['PNG', 'JSON']),
    );
    final image = controller.history.firstWhere((item) => item.isImage);
    expect(image.payload.imageBytes, png.imageBytes);
    expect((await repository.list(query: '图片')).single.id, image.id);
    expect(await repository.list(query: 'iVBOR'), isEmpty);
    final reads = clipboard.reads;
    await controller.pollClipboard();
    expect(clipboard.reads, reads);
  });

  test('重新初始化应用会恢复 Win+V 开关和独立保存的自定义快捷键', () async {
    expect(controller.winVShortcutEnabled, isFalse);
    const shortcut = QuickShortcut(
      key: PhysicalKeyboardKey.keyJ,
      control: true,
      alt: true,
    );
    await controller.saveQuickShortcut(shortcut);
    await controller.saveWinVShortcutEnabled(true);
    final next = AppController(
      repository,
      SyncService(repository, _Credentials()),
      clipboard: _Clipboard(),
    );
    await next.initialize(startMonitor: false);
    expect(next.quickShortcut.sameCombination(shortcut), isTrue);
    expect(next.winVShortcutEnabled, isTrue);
    await next.saveWinVShortcutEnabled(false);
    expect(next.quickShortcut.sameCombination(shortcut), isTrue);
    next.dispose();
  });

  test('复制图片输出图片字节，监听不会重复增加自身复制次数', () async {
    final saved = await repository.capture(png);
    expect(await controller.useItem(saved), isTrue);
    expect(clipboard.written!.imageBytes, png.imageBytes);
    await controller.pollClipboard();
    expect((await repository.list()).single.copyCount, 2);
    clipboard.change([png]);
    await controller.pollClipboard();
    expect((await repository.list()).single.copyCount, 3);
  });

  test('自定义历史上限按数量清理非收藏记录，重新初始化后保留设置', () async {
    final ids = <String>[];
    for (var i = 0; i < 4; i++) {
      final item = await repository.captureText('history-$i');
      ids.add(item!.id);
      await database.database.update(
        'clipboard_item',
        {'last_used_at': 1000 + i},
        where: 'id = ?',
        whereArgs: [item.id],
      );
    }
    await repository.toggleFavorite(ids.first);
    await controller.setHistoryLimit(2);
    expect(
      controller.history.map((item) => item.id),
      unorderedEquals([ids[0], ids[2], ids[3]]),
    );
    final next = AppController(
      repository,
      SyncService(repository, _Credentials()),
      clipboard: _Clipboard(),
    );
    try {
      await next.initialize(startMonitor: false);
      expect(next.historyLimit, 2);
      expect(next.history, hasLength(3));
      await expectLater(next.setHistoryLimit(0), throwsArgumentError);
      expect(await repository.getSetting('history_limit'), '2');
    } finally {
      next.dispose();
    }
  });

  test('图片去重、删除后重新捕获及收藏均保留正确类型', () async {
    final saved = await repository.capture(png);
    await repository.toggleFavorite(saved!.id);
    await repository.softDelete(saved.id);
    final restored = await repository.capture(png);
    expect(restored!.id, saved.id);
    expect(restored.favorite, isTrue);
    expect(restored.deleted, isFalse);
    expect(restored.copyCount, 2);
    expect(restored.typeLabel, 'PNG');
  });

  test('剪切板锁定会重试，复制失败不增加使用次数', () async {
    clipboard.change([png]);
    clipboard.locked = true;
    await controller.pollClipboard();
    expect(controller.history, isEmpty);
    clipboard.locked = false;
    await controller.pollClipboard();
    clipboard.locked = true;
    expect(await controller.useItem(controller.history.single), isFalse);
    expect(controller.history.single.copyCount, 1);
    expect(controller.clipboardError, isNotNull);
  });

  test('读取期间自己复制或暂停记录，不再写入过期数据', () async {
    final saved = await repository.captureText('original');
    clipboard.change([png]);
    clipboard.readGate = Completer<void>();
    final pending = controller.pollClipboard();
    await controller.useItem(saved);
    clipboard.readGate!.complete();
    await pending;
    expect((await repository.list()).single.content, 'original');
    clipboard.readGate = null;
    await controller.setRecording(false);
    clipboard.change([png]);
    await controller.pollClipboard();
    expect((await repository.list()), hasLength(1));
  });
}
