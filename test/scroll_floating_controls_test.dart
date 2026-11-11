import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/screenshot/scroll_stitcher.dart';

const _width = 384, _height = 256, _header = 22, _rail = 12;
const _trackColor = 0xffbbbbbb, _thumbColor = 0xff555555;

int _body(int x, int y) {
  // Two scrolling columns separated by the same blank gutter on every frame.
  if (x < 13 || (x > 233 && x < 249) || x > 355) return 0xff232323;
  final hash = x * 73856093 ^ y * 19349663;
  return 0xff000000 | ((hash ^ (hash >>> 13)) & 0xffffff);
}

int _headerColor(int x, int y) => 0xff223344 + ((x ^ y) & 15);

int? _floatingControl(int x, int y, int top) {
  // The player pops out first. The sticky comment composer appears later when
  // its inline counterpart has scrolled away. Both are dismissed later.
  if (top >= 54 && top < 300 && x >= 281 && x < 348 && y >= 168 && y < 224) {
    if (y == 169) return 0xff454952;
    if (y < 174 || y >= 221) return 0xff262834; // Stable player chrome.
    return 0xff000000 | ((top * 389 + x * 219 + y * 83) & 0xffffff);
  }
  if (top >= 148 && top < 300 && x >= 21 && x < 230 && y >= 226 && y < 251) {
    return (x ^ y) & 7 == 0 ? 0xffece1dc : 0xff211c20;
  }
  if (top >= 54 && x >= 357 && x < 370 && y >= 205 && y < 235) {
    return (x + y) & 7 == 0 ? 0xfff4dabd : 0xff48362b;
  }
  return null;
}

int _railColor(int x, int y, int top) {
  // A down arrow on a native scrollbar. Copying the bottom strip on every
  // accepted frame leaves a ladder of these distinctive arrows in the output.
  final center = _width - _rail ~/ 2;
  if (y >= _height - 10 &&
      y <= _height - 6 &&
      (x - center).abs() <= _height - 6 - y) {
    return 0xff080808;
  }
  final thumbY = _header + 3 + top ~/ 6;
  final endCap = y == thumbY || y == thumbY + 38;
  return y >= thumbY &&
          y < thumbY + 39 &&
          (x - center).abs() <= (endCap ? 2 : 4)
      ? _thumbColor
      : _trackColor;
}

Uint8List _frame(int top) {
  final pixels = Uint32List(_width * _height);
  for (var y = 0; y < _height; y++) {
    for (var x = 0; x < _width; x++) {
      pixels[y * _width + x] = y < _header
          ? _headerColor(x, y)
          : x >= _width - _rail
          ? _railColor(x, y, top)
          : _floatingControl(x, y, top) ?? _body(x, y + top);
    }
  }
  return Uint8List.view(pixels.buffer);
}

void _verifyDocument(ScrollStitcher stitcher, int top) {
  expect(stitcher.height, _height + top);
  final bytes = stitcher.compose();
  final output = Uint32List.view(bytes.buffer, bytes.offsetInBytes);
  for (var y = 0; y < _height + top; y++) {
    for (var x = 0; x < _width; x++) {
      final actual = output[y * _width + x];
      if (y < _header) {
        if (actual == _headerColor(x, y)) continue;
      } else if (x >= _width - _rail) {
        // The chosen thumb can come from different observations. Its track
        // must still end in exactly one arrow, in the last viewport.
        final expected = _railColor(x, y - top, top);
        if (actual == expected ||
            expected != 0xff080808 &&
                (actual == _trackColor || actual == _thumbColor)) {
          continue;
        }
      } else {
        final overlay = _floatingControl(x, y - top, top);
        if (actual == _body(x, y) || actual == overlay) continue;
      }
      fail(
        '画面滚动 ${top}px，成图 ($x, $y) 处正文或固定控件错误：'
        '0x${actual.toRadixString(16)}',
      );
    }
  }
}

void main() {
  test('快滚后旧浮窗遮住接缝时保留原图，回滚到可衔接位置能继续', () {
    final stitcher = ScrollStitcher(_width, _height)..add(_frame(0));
    expect(stitcher.add(_frame(54)).offset, 54);
    final accepted = stitcher.compose();
    expect(stitcher.add(_frame(215)).kind, ScrollMatchKind.unmatched);
    expect(stitcher.compose(), accepted);
    expect(stitcher.add(_frame(108)).offset, 54);
    _verifyDocument(stitcher, 108);
  });
  test('正文右侧类似滑块的色块随文档滚动时逐像素保留原貌', () {
    int color(int x, int y) {
      if (x < _width - _rail) return _body(x, y);
      return (y + 49) % 211 < 39 ? _thumbColor : _trackColor;
    }

    final stitcher = ScrollStitcher(_width, _height);
    Uint8List rows(int top, int count) {
      final pixels = Uint32List(_width * count);
      for (var y = 0; y < count; y++) {
        for (var x = 0; x < _width; x++) {
          pixels[y * _width + x] = color(x, y + top);
        }
      }
      return Uint8List.view(pixels.buffer);
    }

    for (var top = 0; top <= 240; top += 40) {
      expect(stitcher.add(rows(top, _height)).offset, top == 0 ? 0 : 40);
    }
    expect(stitcher.compose(), rows(0, _height + 240));
  });
  test('滚动条滑块越过拼接位置后轨道上仍只有一个完整滑块', () {
    final stitcher = ScrollStitcher(_width, _height);
    for (var top = 0; top <= 1080; top += 54) {
      expect(stitcher.add(_frame(top)).offset, top == 0 ? 0 : 54);
    }
    final bytes = stitcher.compose();
    final output = Uint32List.view(bytes.buffer, bytes.offsetInBytes);
    final center = _width - _rail ~/ 2;
    final thumbRows = [
      for (var y = _header; y < stitcher.height; y++)
        if (output[y * _width + center] == _thumbColor) y,
    ];
    expect(thumbRows.length, 39);
    expect(thumbRows.last - thumbRows.first + 1, 39);

    // A layout change removes the track. Keep the earlier thumb intact and
    // expose the real page pixels in the freshly recorded right-hand strip.
    final noTrack = _frame(1134);
    final fresh = Uint32List.view(noTrack.buffer);
    const pageColor = 0xffabcd12;
    for (var y = _header; y < _height; y++) {
      fresh.fillRange((y + 1) * _width - _rail, (y + 1) * _width, pageColor);
    }
    expect(stitcher.add(noTrack).offset, 54);
    final after = Uint32List.view(stitcher.compose().buffer);
    for (var y = _header; y < 1000; y++) {
      expect(after[y * _width + center], output[y * _width + center]);
    }
    for (var y = stitcher.height - 54; y < stitcher.height; y++) {
      expect(after[y * _width + center], pageColor);
    }
  });
  for (final scenario in {
    '自动等距滚动': [0, 54, 108, 162, 216, 270, 324],
    '手动快慢交替滚动': [0, 27, 92, 151, 158, 212, 273, 327],
  }.entries) {
    test('${scenario.key}时悬浮视频、评论输入框和滚动条箭头不覆盖已露出的正文', () {
      final stitcher = ScrollStitcher(_width, _height);
      var previous = 0;
      for (final top in scenario.value) {
        final match = stitcher.add(_frame(top));
        expect(
          match.kind,
          top == 0 ? ScrollMatchKind.first : ScrollMatchKind.appended,
          reason: '滚动位置 $top',
        );
        expect(match.offset, top - previous);
        // Users can finish at any step. Check the entire image, including
        // initially occluded comments and both sides of every join.
        _verifyDocument(stitcher, top);
        previous = top;
      }
    });
  }
}
