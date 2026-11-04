import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/services/restoring_quick_paste_target.dart';
import 'package:idreaml_clip/src/services/windows_automation_focus.dart';
import 'package:idreaml_clip/src/services/windows_quick_paste_service.dart';

void main() {
  for (final windowClass in [
    'CustomChatWindow',
    'Qt6QWindowIcon',
    'Chrome_WidgetWin_1',
    'SunAwtFrame',
    'OpusApp',
    'XLMAIN',
    'MozillaWindowClass',
    'CASCADIA_HOSTING_WINDOW_CLASS',
  ]) {
    testWidgets('$windowClass routes one paste without requiring UIA', (
      tester,
    ) async {
      final capture = FakeCapture(windowClass);
      final service = WindowsQuickPasteService.withCapture((_) => capture);
      final target = await service.captureTarget();
      expect(target, isNotNull);
      expect(capture.automationCalls, 0);
      final pasted = target!.paste(clipboardSequence: 7);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 20));
      expect(await pasted, isTrue);
      expect(capture.input.events, ['activate', 'restore', 'paste']);
      expect(await target.paste(clipboardSequence: 7), isFalse);
    });
  }

  test('missing native focus still has no paste target', () async {
    final service = WindowsQuickPasteService.withCapture((_) => null);
    expect(await service.captureTarget(), isNull);
  });

  test('desktop and taskbar do not receive automatic paste', () async {
    for (final windowClass in [
      'Progman',
      'WorkerW',
      'Shell_TrayWnd',
      'Shell_SecondaryTrayWnd',
    ]) {
      final capture = FakeCapture(windowClass);
      final service = WindowsQuickPasteService.withCapture((_) => capture);
      expect(await service.captureTarget(), isNull);
      expect(capture.automationCalls, 0);
      expect(capture.input.events, isEmpty);
    }
  });

  test('Explorer folder view does not become a generic paste target', () async {
    final capture = FakeCapture('CabinetWClass');
    final service = WindowsQuickPasteService.withCapture((_) => capture);
    expect(await service.captureTarget(), isNull);
    expect(capture.automationCalls, 1);
  });

  testWidgets('Explorer editor retains its saved focus and selection', (
    tester,
  ) async {
    const focus = WindowsAutomationFocus([
      'address-editor',
    ], AutomationTextSelection('draft', 'dr', 'a'));
    final capture = FakeCapture('CabinetWClass')
      ..automation = Future.value(const WindowsAutomationCapture(true, focus));
    final target = await WindowsQuickPasteService.withCapture((_) => capture)
        .captureTarget();
    expect(target, isNotNull);
    expect(capture.savedFocus, same(focus));
    final pasted = target!.paste(clipboardSequence: 7);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 20));
    expect(await pasted, isTrue);
    expect(capture.input.events, ['activate', 'restore', 'paste']);
  });

  testWidgets('unresponsive Explorer UIA does not allow folder paste', (
    tester,
  ) async {
    final capture = FakeCapture('ExploreWClass')
      ..automation = Completer<WindowsAutomationCapture>().future;
    final target = WindowsQuickPasteService.withCapture((_) => capture)
        .captureTarget();
    await tester.pump(const Duration(milliseconds: 650));
    expect(await target, isNull);
  });

  testWidgets('timed out Explorer provider cannot accumulate workers', (
    tester,
  ) async {
    final probe = Completer<WindowsAutomationCapture>();
    final capture = FakeCapture('CabinetWClass')..automation = probe.future;
    final service = WindowsQuickPasteService.withCapture((_) => capture);
    final first = service.captureTarget();
    await tester.pump(const Duration(milliseconds: 650));
    expect(await first, isNull);
    expect(await service.captureTarget(), isNull);
    expect(capture.automationCalls, 1);

    probe.complete(const WindowsAutomationCapture(true, null));
    await tester.pump();
    expect(await service.captureTarget(), isNotNull);
    expect(capture.automationCalls, 2);
  });

  test('Explorer UIA error leaves automatic paste disabled', () async {
    final capture = FakeCapture('CabinetWClass')..automationThrows = true;
    final service = WindowsQuickPasteService.withCapture((_) => capture);
    expect(await service.captureTarget(), isNull);
  });

  test('switching apps during capture cancels the captured target', () async {
    final pending = Completer<WindowsAutomationCapture>();
    final capture = FakeCapture('CabinetWClass')..automation = pending.future;
    final target = WindowsQuickPasteService.withCapture((_) => capture)
        .captureTarget();
    capture.foreground = false;
    pending.complete(const WindowsAutomationCapture(true, null));
    expect(await target, isNull);
    expect(capture.input.events, isEmpty);
  });

  test('custom editor still cancels if clipboard was replaced', () async {
    final capture = FakeCapture('CustomChatWindow');
    final target = await WindowsQuickPasteService.withCapture((_) => capture)
        .captureTarget();
    capture.input.clipboardSequence = 8;
    expect(await target!.paste(clipboardSequence: 7), isFalse);
    expect(capture.input.events, isEmpty);
  });

  test('custom editor still cancels after the user switches apps', () async {
    final capture = FakeCapture('CustomChatWindow');
    final target = await WindowsQuickPasteService.withCapture((_) => capture)
        .captureTarget();
    capture.input.canActivate = false;
    expect(await target!.paste(clipboardSequence: 7), isFalse);
    expect(capture.input.events, isEmpty);
  });
}

class FakeCapture implements WindowsPasteCapture {
  FakeCapture(this.windowClass);
  @override
  final String windowClass;
  @override
  bool foreground = true;
  int automationCalls = 0;
  bool automationThrows = false;
  Future<WindowsAutomationCapture> automation = Future.value(
    const WindowsAutomationCapture(false, null),
  );
  WindowsAutomationFocus? savedFocus;
  final input = FakeRestoration();

  @override
  Future<WindowsAutomationCapture> captureAutomation() {
    automationCalls++;
    if (automationThrows) throw StateError('provider unavailable');
    return automation;
  }

  @override
  QuickPasteRestoration restoration(
    WindowsAutomationFocus? automation,
    void Function(String)? trace,
  ) {
    savedFocus = automation;
    return input;
  }
}

class FakeRestoration implements QuickPasteRestoration {
  final events = <String>[];
  @override
  bool valid = true;
  @override
  bool canActivate = true;
  @override
  bool foreground = true;
  @override
  bool focused = true;
  @override
  bool keysReleased = true;
  @override
  int clipboardSequence = 7;

  @override
  void activate() => events.add('activate');
  @override
  Future<bool> restoreFocus() async {
    events.add('restore');
    return true;
  }

  @override
  bool sendPaste() {
    events.add('paste');
    return true;
  }
}
