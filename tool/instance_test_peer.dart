import 'dart:async';
import 'dart:io';

import 'package:idreaml_clip/src/services/windows_app_instance.dart';

// Compiled and launched only by scripts/check-windows-lifecycle.ps1, under an
// isolated test namespace and directory. Never opens the real clipboard DB.
Future<void> main(List<String> args) async {
  if (!Platform.isWindows ||
      args.length != 2 ||
      !args[1].startsWith(r'Local\Idreaml.Clip.Test.')) {
    exit(64);
  }
  if (args[0] == 'legacy') {
    stdout.writeln('legacy');
    Timer.periodic(const Duration(minutes: 1), (_) {});
    return;
  }
  final instance = WindowsAppInstance.acquire(namespace: args[1]);
  stdout.writeln(instance.launch.name);
  if (instance.launch != InstanceLaunch.primary) exit(0);
  instance.listen(
    onActivate: () async => stdout.writeln('activated'),
    onShutdown: () async {
      stdout.writeln('shutdown');
      await stdout.flush();
      exit(0);
    },
  );
}
