import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:local_notifier/local_notifier.dart';

import 'reminder_service.dart';

/// Windows 系统 Toast 触达通道，基于 `local_notifier`（WinToast）。
///
/// 未打包的应用需要在开始菜单注册带 AppUserModelID 的快捷方式才能显示
/// Toast，`LocalNotifier.setup` 默认会创建，失败时静默降级。
class WindowsToastReminderSink implements ReminderSink {
  WindowsToastReminderSink({
    this.appName = 'Idreaml Clip',
    this.onOpen,
    bool Function()? available,
  }) : _available = available ?? (() => Platform.isWindows);

  final String appName;

  /// 点击通知后的动作，通常是聚焦主窗口并打开待办页。
  final Future<void> Function()? onOpen;
  final bool Function() _available;

  /// local_notifier 的 LocalNotification 会把自己注册到全局监听列表，
  /// 这里保留有限条数并及时注销，避免长时间运行后监听列表无限增长。
  final _pending = <LocalNotification>[];
  static const int _pendingMax = 20;

  bool _ready = false;
  bool _failed = false;

  Future<bool> _ensureReady() async {
    if (_ready) return true;
    if (_failed || !_available()) return false;
    try {
      await LocalNotifier.instance.setup(appName: appName);
      _ready = true;
      return true;
    } catch (error) {
      _failed = true;
      debugPrint('系统通知初始化失败：$error');
      return false;
    }
  }

  @override
  Future<void> show(ReminderAlert alert) async {
    if (!await _ensureReady()) return;
    try {
      final notification = LocalNotification(
        title: alert.title,
        body: alert.body,
      );
      notification
        ..onClick = () {
          _forget(notification);
          unawaited(_open());
        }
        ..onClose = (_) => _forget(notification);
      _pending.add(notification);
      if (_pending.length > _pendingMax) _forget(_pending.first);
      await notification.show();
    } catch (error) {
      debugPrint('发送系统通知失败：$error');
    }
  }

  /// 点击通知后打开待办页；失败时保持当前窗口状态即可。
  Future<void> _open() async {
    final open = onOpen;
    if (open == null) return;
    try {
      await open();
    } catch (error) {
      debugPrint('打开待办页失败：$error');
    }
  }

  void _forget(LocalNotification notification) {
    _pending.remove(notification);
    LocalNotifier.instance.removeListener(notification);
  }

  void dispose() {
    for (final notification in [..._pending]) {
      _forget(notification);
    }
  }
}
