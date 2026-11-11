import 'dart:math' as math;
import 'dart:ui';

import '../models/arrow_style.dart';

/// The editor, hit testing and PNG export all use the same filled contours.
class ArrowGeometry {
  ArrowGeometry(Offset start, Offset end, double width, this.style) {
    final delta = end - start;
    if (start == end) {
      _circles.add((start, width / 2));
      return;
    }
    final shaft = [start];
    if (style == ArrowStyle.elbow && delta.dx != 0 && delta.dy != 0) {
      // Finish on the longer leg, leaving room for the head on a shallow turn.
      shaft.add(
        delta.dx.abs() >= delta.dy.abs()
            ? Offset(start.dx, end.dy)
            : Offset(end.dx, start.dy),
      );
    }
    shaft.add(end);
    final lastLeg = end - shaft[shaft.length - 2];
    final unit = lastLeg / lastLeg.distance;
    final normal = Offset(-unit.dy, unit.dx);
    final headLength = math.min(width * 14 / 3, lastLeg.distance * .48);
    final headHalf = headLength * 5 / 14;
    final base = end - unit * headLength;
    _shaftHalf = math.min(width / 2, lastLeg.distance / 12);

    if (style == ArrowStyle.filled || style == ArrowStyle.outlined) {
      final neckHalf = headHalf * .35;
      final contour = [
        start,
        base - normal * neckHalf,
        base - normal * headHalf,
        end,
        base + normal * headHalf,
        base + normal * neckHalf,
      ];
      _polygons.add(contour);
      if (style == ArrowStyle.outlined) {
        final inset = headHalf * .24;
        final shaftLength = delta.distance - headLength;
        final tailSlope = neckHalf / shaftLength;
        final headSlope = headHalf / headLength;
        final tailOffset = inset * math.sqrt(1 + tailSlope * tailSlope);
        final headOffset = inset * math.sqrt(1 + headSlope * headSlope);
        final innerBase = base + unit * inset;
        final innerNeck = neckHalf + tailSlope * inset - tailOffset;
        final innerWing = headHalf - headSlope * inset - headOffset;
        _polygons.add([
          start + unit * (tailOffset / tailSlope),
          innerBase - normal * innerNeck,
          innerBase - normal * innerWing,
          end - unit * (headOffset / headSlope),
          innerBase + normal * innerWing,
          innerBase + normal * innerNeck,
        ]);
      }
      return;
    }

    // All parts are painted in one path, so translucent heads and shafts do
    // not darken where their contours meet or overlap.
    _polygons.add([base - normal * headHalf, end, base + normal * headHalf]);
    shaft[shaft.length - 1] = base;
    if (style == ArrowStyle.doubleHeaded) {
      final firstBase = start + unit * headLength;
      _polygons.add([
        firstBase + normal * headHalf,
        start,
        firstBase - normal * headHalf,
      ]);
      shaft[0] = firstBase;
    }
    if (style == ArrowStyle.dashed) {
      _dashedShaft = (start, base);
      final length = (base - start).distance;
      final dash = math.max(_shaftHalf * 7, 1.0);
      final gap = math.max(_shaftHalf * 4, 1.0);
      final gaps = math.max(0, ((length - dash) / (dash + gap)).round());
      final dashLength = (length - gaps * gap) / (gaps + 1);
      for (var i = 0; i <= gaps; i++) {
        final from = start + unit * (i * (dashLength + gap));
        _addShaft(from, from + unit * dashLength);
      }
    } else {
      for (var i = 1; i < shaft.length; i++) {
        _addShaft(shaft[i - 1], shaft[i]);
      }
    }
  }

  final ArrowStyle style;
  final _polygons = <List<Offset>>[];
  final _circles = <(Offset, double)>[];
  (Offset, Offset)? _dashedShaft;
  double _shaftHalf = 0;

  void _addShaft(Offset start, Offset end) {
    final delta = end - start;
    if (delta.distanceSquared > 0) {
      final normal = Offset(-delta.dy, delta.dx) / delta.distance * _shaftHalf;
      _polygons.add([
        start - normal,
        end - normal,
        end + normal,
        start + normal,
      ]);
    }
    _circles.add((start, _shaftHalf));
    _circles.add((end, _shaftHalf));
  }

  Path get _path {
    final path = Path();
    if (style == ArrowStyle.outlined) path.fillType = PathFillType.evenOdd;
    for (final points in _polygons) {
      path.addPolygon(points, true);
    }
    for (final (center, radius) in _circles) {
      path.addOval(Rect.fromCircle(center: center, radius: radius));
    }
    return path;
  }

  Rect get bounds => _path.getBounds();

  bool hit(Offset point, double tolerance) {
    if (_path.contains(point)) return true;
    for (final polygon in _polygons) {
      for (var i = 0; i < polygon.length; i++) {
        if (distanceToSegment(
              point,
              polygon[i],
              polygon[(i + 1) % polygon.length],
            ) <=
            tolerance) {
          return true;
        }
      }
    }
    for (final (center, radius) in _circles) {
      if ((point - center).distance <= radius + tolerance) return true;
    }
    // A dashed shaft remains selectable in its gaps.
    final dashed = _dashedShaft;
    return dashed != null &&
        distanceToSegment(point, dashed.$1, dashed.$2) <=
            _shaftHalf + tolerance;
  }

  void paint(Canvas canvas, Paint paint) {
    canvas.drawPath(_path, paint..style = PaintingStyle.fill);
  }
}

double distanceToSegment(Offset point, Offset a, Offset b) {
  final delta = b - a;
  if (delta.distanceSquared == 0) return (point - a).distance;
  final relative = point - a;
  final t =
      ((relative.dx * delta.dx + relative.dy * delta.dy) /
              delta.distanceSquared)
          .clamp(0.0, 1.0);
  return (point - (a + delta * t)).distance;
}
