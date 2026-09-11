import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/data/clipboard_database.dart';
import 'package:idreaml_clip/src/data/clipboard_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late ClipboardDatabase database;
  late ClipboardRepository repository;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    database = ClipboardDatabase.withFactory(databaseFactoryFfi);
    await database.open(path: inMemoryDatabasePath);
    repository = ClipboardRepository(database);
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
    final remaining = await repository.list();
    expect(remaining, isEmpty);
  });

  test('设置能够持久化并覆盖', () async {
    await repository.setSetting('quick_count', '20');
    await repository.setSetting('quick_count', '50');
    expect(await repository.getSetting('quick_count'), '50');
  });
}
