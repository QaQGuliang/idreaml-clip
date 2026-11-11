// Debug-only, offscreen fixtures: no database, window interaction, capture,
// clipboard monitoring, or shortcut registration.
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final output = Directory(args.isEmpty ? 'render-check' : args.first);
  await output.create(recursive: true);
  const channel = MethodChannel('idreaml_clip/desktop_notes');
  try {
    var count = 0;
    final monitors = await channel.invokeListMethod<dynamic>('monitors') ?? [];
    for (var monitor = 0; monitor < monitors.length; monitor++) {
      for (final opacity in [0.0, .24, 1.0]) {
        for (final scale in [1.0, 1.5]) {
          for (final kind in ['note', 'todo']) {
            await channel.invokeMethod<void>('renderFixture', {
              'kind': kind,
              'monitor': (monitors[monitor] as Map)['id'],
              'scale': scale,
              'transparent': true,
              'opacity': opacity,
              'color': 0xFFFFFFFF,
              'color2': 0xFFD8D0F8,
              'gradient': 'none',
              'path':
                  '${output.absolute.path}/$monitor-$kind-$opacity-$scale.png',
              'rows': [
                {
                  'id': 'render-fixture',
                  'title': kind == 'note' ? '清晰记录每一个想法' : '',
                  'body': kind == 'note'
                      ? '透明度只影响背景底色。\n文字保持清晰，卡片不再有边框。\n100% 透明仍保留柔和毛玻璃。'
                      : '检查不同显示器上的文字与毛玻璃效果',
                  'created': DateTime.now().millisecondsSinceEpoch,
                },
              ],
            });
            count++;
          }
        }
      }
      for (final fontSize in [10.0, 24.0, 32.0]) {
        for (final kind in ['note', 'todo']) {
          for (final scale in [1.0, 1.5]) {
            await channel.invokeMethod<void>('renderFixture', {
              'kind': kind,
              'monitor': (monitors[monitor] as Map)['id'],
              'scale': scale,
              'transparent': false,
              'opacity': 1.0,
              'color': 0xFFFFFFFF,
              'gradient': 'none',
              'fontFamily': 'SimSun',
              'fontSize': fontSize,
              'textColor': 0xFF526887,
              'path':
                  '${output.absolute.path}/$monitor-$kind-type-$fontSize-$scale.png',
              'rows': [
                {
                  'id': 'default-font',
                  'title': kind == 'note' ? '列表默认' : '',
                  'body': '默认样式',
                  'created': DateTime.now().millisecondsSinceEpoch,
                },
                {
                  'id': 'custom-font',
                  'title': kind == 'note' ? '单条自定义' : '',
                  'body': '独立选色',
                  'created': DateTime.now().millisecondsSinceEpoch,
                  'fontFamily': 'KaiTi',
                  'fontSize': 18.0,
                  'textColor': 0xFFE35A6B,
                },
              ],
            });
            count++;
          }
        }
      }
    }
    await File('${output.path}/result.txt')
        .writeAsString('rendered $count fixtures');
    exit(0);
  } catch (error, stack) {
    await File('${output.path}/result.txt').writeAsString('$error\n$stack');
    exit(1);
  }
}
