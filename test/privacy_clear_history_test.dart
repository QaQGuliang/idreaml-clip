import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/app.dart';
import 'package:idreaml_clip/src/app_controller.dart';
import 'package:idreaml_clip/src/data/clipboard_database.dart';
import 'package:idreaml_clip/src/data/clipboard_repository.dart';
import 'package:idreaml_clip/src/services/credential_service.dart';
import 'package:idreaml_clip/src/services/sync_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/clipboard_test_support.dart';

class _NoCredentials implements CredentialStore {
  @override
  Future<String?> readToken({String? id}) async => null;
  @override
  Future<void> writeToken(String token, {String? id}) async {}
  @override
  Future<void> deleteToken({String? id}) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late ClipboardDatabase database;
  late ClipboardRepository repository;
  late AppController controller;
  late String favoriteId;

  setUp(() async {
    database = ClipboardDatabase.withFactory(databaseFactoryFfiNoIsolate);
    await database.open(path: inMemoryDatabasePath);
    repository = ClipboardRepository(database);
    controller = AppController(
      repository,
      SyncService(repository, _NoCredentials()),
    );
    favoriteId = (await repository.captureText('应该保留的收藏'))!.id;
    await repository.toggleFavorite(favoriteId);
    await repository.captureText('应该清空的普通历史');
    await controller.initialize(startMonitor: false);
    await controller.setPage(AppPage.privacy);
  });

  tearDown(() async {
    controller.dispose();
    await database.close();
  });

  testWidgets('隐私清空可取消，确认后保留收藏并刷新历史、快捷面板和统计', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      IdreamlClipApp(
        controller: controller,
        desktopService: RecordingDesktopService(controller),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('移除全部历史中的记录，收藏列表保留'), findsOneWidget);

    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(find.text('清空全部历史？'), findsOneWidget);
    expect(
      find.text('全部历史中的所有记录都会移除，已收藏的内容仍可在收藏中查看。历史删除状态会同步到其他设备。'),
      findsOneWidget,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      expect(await repository.list(), hasLength(2));
    });
    expect(controller.stats.history, 2);

    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    final refreshed = Completer<void>();
    void onRefresh() {
      if (controller.stats.history == 0 && !refreshed.isCompleted) {
        refreshed.complete();
      }
    }

    controller.addListener(onRefresh);
    try {
      await tester.tap(find.text('清空全部历史'));
      await tester.pump();
      await tester.runAsync(() async {
        await refreshed.future.timeout(const Duration(seconds: 5));
      });
    } finally {
      controller.removeListener(onRefresh);
    }
    await tester.pumpAndSettle();
    expect(find.text('已清空全部历史，收藏内容已保留'), findsOneWidget);
    expect(controller.stats.history, 0);
    expect(controller.stats.favorites, 1);
    expect(controller.history, isEmpty);
    expect(controller.quickItems, isEmpty);
    await tester.runAsync(() => controller.setPage(AppPage.favorites));
    await tester.pumpAndSettle();
    expect(controller.history.single.id, favoriteId);
    expect(find.text('应该保留的收藏'), findsWidgets);
    expect(find.byTooltip('删除'), findsNothing);
    expect(find.byTooltip('取消收藏'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
