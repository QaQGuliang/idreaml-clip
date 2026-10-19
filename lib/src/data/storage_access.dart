import 'dart:async';

import '../services/async_gate.dart';

/// Normal operations may overlap; relocation waits for all of them and blocks
/// new operations. Nested repository calls retain their parent's lease.
class StorageAccess {
  final _writers = AsyncGate();
  final _zoneKey = Object();
  final _leases = <Object>{};
  Completer<void>? _blocked;
  Completer<void>? _drained;

  bool get _nested => _leases.contains(Zone.current[_zoneKey]);

  Future<T> run<T>(Future<T> Function() action) async {
    if (_nested) return action();
    while (_blocked != null) {
      await _blocked!.future;
    }
    return _lease(action);
  }

  Future<T> _lease<T>(Future<T> Function() action) async {
    final token = Object();
    _leases.add(token);
    try {
      return await runZoned(action, zoneValues: {_zoneKey: token});
    } finally {
      _leases.remove(token);
      if (_leases.isEmpty) _drained?.complete();
    }
  }

  Future<T> exclusive<T>(Future<T> Function() action) => _writers.run(() async {
    final blocked = Completer<void>();
    _blocked = blocked;
    try {
      if (_leases.isNotEmpty) {
        _drained = Completer<void>();
        await _drained!.future;
        _drained = null;
      }
      return await _lease(action);
    } finally {
      _blocked = null;
      blocked.complete();
    }
  });
}
