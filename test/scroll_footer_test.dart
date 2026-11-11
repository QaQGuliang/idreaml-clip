import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/screenshot/scroll_stitcher.dart';

void main() {
  const width = 240, height = 224, footer = 24;
  int noise(int x, int y) {
    final value = x * 73856093 ^ y * 19349663;
    return value ^ (value >>> 13);
  }

  Uint8List pixels(int rows, int Function(int x, int y) color) {
    final result = Uint8List(rows * width * 4);
    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < width; x++) {
        final i = (y * width + x) * 4;
        final rgb = color(x, y);
        result[i] = rgb & 255;
        result[i + 1] = (rgb >> 8) & 255;
        result[i + 2] = (rgb >> 16) & 255;
        result[i + 3] = 255;
      }
    }
    return result;
  }

  for (final solid in [false, true]) {
    test('底栏有动态进度线时仍保留一份底栏和全部正文（纯色 $solid）', () {
      int color(int x, int y, int top) {
        if (y < height - footer) return noise(x, y + top);
        if (y >= height - 3 && y < height - 1) return top * 0x010101;
        return solid ? 0xdddddd : noise(x, 2000 + y);
      }

      final stitcher = ScrollStitcher(width, height);
      for (final top in [0, 47, 88]) {
        final match = stitcher.add(pixels(height, (x, y) => color(x, y, top)));
        expect(
          match.kind,
          top == 0 ? ScrollMatchKind.first : ScrollMatchKind.appended,
        );
      }
      final expected = pixels(
        height + 88,
        (x, y) => y < height + 88 - footer ? noise(x, y) : color(x, y - 88, 88),
      );
      expect(stitcher.compose(), orderedEquals(expected));
    });
  }

  test('正文底部动画没有固定栏证据时保留整幅首帧', () {
    // A flat patch in a scrolling canvas is the same at both possible
    // positions. A differently repainted strip under it is not a fixed bar.
    const shift = 47;
    Uint8List frame(int top) => pixels(height, (x, y) {
      final documentY = y + top;
      if (documentY >= height - 65 && documentY < height - 1 + shift) {
        if (x < 10 && (documentY & 7) < 4) {
          return noise(x, documentY + top * 13);
        }
        return 0xeeeeee;
      }
      if (top != 0 && y == height - 1) return 0x77cc22;
      return noise(x, documentY);
    });
    final first = frame(0), last = frame(shift);
    final stitcher = ScrollStitcher(width, height)..add(first);
    expect(stitcher.add(last).offset, shift);
    expect(
      stitcher.compose(),
      orderedEquals([
        ...first,
        ...Uint8List.sublistView(last, (height - shift) * width * 4),
      ]),
    );
  });
}
