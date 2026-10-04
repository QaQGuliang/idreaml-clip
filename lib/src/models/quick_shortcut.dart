import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:uni_platform/uni_platform.dart';

class QuickShortcut {
  const QuickShortcut({
    this.key = PhysicalKeyboardKey.keyV,
    this.control = false,
    this.alt = false,
    this.shift = false,
    this.meta = false,
  });

  final PhysicalKeyboardKey key;
  final bool control;
  final bool alt;
  final bool shift;
  final bool meta;

  static QuickShortcut platformDefault([String? platform]) =>
      switch (platform ?? Platform.operatingSystem) {
        'macos' => const QuickShortcut(control: true, alt: true),
        'linux' => const QuickShortcut(control: true, alt: true),
        _ => const QuickShortcut(control: true, shift: true),
      };

  static const modifierKeys = <PhysicalKeyboardKey>[
    PhysicalKeyboardKey.controlLeft,
    PhysicalKeyboardKey.controlRight,
    PhysicalKeyboardKey.altLeft,
    PhysicalKeyboardKey.altRight,
    PhysicalKeyboardKey.shiftLeft,
    PhysicalKeyboardKey.shiftRight,
    PhysicalKeyboardKey.metaLeft,
    PhysicalKeyboardKey.metaRight,
    PhysicalKeyboardKey.fn,
    PhysicalKeyboardKey.fnLock,
  ];

  /// Use the same native key mapping as hotkey_manager, including punctuation,
  /// arrows, navigation, numpad and function keys instead of a dropdown whitelist.
  bool get isValid => !modifierKeys.contains(key) && key.keyCode != null;

  factory QuickShortcut.fromPressedKeys(
    PhysicalKeyboardKey key,
    Set<PhysicalKeyboardKey> pressed,
  ) => QuickShortcut(
    key: key,
    control:
        pressed.contains(PhysicalKeyboardKey.controlLeft) ||
        pressed.contains(PhysicalKeyboardKey.controlRight),
    alt:
        pressed.contains(PhysicalKeyboardKey.altLeft) ||
        pressed.contains(PhysicalKeyboardKey.altRight),
    shift:
        pressed.contains(PhysicalKeyboardKey.shiftLeft) ||
        pressed.contains(PhysicalKeyboardKey.shiftRight),
    meta:
        pressed.contains(PhysicalKeyboardKey.metaLeft) ||
        pressed.contains(PhysicalKeyboardKey.metaRight),
  );

  static String keyName(PhysicalKeyboardKey key) => switch (key) {
    PhysicalKeyboardKey.enter => 'Enter',
    PhysicalKeyboardKey.escape => 'Esc',
    PhysicalKeyboardKey.tab => 'Tab',
    PhysicalKeyboardKey.space => 'Space',
    PhysicalKeyboardKey.backspace => 'Backspace',
    PhysicalKeyboardKey.delete => 'Delete',
    PhysicalKeyboardKey.home => 'Home',
    PhysicalKeyboardKey.end => 'End',
    PhysicalKeyboardKey.pageUp => 'Page Up',
    PhysicalKeyboardKey.pageDown => 'Page Down',
    _ => key.keyLabel,
  };

  String label([String? platform]) {
    final mac = (platform ?? Platform.operatingSystem) == 'macos';
    return [
      if (control) mac ? 'Control' : 'Ctrl',
      if (alt) mac ? 'Option' : 'Alt',
      if (shift) 'Shift',
      if (meta) mac ? 'Command' : 'Win',
      keyName(key),
    ].join(' + ');
  }

  HotKey toHotKey() => HotKey(
    key: key,
    modifiers: [
      if (control) HotKeyModifier.control,
      if (alt) HotKeyModifier.alt,
      if (shift) HotKeyModifier.shift,
      if (meta) HotKeyModifier.meta,
    ],
    scope: HotKeyScope.system,
  );

  String encode() => jsonEncode({
    'key': key.usbHidUsage,
    'control': control,
    'alt': alt,
    'shift': shift,
    'meta': meta,
  });

  static QuickShortcut decode(String? value) {
    try {
      final data = jsonDecode(value ?? '') as Map<String, dynamic>;
      final key = PhysicalKeyboardKey.findKeyByCode(data['key'] as int);
      if (key == null) return platformDefault();
      final shortcut = QuickShortcut(
        key: key,
        control: data['control'] == true,
        alt: data['alt'] == true,
        shift: data['shift'] == true,
        meta: data['meta'] == true,
      );
      return shortcut.isValid ? shortcut : platformDefault();
    } on Object {
      return platformDefault();
    }
  }

  bool sameCombination(QuickShortcut other) => encode() == other.encode();

  int get windowsVirtualKey => key.keyCode!;
}
