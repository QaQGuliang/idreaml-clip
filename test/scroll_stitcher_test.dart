import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:idreaml_clip/src/screenshot/scroll_stitcher.dart';
import 'package:idreaml_clip/src/screenshot/scroll_worker.dart';

void main() {
  const width = 192, height = 180;
  final random = Random(17);
  final document = Uint8List(width * 1200 * 4);
  for (var i = 0; i < document.length; i += 4) {
    document[i] = random.nextInt(256);
    document[i + 1] = random.nextInt(256);
    document[i + 2] = random.nextInt(256);
    document[i + 3] = 255;
  }
  Uint8List frame(int top) => Uint8List.fromList(
    document.sublist(top * width * 4, (top + height) * width * 4),
  );

  test('向下滚动只追加新行，最终像素与原文档完全一致', () {
    final stitcher = ScrollStitcher(width, height);
    expect(stitcher.add(frame(0)).kind, ScrollMatchKind.first);
    for (final offset in [1, 28, 64, 129, 180, 265, 330]) {
      expect(stitcher.add(frame(offset)).kind, ScrollMatchKind.appended);
    }
    expect(stitcher.height, height + 330);
    expect(stitcher.compose(), document.sublist(0, (height + 330) * width * 4));
    final preview = stitcher.thumbnail();
    expect(preview.width, lessThanOrEqualTo(160));
    expect(preview.height, lessThanOrEqualTo(140));
    expect(preview.pixels.length, preview.width * preview.height * 4);
  });

  test('停留、误向上滚动和跳页不改变基准，回到连续位置能恢复', () {
    final stitcher = ScrollStitcher(width, height)..add(frame(100));
    expect(stitcher.add(frame(100)).kind, ScrollMatchKind.unchanged);
    expect(stitcher.add(frame(40)).kind, ScrollMatchKind.reverse);
    expect(stitcher.add(frame(700)).kind, ScrollMatchKind.unmatched);
    expect(stitcher.height, height);
    expect(stitcher.add(frame(160)).kind, ScrollMatchKind.appended);
    expect(
      stitcher.compose(),
      document.sublist(100 * width * 4, 340 * width * 4),
    );
  });

  test('重复条纹有多个可匹配位置时不猜测位移', () {
    Uint8List stripes(int top) {
      final result = Uint8List(width * height * 4);
      for (var y = 0; y < height; y++) {
        final source = ((y + top) % 24) * width * 4;
        result.setRange(y * width * 4, (y + 1) * width * 4, document, source);
      }
      return result;
    }

    final stitcher = ScrollStitcher(width, height)..add(stripes(0));
    expect(stitcher.add(stripes(7)).kind, ScrollMatchKind.unmatched);
    expect(stitcher.height, height);
  });

  test('高度与像素限制均在追加前检查并保留完整结果', () {
    for (final stitcher in [
      ScrollStitcher(width, height, maxHeight: 210),
      ScrollStitcher(width, height, maxPixels: width * 210),
    ]) {
      stitcher.add(frame(0));
      expect(stitcher.add(frame(30)).kind, ScrollMatchKind.appended);
      final before = stitcher.compose();
      expect(stitcher.add(frame(40)).kind, ScrollMatchKind.limit);
      expect(stitcher.compose(), before);
    }
  });

  test('尺寸改变或不合法选区被拒绝', () {
    expect(() => ScrollStitcher(0, height), throwsFormatException);
    expect(() => ScrollStitcher(width, 20), throwsFormatException);
    final stitcher = ScrollStitcher(width, height)..add(frame(0));
    expect(() => stitcher.add(Uint8List(16)), throwsFormatException);
    expect(stitcher.height, height);
  });

  test('浅色文档、聊天列表和深色代码样例按原始像素拼接', () {
    for (final theme in ['document', 'chat', 'code']) {
      final page = img.Image(width: 640, height: 1800, numChannels: 4);
      final background = theme == 'code'
          ? img.ColorRgba8(26, 28, 34, 255)
          : img.ColorRgba8(250, 250, 252, 255);
      img.fill(page, color: background);
      for (var row = 0; row < 50; row++) {
        final color = theme == 'code'
            ? img.ColorRgba8(226, 173, 124, 255)
            : img.ColorRgba8(30, 40, 50, 255);
        if (theme == 'chat') {
          img.fillRect(
            page,
            x1: 15,
            y1: row * 34,
            x2: 43,
            y2: row * 34 + 28,
            color: img.ColorRgba8(row * 41 % 200, row * 73 % 200, 180, 255),
          );
        }
        img.drawString(
          page,
          'Line $row : value_${row * 1237} / detail ${row * row}',
          font: img.arial24,
          x: theme == 'chat' ? 55 : 20,
          y: row * 34,
          color: color,
        );
      }
      Uint8List shot(int top) => img
          .copyCrop(page, x: 0, y: top, width: 640, height: 500)
          .getBytes(order: img.ChannelOrder.bgra);
      final stitcher = ScrollStitcher(640, 500)..add(shot(0));
      for (final top in [34, 153, 288, 470, 655]) {
        expect(
          stitcher.add(shot(top)).kind,
          ScrollMatchKind.appended,
          reason: '$theme at $top',
        );
      }
      expect(
        stitcher.compose(),
        img
            .copyCrop(page, x: 0, y: 0, width: 640, height: 1155)
            .getBytes(order: img.ChannelOrder.bgra),
        reason: theme,
      );
    }
  });

  test('只有红色通道包含内容时仍能识别细节', () {
    Uint8List redFrame(int top) {
      final pixels = frame(top);
      for (var i = 0; i < pixels.length; i += 4) {
        pixels[i] = 0;
        pixels[i + 1] = 0;
      }
      return pixels;
    }

    final stitcher = ScrollStitcher(width, height)..add(redFrame(0));
    expect(stitcher.add(redFrame(70)).kind, ScrollMatchKind.appended);
  });

  test('后台会话合成与预览独立，完成取回原始像素', () async {
    final worker = await ScrollWorker.start(width, height);
    try {
      final initial = await worker.add(frame(0));
      expect(initial['kind'], 'first');
      expect(initial['thumbnail'], isA<TransferableTypedData>());
      await worker.add(frame(65));
      final result = await worker.finish();
      expect(result['height'], height + 65);
      expect(
        (result['pixels'] as TransferableTypedData).materialize().asUint8List(),
        document.sublist(0, (height + 65) * width * 4),
      );
    } finally {
      worker.dispose();
    }
  });
}
