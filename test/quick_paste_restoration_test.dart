import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/services/restoring_quick_paste_target.dart';

void main() {
  test('recognizes an AWT focus owner without accepting arbitrary windows', () {
    expect(isJavaPasteWindow('SunAwtFrame', 'SunAwtCanvas'), isTrue);
    expect(isJavaPasteWindow('SunAwtFrame', 'SunAwtFrame'), isTrue);
    expect(isJavaPasteWindow('SunAwtDialog', 'SunAwtWindow'), isTrue);
    expect(isJavaPasteWindow('CabinetWClass', 'DirectUIHWND'), isFalse);
    expect(isJavaPasteWindow('SunAwtFrame', 'Button'), isFalse);
  });

  testWidgets('restores the input before sending exactly one paste', (
    tester,
  ) async {
    final native = FakeRestoration();
    final target = RestoringQuickPasteTarget(native);
    final result = target.paste(clipboardSequence: 7);
    await tester.pump();
    expect(native.events, ['activate', 'restore']);
    await tester.pump(const Duration(milliseconds: 20));
    expect(native.events, ['activate', 'restore']);
    await tester.pump(const Duration(milliseconds: 20));
    expect(await result, isTrue);
    expect(native.events, ['activate', 'restore', 'paste']);
    expect(await target.paste(clipboardSequence: 7), isFalse);
  });

  testWidgets('waits for shortcut modifiers before restoring focus', (
    tester,
  ) async {
    final native = FakeRestoration()..keysReleased = false;
    final result = RestoringQuickPasteTarget(native)
        .paste(clipboardSequence: 7);
    await tester.pump(const Duration(milliseconds: 40));
    expect(native.events, isEmpty);
    native.keysReleased = true;
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 20));
    expect(await result, isTrue);
  });

  testWidgets('does not paste when the input cannot be restored', (
    tester,
  ) async {
    final native = FakeRestoration()..restorable = false;
    expect(
      await RestoringQuickPasteTarget(native).paste(clipboardSequence: 7),
      isFalse,
    );
    expect(native.events, ['activate', 'restore']);
  });

  testWidgets('does not paste after the user switches to another app', (
    tester,
  ) async {
    final native = FakeRestoration();
    final result = RestoringQuickPasteTarget(native)
        .paste(clipboardSequence: 7);
    await tester.pump();
    native.foreground = false;
    native.canActivate = false;
    await tester.pump(const Duration(milliseconds: 20));
    expect(await result, isFalse);
    expect(native.events, isNot(contains('paste')));
  });

  testWidgets('changed clipboard aborts after asynchronous focus restoration', (
    tester,
  ) async {
    final pending = Completer<bool>();
    final native = FakeRestoration()..restoration = pending.future;
    final result = RestoringQuickPasteTarget(native)
        .paste(clipboardSequence: 7);
    await tester.pump();
    native.clipboardSequence = 8;
    pending.complete(true);
    await tester.pump();
    expect(await result, isFalse);
    expect(native.events, isNot(contains('paste')));
  });

  testWidgets('closed or replaced target aborts while modifiers are held', (
    tester,
  ) async {
    final native = FakeRestoration()..keysReleased = false;
    final result = RestoringQuickPasteTarget(native)
        .paste(clipboardSequence: 7);
    native.valid = false;
    await tester.pump(const Duration(milliseconds: 20));
    expect(await result, isFalse);
    expect(native.events, isEmpty);
  });

  testWidgets('waits for asynchronous editor focus without pasting twice', (
    tester,
  ) async {
    final native = FakeRestoration()..focused = false;
    final result = RestoringQuickPasteTarget(native)
        .paste(clipboardSequence: 7);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(native.events, isNot(contains('paste')));
    native.focused = true;
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(await result, isTrue);
    expect(native.events.where((event) => event == 'paste'), hasLength(1));
  });

  testWidgets('restoration timeout leaves clipboard available without input', (
    tester,
  ) async {
    final native = FakeRestoration()..focused = false;
    final result = RestoringQuickPasteTarget(native)
        .paste(clipboardSequence: 7);
    await tester.pump();
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(await result, isFalse);
    expect(native.clipboardSequence, 7);
    expect(native.events, isNot(contains('paste')));
  });
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
  bool restorable = true;
  Future<bool>? restoration;

  @override
  void activate() => events.add('activate');
  @override
  Future<bool> restoreFocus() async {
    events.add('restore');
    return restoration ?? restorable;
  }

  @override
  bool sendPaste() {
    events.add('paste');
    return true;
  }
}
