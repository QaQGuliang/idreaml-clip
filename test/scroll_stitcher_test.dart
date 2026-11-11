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

  test('快滚时能从有辨识度的短重叠区续接，恢复提示仅预览最后接上的一屏', () {
    final stitcher = ScrollStitcher(width, height)..add(frame(0));
    for (final offset in [154, 314, 468]) {
      expect(stitcher.add(frame(offset)).kind, ScrollMatchKind.appended);
    }
    expect(stitcher.compose(), document.sublist(0, (468 + height) * width * 4));
    expect(stitcher.add(frame(800)).kind, ScrollMatchKind.unmatched);
    final reference = ScrollStitcher(width, height)..add(frame(468));
    expect(
      stitcher.thumbnail(tailOnly: true).pixels,
      reference.thumbnail().pixels,
    );
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

  test('短重叠区域出现不一致时保留已接画面，重新衔接可继续', () {
    final stitcher = ScrollStitcher(width, height)..add(frame(0));
    final changed = frame(160);
    // The first sampled column is two pixels from the left.
    changed[(5 * width + 2) * 4] ^= 1;
    expect(stitcher.add(changed).kind, ScrollMatchKind.unmatched);
    expect(stitcher.compose(), frame(0));
    expect(stitcher.add(frame(160)).kind, ScrollMatchKind.appended);
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

  // The viewport includes fixed window chrome, a changing scrollbar and an
  // optional playing video. The surrounding document still moves as one page.
  Uint8List windowFrame(int top, {int? videoTick}) {
    final result = frame(top);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final i = (y * width + x) * 4;
        if (y < 28 || y >= height - 16) {
          result.setRange(i, i + 4, document, ((900 + y) * width + x) * 4);
        } else if (x >= width - 10) {
          result.fillRange(i, i + 3, (y - top ~/ 4).abs() < 12 ? 80 : 220);
        } else if (videoTick != null && x >= 8 && x < width * .66) {
          result.setRange(
            i,
            i + 4,
            document,
            ((700 + y) * width + (x + videoTick) % width) * 4,
          );
        }
      }
    }
    return result;
  }

  test('整窗口的固定标题栏与底栏仅保留一份，滚动条不干扰衔接', () {
    final first = windowFrame(0);
    final stitcher = ScrollStitcher(width, height)..add(first);
    for (final top in [25, 82, 143]) {
      expect(stitcher.add(windowFrame(top)).kind, ScrollMatchKind.appended);
    }
    final output = stitcher.compose();
    final last = windowFrame(143);
    final reference = ScrollStitcher(width, height)..add(last);
    expect(
      stitcher.thumbnail(tailOnly: true).pixels,
      reference.thumbnail().pixels,
      reason: '手动接管时显示最后实际采到的视口，包括固定标题栏',
    );
    for (var y = 0; y < stitcher.height; y++) {
      final expected = y < 28
          ? first
          : y >= stitcher.height - 16
          ? last
          : document;
      final sourceY = y >= stitcher.height - 16 ? y - 143 : y;
      final length = (width - 10) * 4;
      expect(
        output.sublist(y * width * 4, y * width * 4 + length),
        expected.sublist(sourceY * width * 4, sourceY * width * 4 + length),
        reason: 'row $y',
      );
    }
  });

  test('整窗包含较高的固定标题栏和左侧导航时仍按正文位移追加', () {
    Uint8List withNavigation(int top) {
      final result = windowFrame(top);
      final fixed = frame(500);
      for (var y = 0; y < height; y++) {
        final i = y * width * 4;
        result.setRange(i, i + (y < 62 ? width : 38) * 4, fixed, i);
      }
      return result;
    }

    final stitcher = ScrollStitcher(width, height)..add(withNavigation(0));
    expect(stitcher.add(withNavigation(29)).offset, 29);
    expect(stitcher.add(withNavigation(77)).offset, 48);
    expect(stitcher.height, height + 77);
  });

  test('页内正文跳过一屏时，窄固定导航栏无法单独证明页面停留', () {
    Uint8List withSidebar(int top) {
      final output = frame(top);
      for (var y = 0; y < height; y++) {
        final i = y * width * 4;
        output.setRange(i, i + 36 * 4, document, i);
      }
      return output;
    }

    final stitcher = ScrollStitcher(width, height)..add(withSidebar(0));
    expect(stitcher.add(withSidebar(250)).kind, ScrollMatchKind.unmatched);
    expect(stitcher.height, height);
  });

  Uint8List columnsWithTrack(int left, int right, int scroll) {
    final output = frame(left);
    for (var y = 0; y < height; y++) {
      final start = (y * width + 120) * 4;
      final end = (y + 1) * width * 4;
      output.setRange(start, end, document, start + right * width * 4);
      if (y < 20) {
        output.fillRange(y * width * 4, end, 91);
      } else {
        final thumbStart = 20 + scroll ~/ 4;
        output.fillRange(
          end - 8 * 4,
          end,
          y >= thumbStart && y < thumbStart + 40 ? 65 : 215,
        );
      }
    }
    return output;
  }

  test('快速滚动时使用圆角滑块的可见边缘校验正文位移', () {
    Uint8List shot(int right, int thumbTop) {
      final pixels = columnsWithTrack(0, right, 0);
      for (var y = 20; y < height; y++) {
        final end = (y + 1) * width * 4;
        var color = 215;
        if (y == thumbTop || y == thumbTop + 35) {
          color = 148;
        } else if (y > thumbTop && y < thumbTop + 35) {
          color = 65;
        }
        pixels.fillRange(end - 8 * 4, end, color);
      }
      return pixels;
    }

    final stitcher = ScrollStitcher(width, height)..add(shot(0, 28));
    expect(stitcher.add(shot(100, 51)).offset, 100);
  });

  test('页面左栏吸附、右栏独立显示后续正文，按内容与可见轨道共同确认位移', () {
    final stitcher = ScrollStitcher(width, height)
      ..add(columnsWithTrack(0, 0, 0));
    expect(stitcher.add(columnsWithTrack(40, 40, 40)).offset, 40);
    expect(stitcher.add(columnsWithTrack(75, 80, 80)).offset, 40);
    expect(stitcher.add(columnsWithTrack(75, 120, 120)).offset, 40);
    expect(stitcher.add(columnsWithTrack(75, 160, 160)).offset, 40);
    expect(
      stitcher.add(columnsWithTrack(75, 160, 160)).kind,
      ScrollMatchKind.unchanged,
    );
    expect(stitcher.height, height + 160);
  });

  test('正文一列异步重排，另一列与滑块停稳时保留原图，下一次滚动按新排版接续', () {
    final first = columnsWithTrack(0, 0, 0);
    final stitcher = ScrollStitcher(width, height)..add(first);
    expect(
      stitcher.add(columnsWithTrack(47, 0, 0)).kind,
      ScrollMatchKind.unchanged,
    );
    expect(stitcher.compose(), first);
    expect(stitcher.add(columnsWithTrack(87, 40, 40)).offset, 40);
    expect(stitcher.height, height + 40);
  });

  test('半步滚动遇到吸附转折，按唯一区别于局部重排的真实文档位移追加', () {
    final stitcher = ScrollStitcher(width, height)
      ..add(columnsWithTrack(0, 0, 0));
    expect(stitcher.add(columnsWithTrack(77, 100, 100)).offset, 100);
    expect(stitcher.height, height + 100);
    final ambiguous = ScrollStitcher(width, height)
      ..add(columnsWithTrack(0, 0, 0));
    expect(
      ambiguous.add(columnsWithTrack(99, 100, 100)).kind,
      ScrollMatchKind.unmatched,
    );
  });

  test('同一位置出现多种局部重排时依靠未动的纹理区域与轨道确认停留', () {
    final first = columnsWithTrack(80, 80, 80);
    final stitcher = ScrollStitcher(width, height)..add(first);
    final changes = columnsWithTrack(57, 80, 80);
    final other = columnsWithTrack(127, 80, 80);
    for (var y = 20; y < height; y++) {
      final i = y * width * 4;
      changes.setRange(i, i + 60 * 4, other, i);
    }
    expect(stitcher.add(changes).kind, ScrollMatchKind.unchanged);
    expect(stitcher.compose(), first);
  });

  test('右栏下段遮挡重绘，依据上段连续区域及滑块准确接续', () {
    final stitcher = ScrollStitcher(width, height)
      ..add(columnsWithTrack(0, 0, 0));
    final current = columnsWithTrack(0, 40, 40);
    for (var y = 64; y < height; y++) {
      // Partial redraw across the lower tiles leaves occasional landmarks,
      // but most of each tile disagrees with the old frame.
      if (y % 17 < 7) continue;
      final start = (y * width + 120) * 4;
      current.setRange(
        start,
        ((y + 1) * width - 8) * 4,
        document,
        start + 600 * width * 4,
      );
    }
    expect(stitcher.add(current).offset, 40);
    expect(stitcher.height, height + 40);
  });

  test('底部半步只留下分散的正文区域，仍从可见内容得到精确位移', () {
    final stitcher = ScrollStitcher(width, height)
      ..add(columnsWithTrack(0, 0, 0));
    final current = columnsWithTrack(0, 25, 25);
    for (var y = 20; y < height; y++) {
      // Small glimpses of page content remain throughout the floating panel.
      if (y % 19 < 7) continue;
      for (var x = 120; x < width - 8; x++) {
        final visible =
            x < 144 && y < 70 ||
            x >= 144 && x < 160 && y >= 70 && y < 105 ||
            x >= 160 && y >= 100 && y < 138;
        if (visible) continue;
        final p = (y * width + x) * 4;
        current.setRange(p, p + 4, document, p + 600 * width * 4);
      }
    }
    expect(stitcher.add(current).offset, 25);
    expect(stitcher.height, height + 25);
  });

  test('悬浮视频切过推荐栏的采样区域，可以用连续露出的半段确认快滚位移', () {
    const h = 420;
    Uint8List shot(int scroll, {bool exposeHalf = true}) {
      final pixels = document.sublist(0, h * width * 4);
      for (var y = 20; y < h; y++) {
        final start = (y * width + 128) * 4;
        final end = (y * width + 160) * 4;
        pixels.setRange(start, end, document, start + scroll * width * 4);
        if (scroll != 0 && y % 40 >= 8) {
          final covered = (y * width + (exposeHalf ? 152 : 144)) * 4;
          pixels.setRange(covered, end, document, covered + 500 * width * 4);
        }
        final rowEnd = (y + 1) * width * 4;
        final top = 30 + scroll ~/ 4;
        pixels.fillRange(
          rowEnd - 8 * 4,
          rowEnd,
          y >= top && y < top + 100 ? 60 : 215,
        );
      }
      return pixels;
    }

    final stitcher = ScrollStitcher(width, h)..add(shot(0));
    expect(stitcher.add(shot(120)).offset, 120);
    final obscured = ScrollStitcher(width, h)..add(shot(0));
    expect(
      obscured.add(shot(120, exposeHalf: false)).kind,
      ScrollMatchKind.unmatched,
    );
  });

  test('页面停留时左栏回弹、右栏下段持续重绘，依靠可见正文确认同一位置', () {
    final stitcher = ScrollStitcher(width, height)
      ..add(columnsWithTrack(80, 20, 20));
    final current = columnsWithTrack(57, 20, 20);
    for (var y = 66; y < height; y++) {
      if (y % 19 < 7) continue;
      final start = (y * width + 120) * 4;
      current.setRange(
        start,
        ((y + 1) * width - 8) * 4,
        document,
        start + 650 * width * 4,
      );
    }
    expect(stitcher.add(current).kind, ScrollMatchKind.unchanged);
    expect(stitcher.height, height);
    expect(stitcher.add(columnsWithTrack(97, 60, 60)).offset, 40);
  });

  test('有辨识度的整页先滚完、滑块稍后追上时保持高度并更新下一步轨道参考', () {
    final stitcher = ScrollStitcher(width, height)
      ..add(columnsWithTrack(0, 0, 0));
    expect(stitcher.add(columnsWithTrack(40, 40, 0)).offset, 40);
    final before = stitcher.compose();
    expect(
      stitcher.add(columnsWithTrack(40, 40, 40)).kind,
      ScrollMatchKind.unchanged,
    );
    expect(stitcher.compose(), before);
    expect(stitcher.add(columnsWithTrack(117, 140, 140)).offset, 100);
    expect(stitcher.height, height + 140);
  });

  test('空白页只有位于采样列以外的滚动条移动时，不虚增高度也不误报到底', () {
    const w = 640;
    Uint8List blank(int scroll) {
      final output = Uint8List(w * height * 4);
      for (var y = 0; y < height; y++) {
        final end = (y + 1) * w * 4;
        final color = y >= scroll && y < scroll + 45 ? 50 : 220;
        output.fillRange(end - 4 * 4, end, color);
      }
      return output;
    }

    final stitcher = ScrollStitcher(w, height)..add(blank(12));
    expect(stitcher.add(blank(32)).kind, ScrollMatchKind.unmatched);
    expect(stitcher.height, height);
  });

  test('播放区域占大半时按周边滚动内容续接，停留播放不增加长图高度', () {
    final stitcher = ScrollStitcher(width, height)
      ..add(windowFrame(0, videoTick: 3));
    expect(
      stitcher.add(windowFrame(0, videoTick: 14)).kind,
      ScrollMatchKind.unchanged,
    );
    expect(stitcher.add(windowFrame(44, videoTick: 15)).offset, 44);
    expect(stitcher.add(windowFrame(110, videoTick: 20)).offset, 66);
    expect(
      stitcher.add(windowFrame(110, videoTick: 30)).kind,
      ScrollMatchKind.unchanged,
    );
    expect(
      stitcher.add(windowFrame(40, videoTick: 40)).kind,
      ScrollMatchKind.reverse,
    );
    expect(stitcher.height, height + 110);
  });

  test('两个窗格具有不同滚动距离时保留上次画面', () {
    Uint8List split(int left, int right) {
      final output = frame(left);
      for (var y = 0; y < height; y++) {
        final start = (y * width + width * 2 ~/ 3) * 4;
        output.setRange(
          start,
          (y + 1) * width * 4,
          document,
          start + right * width * 4,
        );
      }
      return output;
    }

    final stitcher = ScrollStitcher(width, height)..add(split(0, 0));
    expect(stitcher.add(split(48, 28)).kind, ScrollMatchKind.unmatched);
    // A video can contain a vertical camera pan. The surrounding identifiable
    // page has stayed still; motion inside the video must not add rows.
    expect(stitcher.add(split(48, 0)).kind, ScrollMatchKind.unmatched);
    expect(stitcher.height, height);
  });

  test('视频右侧只有浅底推荐文字时仍能识别停留与滚动', () {
    const w = 680, h = 430, videoWidth = 428;
    final page = img.Image(width: w, height: 840, numChannels: 4);
    img.fill(page, color: img.ColorRgba8(249, 250, 252, 255));
    final ink = img.ColorRgba8(28, 36, 54, 255);
    for (var index = 0; index < 16; index++) {
      img.drawString(
        page,
        'Part ${index * 73 + 14}',
        font: img.arial24,
        x: videoWidth + 12,
        y: index * 50,
        color: ink,
      );
      img.drawString(
        page,
        'Channel ${(19 - index) * 31}',
        font: img.arial14,
        x: videoWidth + 12,
        y: index * 50 + 24,
        color: ink,
      );
    }
    Uint8List shot(int top, int tick) {
      final pixels = img
          .copyCrop(page, x: 0, y: top, width: w, height: h)
          .getBytes(order: img.ChannelOrder.bgra);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < videoWidth; x++) {
          final i = (y * w + x) * 4;
          final source = ((y + 400) * width + (x + tick) % width) * 4;
          pixels.setRange(i, i + 4, document, source);
        }
      }
      return pixels;
    }

    final stitcher = ScrollStitcher(w, h)..add(shot(0, 2));
    expect(stitcher.add(shot(0, 11)).kind, ScrollMatchKind.unchanged);
    expect(stitcher.add(shot(96, 20)).offset, 96);
    expect(stitcher.add(shot(204, 29)).offset, 108);
    expect(stitcher.add(shot(204, 38)).kind, ScrollMatchKind.unchanged);
  });

  test('重复列表行的渐变缩略图局部相似时，逐段接准，跳过整屏时拒绝续接', () {
    const w = 824, h = 581, listTop = 202, rowHeight = 88, pageHeight = 1962;
    final page = img.Image(width: w, height: pageHeight, numChannels: 4);
    img.fill(page, color: img.ColorRgba8(255, 255, 255, 255));
    final ink = img.ColorRgba8(28, 34, 46, 255);
    for (var i = 0; i < 20; i++) {
      final y = listTop + i * rowHeight;
      for (var row = 0; row < 64; row++) {
        // Different thumbnails share short runs of colors at wrong offsets.
        final phase = (row * 37 + i * 61) % 360;
        img.fillRect(
          page,
          x1: 10,
          y1: y + 12 + row,
          x2: 79,
          y2: y + 12 + row,
          color: img.ColorRgba8(
            phase * 17 % 256,
            phase * 41 % 256,
            phase * 53 % 256,
            255,
          ),
        );
      }
      img.drawString(
        page,
        'Section $i - Browser page #${i * 17 + 31}',
        font: img.arial14,
        x: 98,
        y: y + 22,
        color: ink,
      );
      img.drawString(
        page,
        'Visible paragraphs, thumbnails and a native scrollbar.',
        font: img.arial14,
        x: 98,
        y: y + 48,
        color: ink,
      );
    }
    final raw = page.getBytes(order: img.ChannelOrder.bgra);
    Uint8List shot(int top) {
      final pixels = raw.sublist(top * w * 4, (top + h) * w * 4);
      for (var y = 0; y < h; y++) {
        if (y < 52) {
          pixels.fillRange(y * w * 4, (y + 1) * w * 4, 101);
        } else {
          final thumb = (y - top ~/ 4).abs() < 45;
          pixels.fillRange(
            ((y + 1) * w - 18) * 4,
            (y + 1) * w * 4,
            thumb ? 74 : 220,
          );
        }
      }
      return pixels;
    }

    final stitcher = ScrollStitcher(w, h)..add(shot(0));
    expect(stitcher.add(shot(200)).offset, 200);
    expect(stitcher.add(shot(800)).kind, ScrollMatchKind.unmatched);
    expect(stitcher.height, h + 200);
    for (final top in [400, 600, 800, 1000, 1200, 1381]) {
      final added = stitcher.add(shot(top));
      expect(added.kind, ScrollMatchKind.appended, reason: 'Y=$top');
      expect(stitcher.height, h + top);
    }
    expect(stitcher.add(shot(1381)).kind, ScrollMatchKind.unchanged);
    expect(stitcher.height, pageHeight);
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
