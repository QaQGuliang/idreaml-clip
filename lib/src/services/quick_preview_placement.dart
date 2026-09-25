import 'dart:math' as math;
import 'dart:ui';

class QuickPreviewPlacement {
  const QuickPreviewPlacement({
    required this.windowBounds,
    required this.panelBounds,
    required this.previewBounds,
    this.scale = 1,
  });
  final Rect windowBounds;
  final Rect panelBounds;
  final Rect previewBounds;
  final double scale;

  Rect _local(Rect rect) => Rect.fromLTWH(
    (rect.left - windowBounds.left) / scale,
    (rect.top - windowBounds.top) / scale,
    rect.width / scale,
    rect.height / scale,
  );
  Rect get panelLocal => _local(panelBounds);
  Rect get previewLocal => _local(previewBounds);
}

QuickPreviewPlacement placeQuickPreview({
  required Rect panel,
  required Rect workArea,
  double scale = 1,
  Size? imageSize,
}) {
  final area = workArea.deflate(8 * scale);
  final gap = 8 * scale;
  Size fitImage(Size limit) {
    final source = imageSize!;
    final factor = math.min(
      scale,
      math.min(limit.width / source.width, limit.height / source.height),
    );
    return source * factor;
  }

  final image =
      imageSize != null &&
      imageSize.width > 0 &&
      imageSize.height > 0 &&
      imageSize.width.isFinite &&
      imageSize.height.isFinite;
  final preferred = image
      ? fitImage(Size(480 * scale, math.min(panel.height, area.height)))
      : Size(380 * scale, math.min(panel.height, area.height));
  final rightSpace = math.max(0.0, area.right - panel.right - gap);
  final leftSpace = math.max(0.0, panel.left - area.left - gap);
  final onRight = rightSpace >= preferred.width || rightSpace >= leftSpace;
  final space = onRight ? rightSpace : leftSpace;
  if (space < math.min(220 * scale, preferred.width)) {
    // Very small work areas use an in-panel popup without moving the item.
    final available = panel.deflate(12 * scale);
    final size = image ? fitImage(available.size) : available.size;
    final preview = Rect.fromCenter(
      center: available.center,
      width: size.width,
      height: size.height,
    );
    return QuickPreviewPlacement(
      windowBounds: panel,
      panelBounds: panel,
      previewBounds: preview,
      scale: scale,
    );
  }
  final size = image
      ? fitImage(Size(math.min(preferred.width, space), preferred.height))
      : Size(math.min(preferred.width, space), preferred.height);
  final width = size.width;
  final height = size.height;
  final preview = Rect.fromLTWH(
    onRight ? panel.right + gap : panel.left - gap - width,
    (image ? panel.center.dy - height / 2 : panel.top).clamp(
      area.top,
      area.bottom - height,
    ),
    width,
    height,
  );
  return QuickPreviewPlacement(
    windowBounds: panel.expandToInclude(preview),
    panelBounds: panel,
    previewBounds: preview,
    scale: scale,
  );
}
