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
  final gap = 8 / logicalScale;
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
    final rect = point & size;
    if (bounds.contains(rect.topLeft) && bounds.contains(rect.bottomRight)) {
      return Rect.fromLTWH(
        rect.left.floorToDouble(),
        rect.top.floorToDouble(),
        size.width.floorToDouble(),
        size.height.floorToDouble(),
      );
    }
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
  });

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
    _collecting = true;
    notifyListeners();
    _schedule();
  }

  void _schedule() {
    if (_disposed || !_collecting) return;
    _timer = Timer(const Duration(milliseconds: 160), () async {
      final pending = _capture();
      _inFlight = pending;
      await pending;
      _inFlight = null;
      _schedule();
    });
  }

  Future<void> _capture() async {
    try {
      final frame = await channel.invokeMapMethod<String, dynamic>(
        'scrollFrame',
        {'session': session},
      );
      if (_disposed || !_collecting) return;
      await _process(frame);
    } catch (error) {
      if (_disposed) return;
      warning = true;
      message = error is PlatformException
          ? error.message ?? '暂时无法采集，请返回原窗口或点击完成'
          : '暂时无法拼接，请缓慢滚动或点击完成';
      notifyListeners();
    }
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
    height = result['height'] as int;
    final bytes = result['thumbnail'] as TransferableTypedData?;
    if (bytes != null) {
      final image = await decodeScrollPixels(
        bytes.materialize().asUint8List(),
        result['thumbnailWidth'] as int,
        result['thumbnailHeight'] as int,
      );
      if (_disposed) {
        image.dispose();
        return;
      }
      final previous = preview;
      preview = image;
      previous?.dispose();
    }
    final kind = result['kind'] as String;
    warning = kind == 'reverse' || kind == 'unmatched' || kind == 'limit';
    message = switch (kind) {
      'reverse' => '检测到向上滚动，已暂停追加；请回到原位置向下滚动',
      'unmatched' => '暂时无法拼接，请回到原位置缓慢滚动，或点击完成',
      'limit' => '已达到长图上限，正在进入编辑',
      _ => '在选区内向下滚动 · 点击完成后进入标注编辑',
    };
    notifyListeners();
    if (kind == 'limit') scheduleMicrotask(() => finish(limited: true));
  }

  Future<void> finish({bool limited = false}) async {
    if (_disposed || starting || finishing) return;
    finishing = true;
    _collecting = false;
    _timer?.cancel();
    message = '正在合成长图…';
    notifyListeners();
    try {
      await _inFlight;
      if (_disposed) return;
      final result = await _worker!.finish();
      if (_disposed) return;
      await onEdit(
        (result['pixels'] as TransferableTypedData).materialize().asUint8List(),
        width,
        result['height'] as int,
        limited,
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
    preview?.dispose();
    super.dispose();
  }
}
