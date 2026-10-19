import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'scroll_stitcher.dart';

/// Owns the growing image off the UI isolate. No full image is returned per tick.
class ScrollWorker {
  ScrollWorker._();
  final _responses = ReceivePort();
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _ready = Completer<SendPort>();
  Isolate? _isolate;
  SendPort? _commands;
  int _nextId = 0;
  bool _disposed = false;

  static Future<ScrollWorker> start(int width, int height) async {
    final worker = ScrollWorker._();
    worker._responses.listen(worker._receive);
    try {
      worker._isolate = await Isolate.spawn(
        _run,
        (worker._responses.sendPort, width, height),
        onError: worker._responses.sendPort,
        onExit: worker._responses.sendPort,
      );
      worker._commands = await worker._ready.future.timeout(
        const Duration(seconds: 10),
      );
      return worker;
    } catch (_) {
      worker.dispose();
      rethrow;
    }
  }

  void _receive(dynamic message) {
    if (_disposed) return;
    if (message is SendPort) {
      if (!_ready.isCompleted) _ready.complete(message);
    } else if (message is Map) {
      final reply = Map<String, dynamic>.from(message);
      final pending = _pending.remove(reply['id']);
      if (reply['error'] != null) {
        pending?.completeError(StateError(reply['error'] as String));
      } else {
        pending?.complete(reply);
      }
    } else {
      final error = StateError('长截图处理进程已退出，请重新截图');
      if (!_ready.isCompleted) _ready.completeError(error);
      for (final pending in _pending.values) {
        pending.completeError(error);
      }
      _pending.clear();
    }
  }

  Future<Map<String, dynamic>> add(Uint8List pixels) =>
      _request('frame', TransferableTypedData.fromList([pixels]));
  Future<Map<String, dynamic>> finish() => _request('finish', null);

  Future<Map<String, dynamic>> _request(String method, Object? data) async {
    if (_disposed) throw StateError('长截图会话已结束');
    final id = ++_nextId;
    final pending = Completer<Map<String, dynamic>>();
    _pending[id] = pending;
    _commands!.send({'id': id, 'method': method, 'data': data});
    try {
      return await pending.future.timeout(const Duration(seconds: 20));
    } finally {
      _pending.remove(id);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _isolate?.kill(priority: Isolate.immediate);
    _responses.close();
    for (final pending in _pending.values) {
      pending.completeError(StateError('长截图会话已结束'));
    }
    _pending.clear();
  }

  static void _run((SendPort, int, int) arguments) {
    final (replies, width, height) = arguments;
    final stitcher = ScrollStitcher(width, height);
    final commands = ReceivePort();
    replies.send(commands.sendPort);
    commands.listen((dynamic raw) {
      final command = raw as Map;
      try {
        final reply = <String, dynamic>{'id': command['id'], 'width': width};
        if (command['method'] == 'frame') {
          final pixels = (command['data'] as TransferableTypedData)
              .materialize()
              .asUint8List();
          final result = stitcher.add(pixels);
          reply['kind'] = result.kind.name;
          if (result.kind == ScrollMatchKind.first ||
              result.kind == ScrollMatchKind.appended) {
            final thumbnail = stitcher.thumbnail();
            reply['thumbnail'] = TransferableTypedData.fromList([
              thumbnail.pixels,
            ]);
            reply['thumbnailWidth'] = thumbnail.width;
            reply['thumbnailHeight'] = thumbnail.height;
          }
        } else if (command['method'] == 'finish') {
          reply['pixels'] = TransferableTypedData.fromList([
            stitcher.compose(),
          ]);
        } else {
          throw StateError('未知的长截图操作');
        }
        reply['height'] = stitcher.height;
        replies.send(reply);
      } catch (error) {
        replies.send({'id': command['id'], 'error': error.toString()});
      }
    });
  }
}
