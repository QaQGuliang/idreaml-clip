import 'dart:io';

import 'package:path/path.dart' as path;

import 'startup_service.dart';
import 'windows_startup_link.dart';
import 'windows_startup_service.dart';
import 'windows_startup_store.dart';

/// Startup-folder registration replaces the legacy Run value. The preference
/// is migration intent only, never evidence that Windows has a launch entry.
class WindowsFolderStartupService implements StartupService {
  WindowsFolderStartupService({
    WindowsStartupStore? registry,
    WindowsStartupLinkStore? links,
    String? executable,
    bool Function(String)? exists,
    Future<void> Function()? settle,
  }) : _registry = registry ?? WindowsRegistryStartupStore(),
       _links = links ?? WindowsStartupLinkFile(),
       _executable = executable ?? Platform.resolvedExecutable,
       _exists = exists ?? ((value) => File(value).existsSync()),
       _settle =
           settle ??
           (() => Future<void>.delayed(const Duration(milliseconds: 900)));

  final WindowsStartupStore _registry;
  final WindowsStartupLinkStore _links;
  final String _executable;
  final bool Function(String) _exists;
  final Future<void> Function() _settle;

  bool _samePath(String? value, String expected) =>
      value != null &&
      path.windows.normalize(value).toLowerCase() ==
          path.windows.normalize(expected).toLowerCase();

  bool _commandTargets(String? command, String target) {
    if (command == null) return false;
    final value = command.trim();
    return _samePath(
      value.length >= 2 && value.startsWith('"') && value.endsWith('"')
          ? value.substring(1, value.length - 1)
          : value,
      target,
    );
  }

  bool _valid(StartupLink? link) =>
      link != null &&
      _samePath(link.target, _executable) &&
      link.arguments.isEmpty &&
      _samePath(link.workingDirectory, path.windows.dirname(_executable)) &&
      _exists(_executable);

  StartupState _state(
    WindowsStartupRegistration registration,
    StartupLink? link,
  ) {
    if (!registration.folderAllowed ||
        (link == null && !registration.allowed)) {
      return const StartupState(
        false,
        message: 'Windows 已禁用此启动项；在应用内重新开启可再次保存。',
      );
    }
    if (_valid(link)) return const StartupState(true);
    return StartupState(
      false,
      message: link != null
          ? '启动快捷方式与当前程序不一致，请重新开启。'
          : registration.owner != null ||
                registration.command != null ||
                registration.approval != null
          ? '开机启动项已丢失或被移除，请重新开启。'
          : null,
    );
  }

  void _validateExecutable() {
    if (!path.windows.isAbsolute(_executable) ||
        !_executable.toLowerCase().endsWith('.exe') ||
        _executable.contains(RegExp('["\r\n\x00]')) ||
        _executable.length > 259 ||
        !_exists(_executable)) {
      throw const StartupException('无法设置开机启动：当前程序路径不存在、无效或过长。');
    }
  }

  bool _sameBytes(List<int>? a, List<int>? b) => a?.join(',') == b?.join(',');

  Future<StartupState> _change(
    bool enabled,
    WindowsStartupRegistration before,
    StartupLink? previous, {
    bool preserveApproval = false,
  }) async {
    if (enabled) _validateExecutable();
    final next = enabled
        ? WindowsStartupRegistration(
            owner: _executable,
            folderApproval: preserveApproval
                ? before.folderApproval
                : [2, ...List.filled(11, 0)],
          )
        : const WindowsStartupRegistration();
    try {
      if (enabled) {
        _links.save(_executable);
      } else {
        _links.restore(null);
      }
      // Remove the legacy Run command and its marker: a single launch source.
      _registry.write(next);
      void verify() {
        final actual = _registry.read();
        final link = _links.read();
        final registryMatches = enabled
            ? actual.command == null &&
                  actual.approval == null &&
                  actual.owner == _executable &&
                  actual.folderAllowed
            : actual.sameAs(next);
        if (!registryMatches || (enabled ? !_valid(link) : link != null)) {
          throw const StartupException('开机启动项保存后被更改或移除，未能启用。请检查系统的启动管理设置。');
        }
      }

      verify();
      await _settle();
      verify();
      return StartupState(enabled);
    } catch (error) {
      try {
        _links.restore(previous?.bytes);
        _registry.write(before);
        if (!_registry.read().sameAs(before) ||
            !_sameBytes(_links.read()?.bytes, previous?.bytes)) {
          throw StateError('startup rollback verification');
        }
      } catch (_) {
        throw const StartupException('开机启动设置失败，原设置未能完整恢复。请检查系统的启动管理设置。');
      }
      if (error is StartupException) rethrow;
      throw const StartupException('无法保存开机启动快捷方式，已恢复原设置。');
    }
  }

  @override
  Future<StartupState> initialize() async {
    final registration = _registry.read();
    final link = _links.read();
    if (_valid(link)) return _state(registration, link);
    if (!registration.allowed || !registration.folderAllowed) {
      return _state(registration, link);
    }
    final owner = registration.owner;
    final legacyCurrent = _commandTargets(registration.command, _executable);
    final ownedIntent =
        owner != null &&
        (_samePath(owner, _executable) || !_exists(owner)) &&
        (registration.command == null ||
            _commandTargets(registration.command, owner));
    final mayReplaceLink =
        link == null ||
        (link.arguments.isEmpty &&
            owner != null &&
            _samePath(link.target, owner));
    if ((legacyCurrent || ownedIntent) && mayReplaceLink) {
      return _change(true, registration, link, preserveApproval: true);
    }
    return _state(registration, link);
  }

  @override
  Future<StartupState> read() async => _state(_registry.read(), _links.read());

  @override
  Future<StartupState> setEnabled(bool value) =>
      _change(value, _registry.read(), _links.read());
}
