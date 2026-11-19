import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:git2dart/git2dart.dart' as git2;
import 'package:idreaml_clip/src/app_controller.dart';
import 'package:idreaml_clip/src/data/clipboard_database.dart';
import 'package:idreaml_clip/src/data/clipboard_repository.dart';
import 'package:idreaml_clip/src/data/data_storage.dart';
import 'package:idreaml_clip/src/desk/desk_models.dart';
import 'package:idreaml_clip/src/desk/desktop_notes.dart';
import 'package:idreaml_clip/src/models/clipboard_content.dart';
import 'package:idreaml_clip/src/models/sync_models.dart';
import 'package:idreaml_clip/src/services/credential_service.dart';
import 'package:idreaml_clip/src/services/embedded_git_service.dart';
import 'package:idreaml_clip/src/services/sync_format_service.dart';
import 'package:idreaml_clip/src/services/sync_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _LocalCredentials implements CredentialStore {
  String? _token = 'synthetic-local-git-token';
  int reads = 0;

  @override
  Future<String?> readToken({String? id}) async {
    reads++;
    return _token;
  }

  @override
  Future<void> writeToken(String token, {String? id}) async => _token = token;

  @override
  Future<void> deleteToken({String? id}) async => _token = null;
}

class _RejectPushAfterReconcile extends EmbeddedGitService {
  bool rejectPush = false;
  int reconciliations = 0;
  Directory? worktree;

  @override
  Future<T> synchronize<T>({
    required Directory directory,
    required SyncConfig config,
    required String token,
    required Future<T> Function() reconcile,
  }) async {
    worktree = directory;
    await directory.create(recursive: true);
    final result = await reconcile();
    reconciliations++;
    if (rejectPush) throw SyncFailure(SyncPhase.push, '模拟远端拒绝 push');
    return result;
  }
}

class _Client {
  _Client(
    this.name,
    this.storage,
    this.database,
    this.repository,
    this.credentials,
    this.sync,
    this.controller,
  );

  final String name;
  final DataStorage storage;
  final ClipboardDatabase database;
  final ClipboardRepository repository;
  final _LocalCredentials credentials;
  final SyncService sync;
  final AppController controller;
  bool _closed = false;

  DesktopNotes get notes => controller.desktopNotes!;

  static Future<_Client> open(
    Directory sandbox,
    String name, {
    EmbeddedGitService? git,
  }) async {
    final storage = DataStorage(
      installationDirectory: Directory(p.join(sandbox.path, name, 'install')),
      supportDirectory: Directory(p.join(sandbox.path, name, 'support')),
    );
    await storage.initialize();
    final database = ClipboardDatabase.withFactory(
      databaseFactoryFfi,
      storage: storage,
    );
    await database.open();
    final repository = ClipboardRepository(database);
    final credentials = _LocalCredentials();
    final sync = SyncService(
      repository,
      credentials,
      git: git ?? EmbeddedGitService(),
    );
    final controller = AppController(repository, sync);
    final client = _Client(
      name,
      storage,
      database,
      repository,
      credentials,
      sync,
      controller,
    );
    try {
      // Real initialization must attach desktop sync itself. Never monitor the
      // user's clipboard, attach native desktop windows or load real credentials.
      await controller.initialize(startMonitor: false);
      return client;
    } catch (_) {
      await client.close();
      rethrow;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    controller.dispose();
    await database.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  test(
    '旧仓库只读迁移到新仓库，两台设备分别同步历史、收藏和便签待办',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'idreaml-archive-migration-',
      );
      final clients = <_Client>[];
      addTearDown(() async {
        for (final client in clients.reversed) {
          await client.close();
        }
        final resolved = await root.resolveSymbolicLinks();
        final temp = await Directory.systemTemp.resolveSymbolicLinks();
        expect(p.isWithin(temp, resolved), isTrue);
        expect(p.basename(resolved), startsWith('idreaml-archive-migration-'));
        await Directory(resolved).delete(recursive: true);
      });
      final a = await _Client.open(root, 'home');
      clients.add(a);
      final b = await _Client.open(root, 'company');
      clients.add(b);
      final oldPath = p.join(root.path, 'old.git');
      final newPath = p.join(root.path, 'new.git');
      for (final path in [oldPath, newPath]) {
        git2.Repository.init(path: path, bare: true).free();
      }
      final old = SyncConfig(
        provider: SyncProvider.custom,
        remoteUrl: oldPath,
        username: 'test',
        syncOnStartup: false,
      );
      final next = old.copyWith(remoteUrl: newPath);
      final legacy = Directory(p.join(root.path, 'legacy'));
      final payload = ClipboardContent.text('旧仓库收藏正文');
      final legacyItem = SyncRecord(
        id: 'old-clipboard',
        type: 'text',
        content: payload.content,
        contentHash: payload.hash,
        createdAt: 100,
        updatedAt: 200,
        lastUsedAt: 100,
        copyCount: 1,
        favorite: true,
        deleted: false,
        deviceId: 'old-device',
      );
      final legacyTodo = await b.notes.repository.save(
        DeskKind.todo,
        body: '旧仓库待办',
        done: true,
      );
      final git = EmbeddedGitService();
      await git.synchronize<void>(
        directory: legacy,
        config: old,
        token: 'fixture',
        reconcile: () async {
          final record = File(
            p.join(legacy.path, 'records', 'old-device', '1970-01.jsonl'),
          );
          await record.parent.create(recursive: true);
          await record.writeAsString('${jsonEncode(legacyItem.toJson())}\n');
          final todo = File(
            p.join(legacy.path, 'desktop-v1', 'todo', 'old-device.json'),
          );
          await todo.parent.create(recursive: true);
          await todo.writeAsString(
            jsonEncode({
              'version': 1,
              'kind': 'todo',
              'entries': [legacyTodo.toJson()],
            }),
          );
        },
      );
      String head(String path) {
        final repo = git2.Repository.open(path);
        final ref = git2.Reference.lookup(repo: repo, name: 'refs/heads/main');
        final oid = ref.target;
        try {
          return oid.sha;
        } finally {
          oid.free();
          ref.free();
          repo.free();
        }
      }

      final oldHead = head(oldPath);
      await a.repository.captureText('本机未上传的历史');
      a.sync.config = old;
      expect(await a.sync.syncNow(), isNull);
      expect(a.sync.lastError, contains('导入旧仓库'));
      expect(await a.sync.importRepository(), 2);
      expect(head(oldPath), oldHead);
      expect(await a.repository.list(), hasLength(2));
      expect(
        (await a.repository.list(favoritesOnly: true)).single.content,
        payload.content,
      );
      for (final client in [a, b]) {
        client.sync.config = next;
        await client.notes.updateSettings(DeskKind.todo, {
          'enabled': true,
          'sync': true,
        });
      }
      expect(await a.sync.syncNow(), isNotNull);
      expect(await b.sync.syncNow(), isNotNull);
      expect(b.notes.items(DeskKind.todo).single.done, isTrue);
      expect(await b.repository.list(), hasLength(2));

      // One device uses an old copy while the other clears its history.
      await b.repository.markUsed(
        (await b.repository.list(favoritesOnly: true)).single.id,
      );
      await a.repository.clearHistory();
      expect(await a.sync.syncNow(), isNotNull);
      expect(await b.sync.syncNow(), isNotNull);
      expect(await b.repository.list(), isEmpty);
      final favorite = (await b.repository.list(favoritesOnly: true)).single;
      final inspect = Directory(p.join(root.path, 'inspect'));
      await git.fetchOnly(directory: inspect, config: next, token: 'fixture');
      expect(Directory(p.join(inspect.path, 'history')).existsSync(), isFalse);
      expect(
        await File(p.join(inspect.path, 'favorites', '${payload.hash}.txt'))
            .readAsString(),
        payload.content,
      );
      expect(
        Directory(p.join(inspect.path, 'todos'))
            .listSync()
            .whereType<File>()
            .single
            .readAsStringSync(),
        '- [x] 旧仓库待办',
      );
      expect(head(newPath), isNotEmpty);
      await b.repository.toggleFavorite(favorite.id);
      expect(await b.sync.syncNow(), isNotNull);
      expect(await a.sync.syncNow(), isNotNull);
      expect(await a.repository.list(favoritesOnly: true), isEmpty);
      expect(head(oldPath), oldHead);
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    '公司与家里经真实控制器及云同步双向传递独立便签待办，重启保留开关和接线',
    () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'idreaml-desktop-cloud-sync-',
      );
      final clients = <_Client>[];
      addTearDown(() async {
        for (final client in clients.reversed) {
          await client.close();
        }
        final resolved = await sandbox.resolveSymbolicLinks();
        final temp = await Directory.systemTemp.resolveSymbolicLinks();
        expect(p.isWithin(temp, resolved), isTrue);
        expect(p.basename(resolved), startsWith('idreaml-desktop-cloud-sync-'));
        await sandbox.delete(recursive: true);
      });

      final remote = p.join(sandbox.path, 'remote.git');
      git2.Repository.init(path: remote, bare: true).free();
      final config = SyncConfig(
        provider: SyncProvider.custom,
        remoteUrl: remote,
        username: 'local-test',
        syncOnStartup: false,
      );

      Future<_Client> open(String name) async {
        final client = await _Client.open(sandbox, name);
        clients.add(client);
        return client;
      }

      Future<_Client> restart(_Client client) async {
        await client.close();
        final restarted = await open(client.name);
        expect(restarted.repository.deviceId, client.repository.deviceId);
        expect(restarted.sync.config?.remoteUrl, remote);
        expect(restarted.sync.config?.enabled, isTrue);
        expect(restarted.sync.config?.syncOnStartup, isFalse);
        expect(restarted.sync.syncDesktopNotes, isNotNull);
        for (final kind in DeskKind.values) {
          expect(restarted.notes.config(kind).enabled, isTrue);
          expect(restarted.notes.config(kind).sync, isTrue);
        }
        return restarted;
      }

      Future<SyncResult> synchronize(_Client client) async {
        final result = await client.controller.syncNow().timeout(
          const Duration(seconds: 30),
        );
        expect(client.sync.lastError, isNull, reason: '${client.name} 同步失败');
        expect(client.sync.status, CloudSyncStatus.success);
        expect(result, isNotNull, reason: '${client.name} 未完成同步');
        expect(client.credentials.reads, greaterThan(0));
        expect(
          await client.repository.listForSync(),
          isEmpty,
          reason: '整个流程只同步桌面模块，不创建剪切板历史',
        );
        return result!;
      }

      var company = await open('company');
      var home = await open('home');
      expect(company.storage.root.path, isNot(home.storage.root.path));
      expect(company.repository.deviceId, isNot(home.repository.deviceId));
      for (final client in [company, home]) {
        expect(client.controller.desktopNotes, isNotNull);
        expect(client.sync.syncDesktopNotes, isNotNull);
        expect(await client.repository.listForSync(), isEmpty);
        for (final kind in DeskKind.values) {
          await client.notes.updateSettings(kind, {
            'enabled': true,
            'sync': true,
          });
        }
        // The UI accepts HTTPS only. Seed the real persisted config with a
        // temporary local remote so restart exercises initialize without network.
        client.sync.config = config;
        await client.repository.setSetting(
          'cloud_sync_config',
          config.encode(),
        );
      }

      await company.notes.save(
        DeskKind.note,
        title: '公司记录',
        body: '回家后继续整理的便签',
        textColor: 0xFF526887,
      );
      await company.notes.save(DeskKind.todo, body: '回家完成的待办');
      final note = company.notes.items(DeskKind.note).single;
      final todo = company.notes.items(DeskKind.todo).single;

      company = await restart(company);
      home = await restart(home);
      expect(company.notes.items(DeskKind.note).single.id, note.id);
      expect(company.notes.items(DeskKind.todo).single.id, todo.id);
      expect(home.notes.entries, isEmpty);

      final sent = await synchronize(company);
      expect(sent.exported, 2);
      final received = await synchronize(home);
      expect(received.imported, greaterThanOrEqualTo(2));
      final homeNote = home.notes.items(DeskKind.note).single;
      final homeTodo = home.notes.items(DeskKind.todo).single;
      expect(homeNote.toJson(), note.toJson());
      expect(homeTodo.toJson(), todo.toJson());

      await home.notes.toggle(homeTodo);
      await home.notes.save(
        DeskKind.note,
        id: homeNote.id,
        title: '在家补充',
        body: '家里编辑后同步回公司的便签',
        fontFamily: 'SimSun',
        fontSize: 20,
        textColor: 0xFF6C57E5,
        expected: {homeNote.revision},
      );
      final revisedNote = home.notes.items(DeskKind.note).single;
      final completedTodo = home.notes.items(DeskKind.todo).single;
      expect(completedTodo.done, isTrue);

      home = await restart(home);
      expect(
        home.notes.items(DeskKind.note).single.toJson(),
        revisedNote.toJson(),
      );
      expect(
        home.notes.items(DeskKind.todo).single.toJson(),
        completedTodo.toJson(),
      );
      await synchronize(home);
      await synchronize(company);
      expect(
        company.notes.items(DeskKind.note).single.toJson(),
        revisedNote.toJson(),
      );
      expect(
        company.notes.items(DeskKind.todo).single.toJson(),
        completedTodo.toJson(),
      );
      for (final client in [company, home]) {
        expect(client.notes.conflicts(DeskKind.note), isEmpty);
        expect(client.notes.conflicts(DeskKind.todo), isEmpty);
        expect(await client.repository.list(), isEmpty);
      }
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    '合并导出后推送失败不标记成功或清理待同步状态，重试可重新导出便签待办',
    () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'idreaml-desktop-cloud-failure-',
      );
      _Client? clientToClose;
      addTearDown(() async {
        await clientToClose?.close();
        final resolved = await sandbox.resolveSymbolicLinks();
        final temp = await Directory.systemTemp.resolveSymbolicLinks();
        expect(p.isWithin(temp, resolved), isTrue);
        expect(
          p.basename(resolved),
          startsWith('idreaml-desktop-cloud-failure-'),
        );
        await sandbox.delete(recursive: true);
      });

      final git = _RejectPushAfterReconcile();
      final client = await _Client.open(sandbox, 'company', git: git);
      clientToClose = client;
      client.sync.config = SyncConfig(
        provider: SyncProvider.custom,
        remoteUrl: p.join(sandbox.path, 'simulated-remote.git'),
        username: 'local-test',
        syncOnStartup: false,
      );
      for (final kind in DeskKind.values) {
        await client.notes.updateSettings(kind, {
          'enabled': true,
          'sync': true,
        });
      }

      // Establish a real successful service result before creating pending work.
      expect(await client.controller.syncNow(), isNotNull);
      expect(client.sync.status, CloudSyncStatus.success);
      final lastSuccess = client.sync.lastSyncedAt;
      expect(lastSuccess, isNotNull);
      final clipboard = (await client.repository.captureText('等待推送的剪切板内容'))!;
      await client.notes.save(DeskKind.note, body: '推送被拒绝后仍保留的便签');
      await client.notes.save(DeskKind.todo, body: '推送重试后仍可导出的待办');
      final note = client.notes.items(DeskKind.note).single;
      final todo = client.notes.items(DeskKind.todo).single;
      expect((await client.repository.listForSync()).single.syncState, 'dirty');

      Future<void> expectExportedPayloads() async {
        final records = await SyncFormatService().readAll(git.worktree!);
        expect(records.records.single.id, 'clip-${clipboard.contentHash}');
        expect(
          await File(records.records.single.payloadPath!).readAsString(),
          clipboard.content,
        );
        for (final entry in [note, todo]) {
          final folder = entry.kind == DeskKind.note ? 'notes' : 'todos';
          final body = Directory(p.join(git.worktree!.path, folder))
              .listSync()
              .whereType<File>()
              .single;
          expect(await body.readAsString(), contains(entry.body));
          final meta = File(
            p.join(
              git.worktree!.path,
              'config',
              'metadata',
              folder,
              '${p.basenameWithoutExtension(body.path)}.json',
            ),
          );
          final snapshot =
              jsonDecode(await meta.readAsString()) as Map<String, dynamic>;
          expect(snapshot['id'], entry.id);
          expect(snapshot['revision'], entry.revision);
        }
      }

      git.rejectPush = true;
      final failed = await client.controller.syncNow();
      expect(git.reconciliations, 2, reason: '错误必须发生在真实合并与导出之后');
      expect(failed, isNull);
      expect(client.sync.status, CloudSyncStatus.error);
      expect(client.sync.lastError, contains('模拟远端拒绝 push'));
      expect(client.sync.lastSyncedAt, lastSuccess);
      expect((await client.repository.listForSync()).single.syncState, 'dirty');
      expect(
        (await client.notes.repository.load()).map((entry) => entry.toJson()),
        unorderedEquals([note.toJson(), todo.toJson()]),
      );
      await expectExportedPayloads();

      // Discard the failed local export, as a later fetch/reset can do. The
      // successful retry must regenerate all payloads from durable local data.
      for (final folder in ['history', 'notes', 'todos', 'config/metadata']) {
        await for (final file in Directory(
          p.join(git.worktree!.path, folder),
        ).list(recursive: true, followLinks: false)) {
          if (file is File) await file.delete();
        }
      }

      git.rejectPush = false;
      final retried = await client.controller.syncNow();
      expect(git.reconciliations, 3);
      expect(retried, isNotNull);
      expect(retried!.exported, 3);
      expect(client.sync.status, CloudSyncStatus.success);
      expect(client.sync.lastError, isNull);
      expect(client.sync.lastSyncedAt, isNot(lastSuccess));
      expect((await client.repository.listForSync()).single.syncState, 'clean');
      expect(client.notes.items(DeskKind.note).single.toJson(), note.toJson());
      expect(client.notes.items(DeskKind.todo).single.toJson(), todo.toJson());
      await expectExportedPayloads();
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
