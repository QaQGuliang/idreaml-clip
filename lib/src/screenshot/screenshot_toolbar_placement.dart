import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Distance kept between the floating screenshot toolbar and the screen edge.
const double screenshotToolbarMargin = 8;

/// Screen edge the toolbar hugs when no free spot exists around the selection.
enum ScreenshotToolbarEdge { top, bottom, left, right }

/// Where the floating screenshot toolbar goes, in tools-area local coordinates.
@immutable
class ScreenshotToolbarPlacement {
  const ScreenshotToolbarPlacement(this.offset, {this.edge});

  final Offset offset;

  /// Non-null when no position outside the selection was found, so the toolbar
  /// is pinned to [edge] and unavoidably covers part of the selection.
  final ScreenshotToolbarEdge? edge;

  bool get edgeHugging => edge != null;

  @override
  bool operator ==(Object other) =>
      other is ScreenshotToolbarPlacement &&
      other.offset == offset &&
      other.edge == edge;

  @override
  int get hashCode => Object.hash(offset, edge);
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

/// Places the floating toolbar next to [selection] without covering it.
///
/// Order: below, above, right, left. When the selection leaves no free band
/// (a capture that is almost the whole screen), the toolbar hugs the nearest
/// screen edge and the caller can render it in its compact single-row form;
/// the user can then drag it away.
ScreenshotToolbarPlacement placeScreenshotToolbar({
  required Size screen,
  required Size toolbar,
  Rect? selection,
  Offset? dragOffset,
  double margin = screenshotToolbarMargin,
}) {
  final origin = Offset(margin, margin);
  if (selection == null) {
    return ScreenshotToolbarPlacement(
      clampToolbarToScreen(
        dragOffset ?? origin,
        screen,
        toolbar,
        margin: margin,
      ),
    );
  }
  if (dragOffset != null) {
    return ScreenshotToolbarPlacement(
      clampToolbarToScreen(dragOffset, screen, toolbar, margin: margin),
    );
  }

  final maxLeft = math.max(0.0, screen.width - toolbar.width);
  final maxTop = math.max(0.0, screen.height - toolbar.height);
  double alignX(double x) => x.clamp(0.0, maxLeft);
  double alignY(double y) => y.clamp(0.0, maxTop);

  final candidates = <Offset>[
    // Below the selection.
    if (selection.bottom + toolbar.height <= screen.height - margin)
      Offset(alignX(selection.left), selection.bottom),
    // Above the selection.
    if (selection.top - toolbar.height >= margin)
      Offset(alignX(selection.left), selection.top - toolbar.height),
    // Beside the selection on the right.
    if (selection.right + toolbar.width <= screen.width - margin)
      Offset(selection.right, alignY(selection.top)),
    // Beside the selection on the left.
    if (selection.left - toolbar.width >= margin)
      Offset(selection.left - toolbar.width, alignY(selection.top)),
  ];
  for (final candidate in candidates) {
    final bounds = candidate & toolbar;
    // Clamping can still nudge a candidate across the selection on a screen
    // that is narrower than the toolbar.
    if (!bounds.overlaps(selection)) {
      return ScreenshotToolbarPlacement(candidate);
    }
  }

  // No free band: pin to the closest edge of the screen.
  final distances = {
    ScreenshotToolbarEdge.top: math.max(0.0, selection.top),
    ScreenshotToolbarEdge.bottom: math.max(
      0.0,
      screen.height - selection.bottom,
    ),
    ScreenshotToolbarEdge.left: math.max(0.0, selection.left),
    ScreenshotToolbarEdge.right: math.max(0.0, screen.width - selection.right),
  };
  var edge = ScreenshotToolbarEdge.top;
  for (final candidate in [
    ScreenshotToolbarEdge.bottom,
    ScreenshotToolbarEdge.left,
    ScreenshotToolbarEdge.right,
  ]) {
    if (distances[candidate]! < distances[edge]!) edge = candidate;
  }
  final centeredX = clampToolbarToScreen(
    Offset(selection.center.dx - toolbar.width / 2, 0),
    screen,
    toolbar,
    margin: margin,
  ).dx;
  final centeredY = clampToolbarToScreen(
    Offset(0, selection.center.dy - toolbar.height / 2),
    screen,
    toolbar,
    margin: margin,
  ).dy;
  final offset = switch (edge) {
    ScreenshotToolbarEdge.top => Offset(centeredX, margin),
    ScreenshotToolbarEdge.bottom => Offset(
      centeredX,
      math.max(margin, screen.height - toolbar.height - margin),
    ),
    ScreenshotToolbarEdge.left => Offset(margin, centeredY),
    ScreenshotToolbarEdge.right => Offset(
      math.max(margin, screen.width - toolbar.width - margin),
      centeredY,
    ),
  };
  return ScreenshotToolbarPlacement(offset, edge: edge);
}
