import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/app.dart';
import 'package:idreaml_clip/src/app_controller.dart';
import 'package:idreaml_clip/src/models/sync_models.dart';

import 'support/clipboard_test_support.dart';

void main() {
  late MemoryClipboardRepository repository;
  late AppController controller;
  late RecordingDesktopService desktop;

  setUp(() async {
    repository = MemoryClipboardRepository(count: 2);
    controller = testController(repository);
    desktop = RecordingDesktopService(controller);
  });
  tearDown(() => controller.dispose());

  testWidgets('设备页只显示带编号的设备并按数量统计', (tester) async {
    repository.devices.addAll([
      DeviceInfo(
        id: 'numbered',
        name: 'HOME',
        platform: 'windows',
        lastSeenAt: DateTime.now(),
        isCurrent: true,
        machineId:
            '488cf06028bbbf752906d2e84caea55b0d7794cebfb46ae8a943c2e0c517c877',
      ),
      DeviceInfo(
        id: 'legacy',
        name: 'OLD-BOOK',
        platform: 'windows',
        lastSeenAt: DateTime.now(),
        isCurrent: false,
      ),
    ]);
    await controller.reload();
    await controller.setPage(AppPage.devices);
    await tester.pumpWidget(
      IdreamlClipApp(controller: controller, desktopService: desktop),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('共 1 台设备'), findsOneWidget);
    expect(find.textContaining('HOME'), findsOneWidget);
    expect(find.textContaining('488C-F060-28BB'), findsOneWidget);
    expect(find.textContaining('OLD-BOOK'), findsNothing);
    expect(find.textContaining('无设备编号'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}