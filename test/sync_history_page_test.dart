import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/models/sync_models.dart';
import 'package:idreaml_clip/src/ui/app_theme.dart';
import 'package:idreaml_clip/src/ui/common.dart';
import 'package:idreaml_clip/src/ui/sync_history_page.dart';

void main() {
  final now = DateTime.now();

  DateTime atDaysAgo(int days, int hour, int minute) => DateTime(
    now.year,
    now.month,
    now.day,
    hour,
    minute,
  ).subtract(Duration(days: days));

  SyncHistoryEntry entry(
    DateTime completedAt, {
    required bool succeeded,
    SyncTrigger trigger = SyncTrigger.manual,
    String details = '详情',
  }) => SyncHistoryEntry(
    completedAt: completedAt,
    trigger: trigger,
    succeeded: succeeded,
    details: details,
  );

  final entries = <SyncHistoryEntry>[
    entry(atDaysAgo(0, 9, 30), succeeded: false, details: '拉取远端数据失败 · 网络不可用'),
    entry(
      atDaysAgo(0, 8, 10),
      succeeded: true,
      trigger: SyncTrigger.scheduled,
      details: '导入 1 项，导出快照 2 项',
    ),
    entry(atDaysAgo(1, 21, 5), succeeded: true, details: '导入 0 项，导出快照 3 项'),
    entry(
      atDaysAgo(3, 10, 0),
      succeeded: false,
      trigger: SyncTrigger.startup,
      details: '上传到远端失败 · 服务器拒绝',
    ),
  ];

  Future<void> mount(
    WidgetTester tester, {
    List<SyncHistoryEntry>? records,
    bool unavailable = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 700);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: SyncHistoryPage(
          entries: records ?? entries,
          unavailable: unavailable,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('按天分组展示全部记录并按成功失败筛选', (tester) async {
    await mount(tester);
    final older = atDaysAgo(3, 0, 0);
    expect(find.text('同步记录'), findsOneWidget);
    expect(find.text('今天'), findsOneWidget);
    expect(find.text('昨天'), findsOneWidget);
    expect(
      find.text('${older.year}年${older.month}月${older.day}日'),
      findsOneWidget,
    );
    expect(find.text('2 条'), findsOneWidget);
    expect(find.text('1 条'), findsNWidgets(2));
    expect(find.text('09:30 · 手动同步'), findsOneWidget);
    expect(find.text('08:10 · 定时同步'), findsOneWidget);
    expect(find.text('10:00 · 启动同步'), findsOneWidget);
    expect(find.textContaining('网络不可用'), findsOneWidget);
    expect(find.textContaining('服务器拒绝'), findsOneWidget);
    expect(find.text('4 条'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('sync-history-filter-failed')));
    await tester.pumpAndSettle();
    expect(find.text('2 条'), findsOneWidget);
    expect(find.text('1 条'), findsNWidgets(2));
    expect(find.text('昨天'), findsNothing);
    expect(find.textContaining('网络不可用'), findsOneWidget);
    expect(find.textContaining('服务器拒绝'), findsOneWidget);
    expect(find.textContaining('导入 1 项'), findsNothing);
    expect(
      find.descendant(of: find.byType(StatusPill), matching: find.text('成功')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('sync-history-filter-success')));
    await tester.pumpAndSettle();
    expect(find.text('2 条'), findsOneWidget);
    expect(find.text('1 条'), findsNWidgets(2));
    expect(find.textContaining('导入 1 项'), findsOneWidget);
    expect(find.textContaining('网络不可用'), findsNothing);
    expect(
      find.descendant(of: find.byType(StatusPill), matching: find.text('失败')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('sync-history-filter-all')));
    await tester.pumpAndSettle();
    expect(find.text('今天'), findsOneWidget);
    expect(find.text('昨天'), findsOneWidget);
    expect(find.text('4 条'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('筛选后无匹配记录时显示空状态提示', (tester) async {
    await mount(
      tester,
      records: [entry(atDaysAgo(0, 8, 10), succeeded: true, details: '导入 0 项')],
    );
    await tester.tap(find.byKey(const ValueKey('sync-history-filter-failed')));
    await tester.pumpAndSettle();
    expect(find.text('没有符合条件的记录'), findsOneWidget);
    expect(find.textContaining('切换上方筛选'), findsOneWidget);
    expect(find.text('0 条'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('无记录和记录无法读取时显示对应提示', (tester) async {
    await mount(tester, records: const []);
    expect(find.text('暂无同步记录'), findsOneWidget);
    expect(find.text('0 条'), findsOneWidget);

    await mount(tester, records: const [], unavailable: true);
    expect(find.text('同步记录暂时无法保存或读取，请检查数据目录。'), findsOneWidget);
    expect(find.text('暂无同步记录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
