import 'dart:async';

/// Serializes the final write boundary; clipboard decoding happens outside it.
class AsyncGate {
  Future<void>? _tail;

  Future<T> run<T>(Future<T> Function() action) async {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    if (previous != null) await previous;
    try {
      return await action();
    } finally {
      if (identical(_tail, done.future)) _tail = null;
      done.complete();
    }
  }
}
