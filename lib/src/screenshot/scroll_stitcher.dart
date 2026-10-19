import 'dart:math' as math;
import 'dart:typed_data';

// Bound both the editor's texture size and its temporary full-image buffers.
const maxScrollImageSide = 8192;
const maxScrollImagePixels = 16000000;

enum ScrollMatchKind { first, appended, unchanged, reverse, unmatched, limit }

class ScrollMatch {
  const ScrollMatch(this.kind, [this.offset = 0]);
  final ScrollMatchKind kind;
  final int offset;
}

/// Raw BGRA rows remain untouched. Only matching uses sparse RGB samples.
class ScrollStitcher {
  ScrollStitcher(
    this.width,
    this.frameHeight, {
    this.maxHeight = maxScrollImageSide,
    this.maxPixels = maxScrollImagePixels,
  }) {
    if (width < 16 ||
        frameHeight < 32 ||
        width > maxScrollImageSide ||
        frameHeight > maxHeight ||
        width * frameHeight > maxPixels) {
      throw const FormatException('选区过小或过大，请重新框选滚动内容');
    }
  }

  final int width, frameHeight, maxHeight, maxPixels;
  final List<Uint8List> _parts = [];
  Uint8List? _referenceSamples;
  int height = 0;
  static const _columns = 48;
  static const _rowBytes = _columns * 3;

  Uint8List _sample(Uint8List pixels) {
    if (pixels.length != width * frameHeight * 4) {
      throw const FormatException('采集画面尺寸发生变化');
    }
    final samples = Uint8List(frameHeight * _rowBytes);
    for (var y = 0; y < frameHeight; y++) {
      for (var x = 0; x < _columns; x++) {
        // Keep the scrollbar and the selection boundary out of matching.
        final column = ((x + .5) * width / _columns).floor();
        final from = (y * width + column) * 4;
        final to = y * _rowBytes + x * 3;
        samples.setRange(to, to + 3, pixels, from);
      }
    }
    return samples;
  }

  ScrollMatch add(Uint8List pixels) {
    final samples = _sample(pixels);
    final previous = _referenceSamples;
    if (previous == null) {
      _parts.add(pixels);
      _referenceSamples = samples;
      height = frameHeight;
      return const ScrollMatch(ScrollMatchKind.first);
    }
    final match = _match(previous, samples);
    if (match.kind != ScrollMatchKind.appended) return match;
    final nextHeight = height + match.offset;
    if (nextHeight > maxHeight || nextHeight * width > maxPixels) {
      return const ScrollMatch(ScrollMatchKind.limit);
    }
    _parts.add(
      Uint8List.fromList(
        pixels.sublist((frameHeight - match.offset) * width * 4),
      ),
    );
    _referenceSamples = samples;
    height = nextHeight;
    return match;
  }

  ScrollMatch _match(Uint8List a, Uint8List b) {
    final stationary = _score(a, b, 0, dense: true);
    if (stationary.error < .18 && stationary.badFraction < .001) {
      return const ScrollMatch(ScrollMatchKind.unchanged);
    }
    final minOverlap = math.max(16, (frameHeight * .22).ceil());
    final maxShift = frameHeight - minOverlap;
    final candidates = <({int shift, double score})>[];
    for (var shift = -maxShift; shift <= maxShift; shift++) {
      if (shift == 0) continue;
      final score = _score(a, b, shift, dense: false).error;
      if (score > 10) continue;
      if (candidates.length == 12 && score >= candidates.last.score) continue;
      candidates.add((shift: shift, score: score));
      candidates.sort((left, right) => left.score.compareTo(right.score));
      if (candidates.length > 12) candidates.removeLast();
    }
    final verified = <({int shift, double score})>[];
    for (final candidate in candidates) {
      final score = _score(a, b, candidate.shift, dense: true);
      if (score.error <= 2 &&
          score.badFraction <= .012 &&
          _hasDetail(a, candidate.shift)) {
        verified.add((shift: candidate.shift, score: score.error));
      }
    }
    if (verified.isEmpty) return const ScrollMatch(ScrollMatchKind.unmatched);
    verified.sort((left, right) => left.score.compareTo(right.score));
    final best = verified.first;
    // Repeated text/stripes must not choose an arbitrary equal-looking offset.
    if (verified
        .skip(1)
        .any(
          (other) =>
              (other.shift - best.shift).abs() > 1 &&
              other.score <= best.score + .35,
        )) {
      return const ScrollMatch(ScrollMatchKind.unmatched);
    }
    if (best.shift < 0) return ScrollMatch(ScrollMatchKind.reverse, best.shift);
    return ScrollMatch(ScrollMatchKind.appended, best.shift);
  }

  ({double error, double badFraction}) _score(
    Uint8List a,
    Uint8List b,
    int shift, {
    required bool dense,
  }) {
    final overlap = frameHeight - shift.abs();
    final rows = math.min(overlap, dense ? 128 : 24);
    final columnStep = dense ? 1 : 3;
    var error = 0, count = 0, bad = 0;
    for (var row = 0; row < rows; row++) {
      final y = ((row + .5) * overlap / rows).floor();
      final aRow = (y + math.max<int>(0, shift)) * _rowBytes;
      final bRow = (y + math.max<int>(0, -shift)) * _rowBytes;
      for (var column = 0; column < _columns; column += columnStep) {
        var pixelError = 0;
        for (var channel = 0; channel < 3; channel++) {
          pixelError +=
              (a[aRow + column * 3 + channel] - b[bRow + column * 3 + channel])
                  .abs();
        }
        error += pixelError;
        if (pixelError > 48) bad++;
        count++;
      }
    }
    return (error: error / (count * 3), badFraction: bad / count);
  }

  bool _hasDetail(Uint8List samples, int shift) {
    final start = math.max(0, shift);
    final overlap = frameHeight - shift.abs();
    final hashes = <int>{};
    final step = math.max(1, overlap ~/ 64);
    for (var y = start; y < start + overlap; y += step) {
      var hash = 0;
      for (var x = 0; x < _rowBytes; x++) {
        hash = (hash * 31 + (samples[y * _rowBytes + x] >> 3)) & 0x7fffffff;
      }
      hashes.add(hash);
      if (hashes.length >= 6) return true;
    }
    return false;
  }

  Uint8List compose() {
    if (height == 0) throw StateError('尚未采集到画面');
    final result = Uint8List(width * height * 4);
    var offset = 0;
    for (final part in _parts) {
      result.setRange(offset, offset + part.length, part);
      offset += part.length;
    }
    return result;
  }

  ({Uint8List pixels, int width, int height}) thumbnail() {
    final scale = math.min(160 / width, 140 / height);
    final w = math.max(1, (width * scale).round());
    final h = math.max(1, (height * scale).round());
    final result = Uint8List(w * h * 4);
    var partIndex = 0, partStart = 0;
    for (var y = 0; y < h; y++) {
      final sourceY = math.min(height - 1, (y / scale).floor());
      while (sourceY >= partStart + _parts[partIndex].length ~/ (width * 4)) {
        partStart += _parts[partIndex].length ~/ (width * 4);
        partIndex++;
      }
      for (var x = 0; x < w; x++) {
        final sourceX = math.min(width - 1, (x / scale).floor());
        final from = ((sourceY - partStart) * width + sourceX) * 4;
        result.setRange(
          (y * w + x) * 4,
          (y * w + x + 1) * 4,
          _parts[partIndex],
          from,
        );
      }
    }
    return (pixels: result, width: w, height: h);
  }
}
