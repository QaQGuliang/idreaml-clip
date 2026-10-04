import 'package:idreaml_clip/src/app_controller.dart';
import 'package:idreaml_clip/src/data/clipboard_database.dart';
import 'package:idreaml_clip/src/data/clipboard_repository.dart';
import 'package:idreaml_clip/src/models/clipboard_item.dart';
import 'package:idreaml_clip/src/models/sync_models.dart';
import 'package:idreaml_clip/src/services/credential_service.dart';
import 'package:idreaml_clip/src/services/desktop_service.dart';
import 'package:idreaml_clip/src/services/sync_service.dart';

ClipboardItem sampleItem(int index) => ClipboardItem(
  id: 'item-$index',
  content: '剪切板内容 $index',
  contentHash: 'hash-$index',
  createdAt: DateTime(2026, 9, 17),
  updatedAt: DateTime(2026, 9, 17),
  lastUsedAt: DateTime(2026, 9, 17),
  copyCount: 1,
  favorite: false,
  deleted: false,
  deviceId: 'test-device',
  syncState: 'dirty',
);

class MemoryClipboardRepository extends ClipboardRepository {
  MemoryClipboardRepository({int count = 3})
    : items = List.generate(count, sampleItem),
      super(ClipboardDatabase());

  final List<ClipboardItem> items;
  final List<String> usedIds = [];
  final List<String> deletedIds = [];
  final Map<String, String> settings = {};
  bool failSettingWrite = false;

  @override
  Future<String?> getSetting(String key) async => settings[key];

  @override
  Future<void> setSetting(String key, String value) async {
    if (failSettingWrite) throw StateError('Simulated database write failure');
    settings[key] = value;
  }

  @override
  Future<List<ClipboardItem>> list({
    String query = '',
    bool favoritesOnly = false,
    bool todayOnly = false,
    int? limit,
  }) async => items
      .where(
        (item) =>
            item.content.contains(query) && (!favoritesOnly || item.favorite),
      )
      .take(limit ?? items.length)
      .toList();

  @override
  Future<ClipboardStats> stats() async => ClipboardStats(
    history: items.length,
    favorites: items.where((item) => item.favorite).length,
  );

  @override
  Future<List<DeviceInfo>> listDevices() async => [];

  @override
  Future<void> markUsed(String id) async => usedIds.add(id);

  @override
  Future<void> softDelete(String id) async {
    deletedIds.add(id);
    items.removeWhere((item) => item.id == id);
  }
}

class _UnusedCredentials implements CredentialStore {
  @override
  Future<String?> readToken() async => null;
  @override
  Future<void> writeToken(String token) async {}
  @override
  Future<void> deleteToken() async {}
}

AppController testController(MemoryClipboardRepository repository) =>
    AppController(repository, SyncService(repository, _UnusedCredentials()));

class RecordingDesktopService extends DesktopService {
  RecordingDesktopService(super.controller);
  int hides = 0;
  final quickUsePasteRequests = <bool>[];

  @override
  Future<void> completeQuickUse({bool paste = true}) async {
    quickUsePasteRequests.add(paste);
    await super.completeQuickUse(paste: paste);
  }

  @override
  Future<void> hide() async {
    hides++;
  }
}
