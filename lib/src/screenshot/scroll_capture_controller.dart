import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'scroll_worker.dart';

Future<ui.Image> decodeScrollPixels(
  Uint8List bytes,
  int width,
  int height,
) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: width,
      height: height,
      pixelFormat: ui.PixelFormat.bgra8888,
    );
    codec = await descriptor.instantiateCodec();
    return (await codec.getNextFrame()).image;
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

/// All rectangles use original monitor pixels, including the native window region.
Rect placeScrollControls(Rect selection, Size screen, double logicalScale) {
  final gap = (8 / logicalScale).ceilToDouble();
  final size = Size(
    math.min(340 / logicalScale, screen.width - gap * 2),
    math.min(280 / logicalScale, screen.height - gap * 2),
  );
  final positions = [
    Offset(selection.right + gap, selection.top),
    Offset(selection.left - gap - size.width, selection.top),
    Offset(selection.left, selection.bottom + gap),
    Offset(selection.left, selection.top - gap - size.height),
  ];
  final bounds = (Offset.zero & screen).deflate(gap);
  for (final point in positions) {
    final rect = Rect.fromLTWH(
      point.dx.clamp(bounds.left, bounds.right - size.width).floorToDouble(),
      point.dy.clamp(bounds.top, bounds.bottom - size.height).floorToDouble(),
      size.width.floorToDouble(),
      size.height.floorToDouble(),
    );
    if (!rect.overlaps(selection)) return rect;
  }
  return Rect.fromLTWH(
    (bounds.right - size.width).floorToDouble(),
    bounds.top.floorToDouble(),
    size.width.floorToDouble(),
    size.height.floorToDouble(),
  );
}

class ScrollCaptureController extends ChangeNotifier {
  ScrollCaptureController({
    required this.channel,
    required this.session,
    required this.selection,
    required this.panel,
    required this.onEdit,
    bool autoScroll = false,
  }) : _automatic = autoScroll;

  final MethodChannel channel;
  final int session;
  final Rect selection, panel;
  final Future<void> Function(
    Uint8List pixels,
    int width,
    int height,
    bool limited,
  )
  onEdit;
  ScrollWorker? _worker;
  Timer? _timer;
  Future<void>? _inFlight;
  bool _automatic;
  bool _limited = false, _needsStep = true, _stepMoved = false;
  int _stepAttempts = 0, _stillFrames = 0, _unmatchedFrames = 0;
  int _observationsSinceProgress = 0;
  final _obscuredFor = Stopwatch();
  Map<String, dynamic>? _pendingPreview;
  bool _decodingPreview = false;
  bool get canTakeOver => _automatic && !starting && !finishing && !_limited;
  bool _disposed = false, _collecting = false;
  bool starting = true, finishing = false;
  int height = 0;
  int get width => selection.width.toInt();
  ui.Image? preview;
  String message = '正在准备长截图…';
  bool warning = false;

  Future<void> start() async {
    _worker = await ScrollWorker.start(width, selection.height.toInt());
    if (_disposed) {
      _worker!.dispose();
      return;
    }
    final frame = await channel.invokeMapMethod<String, dynamic>(
      'beginScroll',
      {
        'session': session,
        'x': selection.left.toInt(),
        'y': selection.top.toInt(),
        'width': width,
        'height': selection.height.toInt(),
        'panelX': panel.left.toInt(),
        'panelY': panel.top.toInt(),
        'panelWidth': panel.width.toInt(),
        'panelHeight': panel.height.toInt(),
      },
    );
    if (_disposed) return;
    await _process(frame);
    if (_disposed) return;
    starting = false;
    _collecting = !_limited;
    notifyListeners();
    _schedule(Duration.zero);
  }

  void _schedule(Duration delay) {
    if (_disposed || !_collecting) return;
    _timer = Timer(delay, () async {
      final clock = Stopwatch()..start();
      final pending = _capture();
      _inFlight = pending;
      await pending;
      _inFlight = null;
      // Pace from the start of the last frame. Matching and thumbnail display
      // must not add a fixed delay to every movement of the wheel.
      final interval = _obscuredFor.isRunning
          ? 100
          : _automatic
          ? 65
          : (_stillFrames >= 8 ? 90 : 32);
      _schedule(
        Duration(
          milliseconds: math.max(0, interval - clock.elapsedMilliseconds),
        ),
      );
    });
  }

  Future<void> _capture() async {
    try {
      if (_automatic &&
          _collecting &&
          _needsStep &&
          _unmatchedFrames == 0 &&
          !_obscuredFor.isRunning) {
        await channel.invokeMethod<void>('scrollStep', {'session': session});
        if (_disposed) return;
        _needsStep = false;
        _stepMoved = false;
        _stillFrames = 0;
        _observationsSinceProgress = 0;
        _stepAttempts++;
      }
      final frame = await channel.invokeMapMethod<String, dynamic>(
        'scrollFrame',
        {'session': session},
      );
      if (_disposed) return;
      await _process(frame);
      _obscuredFor
        ..stop()
        ..reset();
    } catch (error) {
      if (_disposed || finishing) return;
      if (error is PlatformException && error.code == 'obscured') {
        // Drop the frame immediately. Probe visibility without sending wheel
        // events while a transient tooltip or popup is fading away.
        _obscuredFor.start();
        if (_obscuredFor.elapsedMilliseconds < 450) return;
      }
      if (_automatic) _collecting = false;
      _stillFrames = 8;
      final reason = error is PlatformException ? error.message : null;
      final description =
          reason ?? (_automatic ? '暂时无法自动采集，可改用手动滚动或点击完成' : '暂时无法采集，请检查选区');
      if (warning && message == description) return;
      warning = true;
      message = description;
      notifyListeners();
    }
  }

  void takeOver() {
    if (!canTakeOver) return;
    _automatic = false;
    _stillFrames = _unmatchedFrames = 0;
    if (!_collecting) {
      _collecting = true;
      if (_inFlight == null) _schedule(Duration.zero);
    }
    warning = false;
    message = '已切换为手动滚动，将鼠标移到选中的内容上即可继续';
    notifyListeners();
  }

  Future<void> _process(Map<String, dynamic>? frame) async {
    if (frame == null ||
        frame['session'] != session ||
        frame['width'] != width ||
        frame['height'] != selection.height.toInt()) {
      throw const FormatException('采集画面尺寸或会话已改变');
    }
    final result = await _worker!.add(frame['pixels'] as Uint8List);
    if (_disposed) return;
    final oldHeight = height, oldMessage = message;
    final oldWarning = warning;
    height = result['height'] as int;
    if (result.containsKey('thumbnail')) {
      // At most one image is decoding and one newer preview is waiting.
      _pendingPreview = result;
      if (!_decodingPreview) unawaited(_decodePreviews());
    }
    final kind = result['kind'] as String;
    _limited = result['atLimit'] as bool;
    if (finishing) return;
    _stillFrames = kind == 'unchanged' ? _stillFrames + 1 : 0;
    _unmatchedFrames = kind == 'unmatched' || kind == 'reverse'
        ? _unmatchedFrames + 1
        : 0;
    _observationsSinceProgress = kind == 'appended'
        ? 0
        : _observationsSinceProgress + 1;
    warning = _unmatchedFrames >= 3 || _limited;
    if (_limited) {
      _collecting = false;
      message = '已达到长图上限，可查看预览，点击完成后编辑';
    } else if (_automatic && _observationsSinceProgress >= 48) {
      // Alternating repaints and still frames may never settle into either
      // a confirmed bottom or a run of consistently unmatched frames.
      _collecting = false;
      warning = true;
      message = '页面持续变化，自动滚动已暂停。可手动接管或点击完成';
    } else if (_unmatchedFrames > 0) {
      // Smooth scrolling and video repaint can briefly disturb alignment.
      // Keep reading at the same position before asking for user action.
      if (_automatic && _unmatchedFrames >= 16) _collecting = false;
      message = _automatic
          ? (_collecting ? '正在寻找与预览末段重叠的画面…' : '暂时找不到与上一屏重叠的内容。可手动接回预览末段，或点击完成')
          : !warning
          ? '正在匹配滚动内容…'
          : kind == 'reverse'
          ? '预览为上次接上的画面，向下滚到这里即可续接'
          : '预览为上次接上的画面，往回滚到这里即可续接';
    } else if (_automatic) {
      message = '正在自动向下滚动，可随时点击完成';
      if (kind == 'appended') {
        _stepMoved = true;
        _stepAttempts = 0;
      } else if (_stepMoved && _stillFrames >= 4) {
        // Allow sticky elements and asynchronously painted lists to settle
        // between automatic steps. Manual capture keeps its faster cadence.
        _needsStep = true;
      } else if (!_stepMoved && _stillFrames >= 16) {
        // Give slow-rendering pages time to respond, then probe only once.
        if (_stepAttempts < 2) {
          _needsStep = true;
        } else {
          _collecting = false;
          message = height > selection.height
              ? '页面未再移动，可能已到底。查看预览后点击完成'
              : '页面没有滚动，可改用手动滚动或点击完成';
        }
      }
    } else {
      message = '在选区内向下滚动 · 点击完成后进入标注编辑';
    }
    if (oldHeight != height || oldMessage != message || oldWarning != warning) {
      notifyListeners();
    }
  }

  Future<void> _decodePreviews() async {
    _decodingPreview = true;
    try {
      while (!_disposed && _pendingPreview != null) {
        final frame = _pendingPreview!;
        _pendingPreview = null;
        final bytes = frame['thumbnail'] as TransferableTypedData;
        final image = await decodeScrollPixels(
          bytes.materialize().asUint8List(),
          frame['thumbnailWidth'] as int,
          frame['thumbnailHeight'] as int,
        );
        if (_disposed || _pendingPreview != null) {
          image.dispose();
        } else {
          final previous = preview;
          preview = image;
          previous?.dispose();
          notifyListeners();
        }
      }
    } catch (_) {
      // Losing a thumbnail does not invalidate the full-resolution capture.
    } finally {
      _decodingPreview = false;
    }
  }

  Future<void> finish() async {
    if (_disposed || starting || finishing) return;
    finishing = true;
    final sampleLastFrame = _collecting;
    _collecting = false;
    _timer?.cancel();
    message = '正在合成长图…';
    notifyListeners();
    try {
      await _inFlight;
      if (_disposed) return;
      // Include motion since the last timer tick, but never scroll further
      // after the user has clicked Finish. A paused preview stays frozen.
      if (sampleLastFrame && !_limited) {
        await _capture();
        if (_disposed) return;
      }
      final result = await _worker!.finish();
      if (_disposed) return;
      await onEdit(
        (result['pixels'] as TransferableTypedData).materialize().asUint8List(),
        width,
        result['height'] as int,
        _limited,
      );
    } catch (_) {
      if (_disposed) return;
      finishing = false;
      warning = true;
      message = '合成长图失败，已有内容已保留，请再次点击完成或取消';
      notifyListeners();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _collecting = false;
    _timer?.cancel();
    _worker?.dispose();
    _pendingPreview = null;
    preview?.dispose();
    super.dispose();
  }
}
