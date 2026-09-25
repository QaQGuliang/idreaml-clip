import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/models/quick_shortcut.dart';

void main() {
  test('各平台默认组合与显示名称', () {
    expect(
      QuickShortcut.platformDefault('windows').label('windows'),
      'Ctrl + Shift + V',
    );
    expect(
      QuickShortcut.platformDefault('macos').label('macos'),
      'Control + Option + V',
    );
    expect(
      QuickShortcut.platformDefault('linux').label('linux'),
      'Ctrl + Alt + V',
    );
  });
  test('自定义快捷键可持久化，非法数据回退默认值', () {
    const shortcut = QuickShortcut(
      key: PhysicalKeyboardKey.keyJ,
      alt: true,
      shift: true,
    );
    expect(
      QuickShortcut.decode(shortcut.encode()).sameCombination(shortcut),
      isTrue,
    );
    expect(
      QuickShortcut.decode('broken')
          .sameCombination(QuickShortcut.platformDefault()),
      isTrue,
    );
    expect(const QuickShortcut(shift: true).isValid, isTrue);
    expect(
      const QuickShortcut(
        key: PhysicalKeyboardKey.escape,
        control: true,
      ).isValid,
      isTrue,
    );
    if (Platform.isWindows) {
      expect(
        const QuickShortcut(
          key: PhysicalKeyboardKey.keyF,
          control: true,
        ).windowsVirtualKey,
        0x46,
      );
      expect(
        const QuickShortcut(
          key: PhysicalKeyboardKey.f12,
          alt: true,
        ).windowsVirtualKey,
        0x7b,
      );
    }
  });

  test('从按键状态完整重建组合，不保留旧修饰键或主键', () {
    final shortcut = QuickShortcut.fromPressedKeys(PhysicalKeyboardKey.keyQ, {
      PhysicalKeyboardKey.altRight,
      PhysicalKeyboardKey.keyQ,
    });
    expect(shortcut.label('windows'), 'Alt + Q');
    expect(shortcut.control, isFalse);
    expect(shortcut.shift, isFalse);
    expect(shortcut.isValid, isTrue);
    final win = QuickShortcut.fromPressedKeys(PhysicalKeyboardKey.period, {
      PhysicalKeyboardKey.metaLeft,
      PhysicalKeyboardKey.shiftRight,
      PhysicalKeyboardKey.period,
    });
    expect(win.label('windows'), 'Shift + Win + .');
    if (Platform.isWindows) expect(win.windowsVirtualKey, 0xbe);
  });

  test('支持标点、方向键和独立功能键，纯修饰键不作为主键', () {
    for (final key in [
      PhysicalKeyboardKey.f8,
      PhysicalKeyboardKey.arrowUp,
      PhysicalKeyboardKey.tab,
      PhysicalKeyboardKey.slash,
      PhysicalKeyboardKey.numpad1,
    ]) {
      final shortcut = QuickShortcut(key: key);
      expect(shortcut.isValid, isTrue, reason: key.debugName);
      expect(
        QuickShortcut.decode(shortcut.encode()).sameCombination(shortcut),
        isTrue,
      );
    }
    expect(
      const QuickShortcut(key: PhysicalKeyboardKey.controlLeft).isValid,
      isFalse,
    );
    expect(const QuickShortcut(key: PhysicalKeyboardKey.fn).isValid, isFalse);
  });
}
