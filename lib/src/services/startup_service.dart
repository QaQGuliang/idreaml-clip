import 'dart:io';

import 'package:launch_at_startup/launch_at_startup.dart';

class StartupState {
  const StartupState(this.enabled, {this.message});
  final bool enabled;
  final String? message;
}

class StartupException implements Exception {
  const StartupException(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract interface class StartupService {
  Future<StartupState> initialize();
  Future<StartupState> read();
  Future<StartupState> setEnabled(bool value);
}

/// Other platforms retain their existing native startup implementation.
class PlatformStartupService implements StartupService {
  @override
  Future<StartupState> initialize() async {
    launchAtStartup.setup(
      appName: 'Idreaml Clip',
      appPath: Platform.resolvedExecutable,
    );
    return read();
  }

  @override
  Future<StartupState> read() async =>
      StartupState(await launchAtStartup.isEnabled());

  @override
  Future<StartupState> setEnabled(bool value) async {
    final success = value
        ? await launchAtStartup.enable()
        : await launchAtStartup.disable();
    final state = await read();
    if (!success || state.enabled != value) {
      throw const StartupException('开机启动设置未生效，请重试。');
    }
    return state;
  }
}
