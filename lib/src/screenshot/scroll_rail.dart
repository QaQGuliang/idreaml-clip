part of 'scroll_stitcher.dart';

/// A narrow opaque track around a thumb. Only the strip proven to contain
/// uniform track pixels above and below the thumb is safe to extend.
class _ScrollRail {
  _ScrollRail(
    this.left,
    this.right,
    this.start,
    this.end,
    this.track,
    this.thumbTop,
    this.thumbHeight,
    this.thumbPixels,
  );

  final int left, right, start, end, track, thumbTop, thumbHeight;
  final Uint32List thumbPixels;

  static _ScrollRail? read(
    Uint8List pixels,
    int width,
    int height,
    _Thumb? thumb, {
    _ScrollRail? reference,
  }) {
    if (thumb == null) return null;
    final data = ByteData.sublistView(pixels);
    int color(int x, int y) => data.getUint32((y * width + x) * 4);
    final track = (thumb.track << 8) | 255;
    final top = thumb.top,
        end = top + thumb.height,
        middle = top + thumb.height ~/ 2;
    bool ink(int x) =>
        color(x, middle) != track &&
        (top > 0 && color(x, top - 1) == track ||
            end < height && color(x, end) == track);
    if (!ink(thumb.x)) return null;
    var left = thumb.x, right = left + 1;
    while (left > 0 && right - left <= 32 && ink(left - 1)) {
      left--;
    }
    while (right < width && right - left <= 32 && ink(right)) {
      right++;
    }
    if (right - left < 2 || right - left > 32) return null;

    bool clearRow(int y) {
      for (var x = left; x < right; x++) {
        if (color(x, y) != track) return false;
      }
      return true;
    }

    var start = top, stop = end;
    while (start > 0 && clearRow(start - 1)) {
      start--;
    }
    while (stop < height && clearRow(stop)) {
      stop++;
    }
    // A colored block in a narrow page column may resemble a thumb. It must
    // also be surrounded by an uninterrupted, full-length physical rail.
    if (stop - start < thumb.rail * .85) return null;
    if (reference != null) {
      return reference.left == left &&
              reference.right == right &&
              reference.start == start &&
              reference.end == stop &&
              reference.track == track
          ? reference
          : null;
    }
    final thumbPixels = Uint32List((right - left) * thumb.height);
    for (var y = top; y < end; y++) {
      for (var x = left; x < right; x++) {
        thumbPixels[(y - top) * (right - left) + x - left] = color(x, y);
      }
    }
    return _ScrollRail(
      left,
      right,
      start,
      stop,
      track,
      top,
      thumb.height,
      thumbPixels,
    );
  }

  // The initial thumb and the original end buttons are retained. Extend the
  // confirmed track between them at the same scale as the surrounding image.
  void paint(
    Uint8List pixels,
    int width,
    int height,
    int verifiedEnd, {
    double scale = 1,
  }) {
    final data = ByteData.sublistView(pixels);
    for (
      var x = (left * scale).ceil();
      x < math.min(width, (right * scale).ceil());
      x++
    ) {
      final sourceX = (x / scale).floor().clamp(left, right - 1);
      for (
        var y = (start * scale).ceil();
        y < math.min(height, (verifiedEnd * scale).ceil());
        y++
      ) {
        final thumbRow = (y / scale).floor() - thumbTop;
        final color = thumbRow >= 0 && thumbRow < thumbHeight
            ? thumbPixels[thumbRow * (right - left) + sourceX - left]
            : track;
        data.setUint32((y * width + x) * 4, color);
      }
    }
  }
}
