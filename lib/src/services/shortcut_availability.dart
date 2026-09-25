import 'dart:io';

import 'package:win32/win32.dart';

import '../models/quick_shortcut.dart';

/// hotkey_manager_windows 0.2.0 does not propagate RegisterHotKey failures.
/// Probe with a temporary registration before asking the plugin to own it.
bool canRegisterShortcut(QuickShortcut shortcut) {
  if (!Platform.isWindows) return true;
  if (shortcut.windowsVirtualKey == 0x7b) {
    return false; // F12 is reserved by Windows.
  }
  const probeId = 0x4c43;
  final modifiers =
      (shortcut.control ? MOD_CONTROL : 0) |
      (shortcut.alt ? MOD_ALT : 0) |
      (shortcut.shift ? MOD_SHIFT : 0) |
      (shortcut.meta ? MOD_WIN : 0) |
      MOD_NOREPEAT;
  if (RegisterHotKey(0, probeId, modifiers, shortcut.windowsVirtualKey) == 0) {
    return false;
  }
  UnregisterHotKey(0, probeId);
  return true;
}
