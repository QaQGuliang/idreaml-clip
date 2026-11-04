import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

String screenshotHex(int rgb) =>
    '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// A read-only overlay. Both the preview and the RGB value use the frozen frame.
class ScreenshotColorPicker extends StatelessWidget {
  const ScreenshotColorPicker({
    super.key,
    required this.image,
    required this.pixel,
    required this.rgb,
    required this.anchor,
  });

  final ui.Image image;
  final Offset pixel;
  final int rgb;
  final Offset anchor;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: CustomSingleChildLayout(
      delegate: _PickerLayout(anchor),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: DecoratedBox(
          key: const ValueKey('screenshot-color-picker'),
          decoration: BoxDecoration(
            color: const Color(0xF5202024),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.white70),
          ),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: DefaultTextStyle(
              style: const TextStyle(
                fontSize: 12,
                height: 1.3,
                color: Colors.white,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CustomPaint(
                    size: const Size(144, 68),
                    painter: _PixelPreview(image, pixel),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: Color(0xFF000000 | rgb),
                          border: Border.all(color: Colors.white70),
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(screenshotHex(rgb)),
                    ],
                  ),
                  Text('RGB(${rgb >> 16}, ${(rgb >> 8) & 255}, ${rgb & 255})'),
                  const Text(
                    'C 复制色值 · F2 隐藏',
                    style: TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _PickerLayout extends SingleChildLayoutDelegate {
  const _PickerLayout(this.anchor);
  final Offset anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    const gap = 16.0;
    final maxX = math.max(0.0, size.width - childSize.width);
    final x = anchor.dx + gap <= maxX
        ? anchor.dx + gap
        : anchor.dx - gap - childSize.width;
    final maxY = math.max(0.0, size.height - childSize.height);
    return Offset(x.clamp(0, maxX), (anchor.dy + gap).clamp(0, maxY));
  }

  @override
  bool shouldRelayout(_PickerLayout oldDelegate) =>
      oldDelegate.anchor != anchor;
}

class _PixelPreview extends CustomPainter {
  const _PixelPreview(this.image, this.pixel);
  final ui.Image image;
  final Offset pixel;

  @override
  void paint(Canvas canvas, Size size) {
    const zoom = 8.0;
    final bounds = Offset.zero & size;
    final pixelCenter = pixel + const Offset(.5, .5);
    canvas.save();
    canvas.clipRect(bounds);
    canvas.drawRect(bounds, Paint()..color = const Color(0xFF303034));
    canvas.translate(bounds.center.dx, bounds.center.dy);
    canvas.scale(zoom);
    canvas.drawImage(
      image,
      -pixelCenter,
      Paint()..filterQuality = FilterQuality.none,
    );
    canvas.restore();

    final target = Rect.fromCenter(
      center: bounds.center,
      width: zoom,
      height: zoom,
    );
    final border = Paint()..style = PaintingStyle.stroke;
    canvas.drawRect(target.inflate(1), border..color = Colors.black);
    canvas.drawRect(target, border..color = Colors.white);
  }

  @override
  bool shouldRepaint(_PixelPreview oldDelegate) =>
      image != oldDelegate.image || pixel != oldDelegate.pixel;
}
