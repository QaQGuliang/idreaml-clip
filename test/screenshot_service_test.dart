import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:image/image.dart' as img;
import 'package:idreaml_clip/src/app_controller.dart';
import 'package:idreaml_clip/src/data/clipboard_database.dart';
import 'package:idreaml_clip/src/data/clipboard_repository.dart';
import 'package:idreaml_clip/src/models/arrow_style.dart';
import 'package:idreaml_clip/src/models/clipboard_content.dart';
import 'package:idreaml_clip/src/models/pinned_image_border.dart';
import 'package:idreaml_clip/src/models/quick_shortcut.dart';
import 'package:idreaml_clip/src/services/clipboard_service.dart';
import 'package:idreaml_clip/src/services/credential_service.dart';
import 'package:idreaml_clip/src/services/screenshot_service.dart';
import 'package:idreaml_clip/src/services/sync_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Clipboard extends ClipboardService {
  @override
  int sequence = 0;
  bool fail = false;
  int writes = 0;
  ClipboardContent? content;
  @override
  Future<List<ClipboardContent>> read() async => [?content];
  @override
  Future<void> write(ClipboardContent value) async {
    if (fail) throw PlatformException(code: 'busy', message: '剪切板正被其他程序使用，请重试');
    content = value;
    sequence++;
    writes++;
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

class _HotKeyPlatform extends MethodChannelHotKeyManager {
  final events = StreamController<Map<Object?, Object?>>.broadcast();
  @override
  Stream<Map<Object?, Object?>> get onKeyEventReceiver => events.stream;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = StandardMethodCodec();
  const hotkeyChannel = MethodChannel('dev.leanflutter.plugins/hotkey_manager');
  final platform = _HotKeyPlatform();
  final originalPlatform = HotKeyManagerPlatform.instance;
  late ClipboardDatabase database;
  late ClipboardRepository repository;
  late AppController controller;
  late ScreenshotService service;
  late _Clipboard clipboard;
  late List<String> calls;
  late List<MethodCall> hotkeys;
  late Directory directory;
  String? exportPath;
  bool available = true;
  final png = img.encodePng(img.Image(width: 4, height: 3));

  Future<Object?> fromEditor(String name, [Object? args]) async {
    final result = Completer<Object?>();
    await messenger.handlePlatformMessage(
      ScreenshotService.channel.name,
      codec.encodeMethodCall(MethodCall(name, args)),
      (reply) {
        try {
          result.complete(reply == null ? null : codec.decodeEnvelope(reply));
        } on Object catch (e, st) {
          result.completeError(e, st);
        }
      },
    );
    return result.future;
  }

  setUpAll(() {
    HotKeyManagerPlatform.instance = platform;
    expect(hotKeyManager.registeredHotKeyList, isEmpty);
  });
  tearDownAll(() async {
    HotKeyManagerPlatform.instance = originalPlatform;
    await platform.events.close();
  });
  setUp(() async {
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
    calls = [];
    hotkeys = [];
    available = true;
    exportPath = null;
    directory = await Directory.systemTemp.createTemp(
      'idreaml-screenshot-test-',
    );
    messenger.setMockMethodCallHandler(hotkeyChannel, (call) async {
      hotkeys.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(ScreenshotService.channel, (call) async {
      calls.add(call.method);
      return call.method == 'chooseSavePath' ? exportPath : null;
    });
    service = ScreenshotService(
      controller,
      supported: true,
      canRegisterShortcut: (_) => available,
    );
    await service.initialize();
  });
  tearDown(() async {
    if (service.active) await fromEditor('closed');
    await service.dispose();
    await hotKeyManager.unregisterAll();
    messenger.setMockMethodCallHandler(hotkeyChannel, null);
    messenger.setMockMethodCallHandler(ScreenshotService.channel, null);
    controller.dispose();
    await database.close();
    await directory.delete(recursive: true);
  });

  test('按钮先确定屏幕再隐藏，快捷键路径不隐藏，重复启动无效', () async {
    expect(calls, ['setPinBorderDefault']);
    calls.clear();
    await service.start(
      buttonPoint: const Offset(20, 30),
      hidePanel: () async {
        calls.add('hide');
      },
    );
    expect(calls, ['prepare', 'hide', 'open']);
    await service.start();
    expect(calls, hasLength(3));
    await fromEditor('closed');
    calls.clear();
    await service.start();
    expect(calls, ['prepare', 'open']);
  });

  test('帮助快捷键读取当前配置，截图快照也携带最新组合', () async {
    Map? opened;
    messenger.setMockMethodCallHandler(ScreenshotService.channel, (call) async {
      if (call.method == 'open') opened = call.arguments as Map;
      return null;
    });
    await service.start();
    expect(
      opened?['screenshotShortcut'],
      controller.screenshotShortcut.label(),
    );
    expect(
      await fromEditor('getScreenshotShortcut'),
      controller.screenshotShortcut.label(),
    );
    const shortcut = QuickShortcut(key: PhysicalKeyboardKey.f9, control: true);
    expect(await service.updateShortcut(shortcut), isNull);
    expect(await fromEditor('getScreenshotShortcut'), shortcut.label());
    await fromEditor('closed');
    await service.start();
    expect(opened?['screenshotShortcut'], shortcut.label());
  });

  test('原生截图启动失败时显示具体原因，并允许开始下一次截图', () async {
    var tooLarge = true;
    messenger.setMockMethodCallHandler(ScreenshotService.channel, (call) async {
      if (call.method == 'open' && tooLarge) {
        throw PlatformException(code: 'capture', message: '桌面总尺寸超过截图上限');
      }
      return null;
    });
    await service.start();
    expect(service.active, isFalse);
    expect(controller.screenshotError, '桌面总尺寸超过截图上限');
    tooLarge = false;
    await service.start();
    expect(service.active, isTrue);
    expect(controller.screenshotError, isNull);
  });

  test('设置页和贴图菜单共用默认边框，重新初始化后恢复', () async {
    final applied = <String>[];
    messenger.setMockMethodCallHandler(ScreenshotService.channel, (call) async {
      if (call.method == 'setPinBorderDefault') {
        applied.add(call.arguments as String);
      }
      return null;
    });

    await service.savePinBorderDefault(PinnedImageBorder.dark);
    await fromEditor('savePinBorderDefault', 'amber');
    expect(service.active, isFalse);
    expect(applied, ['dark', 'amber']);
    expect(controller.pinnedImageBorder, PinnedImageBorder.amber);
    await service.dispose();
    service = ScreenshotService(
      controller,
      supported: true,
      canRegisterShortcut: (_) => true,
    );
    await service.initialize();
    expect(applied, ['dark', 'amber', 'amber']);
    expect(clipboard.writes, 0);
  });

  test('预热不启动会话，预热失败仍可截图，新样式在后续会话生效', () async {
    Map? opened;
    messenger.setMockMethodCallHandler(ScreenshotService.channel, (call) async {
      calls.add(call.method);
      if (call.method == 'warmUp') throw PlatformException(code: 'unavailable');
      if (call.method == 'open') opened = call.arguments as Map;
      return null;
    });
    await service.warmUp();
    expect(service.active, isFalse);
    await service.start();
    expect(service.active, isTrue);
    expect(opened?['styles'], '{}');
    expect(opened?.containsKey('defaultArrowStyle'), isFalse);
    expect(opened?['showColorPicker'], true);
    expect(opened?['autoScroll'], false);
    const styles = '{"rectangle":{"color":4278190080}}';
    await fromEditor('styles', styles);
    await fromEditor('closed');
    await controller.saveShowScreenshotColorPicker(false);
    await controller.saveAutoScrollCapture(true);
    await controller.saveDefaultArrowStyle(ArrowStyle.dashed);
    await service.start();
    expect(opened?['styles'], styles);
    expect(opened?['defaultArrowStyle'], 'dashed');
    expect(opened?['showColorPicker'], false);
    expect(opened?['autoScroll'], true);
    expect(await repository.getSetting('screenshot_styles'), styles);
  });

  test('贴图保留剪切板，历史写入失败后重试不重复创建浮窗', () async {
    clipboard.content = const ClipboardContent.text('原内容');
    await service.start();
    await database.database.execute('''
      CREATE TRIGGER fail_receipt BEFORE INSERT ON screenshot_commit
      BEGIN SELECT RAISE(ABORT, 'test'); END
    ''');
    final request = {'png': png, 'pin': true, 'x': 120, 'y': 32};
    final first = await fromEditor('commit', request) as Map;
    expect(first['locked'], isTrue);
    expect(first['error'], contains('贴图已显示'));
    await database.database.execute('DROP TRIGGER fail_receipt');
    final retry = await fromEditor('commit', request) as Map;
    expect(retry['success'], true);
    expect(calls.where((c) => c == 'pinImage'), hasLength(1));
    expect(controller.history.single.payload.imageBytes, png);
    expect(controller.history.single.copyCount, 1);
    expect(clipboard.writes, 0);
    expect(clipboard.content!.content, '原内容');
    await fromEditor('closed');
    await fromEditor('copyPinnedImage', png);
    expect(clipboard.content!.imageBytes, png);
  });

  test('另存为成功同时复制及入库，普通完成不出现文件对话框', () async {
    exportPath = '${directory.path}/副本.png';
    await service.start();
    final result =
        await fromEditor('commit', {'png': png, 'saveAs': true}) as Map;
    expect(result['success'], isTrue);
    expect(await File(exportPath!).readAsBytes(), png);
    expect(controller.history.single.payload.imageBytes, png);
    expect(clipboard.writes, 1);
    await fromEditor('closed');
    calls.clear();
    await service.start();
    await fromEditor('commit', {'png': png, 'saveAs': false});
    expect(calls, isNot(contains('chooseSavePath')));
  });

  test('取消另存为不复制不入库，保留会话供编辑', () async {
    await service.start();
    final result =
        await fromEditor('commit', {'png': png, 'saveAs': true}) as Map;
    expect(result['cancelled'], isTrue);
    expect(service.active, isTrue);
    expect(clipboard.writes, 0);
    expect(controller.history, isEmpty);
  });

  test('副本成功而复制失败，重试不重复另存并使用原最终图像', () async {
    exportPath = '${directory.path}/副本.png';
    clipboard.fail = true;
    await service.start();
    final failed =
        await fromEditor('commit', {'png': png, 'saveAs': true}) as Map;
    expect(failed['locked'], isTrue);
    expect(failed['error'], contains('副本已保存'));
    clipboard.fail = false;
    final result = await fromEditor('commit', {
      'png': img.encodePng(img.Image(width: 8, height: 8)),
      'saveAs': true,
    }) as Map;
    expect(result['success'], isTrue);
    expect(calls.where((c) => c == 'chooseSavePath'), hasLength(1));
    expect(controller.history.single.payload.imageBytes, png);
    expect(controller.history.single.copyCount, 1);
  });

  test('快捷键冲突保留配置，录入期间停用截图并在退出时恢复', () async {
    available = false;
    expect(
      await service.updateShortcut(
        const QuickShortcut(key: PhysicalKeyboardKey.f8),
      ),
      isNotNull,
    );
    expect(controller.screenshotShortcut.key, PhysicalKeyboardKey.f1);
    available = true;
    await service.suspendShortcut();
    await service.start();
    expect(service.active, isFalse);
    expect(
      await service.updateShortcut(
        const QuickShortcut(key: PhysicalKeyboardKey.f8),
      ),
      isNull,
    );
    await service.resumeShortcut();
    expect(controller.screenshotShortcut.key, PhysicalKeyboardKey.f8);
    expect(hotKeyManager.registeredHotKeyList, hasLength(1));
  });
}
