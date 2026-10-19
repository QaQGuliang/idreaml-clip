import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/data/data_storage.dart';
import 'package:idreaml_clip/src/services/directory_picker.dart';
import 'package:idreaml_clip/src/ui/storage_directory_card.dart';
import 'package:path/path.dart' as p;

import 'support/clipboard_test_support.dart';

class _Storage extends DataStorage {
  _Storage() {
    root = Directory(p.absolute('old-data'));
  }
  @override
  Future<String> validateDestination(String input) async {
    if (!p.isAbsolute(input)) throw const StorageException('请输入完整的绝对目录路径。');
    return p.normalize(input);
  }
}

class _Repository extends MemoryClipboardRepository {
  @override
  final _Storage storage = _Storage();
  int moves = 0;
  Completer<void>? finish;
  bool fail = false;
  @override
  Future<StorageMoveResult> moveStorage(String path) async {
    moves++;
    await finish?.future;
    if (fail) throw const StorageException('迁移失败，已保留原目录。');
    storage.root = Directory(path);
    return const StorageMoveResult();
  }
}

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(DirectoryPicker.channel, (_) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(DirectoryPicker.channel, null);
  });

  Future<void> open(WidgetTester tester, _Repository repository) async {
    final controller = testController(repository);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnimatedBuilder(
            animation: controller,
            builder: (_, _) => StorageDirectoryCard(controller: controller),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('change-storage-directory')));
    await tester.pumpAndSettle();
  }

  testWidgets('相同路径直接结束，不确认也不迁移', (tester) async {
    final repository = _Repository();
    await open(tester, repository);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('确认迁移数据？'), findsNothing);
    expect(find.text('更改数据存储目录'), findsNothing);
    expect(repository.moves, 0);
  });

  testWidgets('不同路径先展示新旧目录和删除说明，取消保留原数据', (tester) async {
    final repository = _Repository();
    final original = repository.storage.root.path;
    final destination = p.absolute('new-data');
    await open(tester, repository);
    await tester.enterText(
      find.byKey(const ValueKey('storage-directory-input')),
      destination,
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('确认迁移数据？'), findsOneWidget);
    expect(find.text(destination), findsWidgets);
    expect(find.text(original), findsWidgets);
    expect(find.textContaining('原目录及其所有内容将被删除'), findsOneWidget);
    expect(repository.moves, 0);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(repository.moves, 0);
    expect(repository.storage.root.path, original);
    expect(find.text('更改数据存储目录'), findsOneWidget);
  });

  testWidgets('确认后才迁移，迁移期间禁用重复提交，完成更新路径', (tester) async {
    final repository = _Repository()..finish = Completer<void>();
    final destination = p.absolute('new-data');
    await open(tester, repository);
    await tester.enterText(
      find.byKey(const ValueKey('storage-directory-input')),
      destination,
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-storage-migration')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(repository.moves, 1);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '取消'))
          .onPressed,
      isNull,
    );
    repository.finish!.complete();
    await tester.pumpAndSettle();
    expect(find.text('更改数据存储目录'), findsNothing);
    expect(find.text(destination), findsOneWidget);
    expect(find.text('数据迁移完成，旧目录已删除。'), findsOneWidget);
  });

  testWidgets('迁移失败保留原路径并恢复操作入口', (tester) async {
    final repository = _Repository()..fail = true;
    final original = repository.storage.root.path;
    await open(tester, repository);
    await tester.enterText(
      find.byKey(const ValueKey('storage-directory-input')),
      p.absolute('new-data'),
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-storage-migration')));
    await tester.pumpAndSettle();
    expect(find.text('迁移失败，已保留原目录。'), findsOneWidget);
    expect(repository.storage.root.path, original);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('选择文件夹只回填路径，仍可手动修改并经过保存确认', (tester) async {
    final repository = _Repository();
    final selected = p.absolute('选择的 目录');
    MethodCall? request;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(DirectoryPicker.channel, (call) async {
          request = call;
          return selected;
        });
    await open(tester, repository);
    await tester.tap(find.byKey(const ValueKey('browse-storage-directory')));
    await tester.pumpAndSettle();
    expect(request?.method, 'chooseDirectory');
    expect(request?.arguments, repository.storage.root.path);
    final field = find.byKey(const ValueKey('storage-directory-input'));
    expect(tester.widget<TextField>(field).controller!.text, selected);
    expect(repository.moves, 0);
    expect(find.text('确认迁移数据？'), findsNothing);
    final edited = p.join(selected, '手动新增');
    await tester.enterText(field, edited);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('确认迁移数据？'), findsOneWidget);
    expect(find.text(edited), findsWidgets);
    expect(repository.moves, 0);
  });

  testWidgets('取消选择文件夹保留手动输入的路径', (tester) async {
    final repository = _Repository();
    await open(tester, repository);
    final field = find.byKey(const ValueKey('storage-directory-input'));
    final typed = p.absolute('手动路径');
    await tester.enterText(field, typed);
    await tester.tap(find.byKey(const ValueKey('browse-storage-directory')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, typed);
    expect(repository.moves, 0);
  });

  testWidgets('选择窗口失败后可继续手动输入和保存', (tester) async {
    final repository = _Repository();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(DirectoryPicker.channel, (_) async {
          throw PlatformException(code: 'directory_dialog');
        });
    await open(tester, repository);
    await tester.tap(find.byKey(const ValueKey('browse-storage-directory')));
    await tester.pumpAndSettle();
    expect(find.text('无法打开文件夹选择窗口，请重试或手动输入路径。'), findsOneWidget);
    final field = find.byKey(const ValueKey('storage-directory-input'));
    expect(tester.widget<TextField>(field).enabled, isTrue);
    await tester.enterText(field, p.absolute('手动路径'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('确认迁移数据？'), findsOneWidget);
  });

  testWidgets('选择窗口打开期间不能重复打开或提交迁移', (tester) async {
    final repository = _Repository();
    final selected = Completer<String?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          DirectoryPicker.channel,
          (_) => selected.future,
        );
    await open(tester, repository);
    await tester.tap(find.byKey(const ValueKey('browse-storage-directory')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('browse-storage-directory')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
          .onPressed,
      isNull,
    );
    selected.complete(null);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('browse-storage-directory')),
          )
          .onPressed,
      isNotNull,
    );
    expect(repository.moves, 0);
  });
}
