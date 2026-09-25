import 'dart:math' as math;
import 'dart:ui';

const quickPanelSize = Size(347, 427);

Rect nearestWorkArea(Offset pointer, List<Rect> workAreas) {
  if (workAreas.isEmpty) {
    throw ArgumentError.value(workAreas, 'workAreas', 'Must not be empty');
  }

  double distanceSquared(Rect area) {
    final nearest = Offset(
      pointer.dx.clamp(area.left, area.right),
      pointer.dy.clamp(area.top, area.bottom),
    );
    return (pointer - nearest).distanceSquared;
  }

  return workAreas.reduce(
    (a, b) => distanceSquared(a) <= distanceSquared(b) ? a : b,
  );
}

/// Keeps the popup near the pointer and inside the nearest screen's work area.
Rect placeQuickPanel({
  required Offset pointer,
  required List<Rect> workAreas,
  double scale = 1,
}) {
  final area = nearestWorkArea(pointer, workAreas);
  final margin = 8.0 * scale;
  final gap = 12.0 * scale;
  final inset = math.min(margin, math.min(area.width, area.height) / 4);
  final usable = area.deflate(inset);
  final size = Size(
    math.min(quickPanelSize.width * scale, usable.width),
    math.min(quickPanelSize.height * scale, usable.height),
  );
  var x = pointer.dx + gap;
  var y = pointer.dy + gap;
  if (x + size.width > usable.right) x = pointer.dx - size.width - gap;
  if (y + size.height > usable.bottom) y = pointer.dy - size.height - gap;
  return Rect.fromLTWH(
    x.clamp(usable.left, usable.right - size.width),
    y.clamp(usable.top, usable.bottom - size.height),
    size.width,
    size.height,
  );
}
