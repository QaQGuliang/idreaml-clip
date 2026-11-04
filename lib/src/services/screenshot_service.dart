import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../app_controller.dart';
import '../models/clipboard_content.dart';
import '../models/pinned_image_border.dart';
import '../models/quick_shortcut.dart';
import 'async_gate.dart';
import 'clipboard_image_codec.dart';
import 'shortcut_availability.dart' as availability;

class ScreenshotService {
  ScreenshotService(
    this.controller, {
    bool? supported,
    bool Function(QuickShortcut)? canRegisterShortcut,
  }) : supported = supported ?? Platform.isWindows,
       _canRegisterShortcut =
           canRegisterShortcut ?? availability.canRegisterShortcut;
  final AppController controller;
  static const channel = MethodChannel('idreaml_clip/screenshot');
  final bool supported;
  final bool Function(QuickShortcut) _canRegisterShortcut;
  final _borderWrites = AsyncGate();
  bool _initialized = false;
  bool active = false;
  bool _suspended = false;
  bool _savingShortcut = false;
  bool _committing = false;
  bool _disposed = false;
  HotKey? _shortcut;
  String? _session;
  Uint8List? _pendingPng;
  String? _savedPath;
  bool _saveMode = false;
  bool _pinned = false;
  Future<void>? _commitFinished;
  String _styles = '{}';

  Future<void> initialize() async {
    if (!supported) return;
    _initialized = true;
    channel.setMethodCallHandler(_handle);
    _styles =
        await controller.repository.getSetting('screenshot_styles') ?? '{}';
    await channel.invokeMethod<void>(
      'setPinBorderDefault',
      controller.pinnedImageBorder.name,
    );
    await resumeShortcut();
  }

  Future<void> savePinBorderDefault(PinnedImageBorder border) =>
      _borderWrites.run(() async {
        await controller.savePinnedImageBorder(border);
        await channel.invokeMethod<void>('setPinBorderDefault', border.name);
      });

  Future<void> warmUp() async {
    if (!supported || _disposed) return;
    try {
      await channel.invokeMethod<void>('warmUp');
    } on Object {
      // A failed prewarm is retried lazily when the user starts a capture.
    }
  }

  void _onHotKey(HotKey key) {
    if (!_disposed && !_suspended && key.identifier == _shortcut?.identifier) {
      unawaited(start());
    }
  }

  Future<void> start({
    Offset? buttonPoint,
    Future<void> Function()? hidePanel,
  }) async {
    if (!supported || active || _disposed || _suspended) return;
    active = true;
    _session = const Uuid().v4();
    _pendingPng = null;
    _savedPath = null;
    _saveMode = false;
    _pinned = false;
    try {
      await channel.invokeMethod<void>('prepare', {
        if (buttonPoint != null) 'x': buttonPoint.dx,
        if (buttonPoint != null) 'y': buttonPoint.dy,
      });
      if (hidePanel != null) await hidePanel();
      await channel.invokeMethod<void>('open', {
        'styles': _styles,
        'showColorPicker': controller.showScreenshotColorPicker,
      });
      controller.setScreenshotError(null);
    } on Object {
      active = false;
      _session = null;
      controller.setScreenshotError('截图启动失败，请重试；若快捷键被占用，可在设置中修改');
    }
  }

  Future<Object?> _handle(MethodCall call) async {
    if (call.method == 'savePinBorderDefault' && !_disposed) {
      final border = PinnedImageBorder.tryParse(call.arguments as String?);
      if (border == null) {
        throw PlatformException(code: 'border', message: '未知的贴图边框样式');
      }
      await savePinBorderDefault(border);
      return null;
    }
    if (call.method == 'copyPinnedImage' && !_disposed) {
      final png = call.arguments as Uint8List;
      await controller.clipboard.write(
        ClipboardContent.image(png, 'image/png'),
      );
      return null;
    }
    if (call.method == 'copyColor' && active && !_disposed) {
      final hex = (call.arguments as Map)['hex'] as String;
      await controller.clipboard.write(ClipboardContent.text(hex));
      return null;
    }
    if (call.method == 'closed') {
      final session = _session;
      try {
        await _commitFinished;
        if (session != null) await controller.releaseScreenshot(session);
      } finally {
        active = false;
        _session = null;
        _pendingPng = null;
        _savedPath = null;
      }
      return null;
    }
    if (call.method == 'styles') {
      final styles = call.arguments as String;
      _styles = styles;
      await controller.repository.setSetting('screenshot_styles', styles);
      return null;
    }
    if (call.method != 'commit' || !active || _session == null || _disposed) {
      throw PlatformException(code: 'state', message: '截图会话已结束');
    }
    if (_committing) return {'error': '正在完成截图，请稍候', 'locked': true};
    _committing = true;
    final done = Completer<void>();
    _commitFinished = done.future;
    try {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      _pendingPng ??= args['png'] as Uint8List;
      final png = _pendingPng!;
      if (png.length > maxClipboardImageBytes ||
          imageMimeType(png) != 'image/png') {
        throw const FormatException('截图无法输出，请缩小选区后重试');
      }
      final image = ClipboardContent.image(png, 'image/png');
      if (_pinned ||
          (args['pin'] == true &&
              _savedPath == null &&
              !controller.screenshotWasCopied(_session!))) {
        if (!_pinned) {
          await channel.invokeMethod<void>('pinImage', {
            'png': png,
            'x': args['x'],
            'y': args['y'],
          });
          _pinned = true;
        }
        await controller.recordScreenshot(_session!, image);
        return {'success': true};
      }
      if (_savedPath == null && !controller.screenshotWasCopied(_session!)) {
        _saveMode = args['saveAs'] == true;
      }
      if (_saveMode && _savedPath == null) {
        final lastDirectory = await controller.repository.getSetting(
          'screenshot_directory',
        );
        final now = DateTime.now()
            .toIso8601String()
            .split('.')
            .first
            .replaceAll(':', '-');
        final path = await channel.invokeMethod<String>('chooseSavePath', {
          'name': '截图-$now.png',
          'directory': lastDirectory ?? '',
        });
        if (path == null) {
          _pendingPng = null;
          return {'cancelled': true};
        }
        if (p.extension(path).toLowerCase() != '.png') {
          throw const FormatException('请使用 .png 文件名保存截图');
        }
        // Rename a fully flushed sibling file so failure preserves an existing file.
        final temporary = File('$path.${const Uuid().v4()}.tmp');
        try {
          await temporary.writeAsBytes(png, flush: true);
          await temporary.rename(path);
          _savedPath = path;
        } finally {
          if (await temporary.exists()) await temporary.delete();
        }
        // A preference failure must not undo or repeat a successful export.
        try {
          await controller.repository.setSetting(
            'screenshot_directory',
            p.dirname(path),
          );
        } on Object {
          /* The exported image remains valid. */
        }
      }
      await controller.commitScreenshot(_session!, image);
      return {'success': true};
    } on Object catch (error) {
      final copied =
          _session != null && controller.screenshotWasCopied(_session!);
      final locked = _savedPath != null || copied || _pinned;
      if (!locked) _pendingPng = null;
      final prefix = [
        if (_pinned) '贴图已显示',
        if (_savedPath != null) '副本已保存',
        if (copied) '图片已复制',
      ].join('，');
      final detail = error is PlatformException
          ? error.message
          : error is FormatException
          ? error.message
          : '操作失败，请重试';
      return {
        'error': '${prefix.isEmpty ? '' : '$prefix；'}$detail',
        'locked': locked,
      };
    } finally {
      _committing = false;
      done.complete();
    }
  }

  Future<void> suspendShortcut() async {
    _suspended = true;
    final shortcut = _shortcut;
    if (shortcut != null) {
      await hotKeyManager.unregister(shortcut);
      _shortcut = null;
    }
  }

  Future<void> resumeShortcut() async {
    _suspended = false;
    if (!_initialized || !supported || _disposed || _shortcut != null) return;
    try {
      if (!_canRegisterShortcut(controller.screenshotShortcut)) {
        throw StateError('unavailable');
      }
      final hotKey = controller.screenshotShortcut.toHotKey();
      await hotKeyManager.register(hotKey, keyDownHandler: _onHotKey);
      _shortcut = hotKey;
      controller.setScreenshotError(null);
    } on Object {
      controller.setScreenshotError('截图快捷键被占用或注册失败，请修改；截图按钮仍可使用');
    }
  }

  Future<String?> updateShortcut(QuickShortcut shortcut) async {
    if (_savingShortcut) return '正在保存快捷键，请稍候';
    if (!shortcut.isValid) return '系统不支持这个按键，请重新录入';
    if (shortcut.sameCombination(controller.quickShortcut) ||
        (shortcut.meta &&
            !shortcut.control &&
            !shortcut.alt &&
            !shortcut.shift &&
            shortcut.key == PhysicalKeyboardKey.keyV)) {
      return '该组合已用于快捷剪切板';
    }
    if (_shortcut != null &&
        shortcut.sameCombination(controller.screenshotShortcut)) {
      return null;
    }
    _savingShortcut = true;
    HotKey? replacement;
    try {
      if (!_canRegisterShortcut(shortcut)) return '该快捷键已被占用或被系统保留';
      replacement = shortcut.toHotKey();
      await hotKeyManager.register(replacement, keyDownHandler: _onHotKey);
      await controller.saveScreenshotShortcut(shortcut);
      final old = _shortcut;
      _shortcut = replacement;
      replacement = null;
      if (old != null) {
        try {
          await hotKeyManager.unregister(old);
        } on Object {
          controller.setScreenshotError('新截图快捷键已生效，旧注册将在重启后释放');
        }
      }
      return null;
    } on Object {
      if (replacement != null) await hotKeyManager.unregister(replacement);
      return '截图快捷键保存失败，请重试';
    } finally {
      _savingShortcut = false;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    if (active) await channel.invokeMethod<void>('close');
    await _commitFinished;
    await suspendShortcut();
    channel.setMethodCallHandler(null);
  }
}
