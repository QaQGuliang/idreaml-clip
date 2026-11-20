import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Distance kept between the floating screenshot toolbar and the screen edge.
const double screenshotToolbarMargin = 8;

/// Where the floating screenshot toolbar goes, in tools-area local coordinates.
@immutable
class ScreenshotToolbarPlacement {
  const ScreenshotToolbarPlacement(this.offset);

  final Offset offset;

  @override
  bool operator ==(Object other) =>
      other is ScreenshotToolbarPlacement && other.offset == offset;

  @override
  int get hashCode => offset.hashCode;
}

/// Keeps [offset] inside a screen of [screen] with an optional drag offset.
Offset clampToolbarToScreen(
  Offset offset,
  Size screen,
  Size toolbar, {
  double margin = screenshotToolbarMargin,
}) => Offset(
  offset.dx.clamp(
    margin,
    math.max(margin, screen.width - toolbar.width - margin),
  ),
  offset.dy.clamp(
    margin,
    math.max(margin, screen.height - toolbar.height - margin),
  ),
);

/// Places the floating toolbar at the bottom-left corner of [selection].
///
/// With no selection the screen's bottom-left corner is used. The toolbar may
/// overlap the selection by design; the user can drag it elsewhere. A
/// [dragOffset] always wins and is clamped to the screen.
ScreenshotToolbarPlacement placeScreenshotToolbar({
  required Size screen,
  required Size toolbar,
  Rect? selection,
  Offset? dragOffset,
  double margin = screenshotToolbarMargin,
}) {
  if (dragOffset != null) {
    return ScreenshotToolbarPlacement(
      clampToolbarToScreen(dragOffset, screen, toolbar, margin: margin),
    );
  }
  final anchor = selection?.bottomLeft ??
      Offset(margin, screen.height - margin);
  return ScreenshotToolbarPlacement(
    clampToolbarToScreen(
      Offset(anchor.dx, anchor.dy - toolbar.height),
      screen,
      toolbar,
      margin: margin,
    ),
  );
}
