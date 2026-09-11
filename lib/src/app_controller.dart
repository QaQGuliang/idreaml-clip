import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'data/clipboard_repository.dart';
import 'models/clipboard_item.dart';
import 'models/sync_models.dart';
import 'services/sync_service.dart';

enum AppPage { history, favorites, sync, devices, privacy, settings }

class AppController extends ChangeNotifier {
  AppController(this.repository, this.syncService) {
    syncService.addListener(_onSyncChanged);
    syncService.onSynced = reload;
  }

  final ClipboardRepository repository;
  final SyncService syncService;
  Timer? _monitor;
  bool _readingClipboard = false;
  String? _lastObservedText;
  String? _selfWrittenText;

  List<ClipboardItem> history = const [];
  List<ClipboardItem> quickItems = const [];
  ClipboardStats stats = const ClipboardStats(history: 0, favorites: 0);
  List<DeviceInfo> devices = const [];
  AppPage page = AppPage.history;
  bool quickMode = false;
  bool recordingEnabled = true;
  bool launchAtStartupEnabled = false;
  bool busy = true;
  bool quickFavoritesOnly = false;
  int quickCount = 30;
  int historyLimit = 10000;
  int autoCleanupDays = 0;
  int selectedQuickIndex = 0;
  String? selectedHistoryId;
  String historySearch = '';
  String quickSearch = '';
  bool historyTodayOnly = false;

  ClipboardItem? get selectedHistory {
    for (final item in history) {
      if (item.id == selectedHistoryId) return item;
    }
    return history.isEmpty ? null : history.first;
  }

  ClipboardItem? get selectedQuick => quickItems.isEmpty
      ? null
      : quickItems[selectedQuickIndex.clamp(0, quickItems.length - 1)];

  Future<void> initialize({bool startMonitor = true}) async {
    await repository.initializeDevice();
    quickCount =
        int.tryParse(await repository.getSetting('quick_count') ?? '') ?? 30;
    historyLimit =
        int.tryParse(await repository.getSetting('history_limit') ?? '') ??
        10000;
    autoCleanupDays =
        int.tryParse(await repository.getSetting('auto_cleanup_days') ?? '') ??
        0;
    recordingEnabled =
        (await repository.getSetting('recording_enabled') ?? 'true') == 'true';
    await repository.cleanupOlderThan(autoCleanupDays);
    await repository.enforceHistoryLimit(historyLimit);
    await reload();
    await syncService.initialize();
    if (startMonitor) {
      _monitor = Timer.periodic(
        const Duration(milliseconds: 700),
        (_) => _pollClipboard(),
      );
    }
    busy = false;
    notifyListeners();
  }

  void _onSyncChanged() => notifyListeners();

  Future<void> saveSyncConfig(SyncConfig config, {String? token}) =>
      syncService.saveConfig(config, token: token);

  Future<SyncResult?> syncNow() => syncService.syncNow();

  Future<void> disconnectSync() => syncService.disconnect();

  Future<void> _pollClipboard() async {
    if (!recordingEnabled || _readingClipboard) return;
    _readingClipboard = true;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;
      if (text == null || text.trim().isEmpty || text == _lastObservedText) {
        return;
      }
      _lastObservedText = text;
      if (_selfWrittenText == text) {
        _selfWrittenText = null;
        return;
      }
      await repository.captureText(text);
      await repository.enforceHistoryLimit(historyLimit);
      await reload();
    } on PlatformException {
      // The clipboard can be temporarily locked; the next poll retries.
    } finally {
      _readingClipboard = false;
    }
  }

  Future<void> reload() async {
    final results = await Future.wait<Object>([
      repository.list(
        query: historySearch,
        favoritesOnly: page == AppPage.favorites,
        todayOnly: historyTodayOnly,
      ),
      repository.list(
        query: quickSearch,
        favoritesOnly: quickFavoritesOnly,
        limit: quickSearch.trim().isEmpty ? quickCount : null,
      ),
      repository.stats(),
      repository.listDevices(),
    ]);
    history = results[0] as List<ClipboardItem>;
    quickItems = results[1] as List<ClipboardItem>;
    stats = results[2] as ClipboardStats;
    devices = results[3] as List<DeviceInfo>;
    selectedQuickIndex = quickItems.isEmpty
        ? 0
        : selectedQuickIndex.clamp(0, quickItems.length - 1);
    if (selectedHistoryId == null ||
        !history.any((item) => item.id == selectedHistoryId)) {
      selectedHistoryId = history.isEmpty ? null : history.first.id;
    }
    notifyListeners();
  }

  Future<void> setPage(AppPage value) async {
    page = value;
    historyTodayOnly = false;
    await reload();
  }

  Future<void> setHistorySearch(String value) async {
    historySearch = value;
    await reload();
  }

  Future<void> setQuickSearch(String value) async {
    quickSearch = value;
    await reload();
    selectedQuickIndex = 0;
    notifyListeners();
  }

  Future<void> setQuickFavoritesOnly(bool value) async {
    quickFavoritesOnly = value;
    await reload();
    selectedQuickIndex = 0;
    notifyListeners();
  }

  Future<void> setHistoryTodayOnly(bool value) async {
    historyTodayOnly = value;
    await reload();
  }

  void selectHistory(String id) {
    selectedHistoryId = id;
    notifyListeners();
  }

  void moveQuickSelection(int delta) {
    if (quickItems.isEmpty) return;
    selectedQuickIndex = (selectedQuickIndex + delta).clamp(
      0,
      quickItems.length - 1,
    );
    notifyListeners();
  }

  Future<bool> useItem(ClipboardItem? item) async {
    if (item == null) return false;
    _selfWrittenText = item.content;
    _lastObservedText = item.content;
    await Clipboard.setData(ClipboardData(text: item.content));
    await repository.markUsed(item.id);
    await reload();
    return true;
  }

  Future<void> toggleFavorite(String id) async {
    await repository.toggleFavorite(id);
    await reload();
  }

  Future<void> deleteItem(String id) async {
    await repository.softDelete(id);
    await reload();
  }

  Future<void> clearHistory() async {
    await repository.clearHistory();
    await reload();
  }

  Future<void> setRecording(bool value) async {
    recordingEnabled = value;
    await repository.setSetting('recording_enabled', '$value');
    notifyListeners();
  }

  Future<void> setQuickCount(int value) async {
    if (!const [20, 30, 40, 50].contains(value)) return;
    quickCount = value;
    await repository.setSetting('quick_count', '$value');
    await reload();
  }

  Future<void> setHistoryLimit(int value) async {
    if (!const [1000, 5000, 10000, 50000].contains(value)) return;
    historyLimit = value;
    await repository.setSetting('history_limit', '$value');
    await repository.enforceHistoryLimit(value);
    await reload();
  }

  Future<void> setAutoCleanupDays(int value) async {
    if (!const [0, 30, 90, 180].contains(value)) return;
    autoCleanupDays = value;
    await repository.setSetting('auto_cleanup_days', '$value');
    await repository.cleanupOlderThan(value);
    await reload();
  }

  void setLaunchAtStartupState(bool value) {
    launchAtStartupEnabled = value;
    notifyListeners();
  }

  void enterQuickMode() {
    quickMode = true;
    quickFavoritesOnly = false;
    selectedQuickIndex = 0;
    quickSearch = '';
    unawaited(reload());
    notifyListeners();
  }

  void leaveQuickMode() {
    quickMode = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _monitor?.cancel();
    syncService.removeListener(_onSyncChanged);
    syncService.dispose();
    super.dispose();
  }
}
