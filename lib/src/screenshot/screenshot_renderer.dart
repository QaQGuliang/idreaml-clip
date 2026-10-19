import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'screenshot_model.dart';

void paintAnnotation(Canvas canvas, ScreenshotAnnotation object) {
  final style = object.style;
  final paint = Paint()
    ..color = style.color
    ..strokeWidth = style.width
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  final points = object.points;
  switch (object.tool) {
    case ScreenshotTool.rectangle:
      canvas.drawRect(object.bounds, paint);
    case ScreenshotTool.ellipse:
      canvas.drawOval(object.bounds, paint);
    case ScreenshotTool.cover:
      canvas.drawRect(
        object.bounds,
        paint
          ..style = PaintingStyle.fill
          ..color = style.color.withAlpha(255),
      );
    case ScreenshotTool.line:
      canvas.drawLine(points.first, points.last, paint);
    case ScreenshotTool.arrow:
      canvas.drawLine(points.first, points.last, paint);
      final angle = math.atan2(
        points.last.dy - points.first.dy,
        points.last.dx - points.first.dx,
      );
      final length = math.max(10.0, style.width * 4);
      final path = Path()
        ..moveTo(
          points.last.dx - length * math.cos(angle - .5),
          points.last.dy - length * math.sin(angle - .5),
        )
        ..lineTo(points.last.dx, points.last.dy)
        ..lineTo(
          points.last.dx - length * math.cos(angle + .5),
          points.last.dy - length * math.sin(angle + .5),
        );
      canvas.drawPath(path, paint);
    case ScreenshotTool.pen:
    case ScreenshotTool.highlighter:
      if (object.tool == ScreenshotTool.highlighter) {
        paint.color = style.color.withAlpha(85);
      }
      final path = Path()..moveTo(points.first.dx, points.first.dy);
      for (final point in points.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      if (points.length == 1) {
        canvas.drawCircle(
          points.first,
          style.width / 2,
          paint..style = PaintingStyle.fill,
        );
      } else {
        canvas.drawPath(path, paint);
      }
    case ScreenshotTool.text:
      object.textPainter.paint(canvas, points.first);
    case ScreenshotTool.number:
      canvas.drawCircle(
        points.first,
        style.fontSize * .75,
        paint..style = PaintingStyle.fill,
      );
      final text = TextPainter(
        text: TextSpan(
          text: '${object.number}',
          style: TextStyle(
            color: const Color(0xFFFFFFFF),
            fontSize: style.fontSize,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(
        canvas,
        points.first - Offset(text.width / 2, text.height / 2),
      );
    case ScreenshotTool.mosaic:
    case ScreenshotTool.select:
      break;
  }
}

/// Mosaic samples already-composited pixels, including preceding annotations.
Future<ui.Image> renderScreenshot(
  ui.Image background,
  List<ScreenshotAnnotation> objects,
) async {
  final width = background.width, height = background.height;
  final bounds = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
  var recorder = ui.PictureRecorder();
  var canvas = Canvas(recorder)..drawImage(background, Offset.zero, Paint());
  final intermediates = <ui.Image>[];
  try {
    for (final object in objects) {
      if (object.tool != ScreenshotTool.mosaic) {
        paintAnnotation(canvas, object);
        continue;
      }
      final rect = object.bounds.intersect(bounds);
      if (rect.isEmpty) continue;
      final picture = recorder.endRecording();
      final previous = await picture.toImage(width, height);
      picture.dispose();
      // The new raster no longer depends on previous intermediate bitmaps.
      // Keep memory bounded even when many mosaic regions are drawn.
      for (final image in intermediates) {
        image.dispose();
      }
      intermediates.clear();
      intermediates.add(previous);
      final block = math.max(2.0, object.style.width);
      final lowWidth = math.max(1, (rect.width / block).ceil());
      final lowHeight = math.max(1, (rect.height / block).ceil());
      final smallRecorder = ui.PictureRecorder();
      Canvas(smallRecorder).drawImageRect(
        previous,
        rect,
        Rect.fromLTWH(0, 0, lowWidth.toDouble(), lowHeight.toDouble()),
        Paint()..filterQuality = FilterQuality.low,
      );
      final smallPicture = smallRecorder.endRecording();
      final small = await smallPicture.toImage(lowWidth, lowHeight);
      smallPicture.dispose();
      intermediates.add(small);
      recorder = ui.PictureRecorder();
      canvas = Canvas(recorder)
        ..drawImage(previous, Offset.zero, Paint())
        ..drawImageRect(
          small,
          Rect.fromLTWH(0, 0, lowWidth.toDouble(), lowHeight.toDouble()),
          rect,
          Paint()..filterQuality = FilterQuality.none,
        );
    }
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(width, height);
    } finally {
      picture.dispose();
    }
  } finally {
    for (final image in intermediates) {
      image.dispose();
    }
  }
}

Future<Uint8List> exportScreenshot(
  ui.Image background,
  ScreenshotSnapshot snapshot,
) async {
  final rect = snapshot.selection;
  if (rect == null || rect.isEmpty) throw const FormatException('请先选择截图区域');
  final composed = await renderScreenshot(background, snapshot.annotations);
  try {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImageRect(
      composed,
      rect,
      Rect.fromLTWH(0, 0, rect.width, rect.height),
      Paint(),
    );
    final picture = recorder.endRecording();
    final cropped = await picture.toImage(
      rect.width.toInt(),
      rect.height.toInt(),
    );
    picture.dispose();
    try {
      final bytes = await cropped.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw const FormatException('无法编码截图');
      return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
    } finally {
      cropped.dispose();
    }
  } finally {
    composed.dispose();
  }
}
