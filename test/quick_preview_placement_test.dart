import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/services/quick_preview_placement.dart';

void main() {
  test('图片预览保持横图、竖图及长截图比例，边缘和高 DPI 下完整可见', () {
    for (final imageSize in [
      const Size(1600, 900),
      const Size(900, 1600),
      const Size(400, 4000),
      const Size(32, 16),
    ]) {
      for (final (panel, area, scale) in [
        (
          const Rect.fromLTWH(100, 200, 347, 427),
          const Rect.fromLTWH(0, 0, 1920, 1040),
          1.0,
        ),
        (
          const Rect.fromLTWH(1550, 500, 347, 427),
          const Rect.fromLTWH(0, 0, 1920, 1040),
          1.0,
        ),
        (
          const Rect.fromLTWH(-1400, 60, 694, 854),
          const Rect.fromLTWH(-1920, 0, 1920, 1080),
          2.0,
        ),
        (
          const Rect.fromLTWH(180, 50, 347, 427),
          const Rect.fromLTWH(0, 0, 700, 600),
          1.0,
        ),
      ]) {
        final result = placeQuickPreview(
          panel: panel,
          workArea: area,
          scale: scale,
          imageSize: imageSize,
        );
        expect(
          result.previewBounds.size.aspectRatio,
          closeTo(imageSize.aspectRatio, 0.00001),
        );
        expect(result.panelBounds, panel);
        expect(area.contains(result.windowBounds.topLeft), isTrue);
        expect(area.contains(result.windowBounds.bottomRight), isTrue);
        expect(result.previewLocal.width, lessThanOrEqualTo(480));
        expect(result.previewLocal.height, lessThanOrEqualTo(427));
      }
    }
  });

  test('右侧、左侧、副屏高 DPI 与窄屏预览都在可用区域内，原面板不移动', () {
    for (final (panel, area, scale) in [
      (
        const Rect.fromLTWH(100, 200, 347, 427),
        const Rect.fromLTWH(0, 0, 1920, 1040),
        1.0,
      ),
      (
        const Rect.fromLTWH(1550, 500, 347, 427),
        const Rect.fromLTWH(0, 0, 1920, 1040),
        1.0,
      ),
      (
        const Rect.fromLTWH(-1400, 60, 694, 854),
        const Rect.fromLTWH(-1920, 0, 1920, 1080),
        2.0,
      ),
      (
        const Rect.fromLTWH(260, 50, 347, 427),
        const Rect.fromLTWH(0, 0, 900, 600),
        1.0,
      ),
      (
        const Rect.fromLTWH(180, 50, 347, 427),
        const Rect.fromLTWH(0, 0, 700, 600),
        1.0,
      ),
    ]) {
      final result = placeQuickPreview(
        panel: panel,
        workArea: area,
        scale: scale,
      );
      expect(result.panelBounds, panel);
      expect(area.contains(result.windowBounds.topLeft), isTrue);
      expect(area.contains(result.windowBounds.bottomRight), isTrue);
      expect(result.panelLocal.size, const Size(347, 427));
      expect(result.previewBounds.width, greaterThan(200 * scale));
    }
  });
}
