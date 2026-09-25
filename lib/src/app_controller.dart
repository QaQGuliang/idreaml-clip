import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'data/clipboard_repository.dart';
import 'models/clipboard_item.dart';
import 'models/sync_models.dart';
import 'models/quick_shortcut.dart';
import 'models/workspace_layout.dart';
import 'services/sync_service.dart';
import 'services/clipboard_service.dart';

enum AppPage { history, favorites, sync, devices, privacy, settings }

class AppController extends ChangeNotifier {
  AppController(
    this.repository,
    this.syncService, {
    ClipboardService? clipboard,
  }) : clipboard = clipboard ?? TextClipboardService() {
    syncService.addListener(_onSyncChanged);
    syncService.onSynced = reload;
  }

  final ClipboardRepository repository;
  final SyncService syncService;
  final ClipboardService clipboard;
  Timer? _monitor;
  bool _readingClipboard = false;
  bool _writingClipboard = false;
  bool _disposed = false;
  int? _lastSequence;
  String? _lastSignature;
  String? clipboardError;
  int? copiedClipboardSequence;
  QuickShortcut quickShortcut = QuickShortcut.platformDefault();
  bool winVShortcutEnabled = false;
  bool shortcutModeChanging = false;
  String? shortcutError;
  WorkspaceLayout workspaceLayout = const WorkspaceLayout();
  int _writeGeneration = 0;

  List<ClipboardItem> history = const [];
  List<ClipboardItem> quickItems = const [];
  ClipboardStats stats = const ClipboardStats(history: 0, favorites: 0);
  List<DeviceInfo> devices = const [];
  AppPage page = AppPage.history;
  bool quickMode = false;
  int quickSession = 0;
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
    workspaceLayout = WorkspaceLayout.decode(
      await repository.getSetting('workspace_layout'),
    );
    quickShortcut = QuickShortcut.decode(
      await repository.getSetting('quick_shortcut'),
    );
    winVShortcutEnabled =
        await repository.getSetting('win_v_shortcut_enabled') == 'true';
    quickCount =
        int.tryParse(await repository.getSetting('quick_count') ?? '') ?? 30;
    historyLimit =
        int.tryParse(await repository.getSetting('history_limit') ?? '') ??
        10000;
    if (historyLimit < 1) historyLimit = 10000;
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
        (_) => pollClipboard(),
      );
    }
    busy = false;
    notifyListeners();
  }

  void _onSyncChanged() => notifyListeners();

  void resizeWorkspace({double? sidebarWidth, double? historyFraction}) {
    workspaceLayout = workspaceLayout.copyWith(
      sidebarWidth: sidebarWidth,
      historyFraction: historyFraction,
    );
    notifyListeners();
  }

  Future<void> saveWorkspaceLayout() =>
      repository.setSetting('workspace_layout', workspaceLayout.encode());

  Future<void> saveSyncConfig(SyncConfig config, {String? token}) =>
      syncService.saveConfig(config, token: token);

  Future<SyncResult?> syncNow() => syncService.syncNow();

  Future<void> disconnectSync() => syncService.disconnect();

  Future<void> pollClipboard() async {
    if (!recordingEnabled ||
        _readingClipboard ||
        _writingClipboard ||
        _disposed) {
      return;
    }
    final sequence = clipboard.sequence;
    final writeGeneration = _writeGeneration;
    if (sequence != null && sequence == _lastSequence) return;
    _readingClipboard = true;
    try {
      final contents = await clipboard.read();
      if (_disposed ||
          !recordingEnabled ||
          _writingClipboard ||
          writeGeneration != _writeGeneration) {
        return;
      }
      // A newer clipboard value arriving during decoding is read on the next poll.
      final signature = contents.map((content) => content.hash).join(':');
      if (sequence == null && signature == _lastSignature) return;
      for (final content in contents) {
        await repository.capture(content);
      }
      _lastSequence = clipboard.lastReadSequence ?? sequence;
      _lastSignature = signature;
      clipboardError = null;
      await repository.enforceHistoryLimit(historyLimit);
      await reload();
    } on PlatformException {
      // The clipboard can be temporarily locked; the next poll retries.
    } on FormatException catch (error) {
      _lastSequence = sequence;
      clipboardError = error.message;
      if (!_disposed) notifyListeners();
    } on Exception {
      clipboardError = '读取剪切板失败，将自动重试';
      if (!_disposed) notifyListeners();
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
    _writingClipboard = true;
    _writeGeneration++;
    try {
      await clipboard.write(item.payload);
      _lastSequence = clipboard.sequence;
      copiedClipboardSequence = _lastSequence;
      _lastSignature = item.payload.hash;
      clipboardError = null;
      await repository.markUsed(item.id);
      await reload();
      return true;
    } on Exception {
      clipboardError = '复制失败，请重试';
      notifyListeners();
      return false;
    } finally {
      _writingClipboard = false;
    }
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
    if (value < 1) throw ArgumentError.value(value, 'value', '必须为正整数');
    await repository.setSetting('history_limit', '$value');
    historyLimit = value;
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

  Future<void> saveQuickShortcut(QuickShortcut value) async {
    await repository.setSetting('quick_shortcut', value.encode());
    quickShortcut = value;
    shortcutError = null;
    notifyListeners();
  }

  void setShortcutError(String? message) {
    shortcutError = message;
    notifyListeners();
  }

  Future<void> saveWinVShortcutEnabled(bool value) async {
    await repository.setSetting('win_v_shortcut_enabled', '$value');
    winVShortcutEnabled = value;
    shortcutError = null;
    notifyListeners();
  }

  void setShortcutModeChanging(bool value) {
    shortcutModeChanging = value;
    notifyListeners();
  }

  Future<void> enterQuickMode() async {
    quickMode = true;
    quickSession++;
    quickFavoritesOnly = false;
    selectedQuickIndex = 0;
    quickSearch = '';
    await reload();
  }

  void leaveQuickMode() {
    quickMode = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _monitor?.cancel();
    clipboard.dispose();
    syncService.removeListener(_onSyncChanged);
    syncService.dispose();
    super.dispose();
  }
}
