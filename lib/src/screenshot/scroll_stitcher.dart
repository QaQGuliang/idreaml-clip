import 'dart:math' as math;
import 'dart:typed_data';

part 'scroll_rail.dart';

// Bound both the editor's texture size and its temporary full-image buffers.
const maxScrollImageSide = 8192;
const maxScrollImagePixels = 16000000;

enum ScrollMatchKind { first, appended, unchanged, reverse, unmatched, limit }

class ScrollMatch {
  const ScrollMatch(this.kind, [this.offset = 0]) : _refreshReference = false;
  const ScrollMatch._stationaryUpdate()
    : kind = ScrollMatchKind.unchanged,
      offset = 0,
      _refreshReference = true;
  final ScrollMatchKind kind;
  final int offset;
  final bool _refreshReference;
}

/// Tracks spatial coverage rather than letting a dense animated widget win
/// through its number of pixels. Fixed top/bottom bars alone are not evidence
/// that the page between them is stationary.
class _MotionEvidence {
  final _laneBands = Uint8List(ScrollStitcher._lanes);
  var hits = 0;

  void add(int lane, int band) {
    _laneBands[lane] |= 1 << band;
    hits++;
  }

  bool distributed({
    required bool stationary,
    int minimumLanes = 2,
    bool interiorOnly = false,
  }) {
    if (hits < 10) return false;
    var bands = 0, matchingLanes = 0;
    final edge = interiorOnly ? 2 : 0;
    for (var lane = edge; lane < _laneBands.length - edge; lane++) {
      final mask = _laneBands[lane];
      if (mask == 0 || (mask & (mask - 1)) == 0) continue;
      if (stationary && (mask & 0x3c) == 0) continue;
      matchingLanes++;
      bands |= mask;
    }
    if (matchingLanes < minimumLanes) return false;
    var count = 0;
    while (bands != 0) {
      bands &= bands - 1;
      count++;
    }
    return count >= (stationary ? 4 : 3);
  }
}

typedef _Thumb = ({int x, int top, int height, int rail, int track, int color});

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
  ({Uint8List pixels, int width, int height})? _lastViewport;
  Uint8List? _referenceSamples;
  Uint32List? _referenceEdge;
  List<Map<int, int>>? _referenceAnchors;
  _Thumb? _referenceThumb;
  _ScrollRail? _rail;
  bool _railEnded = false;
  int _verifiedRailEnd = 0;
  int height = 0;
  static const _columns = 48;
  static const _rowBytes = _columns * 3;
  late final _columnOffsets = List.generate(
    _columns,
    (x) => ((x + .5) * width / _columns).floor() * 4,
    growable: false,
  );

  Uint8List _sample(Uint8List pixels) {
    if (pixels.length != width * frameHeight * 4) {
      throw const FormatException('采集画面尺寸发生变化');
    }
    final samples = Uint8List(frameHeight * _rowBytes);
    for (var y = 0; y < frameHeight; y++) {
      for (var x = 0; x < _columns; x++) {
        final from = y * width * 4 + _columnOffsets[x];
        final to = y * _rowBytes + x * 3;
        samples[to] = pixels[from];
        samples[to + 1] = pixels[from + 1];
        samples[to + 2] = pixels[from + 2];
      }
    }
    return samples;
  }

  ScrollMatch add(Uint8List pixels) {
    final samples = _sample(pixels);
    final previous = _referenceSamples;
    if (previous == null) {
      _parts.add(pixels);
      _referenceEdge = _sampleRightEdge(pixels);
      _referenceSamples = samples;
      _referenceThumb = _readThumb(pixels);
      _rail = _ScrollRail.read(pixels, width, frameHeight, _referenceThumb);
      height = frameHeight;
      return const ScrollMatch(ScrollMatchKind.first);
    }
    var match = _match(previous, samples);
    List<Map<int, int>>? anchors;
    final thumb = _readThumb(pixels);
    final thumbMotion = _thumbMotion(_referenceThumb, thumb);
    // The thin rail may lie between all 48 sampled columns. Give contradictory
    // motion a second look, allowing for a one-pixel change in thumb position.
    final recheck =
        thumbMotion != null &&
        thumb != null &&
        ((match.kind == ScrollMatchKind.unchanged && thumbMotion != 0) ||
            (match.offset != 0 &&
                (match.offset - thumbMotion).abs() >
                    math.max(
                      thumb.rail / thumb.height + 1,
                      match.offset.abs() * .12,
                    )));
    if (match.kind == ScrollMatchKind.unmatched || recheck) {
      anchors = _anchors(samples);
      match = _matchRegions(
        previous,
        samples,
        _referenceAnchors ??= _anchors(previous),
        anchors,
        thumbMotion,
        thumb,
      );
    }
    if (match._refreshReference) {
      // The next step starts from the new layout/rail position. Existing
      // output pixels are already at the verified document position.
      _referenceSamples = samples;
      _referenceEdge = _sampleRightEdge(pixels);
      _referenceAnchors = anchors;
      _referenceThumb = thumb;
      _lastViewport = _thumbnailOf([pixels], frameHeight);
    }
    if (match.kind != ScrollMatchKind.appended) return match;
    final nextHeight = height + match.offset;
    if (nextHeight > maxHeight || nextHeight * width > maxPixels) {
      return const ScrollMatch(ScrollMatchKind.limit);
    }
    final edge = _sampleRightEdge(pixels);
    final overlap = frameHeight - match.offset;
    final cut = _overlapCut(
      previous,
      samples,
      _referenceEdge!,
      edge,
      match.offset,
    );
    if (cut == null) return const ScrollMatch(ScrollMatchKind.unmatched);
    var remove = (overlap - cut) * width * 4;
    while (remove > 0) {
      final part = _parts.removeLast();
      if (part.length > remove) {
        final retained = part.length - remove;
        _parts.add(
          retained * 2 < part.buffer.lengthInBytes
              ? part.sublist(0, retained)
              : Uint8List.sublistView(part, 0, retained),
        );
      }
      remove -= part.length;
    }
    final from = cut * width * 4;
    _parts.add(
      from > pixels.length ~/ 2
          ? pixels.sublist(from)
          : Uint8List.sublistView(pixels, from),
    );
    final rail = _rail;
    if (rail != null) {
      // When a rail disappears or changes track, retain only the verified
      // prefix that still belongs to the old source. Leave the new tail raw.
      final documentTop = nextHeight - frameHeight;
      _verifiedRailEnd = math.min(_verifiedRailEnd, documentTop + cut);
      if (!_railEnded) {
        _railEnded =
            _ScrollRail.read(
              pixels,
              width,
              frameHeight,
              thumb,
              reference: rail,
            ) ==
            null;
        final moved =
            thumbMotion != null &&
            thumbMotion > 0 &&
            thumb != null &&
            (thumbMotion - match.offset).abs() <= thumb.rail / thumb.height + 1;
        if (!_railEnded && (_verifiedRailEnd > 0 || moved)) {
          _verifiedRailEnd = rail.end + documentTop;
        }
      }
    }
    _referenceEdge = edge;
    _referenceSamples = samples;
    _referenceAnchors = anchors;
    _referenceThumb = thumb;
    // The composed tail can differ from the last real viewport when the
    // page has a sticky header or a playing video.
    _lastViewport = _thumbnailOf([pixels], frameHeight);
    height = nextHeight;
    return match;
  }

  // Ignore narrow scrollbar or indicator changes when locating fixed chrome.
  int _fixedRows(Uint8List a, Uint8List b, int limit, {required bool bottom}) {
    var rows = 0;
    while (rows < limit) {
      final start = (bottom ? frameHeight - 1 - rows : rows) * _rowBytes;
      var differences = 0;
      for (var x = start; x < start + _rowBytes; x += 3) {
        if (a[x] != b[x] || a[x + 1] != b[x + 1] || a[x + 2] != b[x + 2]) {
          if (++differences > 2) return rows;
        }
      }
      rows++;
    }
    return rows;
  }

  // Thin scrollbar arrows and edge controls can fall between all regular
  // samples. Only this narrow strip is needed alongside the match reference.
  static const _edgeColumns = 8;

  Uint32List _sampleRightEdge(Uint8List pixels) {
    final result = Uint32List(frameHeight * _edgeColumns);
    final step = math.min(4, width ~/ _edgeColumns);
    for (var y = 0; y < frameHeight; y++) {
      for (var x = 0; x < _edgeColumns; x++) {
        final p = ((y + 1) * width - 1 - x * step) * 4;
        result[y * _edgeColumns + x] =
            pixels[p] | (pixels[p + 1] << 8) | (pixels[p + 2] << 16);
      }
    }
    return result;
  }

  int _rowDisagreements(Uint8List a, Uint8List b, int oldY, int y) {
    var count = 0;
    var p = oldY * _rowBytes, q = y * _rowBytes;
    for (var x = 0; x < _columns; x++, p += 3, q += 3) {
      if (!_sameSample(a, p, b, q)) count++;
    }
    return count;
  }

  bool _sameSample(Uint8List a, int p, Uint8List b, int q) =>
      a[p] == b[q] && a[p + 1] == b[q + 1] && a[p + 2] == b[q + 2];

  // A wide, textured horizontal edge that stays at the same screen position
  // below a moving column can be the rim of a floating player. Large jumps
  // must expose that rim above the new header to recover the covered content.
  int _lowerFixedEdge(Uint8List old, Uint8List current, int header, int shift) {
    final middle = frameHeight ~/ 2;
    final movingAbove = Uint8List(_columns);
    for (var x = 0; x < _columns; x++) {
      var different = 0;
      for (var y = header; y < middle; y += 4) {
        final p = y * _rowBytes + 3 * x;
        if (!_sameSample(old, p, current, p) && ++different == 3) {
          movingAbove[x] = 1;
          break;
        }
      }
    }
    for (var y = middle; y + 2 < frameHeight; y++) {
      var adjacent = 0;
      for (var x = 0; x < _columns; x++) {
        final p = y * _rowBytes + 3 * x, q = p + 2 * _rowBytes;
        if ((movingAbove[x] != 0 || x >= _columns * 7 ~/ 8) &&
            _sameSample(old, p, current, p) &&
            _sameSample(old, q, current, q) &&
            !_sameSample(old, p, old, q) &&
            (y < shift + header ||
                !_sameSample(old, p, current, p - shift * _rowBytes) ||
                !_sameSample(old, q, current, q - shift * _rowBytes))) {
          if (++adjacent >= 3) return y - 4;
          // A row of side buttons can occupy only one sample column. Require
          // several more identical screen pixels through its textured edge.
          if (x >= _columns * 7 ~/ 8 && y + 12 < frameHeight) {
            var rows = 0;
            for (var n = 0; n < 12; n++) {
              final at = p + n * _rowBytes;
              if (!_sameSample(old, at, current, at)) break;
              rows++;
            }
            if (rows == 12) return y - 4;
          }
        } else {
          adjacent = 0;
        }
      }
    }
    return frameHeight;
  }

  // old[y + shift] and current[y] refer to the same document row. A bottom-
  // aligned splice burns floating widgets from the old viewport into the page.
  // Roll the tail forward at a continuous band above those widgets instead.
  int? _overlapCut(
    Uint8List old,
    Uint8List current,
    Uint32List oldEdge,
    Uint32List edge,
    int shift,
  ) {
    final overlap = frameHeight - shift;
    final header = _fixedRows(old, current, frameHeight ~/ 2, bottom: false);
    final end = shift >= frameHeight ~/ 2
        ? _lowerFixedEdge(old, current, header, shift) - shift
        : overlap;
    if (end <= header) return null;
    var changedRows = 0;
    for (var y = math.max(header, frameHeight ~/ 2 - shift); y < overlap; y++) {
      final oldY = y + shift;
      var changed = _rowDisagreements(old, current, oldY, y) >= 3;
      for (var x = 0; !changed && x < _edgeColumns; x++) {
        final oldPixel = oldEdge[oldY * _edgeColumns + x];
        changed =
            oldPixel == edge[oldY * _edgeColumns + x] &&
            oldPixel != edge[y * _edgeColumns + x];
      }
      if (changed && ++changedRows >= 3) break;
    }
    // Preserve the original capture if just a few pixels repainted.
    if (changedRows < 3 && end == overlap) return overlap;

    final band = math.min(9, end - header);
    final ideal = header + (end - header - band) ~/ 3;
    final disagreements = Uint8List(end - header);
    var sum = 0, best = 0x7fffffff, cut = overlap;
    for (var y = header; y < end; y++) {
      final i = y - header;
      final count = _rowDisagreements(old, current, y + shift, y);
      disagreements[i] = count;
      sum += count;
      if (i >= band) sum -= disagreements[i - band];
      if (i < band - 1) continue;
      final start = y + 1 - band;
      final score = sum * overlap + (start - ideal).abs();
      if (score < best) {
        best = score;
        cut = start + band ~/ 2;
      }
    }
    return cut;
  }

  // A fingerprint covers four sample columns over five rows. Index only
  // landmarks that occur exactly once in their lane within this viewport.
  // Common background, text baselines and periodic patterns cannot vote.
  static const _laneColumns = 4;
  static const _lanes = _columns ~/ _laneColumns;
  List<Map<int, int>> _anchors(Uint8List samples) {
    final index = List.generate(_lanes, (_) => <int, int>{});
    final rows = Uint32List(frameHeight);
    for (var lane = 0; lane < _lanes; lane++) {
      for (var y = 0; y < frameHeight; y++) {
        var hash = 0;
        final left = y * _rowBytes + lane * _laneColumns * 3;
        for (var p = left; p < left + _laneColumns * 3; p += 3) {
          final rgb =
              (samples[p] >> 3) << 10 |
              (samples[p + 1] >> 3) << 5 |
              (samples[p + 2] >> 3);
          hash = (hash * 65599 + rgb) & 0x3fffffff;
        }
        rows[y] = hash;
      }
      final entries = index[lane];
      for (var y = 0; y < frameHeight - 4; y++) {
        if (rows[y] == rows[y + 2] && rows[y] == rows[y + 4]) continue;
        final hash =
            ((rows[y] * 65599 + rows[y + 2]) * 65599 + rows[y + 4]) &
            0x3fffffff;
        entries[hash] = entries.containsKey(hash) ? -1 : y;
      }
    }
    return index;
  }

  // A narrow solid thumb on a predominantly two-color rail can corroborate
  // verified content motion, but never generates new rows on its own.
  _Thumb? _readThumb(Uint8List pixels) {
    int color(int x, int y) {
      final p = (y * width + x) * 4;
      return pixels[p] << 16 | pixels[p + 1] << 8 | pixels[p + 2];
    }

    _Thumb? best;
    final edge = math.min(32, width ~/ 6);
    for (int x = width - 2; x >= width - edge && x >= edge; x -= 2) {
      // A thumb occupying more than half a rail is ambiguous with its track.
      var track = -1, balance = 0;
      for (var y = 0; y < frameHeight; y += 7) {
        final pixel = color(x, y);
        if (balance == 0) track = pixel;
        balance += pixel == track ? 1 : -1;
      }
      int trackRows = 0, size = 0, top = 0, thumbColor = -1;
      int start = frameHeight, end = 0;
      int runStart = 0, last = color(x, 0);
      for (var y = 0; y <= frameHeight; y++) {
        final pixel = y == frameHeight ? -1 : color(x, y);
        if (pixel == track) {
          if (trackRows++ == 0) start = y;
          end = y + 1;
        }
        if (pixel == last) continue;
        if (last != track && y - runStart > size) {
          top = runStart;
          size = y - runStart;
          thumbColor = last;
        }
        last = pixel;
        runStart = y;
      }
      final rail = math.max<int>(end, top + size) - math.min<int>(start, top);
      // Chrome's rounded thumb can have an antialiased pixel between its
      // solid fill and the track on each end. Count those visible edges when
      // converting thumb travel to a corroborating document displacement.
      bool hasEdge(int y, int outside) =>
          outside >= 0 &&
          outside < frameHeight &&
          color(x, y) != track &&
          color(x, y) != thumbColor &&
          color(x, outside) == track;
      if (size >= 8) {
        if (hasEdge(top + size, top + size + 1)) size++;
        if (hasEdge(top - 1, top - 2)) {
          top--;
          size++;
        }
      }
      if (rail < frameHeight ~/ 2 ||
          size < 8 ||
          size * 2 >= rail ||
          size <= (best?.height ?? 0) ||
          trackRows + size < rail * .92) {
        continue;
      }
      final mid = top + size ~/ 2;
      if (color(x - 1, mid) != thumbColor ||
          color(x - edge, mid) == thumbColor) {
        continue;
      }
      best = (
        x: x,
        top: top,
        height: size,
        rail: rail,
        track: track,
        color: thumbColor,
      );
    }
    return best;
  }

  double? _thumbMotion(_Thumb? a, _Thumb? b) {
    if (a == null ||
        b == null ||
        (a.x - b.x).abs() > 2 ||
        (a.height - b.height).abs() > 2 ||
        (a.rail - b.rail).abs() > 4 ||
        a.color != b.color ||
        a.track != b.track) {
      return null;
    }
    return (b.top - a.top) * a.rail / a.height;
  }

  bool _onlyThumbChanged(Uint8List a, Uint8List b, _Thumb old, _Thumb next) {
    final edge = math.min(32, width ~/ 6);
    final bodyBytes =
        _columnOffsets.where((x) => x < (width - edge) * 4).length * 3;
    for (var y = 0; y < frameHeight; y++) {
      final nearThumb =
          y >= old.top - 2 && y <= old.top + old.height + 2 ||
          y >= next.top - 2 && y <= next.top + next.height + 2;
      final start = y * _rowBytes;
      final end = start + (nearThumb ? bodyBytes : _rowBytes);
      for (var p = start; p < end; p++) {
        if (a[p] != b[p]) return false;
      }
    }
    return true;
  }

  ScrollMatch _matchRegions(
    Uint8List a,
    Uint8List b,
    List<Map<int, int>> old,
    List<Map<int, int>> next,
    double? thumbMotion,
    _Thumb? currentThumb,
  ) {
    final evidence = <int, _MotionEvidence>{};
    final stationaryBody = _MotionEvidence();
    final top = _fixedRows(a, b, frameHeight ~/ 2, bottom: false);
    final bottom =
        frameHeight - _fixedRows(a, b, frameHeight ~/ 4, bottom: true);
    // A very short overlap still requires the full exact verification in
    // _match. Local landmarks alone cannot establish a safe seam there.
    final minOverlap = math.max(16, (frameHeight * .22).ceil());
    for (var lane = 0; lane < _lanes; lane++) {
      final left = lane * _laneColumns * 3;
      for (final landmark in next[lane].entries) {
        final y = landmark.value;
        if (y < 0) continue;
        final oldY = old[lane][landmark.key];
        if (oldY == null || oldY < 0) continue;
        final shift = oldY - y;
        final overlap = frameHeight - shift.abs();
        if (overlap < minOverlap) continue;
        // Independently verify the *unquantized* patch, including the rows
        // between the fingerprint samples, before counting its displacement.
        var matches = true;
        for (var row = 0; row < 5 && matches; row++) {
          final prior = (oldY + row) * _rowBytes + left;
          final current = (y + row) * _rowBytes + left;
          for (var p = 0; p < _laneColumns * 3; p++) {
            if ((a[prior + p] - b[current + p]).abs() > 7) {
              matches = false;
              break;
            }
          }
        }
        if (!matches) continue;
        final band = (y - math.max(0, -shift)) * 8 ~/ overlap;
        (evidence[shift] ??= _MotionEvidence()).add(lane, band);
        // Fixed window chrome often has as many identifiable landmarks as the
        // body. Only a second stationary region extending into the body is a
        // conflict. Keep edge lanes enabled for finding movement and stillness.
        if (shift == 0 &&
            lane >= 2 &&
            lane < _lanes - 2 &&
            y >= top &&
            y + 4 < bottom) {
          stationaryBody.add(lane, (y - top) * 8 ~/ (bottom - top));
        }
      }
    }
    final candidates = <int>[];
    final thumb = _referenceThumb;
    // Rounding each thumb position contributes up to one pixel of travel
    // error. Its measured length is also rounded to the nearest pixel.
    final uncertainty = thumb == null
        ? 0.0
        : (thumb.rail + (thumbMotion ?? 0).abs() * .5) / (thumb.height - .5);
    bool nearThumb(int shift) =>
        thumbMotion != null &&
        shift.sign == thumbMotion.sign &&
        (thumbMotion - shift).abs() <= uncertainty;
    for (final entry in evidence.entries) {
      if (entry.key == 0 || !entry.value.distributed(stationary: false)) {
        continue;
      }
      if (_coherentLanes(
        a,
        b,
        entry.key,
        entry.value,
        top,
        bottom,
        votedBandsOnly: nearThumb(entry.key),
      )) {
        candidates.add(entry.key);
      }
    }
    final stationary =
        (evidence[0]?.distributed(stationary: true) ?? false) &&
        stationaryBody.distributed(stationary: false, minimumLanes: 1);
    if (candidates.isEmpty) {
      // Some renderers animate the scrollbar after drawing the scrolled page.
      // Require a distinctive stationary body AND exact samples everywhere
      // outside the two thumb footprints, so a blank page cannot certify this.
      if (thumb != null &&
          currentThumb != null &&
          thumbMotion != null &&
          thumbMotion != 0 &&
          (evidence[0]?.distributed(stationary: true, interiorOnly: true) ??
              false) &&
          _onlyThumbChanged(a, b, thumb, currentThumb)) {
        return const ScrollMatch._stationaryUpdate();
      }
      return ScrollMatch(
        stationary && (thumbMotion == null || thumbMotion == 0)
            ? ScrollMatchKind.unchanged
            : ScrollMatchKind.unmatched,
      );
    }
    if (stationary &&
        thumbMotion == 0 &&
        candidates.every((shift) => shift.abs() > uncertainty) &&
        stationaryBody.distributed(stationary: true) &&
        _coherentLanes(
          a,
          b,
          0,
          evidence[0]!,
          top,
          bottom,
          votedBandsOnly: true,
          interiorOnly: true,
        )) {
      // Local layout changes can have several offsets while another textured
      // body region and the document's scrollbar both confirm zero movement.
      return const ScrollMatch._stationaryUpdate();
    }
    var movement = candidates.first;
    if (candidates.length > 1) {
      // A sticky or reflowing pane may move by any other distance. Trust only
      // a single verified candidate within the document rail's resolution.
      // Without that independent reading the competing motions are ambiguous.
      final plausible = candidates.where(nearThumb).toList();
      if (plausible.length != 1) {
        return const ScrollMatch(ScrollMatchKind.unmatched);
      }
      movement = plausible.single;
    }
    // A scrolling video/pane next to stationary identifiable page content
    // cannot establish that the document itself moved.
    if (stationary && !nearThumb(movement)) {
      return const ScrollMatch(ScrollMatchKind.unmatched);
    }
    return ScrollMatch(
      movement > 0 ? ScrollMatchKind.appended : ScrollMatchKind.reverse,
      movement,
    );
  }

  // Unique short patches can still recur by chance in gradients or list
  // thumbnails. Check other informative pixels *throughout the overlapping
  // body* in the same lanes, including pixels that didn't vote. A playing
  // video in other lanes neither confirms nor vetoes the movement.
  bool _coherentLanes(
    Uint8List a,
    Uint8List b,
    int shift,
    _MotionEvidence evidence,
    int top,
    int bottom, {
    required bool votedBandsOnly,
    bool interiorOnly = false,
  }) {
    final start = top + math.max<int>(0, -shift);
    final end = bottom - math.max<int>(0, shift) - 3;
    var coherent = 0;
    var verifiedTiles = 0,
        verifiedPixels = 0,
        verifiedLanes = 0,
        verifiedBands = 0;
    final textured = Uint16List(16), alignedTexture = Uint16List(16);
    final edge = interiorOnly ? 2 : 0;
    for (var lane = edge; lane < _lanes - edge; lane++) {
      final mask = evidence._laneBands[lane];
      if ((mask & (mask - 1)) == 0) continue;
      var agreeing = 0, informative = 0;
      if (votedBandsOnly) {
        textured.fillRange(0, 16, 0);
        alignedTexture.fillRange(0, 16, 0);
      }
      for (var y = start; y < end; y += 2) {
        final band =
            (y - math.max<int>(0, -shift)) * 8 ~/ (frameHeight - shift.abs());
        if (votedBandsOnly && (mask & (1 << band)) == 0) continue;
        final old = (y + shift) * _rowBytes + lane * _laneColumns * 3;
        final next = y * _rowBytes + lane * _laneColumns * 3;
        for (var x = 0; x < _laneColumns * 3; x += 3) {
          var contrast = false, aligned = true;
          for (var c = x; c < x + 3; c++) {
            final p = a[old + c], q = b[next + c];
            final p2 = a[old + c + 3 * _rowBytes],
                q2 = b[next + c + 3 * _rowBytes];
            if ((p - p2).abs() > 8 || (q - q2).abs() > 8) contrast = true;
            if ((p - q).abs() > 7 || (p2 - q2).abs() > 7) aligned = false;
          }
          if (contrast) {
            informative++;
            if (aligned) agreeing++;
            if (votedBandsOnly) {
              final half = band * 2 + x ~/ 6;
              textured[half]++;
              if (aligned) alignedTexture[half]++;
            }
          }
        }
      }
      if (informative >= 8 && agreeing >= informative * .72) coherent++;
      if (coherent >= 2) return true;
      if (votedBandsOnly) {
        // Reflow and floating video can leave irregular islands of content.
        // The independent thumb reading and the unique landmarks nominate
        // the shift; verify its pixels at separate positions on both axes,
        // without requiring them to describe a filled rectangle.
        for (var band = 0; band < 8; band++) {
          final left = band * 2, right = left + 1;
          final both = textured[left] + textured[right];
          var matches = alignedTexture[left] + alignedTexture[right];
          if (both < 8 || matches < both * .9) {
            // A floating player's edge may bisect this four-column patch.
            // The full patch already supplied a unique landmark for this
            // rail-confirmed movement. Accept one exposed half only when
            // every informative sample in it independently aligns.
            if (shift == 0) continue;
            matches = 0;
            for (var half = left; half <= right; half++) {
              if (textured[half] >= 16 &&
                  alignedTexture[half] == textured[half]) {
                matches += textured[half];
              }
            }
            if (matches == 0) continue;
          }
          verifiedTiles++;
          verifiedPixels += matches;
          verifiedLanes |= 1 << lane;
          verifiedBands |= 1 << band;
        }
        if (verifiedTiles >= 4 &&
            verifiedPixels >= 64 &&
            (verifiedLanes & (verifiedLanes - 1)) != 0 &&
            (verifiedBands & (verifiedBands - 1)) != 0) {
          return true;
        }
      }
    }
    return false;
  }

  ScrollMatch _match(Uint8List a, Uint8List b) {
    final stationary = _score(a, b, 0, dense: true);
    if (stationary.error < .18 && stationary.badFraction < .001) {
      return const ScrollMatch(ScrollMatchKind.unchanged);
    }
    // Short overlaps allow faster wheel motion, but require an exact match
    // on every sampled row rather than the normal tolerance for small changes.
    final minOverlap = math.max(16, (frameHeight * .10).ceil());
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
      final shift = candidate.shift;
      final overlap = frameHeight - shift.abs();
      if (overlap < frameHeight * .22) {
        final startA = math.max(0, shift) * _rowBytes;
        final startB = math.max(0, -shift) * _rowBytes;
        if (candidate.score != 0 || !_hasDetail(a, shift, distinctRows: 12)) {
          continue;
        }
        var i = 0;
        while (i < overlap * _rowBytes && a[startA + i] == b[startB + i]) {
          i++;
        }
        if (i == overlap * _rowBytes) verified.add((shift: shift, score: 0));
      } else {
        final score = _score(a, b, shift, dense: true);
        if (score.error <= 2 &&
            score.badFraction <= .012 &&
            _hasDetail(a, shift)) {
          verified.add((shift: shift, score: score.error));
        }
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
    final columns = _columns ~/ columnStep;
    final maxError = (dense ? 2 : 10) * rows * columns * 3;
    final startA = math.max(0, shift);
    final startB = math.max(0, -shift);
    var error = 0, count = 0, bad = 0;
    for (var row = 0; row < rows; row++) {
      final y = ((row + .5) * overlap / rows).floor();
      final aRow = (y + startA) * _rowBytes;
      final bRow = (y + startB) * _rowBytes;
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
      // Even a perfect match on the remaining rows cannot rescue this shift.
      if (error > maxError) return (error: double.infinity, badFraction: 1);
    }
    return (error: error / (count * 3), badFraction: bad / count);
  }

  bool _hasDetail(Uint8List samples, int shift, {int distinctRows = 6}) {
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
      if (hashes.length >= distinctRows) return true;
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
    if (_verifiedRailEnd > 0) {
      _rail?.paint(result, width, height, _verifiedRailEnd);
    }
    return result;
  }

  ({Uint8List pixels, int width, int height}) thumbnail({
    bool tailOnly = false,
  }) =>
      (tailOnly ? _lastViewport : null) ??
      _thumbnailOf(_parts, height, rail: _verifiedRailEnd > 0 ? _rail : null);

  ({Uint8List pixels, int width, int height}) _thumbnailOf(
    List<Uint8List> parts,
    int sourceHeight, {
    _ScrollRail? rail,
  }) {
    final scale = math.min(160 / width, 140 / sourceHeight);
    final w = math.max(1, (width * scale).round());
    final h = math.max(1, (sourceHeight * scale).round());
    final result = Uint8List(w * h * 4);
    final columns = List<int>.generate(
      w,
      (x) => math.min<int>(width - 1, (x / scale).floor()) * 4,
      growable: false,
    );
    var partIndex = 0, partStart = 0;
    for (var y = 0; y < h; y++) {
      final sourceY = math.min<int>(sourceHeight - 1, (y / scale).floor());
      while (sourceY >= partStart + parts[partIndex].length ~/ (width * 4)) {
        partStart += parts[partIndex].length ~/ (width * 4);
        partIndex++;
      }
      final part = parts[partIndex];
      final row = (sourceY - partStart) * width * 4;
      for (var x = 0; x < w; x++) {
        final from = row + columns[x], to = (y * w + x) * 4;
        result[to] = part[from];
        result[to + 1] = part[from + 1];
        result[to + 2] = part[from + 2];
        result[to + 3] = part[from + 3];
      }
    }
    rail?.paint(result, w, h, _verifiedRailEnd, scale: scale);
    return (pixels: result, width: w, height: h);
  }
}
