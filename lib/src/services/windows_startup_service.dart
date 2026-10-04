import 'dart:io';

import 'package:path/path.dart' as path;

import 'startup_service.dart';
import 'windows_startup_store.dart';

class WindowsStartupRegistration {
  const WindowsStartupRegistration({
    this.command,
    this.approval,
    this.owner,
    this.folderApproval,
  });
  final String? command;
  final List<int>? approval;
  // An explicitly enabled executable, stored separately from Windows' Run key.
  // This is not inferred from an orphaned StartupApproved marker left by 1.0.3.
  final String? owner;
  final List<int>? folderApproval;

  static bool approvalAllows(List<int>? value) =>
      value == null || (value.length == 12 && (value[0] == 2 || value[0] == 6));

  bool get folderAllowed => approvalAllows(folderApproval);

  bool get allowed => approvalAllows(approval);

  bool sameAs(WindowsStartupRegistration other) =>
      command == other.command &&
      owner == other.owner &&
      folderApproval?.join(',') == other.folderApproval?.join(',') &&
      ((approval == null && other.approval == null) ||
          (approval != null &&
              other.approval != null &&
              approval!.join(',') == other.approval!.join(',')));
}

abstract interface class WindowsStartupStore {
  WindowsStartupRegistration read();
  void write(WindowsStartupRegistration value);
}

class WindowsStartupService implements StartupService {
  WindowsStartupService({
    WindowsStartupStore? store,
    String? executable,
    bool Function(String)? exists,
  }) : _store = store ?? WindowsRegistryStartupStore(),
       _executable = executable ?? Platform.resolvedExecutable,
       _exists = exists ?? ((value) => File(value).existsSync());

  final WindowsStartupStore _store;
  final String _executable;
  final bool Function(String) _exists;

  bool _samePath(String? a, String b) =>
      a != null &&
      path.windows.normalize(a).toLowerCase() ==
          path.windows.normalize(b).toLowerCase();

  bool _targets(String? command, String executable) {
    if (command == null) return false;
    final trimmed = command.trim();
    final unquoted =
        trimmed.length >= 2 && trimmed.startsWith('"') && trimmed.endsWith('"')
        ? trimmed.substring(1, trimmed.length - 1)
        : trimmed;
    // Only the exact legacy/new executable is accepted, never commands with args.
    return _samePath(unquoted, executable);
  }

  StartupState _state(WindowsStartupRegistration value) {
    if (!value.allowed) {
      return const StartupState(
        false,
        message: 'Windows 已禁用或限制此启动项；在应用内重新开启可再次保存。',
      );
    }
    if (_targets(value.command, _executable)) return const StartupState(true);
    return StartupState(
      false,
      message: value.command != null
          ? '开机启动指向其他程序目录；开启后将使用当前程序。'
          : value.approval != null || value.owner != null
          ? '开机启动记录不完整；开启后应用会自动修复。'
          : null,
    );
  }

  void _validateExecutable() {
    if (!path.windows.isAbsolute(_executable) ||
        !_executable.toLowerCase().endsWith('.exe') ||
        _executable.contains(RegExp('["\r\n\x00]')) ||
        '"$_executable"'.length > 260 ||
        !_exists(_executable)) {
      throw const StartupException('无法设置开机启动：当前程序路径不存在、无效或过长。');
    }
  }

  WindowsStartupRegistration _enabled() => WindowsStartupRegistration(
    command: '"$_executable"',
    approval: [2, ...List.filled(11, 0)],
    owner: _executable,
  );

  void _commit(
    WindowsStartupRegistration before,
    WindowsStartupRegistration next,
  ) {
    try {
      _store.write(next);
      if (!_store.read().sameAs(next)) {
        throw const StartupException('开机启动设置写入后未通过校验，记录可能被系统或其他程序更改。');
      }
    } catch (error) {
      try {
        _store.write(before);
        if (!_store.read().sameAs(before)) {
          throw StateError('rollback verification');
        }
      } catch (_) {
        throw const StartupException('开机启动设置失败，且无法完整恢复原设置；请重试。');
      }
      if (error is StartupException) rethrow;
      throw const StartupException('无法保存开机启动设置，已恢复原设置。');
    }
  }

  @override
  Future<StartupState> initialize() async {
    final before = _store.read();
    // Respect Task Manager's disabled state, including when Run has disappeared.
    if (!before.allowed) return _state(before);
    final current = _targets(before.command, _executable);
    final owner = before.owner;
    final mayRecover =
        owner != null &&
        (_samePath(owner, _executable) || !_exists(owner)) &&
        (before.command == null || _targets(before.command, owner));
    if (current || mayRecover) {
      _validateExecutable();
      final next = WindowsStartupRegistration(
        command: '"$_executable"',
        // Do not rewrite Windows' approval state on ordinary app startup.
        approval: before.approval,
        owner: _executable,
      );
      if (!before.sameAs(next)) _commit(before, next);
      return const StartupState(true);
    }
    return _state(before);
  }

  @override
  Future<StartupState> read() async => _state(_store.read());

  @override
  Future<StartupState> setEnabled(bool value) async {
    if (value) _validateExecutable();
    final before = _store.read();
    _commit(before, value ? _enabled() : const WindowsStartupRegistration());
    return StartupState(value);
  }
}
