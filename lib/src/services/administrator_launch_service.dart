import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../data/clipboard_repository.dart';

class AdministratorRestartOptions {
  const AdministratorRestartOptions({this.parentId, this.locatorPath});
  final int? parentId;
  final String? locatorPath;

  factory AdministratorRestartOptions.parse(List<String> arguments) {
    int? parent;
    String? locator;
    for (final argument in arguments) {
      if (argument.startsWith('--administrator-parent-pid=')) {
        final value = int.tryParse(
          argument.substring('--administrator-parent-pid='.length),
        );
        if (parent != null ||
            value == null ||
            value <= 0 ||
            value > 0xffffffff) {
          throw const FormatException('管理员重启的原进程标识无效。');
        }
        parent = value;
      } else if (argument.startsWith('--storage-locator=')) {
        final value = argument.substring('--storage-locator='.length);
        if (locator != null || !p.isAbsolute(value)) {
          throw const FormatException('管理员重启的数据目录配置路径无效。');
        }
        locator = value;
      }
    }
    return AdministratorRestartOptions(parentId: parent, locatorPath: locator);
  }
}

abstract interface class AdministratorPlatform {
  bool get supported;
  Future<bool> isElevated();
  Future<void> restartElevated({String? locatorPath});
  Future<void> waitForParentExit(int parentId);
}

class WindowsAdministratorPlatform implements AdministratorPlatform {
  static const channel = MethodChannel('idreaml_clip/administrator');
  @override
  bool get supported => Platform.isWindows;
  @override
  Future<bool> isElevated() async =>
      await channel.invokeMethod<bool>('isElevated') ?? false;
  @override
  Future<void> restartElevated({String? locatorPath}) =>
      channel.invokeMethod<void>('restartElevated', locatorPath);
  @override
  Future<void> waitForParentExit(int parentId) =>
      channel.invokeMethod<void>('waitForParentExit', parentId);
}

class AdministratorLaunchService {
  AdministratorLaunchService(this.repository, {AdministratorPlatform? platform})
    : platform = platform ?? WindowsAdministratorPlatform();

  static const settingKey = 'run_as_administrator';
  final ClipboardRepository repository;
  final AdministratorPlatform platform;
  bool enabled = false;
  bool elevated = false;
  bool changing = false;
  bool initialized = false;
  String? message;
  bool get supported => platform.supported;

  /// Returns true only after Windows accepted an elevated replacement. The
  /// caller then closes SQLite/plugins and exits, releasing the instance lock.
  Future<bool> initialize({bool requestRestart = true}) async {
    if (initialized) return false;
    initialized = true;
    if (!supported) return false;
    enabled = await repository.getSetting(settingKey) == 'true';
    try {
      elevated = await platform.isElevated();
      if (requestRestart && enabled && !elevated) {
        await platform.restartElevated(
          locatorPath: repository.storage?.locatorPath,
        );
        return true;
      }
    } catch (error) {
      message = _cancelled(error)
          ? '本次管理员授权已取消，继续以普通身份运行；下次启动仍会请求授权。'
          : '管理员启动失败，已继续运行。可关闭开关后重试。';
    }
    return false;
  }

  Future<bool> setEnabled(bool value) async {
    if (!supported) throw UnsupportedError('仅 Windows 支持管理员启动。');
    if (changing) throw StateError('正在切换启动权限，请稍候。');
    changing = true;
    final previous = enabled;
    message = null;
    try {
      elevated = await platform.isElevated();
      await repository.setSetting(settingKey, '$value');
      enabled = value;
      if (value && !elevated) {
        try {
          await platform.restartElevated(
            locatorPath: repository.storage?.locatorPath,
          );
          return true;
        } catch (error) {
          try {
            await repository.setSetting(settingKey, '$previous');
            enabled = previous;
          } catch (_) {
            message = '管理员重启未完成，还原开关失败。请关闭开关后重试。';
            return false;
          }
          message = _cancelled(error)
              ? '管理员授权已取消，已保留原设置并继续运行。'
              : '无法以管理员身份重启，已保留原设置并继续运行。';
          return false;
        }
      }
      message = !value && elevated
          ? '已关闭默认管理员启动；当前进程仍为管理员，下次从桌面普通启动时生效。'
          : value
          ? '已保存，以后默认请求管理员权限。'
          : '已关闭默认管理员启动。';
      return false;
    } catch (_) {
      message = '无法保存管理员启动设置，请重试。';
      rethrow;
    } finally {
      changing = false;
    }
  }

  bool _cancelled(Object error) =>
      error is PlatformException && error.code == 'cancelled';
}
