import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'data/clipboard_repository.dart';
import 'data/data_storage.dart';
import 'models/arrow_style.dart';
import 'models/clipboard_item.dart';
import 'models/clipboard_content.dart';
import 'models/pinned_image_border.dart';
import 'models/sync_models.dart';
import 'models/quick_shortcut.dart';
import 'models/workspace_layout.dart';
import 'services/sync_service.dart';
import 'services/clipboard_service.dart';
import 'services/async_gate.dart';

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
  final _clipboardGate = AsyncGate();
  final _copiedScreenshots = <String, String>{};
  static const defaultScreenshotShortcut = QuickShortcut(
    key: PhysicalKeyboardKey.f1,
  );
  QuickShortcut screenshotShortcut = defaultScreenshotShortcut;
  bool showScreenshotColorPicker = true;
  bool autoScrollCapture = false;
  ArrowStyle? defaultArrowStyle;
  PinnedImageBorder pinnedImageBorder = PinnedImageBorder.none;
  String? screenshotError;
  bool runAsAdministratorEnabled = false;
  bool isAdministrator = false;
  bool administratorChanging = false;
  String? administratorMessage;

  void setAdministratorState({
    required bool enabled,
    required bool elevated,
    String? message,
    bool changing = false,
  }) {
    runAsAdministratorEnabled = enabled;
    isAdministrator = elevated;
    administratorMessage = message;
    administratorChanging = changing;
    if (!_disposed) notifyListeners();
  }

  bool storageChanging = false;
  String? storageMessage;
  String? get storagePath => repository.storage?.root.path;

  Future<String> validateStoragePath(String value) =>
      repository.storage!.validateDestination(value);

  Future<StorageMoveResult> changeStoragePath(String value) async {
    if (administratorChanging) throw const StorageException('正在切换启动权限，请稍候。');
    if (storageChanging) throw const StorageException('正在迁移数据，请稍候。');
    storageChanging = true;
    storageMessage = null;
    notifyListeners();
    try {
      final result = await repository.moveStorage(value);
      storageMessage = result.warning ?? '数据迁移完成，旧目录已删除。';
      await reload();
      return result;
    } finally {
      storageChanging = false;
      if (!_disposed) notifyListeners();
    }
  }

  List<ClipboardItem> history = const [];
  List<ClipboardItem> quickItems = const [];
  ClipboardStats stats = const ClipboardStats(history: 0, favorites: 0);
  List<DeviceInfo> devices = const [];
  AppPage page = AppPage.history;
  bool quickMode = false;
  int quickSession = 0;
  bool launchAtStartupEnabled = false;
  bool launchAtStartupChanging = false;
  String? launchAtStartupMessage;
  bool busy = true;
  bool quickFavoritesOnly = false;
  int quickCount = 30;
  static const _quickCounts = [20, 30, 40, 50];
  int historyLimit = 10000;
  int autoCleanupDays = 0;
  int selectedQuickIndex = 0;
  String? selectedHistoryId;
  String historySearch = '';
  String quickSearch = '';
  bool historyTodayOnly = false;
  static const _pageSize = 100;
  int historyPage = 0;
  int quickSearchPage = 0;
  bool hasNextHistoryPage = false;
  bool hasNextQuickPage = false;
  int _historyRevision = 0;
  int _quickRevision = 0;
  int _overviewRevision = 0;
  final _historyQueries = AsyncGate();
  final _quickQueries = AsyncGate();
  List<ClipboardItem>? _recentQuickItems;

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
    final settings = await repository.getSettings([
      'workspace_layout',
      'quick_shortcut',
      'screenshot_shortcut',
      'show_screenshot_color_picker',
      'auto_scroll_capture',
      'default_arrow_style',
      'pinned_image_border',
      'win_v_shortcut_enabled',
      'quick_count',
      'history_limit',
      'auto_cleanup_days',
    ]);
    workspaceLayout = WorkspaceLayout.decode(settings['workspace_layout']);
    quickShortcut = QuickShortcut.decode(settings['quick_shortcut']);
    screenshotShortcut = QuickShortcut.decode(
      settings['screenshot_shortcut'],
      fallback: defaultScreenshotShortcut,
    );
    showScreenshotColorPicker =
        settings['show_screenshot_color_picker'] != 'false';
    autoScrollCapture = settings['auto_scroll_capture'] == 'true';
    defaultArrowStyle = ArrowStyle.tryParse(settings['default_arrow_style']);
    pinnedImageBorder =
        PinnedImageBorder.tryParse(settings['pinned_image_border']) ??
        PinnedImageBorder.none;
    winVShortcutEnabled = settings['win_v_shortcut_enabled'] == 'true';
    quickCount = int.tryParse(settings['quick_count'] ?? '') ?? 30;
    if (!_quickCounts.contains(quickCount)) quickCount = 30;
    historyLimit = int.tryParse(settings['history_limit'] ?? '') ?? 10000;
    if (historyLimit < 1) historyLimit = 10000;
    autoCleanupDays = int.tryParse(settings['auto_cleanup_days'] ?? '') ?? 0;
    await repository.cleanupOlderThan(autoCleanupDays);
    await repository.enforceHistoryLimit(historyLimit);
    await reload();
    await syncService.initialize();
    if (startMonitor) {
      // Recording is always active; legacy recording_enabled settings are ignored.
      _monitor = Timer.periodic(
        const Duration(milliseconds: 700),
        (_) => pollClipboard(),
      );
      unawaited(pollClipboard());
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
    if (_readingClipboard ||
        _writingClipboard ||
        _disposed ||
        storageChanging) {
      return;
    }
    final sequence = clipboard.sequence;
    final writeGeneration = _writeGeneration;
    if (sequence != null && sequence == _lastSequence) return;
    _readingClipboard = true;
    try {
      final contents = await clipboard.read();
      if (_disposed ||
          _writingClipboard ||
          writeGeneration != _writeGeneration) {
        return;
      }
      // A newer clipboard value arriving during decoding is read on the next poll.
      final signature = sequence == null
          ? contents.map((content) => content.hash).join(':')
          : null;
      if (sequence == null && signature == _lastSignature) return;
      await _clipboardGate.run(() async {
        if (_disposed ||
            _writingClipboard ||
            writeGeneration != _writeGeneration) {
          return;
        }
        for (final content in contents) {
          await repository.capture(content);
        }
        _lastSequence = clipboard.lastReadSequence ?? sequence;
        _lastSignature = signature;
        clipboardError = null;
        await repository.enforceHistoryLimit(historyLimit);
        await reload();
      });
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

  Future<void> _readHistory() async {
    final revision = ++_historyRevision;
    // A sync may refresh these lists inside an existing storage lease.
    // Always take the lease before the query gate so relocation can drain it.
    final rows = await repository.access(
      () => _historyQueries.run(() async {
        if (_disposed || revision != _historyRevision) return null;
        return repository.list(
          query: historySearch,
          favoritesOnly: page == AppPage.favorites,
          todayOnly: historyTodayOnly,
          limit: _pageSize + 1,
          offset: historyPage * _pageSize,
          loadImages: false,
        );
      }),
    );
    if (_disposed || revision != _historyRevision || rows == null) return;
    if (rows.isEmpty && historyPage > 0) {
      historyPage = 0;
      return _readHistory();
    }
    hasNextHistoryPage = rows.length > _pageSize;
    history = rows.take(_pageSize).toList(growable: false);
    if (selectedHistoryId == null ||
        !history.any((item) => item.id == selectedHistoryId)) {
      selectedHistoryId = history.isEmpty ? null : history.first.id;
    }
  }

  Future<void> _readQuick() async {
    final revision = ++_quickRevision;
    final searching = quickSearch.trim().isNotEmpty;
    final size = searching ? _pageSize : quickCount;
    final rows = await repository.access(
      () => _quickQueries.run(() async {
        if (_disposed || revision != _quickRevision) return null;
        return repository.list(
          query: quickSearch,
          favoritesOnly: quickFavoritesOnly,
          limit: searching ? size + 1 : size,
          offset: quickSearchPage * size,
          loadImages: false,
        );
      }),
    );
    if (_disposed || revision != _quickRevision || rows == null) return;
    if (rows.isEmpty && quickSearchPage > 0) {
      quickSearchPage = 0;
      return _readQuick();
    }
    hasNextQuickPage = searching && rows.length > size;
    quickItems = rows.take(size).toList(growable: false);
    if (!searching && !quickFavoritesOnly) _recentQuickItems = quickItems;
    selectedQuickIndex = quickItems.isEmpty
        ? 0
        : selectedQuickIndex.clamp(0, quickItems.length - 1);
  }

  Future<void> _readOverview() async {
    final revision = ++_overviewRevision;
    final results = await Future.wait<Object>([
      repository.stats(),
      repository.listDevices(),
    ]);
    if (_disposed || revision != _overviewRevision) return;
    stats = results[0] as ClipboardStats;
    devices = results[1] as List<DeviceInfo>;
  }

  Future<void> reload() async {
    _recentQuickItems = null;
    await Future.wait([_readHistory(), _readQuick(), _readOverview()]);
    if (!_disposed) notifyListeners();
  }

  Future<void> changeHistoryPage(int delta) async {
    if ((delta != 1 || !hasNextHistoryPage) &&
        (delta != -1 || historyPage == 0)) {
      return;
    }
    historyPage += delta;
    await _readHistory();
    if (!_disposed) notifyListeners();
  }

  Future<void> changeQuickPage(int delta) async {
    if ((delta != 1 || !hasNextQuickPage) &&
        (delta != -1 || quickSearchPage == 0)) {
      return;
    }
    quickSearchPage += delta;
    selectedQuickIndex = 0;
    await _readQuick();
    if (!_disposed) notifyListeners();
  }

  Future<void> setPage(AppPage value) async {
    page = value;
    historyTodayOnly = false;
    historyPage = 0;
    if (value == AppPage.history || value == AppPage.favorites) {
      await _readHistory();
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> setHistorySearch(String value) async {
    historySearch = value;
    historyPage = 0;
    await _readHistory();
    if (!_disposed) notifyListeners();
  }

  Future<void> setQuickSearch(String value) async {
    quickSearch = value;
    quickSearchPage = 0;
    selectedQuickIndex = 0;
    await _readQuick();
    if (!_disposed) notifyListeners();
  }

  Future<void> setQuickFavoritesOnly(bool value) async {
    quickFavoritesOnly = value;
    quickSearchPage = 0;
    selectedQuickIndex = 0;
    await _readQuick();
    if (!_disposed) notifyListeners();
  }

  Future<void> setHistoryTodayOnly(bool value) async {
    historyTodayOnly = value;
    historyPage = 0;
    await _readHistory();
    if (!_disposed) notifyListeners();
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
    _writeGeneration++;
    return _clipboardGate.run(() async {
      _writingClipboard = true;
      try {
        final payload = await repository.readPayload(item);
        await clipboard.write(payload);
        _lastSequence = clipboard.lastWriteSequence ?? clipboard.sequence;
        copiedClipboardSequence = _lastSequence;
        _lastSignature = item.contentHash;
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
    });
  }

  bool screenshotWasCopied(String operationId) =>
      _copiedScreenshots.containsKey(operationId);

  Future<void> commitScreenshot(
    String operationId,
    ClipboardContent image,
  ) async {
    if (!image.isImage) throw ArgumentError('截图必须为图片');
    _writeGeneration++;
    await _clipboardGate.run(() async {
      _writingClipboard = true;
      try {
        final hash = image.hash;
        final previous = _copiedScreenshots[operationId];
        if (previous != null && previous != hash) {
          throw StateError('请先完成当前截图结果的处理');
        }
        if (previous == null) {
          await clipboard.write(image);
          _copiedScreenshots[operationId] = hash;
          _lastSequence = clipboard.lastWriteSequence ?? clipboard.sequence;
          _lastSignature = hash;
        }
        await recordScreenshot(operationId, image);
      } finally {
        _writingClipboard = false;
      }
    });
  }

  Future<void> recordScreenshot(
    String operationId,
    ClipboardContent image,
  ) async {
    await repository.captureScreenshot(operationId, image);
    await repository.enforceHistoryLimit(historyLimit);
    await reload();
  }

  Future<void> releaseScreenshot(String operationId) async {
    await _clipboardGate.run(() async {
      _copiedScreenshots.remove(operationId);
      await repository.releaseScreenshotReceipt(operationId);
    });
  }

  void setScreenshotError(String? error) {
    screenshotError = error;
    if (!_disposed) notifyListeners();
  }

  Future<void> saveScreenshotShortcut(QuickShortcut shortcut) async {
    await repository.setSetting('screenshot_shortcut', shortcut.encode());
    screenshotShortcut = shortcut;
    setScreenshotError(null);
  }

  Future<void> saveShowScreenshotColorPicker(bool enabled) async {
    await repository.setSetting('show_screenshot_color_picker', '$enabled');
    showScreenshotColorPicker = enabled;
    if (!_disposed) notifyListeners();
  }

  Future<void> saveAutoScrollCapture(bool enabled) async {
    await repository.setSetting('auto_scroll_capture', '$enabled');
    autoScrollCapture = enabled;
    if (!_disposed) notifyListeners();
  }

  Future<void> saveDefaultArrowStyle(ArrowStyle? style) async {
    await repository.setSetting('default_arrow_style', style?.name ?? 'last');
    defaultArrowStyle = style;
    if (!_disposed) notifyListeners();
  }

  Future<void> savePinnedImageBorder(PinnedImageBorder border) async {
    await repository.setSetting('pinned_image_border', border.name);
    pinnedImageBorder = border;
    if (!_disposed) notifyListeners();
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

  Future<void> setQuickCount(int value) async {
    if (!_quickCounts.contains(value)) return;
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

  void setLaunchAtStartupState(bool value, {String? message}) {
    launchAtStartupEnabled = value;
    launchAtStartupMessage = message;
    notifyListeners();
  }

  void setLaunchAtStartupChanging(bool value) {
    launchAtStartupChanging = value;
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
    quickSearchPage = 0;
    hasNextQuickPage = false;
    final recent = _recentQuickItems;
    if (recent == null) {
      await _readQuick();
    } else {
      _quickRevision++;
      quickItems = recent;
    }
    if (!_disposed) notifyListeners();
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
