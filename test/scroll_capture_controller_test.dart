import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/screenshot/scroll_capture_controller.dart';
import 'package:idreaml_clip/src/screenshot/scroll_stitcher.dart';

Map<String, Object> captureFrame(int width, int height, int top) {
  final pixels = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = (y * width + x) * 4;
      final value = (y + top) * 19349663 ^ x * 73856093;
      pixels[i] = value >> 16;
      pixels[i + 1] = value >> 8;
      pixels[i + 2] = value;
      pixels[i + 3] = 255;
    }
  }
  return {'session': 1, 'width': width, 'height': height, 'pixels': pixels};
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/scroll-limit');
  test('选区贴住显示器上边时优先把预览放在旁边的可用空间', () {
    const area = Rect.fromLTRB(600, 0, 1150, 690);
    final panel = placeScrollControls(area, const Size(1200, 800), 1);
    expect(panel.overlaps(area), isFalse);
    expect(panel.right, lessThanOrEqualTo(area.left));
    expect(panel.top, greaterThanOrEqualTo(0));
  });
  for (final initialHeight in [maxScrollImageSide, maxScrollImageSide - 2]) {
    test('采集高度从 $initialHeight 恰好达到上限，留在预览且不再滚轮', () async {
      const width = 32;
      var steps = 0, edits = 0;
      final limit = Completer<void>();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'scrollStep') {
          steps++;
          return null;
        }
        return captureFrame(width, initialHeight, steps * 2);
      });
      addTearDown(
        () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final controller = ScrollCaptureController(
        channel: channel,
        session: 1,
        panel: Rect.zero,
        selection: Rect.fromLTWH(
          0,
          0,
          width.toDouble(),
          initialHeight.toDouble(),
        ),
        autoScroll: true,
        onEdit: (pixels, width, height, limited) async {
          expect(limited, isTrue);
          edits++;
        },
      );
      addTearDown(controller.dispose);
      controller.addListener(() {
        if (controller.message.contains('达到长图上限') && !limit.isCompleted) {
          limit.complete();
        }
      });
      await controller.start();
      await limit.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(controller.height, maxScrollImageSide);
      expect(controller.canTakeOver, isFalse);
      expect(steps, initialHeight == maxScrollImageSide ? 0 : 1);
      expect(edits, 0);
      await controller.finish();
      expect(edits, 1);
    });
  }

  for (final transientPopup in [true, false]) {
    test(
      transientPopup
          ? '自动滚动遭遇短暂浮层时只检查可见性，恢复后才发送滚轮'
          : '动画短暂重绘多帧后能继续衔接，等待期间不多滚一屏',
      () async {
        const width = 192, height = 180;
        var reads = 0, steps = 0;
        final calls = <String>[];
        final appended = Completer<void>();
        final covered = PlatformException(code: 'obscured', message: '选区被遮挡');
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
          call,
        ) async {
          calls.add(call.method);
          if (call.method == 'beginScroll') {
            return captureFrame(width, height, 0);
          }
          if (call.method == 'scrollStep') {
            steps++;
            if (transientPopup && steps == 1) throw covered;
            return null;
          }
          reads++;
          if (transientPopup && reads <= 2) throw covered;
          final top = transientPopup
              ? (steps > 1 ? 30 : 0)
              : (reads <= 5 ? 10000 : 30);
          return captureFrame(width, height, top);
        });
        addTearDown(
          () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        final controller = ScrollCaptureController(
          channel: channel,
          session: 1,
          selection: const Rect.fromLTWH(0, 0, 192, 180),
          panel: Rect.zero,
          autoScroll: true,
          onEdit: (_, _, _, _) async => fail('采集期间不应进入编辑'),
        );
        addTearDown(controller.dispose);
        controller.addListener(() {
          if (controller.height == height + 30 && !appended.isCompleted) {
            appended.complete();
          }
        });
        await controller.start();
        await appended.future.timeout(const Duration(seconds: 4));
        expect(controller.warning, isFalse);
        expect(calls, [
          'beginScroll',
          'scrollStep',
          if (transientPopup) ...[
            'scrollFrame',
            'scrollFrame',
            'scrollFrame',
            'scrollStep',
          ] else
            ...List.filled(5, 'scrollFrame'),
          'scrollFrame',
        ]);
      },
    );
  }

  test('页面持续在旧画面和重绘帧之间切换时停止等待，不多滚或自动完成', () async {
    const width = 192, height = 180;
    var steps = 0, reads = 0;
    final paused = Completer<void>();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'scrollStep') {
        steps++;
        return null;
      }
      if (call.method == 'beginScroll') return captureFrame(width, height, 0);
      reads++;
      return captureFrame(width, height, reads.isOdd ? 0 : 10000);
    });
    addTearDown(
      () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final controller = ScrollCaptureController(
      channel: channel,
      session: 1,
      selection: const Rect.fromLTWH(0, 0, 192, 180),
      panel: Rect.zero,
      autoScroll: true,
      onEdit: (_, _, _, _) async => fail('必须由用户完成'),
    );
    addTearDown(controller.dispose);
    controller.addListener(() {
      if (controller.message.contains('自动滚动已暂停') && !paused.isCompleted) {
        paused.complete();
      }
    });
    await controller.start();
    await paused.future.timeout(const Duration(seconds: 8));
    expect(
      [steps, controller.height, controller.canTakeOver],
      [1, height, true],
    );
  });

  test('真实浮层持续遮挡时保留结果，移开后手动接管从原图继续', () async {
    const width = 192, height = 180;
    var steps = 0, top = 0;
    var covered = false;
    final paused = Completer<void>(), resumed = Completer<void>();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'scrollStep') {
        steps++;
        top += 25;
        return null;
      }
      if (covered) throw PlatformException(code: 'obscured', message: '选区被遮挡');
      return captureFrame(width, height, top);
    });
    addTearDown(
      () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final controller = ScrollCaptureController(
      channel: channel,
      session: 1,
      selection: const Rect.fromLTWH(0, 0, 192, 180),
      panel: Rect.zero,
      autoScroll: true,
      onEdit: (_, _, _, _) async => fail('必须由用户完成'),
    );
    addTearDown(controller.dispose);
    controller.addListener(() {
      if (controller.height == height + 25 && !paused.isCompleted) {
        covered = true;
      }
      if (controller.message == '选区被遮挡' && !paused.isCompleted) {
        paused.complete();
      }
      if (controller.height == height + 50 && !resumed.isCompleted) {
        resumed.complete();
      }
    });
    await controller.start();
    await paused.future.timeout(const Duration(seconds: 4));
    expect(controller.height, height + 25);
    covered = false;
    top += 25;
    controller.takeOver();
    await resumed.future.timeout(const Duration(seconds: 4));
    expect(steps, 1);
    expect(controller.warning, isFalse);
  });
}
