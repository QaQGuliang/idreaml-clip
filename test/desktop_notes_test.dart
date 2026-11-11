import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:git2dart/git2dart.dart' as git2;
import 'package:idreaml_clip/src/models/sync_models.dart';
import 'package:idreaml_clip/src/services/embedded_git_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:idreaml_clip/src/desk/desk_models.dart';
import 'package:idreaml_clip/src/desk/desk_repository.dart';
import 'package:idreaml_clip/src/desk/desktop_notes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late DeskRepository a, b;
  setUpAll(sqfliteFfiInit);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('idreaml-desk-test-');
    a = DeskRepository(
      deviceId: 'device-a',
      testPath: p.join(root.path, 'a.db'),
      factory: databaseFactoryFfiNoIsolate,
    );
    b = DeskRepository(
      deviceId: 'device-b',
      testPath: p.join(root.path, 'b.db'),
      factory: databaseFactoryFfiNoIsolate,
    );
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('历史内容兼容默认文字样式，拒绝无效的同步字号和透明文字色', () async {
    final original = await a.save(DeskKind.note, body: '原来的便签');
    final legacy = original.toJson();
    expect(legacy.containsKey('textColor'), isFalse);
    final restored = DeskEntry.fromJson(Map<String, dynamic>.from(legacy));
    expect(restored.fontFamily, isNull);
    expect(restored.fontSize, isNull);
    expect(restored.textColor, isNull);
    final defaults = DeskSettings.fromJson({});
    expect(defaults.fontFamily, '');
    expect(defaults.fontSize, 12);
    expect(defaults.textColor, isNull);
    for (final invalid in [
      {'fontSize': 0},
      {'fontSize': 1000},
      {'fontSize': double.nan},
      {'textColor': 0x006c57e5},
      {'textColor': 'red'},
      {'fontFamily': 'bad\u0000font'},
    ]) {
      expect(
        () => DeskEntry.fromJson({...legacy, ...invalid}),
        throwsFormatException,
      );
    }
    await expectLater(
      a.save(DeskKind.note, body: '无效', textColor: 0x226c57e5),
      throwsFormatException,
    );
    expect((await a.load()).length, 1);
  });

  test('单条文字样式随内容同步，完成恢复和清除覆盖均保留正确样式', () async {
    final remote = Directory(p.join(root.path, 'styled-remote'));
    final notes = DesktopNotes(a);
    await notes.initialize();
    await notes.updateSettings(DeskKind.todo, {
      'enabled': true,
      'fontFamily': 'SimSun',
      'fontSize': 20.0,
      'textColor': 0xff526887,
    });
    await notes.save(
      DeskKind.todo,
      body: '带有个人样式的事项',
      fontFamily: 'KaiTi',
      fontSize: 24,
      textColor: 0xffe35a6b,
    );
    final created = notes.items(DeskKind.todo).single;
    await notes.toggle(created);
    await notes.toggle(notes.items(DeskKind.todo).single);
    await a.synchronize(remote, {DeskKind.todo});
    await b.synchronize(remote, {DeskKind.todo});
    final incoming = (await b.load()).single;
    expect(incoming.fontFamily, 'KaiTi');
    expect(incoming.fontSize, 24);
    expect(incoming.textColor, 0xffe35a6b);
    expect(incoming.done, isFalse);
    expect(await b.preference('settings.todo'), isNull);
    final reset = await b.save(
      DeskKind.todo,
      id: incoming.id,
      body: incoming.body,
      expected: {incoming.revision},
      fontFamily: null,
      fontSize: null,
      textColor: null,
    );
    await b.synchronize(remote, {DeskKind.todo});
    await a.synchronize(remote, {DeskKind.todo});
    await notes.reload();
    final merged = notes.items(DeskKind.todo).single;
    expect(merged.revision, reset.revision);
    expect(merged.fontFamily, isNull);
    expect(merged.fontSize, isNull);
    expect(merged.textColor, isNull);
    expect(notes.config(DeskKind.todo).fontFamily, 'SimSun');
    expect(notes.config(DeskKind.todo).textColor, 0xff526887);
    final reopened = DesktopNotes(a);
    await reopened.initialize();
    expect(reopened.config(DeskKind.todo).fontSize, 20);
    expect(reopened.config(DeskKind.todo).textColor, 0xff526887);
    reopened.dispose();
    notes.dispose();
  });

  test('并发文字颜色修改保留版本，采用某版本时保留其全部样式', () async {
    final initial = await a.save(DeskKind.note, body: '同一条内容');
    await b.merge([initial]);
    final red = await a.save(
      DeskKind.note,
      id: initial.id,
      body: initial.body,
      textColor: 0xffe35a6b,
      fontSize: 18,
      expected: {initial.revision},
    );
    final blue = await b.save(
      DeskKind.note,
      id: initial.id,
      body: initial.body,
      textColor: 0xff526887,
      fontFamily: 'Consolas',
      fontSize: 22,
      expected: {initial.revision},
    );
    await a.merge([blue]);
    expect(
      (await a.load()).map((e) => e.textColor),
      containsAll([0xffe35a6b, 0xff526887]),
    );
    final chosen = await a.save(
      DeskKind.note,
      id: initial.id,
      body: blue.body,
      fontFamily: blue.fontFamily,
      fontSize: blue.fontSize,
      textColor: blue.textColor,
      expected: {red.revision, blue.revision},
    );
    await b.merge([chosen]);
    expect((await b.load()).single.textColor, blue.textColor);
    expect((await b.load()).single.fontSize, blue.fontSize);
    expect((await b.load()).single.fontFamily, blue.fontFamily);
  });

  test('原生新增的选色随草稿恢复并保存，取消后不影响下一条默认样式', () async {
    if (!Platform.isWindows) return;
    const channel = MethodChannel('test/desk_typography');
    const codec = StandardMethodCodec();
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    final notes = DesktopNotes(a, channel: channel);
    await notes.initialize();
    await notes.updateSettings(DeskKind.note, {
      'enabled': true,
      'fontSize': 18.0,
      'textColor': 0xff526887,
    });
    await notes.attachNative();
    Future<void> incoming(String method, Map<String, Object?> args) async {
      Object? error;
      await messenger.handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(MethodCall(method, args)),
        (reply) {
          try {
            codec.decodeEnvelope(reply!);
          } catch (e) {
            error = e;
          }
        },
      );
      expect(error, isNull);
    }

    final draft = <String, Object?>{
      'kind': 'note',
      'title': '选色草稿',
      'body': '继续编辑',
      'fontFamily': 'SimSun',
      'fontSize': 20.0,
      'textColor': 0xffe35a6b,
    };
    await incoming('draft', draft);
    await notes.compose(DeskKind.note);
    final compose =
        calls.lastWhere((call) => call.method == 'compose').arguments as Map;
    expect(compose['textColor'], 0xffe35a6b);
    expect(compose['fontSize'], 20.0);
    await incoming('save', draft);
    expect(notes.items(DeskKind.note).single.textColor, 0xffe35a6b);
    final published =
        calls.lastWhere((call) => call.method == 'configure').arguments as Map;
    expect(published['note']['textColor'], 0xff526887);
    expect(published['note']['rows'][0]['textColor'], 0xffe35a6b);
    expect((await notes.draft(DeskKind.note))['textColor'], isNull);
    await incoming('draft', draft);
    await incoming('cancel', {'kind': 'note'});
    expect((await notes.draft(DeskKind.note))['textColor'], isNull);
    notes.dispose();
    await Future<void>.delayed(Duration.zero);
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('独立数据库保存便签、待办与本机设置，重新打开仍保留', () async {
    final note = await a.save(DeskKind.note, body: '独立内容', title: '标题');
    await a.save(DeskKind.todo, body: '处理事项', done: true);
    await a.savePreference('draft.note', '未提交的草稿');
    final reopened = DeskRepository(
      deviceId: 'device-a',
      testPath: p.join(root.path, 'a.db'),
      factory: databaseFactoryFfiNoIsolate,
    );
    expect((await reopened.load()).map((e) => e.id), contains(note.id));
    expect(
      (await reopened.load()).where((e) => e.kind == DeskKind.todo).single.done,
      true,
    );
    expect(await reopened.preference('draft.note'), '未提交的草稿');
    final db = await databaseFactoryFfiNoIsolate.openDatabase(
      p.join(root.path, 'a.db'),
    );
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table'",
    );
    expect(tables.any((r) => r['name'] == 'clipboard_item'), false);
    await db.close();
  });

  test('并发编辑保留双方版本，显式处理后所有设备收敛且旧快照不能复活', () async {
    final base = await a.save(DeskKind.note, body: '初始');
    await b.merge([base]);
    final left = await a.save(
      DeskKind.note,
      id: base.id,
      body: 'A 的修改',
      expected: {base.revision},
    );
    final right = await b.save(
      DeskKind.note,
      id: base.id,
      body: 'B 的修改',
      expected: {base.revision},
    );
    await a.merge([right]);
    await b.merge([left]);
    expect((await a.load()).length, 2);
    expect((await b.load()).length, 2);
    expect(await a.merge([right, left, base]), 0);
    await expectLater(
      a.save(DeskKind.note, id: base.id, body: '静默覆盖'),
      throwsStateError,
    );
    final resolved = await a.save(
      DeskKind.note,
      id: base.id,
      body: '选择 B 的修改',
      expected: {left.revision, right.revision},
    );
    await b.merge([resolved]);
    await b.merge([base, left, right]);
    expect((await b.load()).single.body, '选择 B 的修改');
    expect((await b.load()).single.revision, resolved.revision);
  });

  test('删除和离线修改形成冲突，采用删除后旧数据不会重新出现', () async {
    final base = await a.save(DeskKind.todo, body: '待完成');
    await b.merge([base]);
    final deleted = await a.save(
      DeskKind.todo,
      id: base.id,
      body: '',
      deleted: true,
      expected: {base.revision},
    );
    final changed = await b.save(
      DeskKind.todo,
      id: base.id,
      body: '离线更新',
      done: true,
      expected: {base.revision},
    );
    await a.merge([changed]);
    expect((await a.load()).length, 2);
    final resolution = await a.save(
      DeskKind.todo,
      id: base.id,
      body: '',
      deleted: true,
      expected: {deleted.revision, changed.revision},
    );
    await b.merge([resolution]);
    await b.merge([base, deleted, changed]);
    expect((await b.load()).single.deleted, true);
    expect((await b.load()).single.body, isEmpty);
  });

  test('编辑窗口的旧版本不能覆盖已收到的新版本', () async {
    final base = await a.save(DeskKind.note, body: '原内容');
    await b.merge([base]);
    final remote = await b.save(
      DeskKind.note,
      id: base.id,
      body: '新内容',
      expected: {base.revision},
    );
    await a.merge([remote]);
    await expectLater(
      a.save(
        DeskKind.note,
        id: base.id,
        body: '旧窗口提交',
        expected: {base.revision},
      ),
      throwsStateError,
    );
    expect((await a.load()).single.body, '新内容');
  });

  test('Git 同步独立文件，只发送选中模块且不发送设置和草稿', () async {
    final git = Directory(p.join(root.path, 'remote'));
    await a.save(DeskKind.note, body: '便签');
    await a.save(DeskKind.todo, body: '待办');
    await a.savePreference('draft.note', '敏感草稿');
    await a.savePreference('settings.note', '本机显示器');
    await a.synchronize(git, {DeskKind.note});
    final file = File(p.join(git.path, 'desktop-v1', 'note', 'device-a.json'));
    expect(await file.exists(), true);
    expect(
      await Directory(p.join(git.path, 'desktop-v1', 'todo')).exists(),
      false,
    );
    final text = await file.readAsString();
    expect(text, isNot(contains('敏感草稿')));
    expect(text, isNot(contains('本机显示器')));
    await b.synchronize(git, {DeskKind.note});
    expect((await b.load()).single.body, '便签');
    final downloaded = (await b.load()).single;
    await b.save(
      DeskKind.note,
      id: downloaded.id,
      body: '其他设备更新',
      expected: {downloaded.revision},
    );
    await b.synchronize(git, {DeskKind.note});
    await a.synchronize(git, {DeskKind.note});
    expect(
      (await a.load()).where((e) => e.kind == DeskKind.note).single.body,
      '其他设备更新',
    );
    expect(
      (await a.load()).where((e) => e.kind == DeskKind.todo).single.body,
      '待办',
    );
  });

  test('关闭功能或同步开关时不发送数据，重新开启补同步', () async {
    final notes = DesktopNotes(a);
    await notes.initialize();
    expect(notes.enabled(DeskKind.note), false);
    await expectLater(
      notes.save(DeskKind.note, body: '不能添加'),
      throwsStateError,
    );
    await notes.updateSettings(DeskKind.note, {'enabled': true});
    await notes.save(DeskKind.note, body: '本地内容');
    final git = Directory(p.join(root.path, 'remote'));
    await notes.synchronize(git);
    expect(await git.exists(), false);
    await notes.updateSettings(DeskKind.note, {'sync': true, 'enabled': false});
    await notes.synchronize(git);
    expect(await git.exists(), false);
    await notes.updateSettings(DeskKind.note, {'enabled': true});
    await notes.synchronize(git);
    expect(
      await File(p.join(git.path, 'desktop-v1', 'note', 'device-a.json'))
          .exists(),
      true,
    );
    expect(notes.items(DeskKind.note).single.body, '本地内容');
    notes.dispose();
  });

  test('未来同步格式拒绝导入，不清除本地内容', () async {
    await a.save(DeskKind.note, body: '本地安全保留');
    final git = Directory(p.join(root.path, 'remote'));
    final folder = Directory(p.join(git.path, 'desktop-v1', 'note'));
    await folder.create(recursive: true);
    await File(
      p.join(folder.path, 'future.json'),
    ).writeAsString(jsonEncode({'version': 99, 'kind': 'note', 'entries': []}));
    await expectLater(
      a.synchronize(git, {DeskKind.note}),
      throwsFormatException,
    );
    expect((await a.load()).single.body, '本地安全保留');
  });

  test('两个设备独立新增相同文字仍是两条不同内容', () async {
    final one = await a.save(DeskKind.note, body: '相同内容');
    final two = await b.save(DeskKind.note, body: '相同内容');
    await a.merge([two]);
    expect(one.id, isNot(two.id));
    expect((await a.load()).length, 2);
  });

  test('两个独立工作目录通过内置 Git 传递便签与待办完成状态', () async {
    final remote = p.join(root.path, 'remote.git');
    git2.Repository.init(path: remote, bare: true).free();
    final config = SyncConfig(
      provider: SyncProvider.custom,
      remoteUrl: remote,
      username: 'test',
    );
    final git = EmbeddedGitService();
    Future<void> sync(DeskRepository desk, String name) async {
      final directory = Directory(p.join(root.path, name));
      await git.synchronize<int>(
        directory: directory,
        config: config,
        token: 'not-used',
        reconcile: () => desk.synchronize(directory, DeskKind.values.toSet()),
      );
    }

    await a.save(DeskKind.note, body: '通过 Git 传递的便签');
    final task = await a.save(DeskKind.todo, body: '跨设备完成');
    await sync(a, 'first');
    await sync(b, 'second');
    expect(
      (await b.load()).where((e) => e.kind == DeskKind.note).single.body,
      '通过 Git 传递的便签',
    );
    await b.save(
      DeskKind.todo,
      id: task.id,
      body: task.body,
      done: true,
      expected: {task.revision},
    );
    await sync(b, 'second');
    await sync(a, 'first');
    expect((await a.load()).where((e) => e.id == task.id).single.done, true);
    expect(await a.preference('settings.note'), isNull);
    String head() {
      final repo = git2.Repository.open(p.join(root.path, 'first'));
      final ref = repo.head;
      final oid = ref.target;
      try {
        return oid.sha;
      } finally {
        oid.free();
        ref.free();
        repo.free();
      }
    }

    final previousHead = head();
    await sync(a, 'first');
    expect(head(), previousHead, reason: '没有数据变动时不产生重复同步提交');
  });

  test('大快照按字节分片，重新同步保留全部内容且只清理本设备旧分片', () async {
    final chunked = DeskRepository(
      deviceId: 'device-a',
      testPath: p.join(root.path, 'a.db'),
      maxSyncFileBytes: 1500,
      factory: databaseFactoryFfiNoIsolate,
    );
    for (var i = 0; i < 8; i++) {
      await chunked.save(DeskKind.note, body: '中文内容 $i ${'便签' * 50}');
    }
    final git = Directory(p.join(root.path, 'remote'));
    await chunked.synchronize(git, {DeskKind.note});
    final folder = Directory(p.join(git.path, 'desktop-v1', 'note'));
    final files = await folder.list().where((f) => f is File).toList();
    expect(files.length, greaterThan(1));
    for (final file in files.cast<File>()) {
      expect(await file.length(), lessThanOrEqualTo(1500));
      expect(jsonDecode(await file.readAsString())['version'], 1);
    }
    await b.synchronize(git, {DeskKind.note});
    expect((await b.load()).length, 8);
    await a.synchronize(git, {DeskKind.note});
    expect(await File(p.join(folder.path, 'device-b.json')).exists(), true);
    expect(await File(p.join(folder.path, 'device-a.1.json')).exists(), false);
    expect((await a.load()).length, 8);
  });

  test('并行修改设置不会互相覆盖，空正文不能写入数据库', () async {
    final notes = DesktopNotes(a);
    await notes.initialize();
    await Future.wait([
      notes.updateSettings(DeskKind.note, {'enabled': true}),
      notes.updateSettings(DeskKind.note, {'opacity': 0.7}),
      notes.updateSettings(DeskKind.note, {'monitor': 'display-b'}),
    ]);
    expect(notes.enabled(DeskKind.note), true);
    expect(notes.config(DeskKind.note).opacity, 0.7);
    expect(notes.config(DeskKind.note).monitor, 'display-b');
    await expectLater(
      notes.save(DeskKind.note, body: '  \n '),
      throwsFormatException,
    );
    expect(await a.load(), isEmpty);
    notes.dispose();
  });

  test('桌面发布过滤已完成待办，编辑器复制序列可被历史采集排除', () async {
    if (!Platform.isWindows) return;
    const channel = MethodChannel('test/desktop_notes');
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'ignoreClipboard') return call.arguments == 42;
      return null;
    });
    final notes = DesktopNotes(a, channel: channel);
    await notes.initialize();
    await notes.updateSettings(DeskKind.todo, {'enabled': true});
    await notes.save(DeskKind.todo, body: '未完成');
    await notes.save(DeskKind.todo, body: '已完成', done: true);
    await notes.attachNative();
    final config =
        calls.lastWhere((c) => c.method == 'configure').arguments as Map;
    expect((config['todo']['rows'] as List).single['body'], '未完成');
    expect(await notes.ignoresClipboard(42), true);
    expect(await notes.ignoresClipboard(43), false);
    await notes.editing(true);
    expect(calls.last.method, 'editing');
    expect(calls.last.arguments, true);
    notes.dispose();
    await Future<void>.delayed(Duration.zero);
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('设置调整和草稿独立保留，完成后可在管理页恢复', () async {
    final notes = DesktopNotes(a);
    await notes.initialize();
    await notes.updateSettings(DeskKind.todo, {
      'enabled': true,
      'monitor': '外接屏',
      'x': 80.0,
    });
    await notes.storeDraft(DeskKind.note, '标题', '便签草稿');
    await notes.storeDraft(DeskKind.todo, '', '待办草稿');
    await notes.save(DeskKind.todo, body: '测试事项');
    await notes.toggle(notes.items(DeskKind.todo).single);
    expect(notes.items(DeskKind.todo).single.done, true);
    await notes.toggle(notes.items(DeskKind.todo).single);
    expect(notes.items(DeskKind.todo).single.done, false);
    await notes.updateSettings(DeskKind.todo, {'enabled': false});
    expect(notes.config(DeskKind.todo).monitor, '外接屏');
    expect((await notes.draft(DeskKind.note))['body'], '便签草稿');
    expect((await notes.draft(DeskKind.todo))['body'], '待办草稿');
    expect((await a.load()).length, 1);
    notes.dispose();
  });
}
