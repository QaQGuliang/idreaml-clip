abstract class QuickPasteTarget {
  Future<bool> paste({int? clipboardSequence});
}

abstract class QuickPasteService {
  Future<QuickPasteTarget?> captureTarget();
}

class CopyOnlyPasteService implements QuickPasteService {
  const CopyOnlyPasteService();

  @override
  Future<QuickPasteTarget?> captureTarget() async => null;
}
