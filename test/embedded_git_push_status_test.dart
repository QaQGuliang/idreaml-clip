import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/models/sync_models.dart';
import 'package:idreaml_clip/src/services/embedded_git_service.dart';
import 'package:path/path.dart' as p;

void main() {
  late _SmartHttpRemote remote;
  late Directory client;
  final git = EmbeddedGitService();

  setUp(() async {
    remote = await _SmartHttpRemote.create();
    client = Directory(p.join(remote.root.path, 'client'));
  });
  tearDown(() async => remote.close());

  Future<String> synchronize(String content, {SyncConfig? config}) =>
      git.synchronize<String>(
        directory: client,
        config:
            config ??
            SyncConfig(
              provider: SyncProvider.custom,
              remoteUrl: remote.url,
              username: 'fixture-user',
            ),
        token: 'fixture-token',
        reconcile: () async {
          await File(p.join(client.path, 'state.txt')).writeAsString(content);
          return content;
        },
      );

  test('自签名且域名不匹配的 HTTPS 仓库仅在当前自托管连接启用例外时可同步', () async {
    final secure = await _SmartHttpRemote.create(tls: true);
    addTearDown(secure.close);
    secure.requireAuthentication = true;
    final strict = SyncConfig(
      provider: SyncProvider.custom,
      remoteUrl: secure.url,
      username: 'fixture-user',
    );
    final skipped = SyncConfig.decode(
      jsonEncode({...strict.toJson(), 'certificate_exception_url': secure.url}),
    );
    final certificateFailure = throwsA(
      isA<SyncFailure>()
          .having((error) => error.phase, 'failure phase', SyncPhase.fetch)
          .having((error) => error.message, 'message', contains('证书')),
    );
    expect(strict.skipCertificateVerification, isFalse);
    await expectLater(
      synchronize('blocked', config: strict),
      certificateFailure,
    );
    expect(secure.pushRequests, 0);

    expect(
      SyncConfig.decode(skipped.encode()).skipCertificateVerification,
      isTrue,
    );
    expect(
      skipped.copyWith(branch: 'other').skipCertificateVerification,
      isTrue,
    );
    expect(
      skipped
          .copyWith(remoteUrl: '${secure.url}/different')
          .skipCertificateVerification,
      isFalse,
    );
    expect(
      await synchronize('verified exception', config: skipped),
      'verified exception',
    );
    expect(await secure.readState(), 'verified exception');
    expect(secure.authenticatedFetches, greaterThan(0));
    expect(secure.pushRequests, 1);

    await expectLater(
      synchronize(
        'blocked',
        config: skipped.copyWith(provider: SyncProvider.gitlab),
      ),
      certificateFailure,
    );
    await expectLater(
      synchronize('blocked again', config: strict),
      certificateFailure,
    );
    expect(await secure.readState(), 'verified exception');
  });

  test('HTTPS 证书例外不能用于重定向到另一个主机名', () async {
    final secure = await _SmartHttpRemote.create(tls: true);
    addTearDown(secure.close);
    secure.redirectHost = 'localhost';
    await expectLater(
      synchronize(
        'must not upload',
        config: SyncConfig(
          provider: SyncProvider.custom,
          remoteUrl: secure.url,
          username: 'fixture-user',
          certificateExceptionUrl: secure.url,
        ),
      ),
      throwsA(
        isA<SyncFailure>().having(
          (error) => error.phase,
          'failure phase',
          SyncPhase.fetch,
        ),
      ),
    );
    expect(secure.redirects, greaterThan(0));
    expect(secure.pushRequests, 0);
  });

  for (final tls in [false, true]) {
    test('自托管 ${tls ? 'HTTPS' : 'HTTP'} 可拉取最新快照、双向同步并保留远端历史', () async {
      final server = tls ? await _SmartHttpRemote.create(tls: true) : remote;
      if (tls) addTearDown(server.close);
      server.requireAuthentication = true;
      final config = SyncConfig(
        provider: SyncProvider.custom,
        remoteUrl: server.url,
        username: 'fixture-user',
        certificateExceptionUrl: tls ? server.url : null,
      );
      final first = Directory(p.join(remote.root.path, 'first'));
      final second = Directory(p.join(remote.root.path, 'second'));
      Future<String> exchange(Directory directory, String text) =>
          git.synchronize<String>(
            directory: directory,
            config: config,
            token: 'fixture-token',
            reconcile: () async {
              final file = File(p.join(directory.path, 'state.txt'));
              final previous = await file.exists()
                  ? await file.readAsString()
                  : '';
              await file.writeAsString(text);
              return previous;
            },
          );
      expect(await exchange(first, 'one'), '');
      expect(await exchange(first, 'two'), 'one');
      expect(await exchange(first, 'three'), 'two');
      expect(await exchange(second, 'four'), 'three');
      expect(
        await File(p.join(second.path, '.git', 'shallow')).exists(),
        isTrue,
      );
      expect(await exchange(first, 'five'), 'four');
      expect(await exchange(second, 'six'), 'five');
      expect(await server.readState(), 'six');
      expect(await server.commitCount(), 6);
      expect(server.errors, isEmpty);
      expect(server.authenticatedFetches, greaterThan(0));
    });
  }

  test('拉取返回 HTTP 500 时明确记录状态码，且不进入合并或上传', () async {
    final secure = await _SmartHttpRemote.create(tls: true);
    addTearDown(secure.close);
    secure.fetchStatus = HttpStatus.internalServerError;
    await expectLater(
      git.synchronize<void>(
        directory: client,
        config: SyncConfig(
          provider: SyncProvider.custom,
          remoteUrl: secure.url,
          username: 'fixture-user',
          certificateExceptionUrl: secure.url,
        ),
        token: 'fixture-token',
        reconcile: () async => fail('HTTP 500 后不应合并数据'),
      ),
      throwsA(
        isA<SyncFailure>()
            .having((error) => error.phase, 'phase', SyncPhase.fetch)
            .having(
              (error) => error.message,
              'diagnostic',
              contains('HTTP 500'),
            ),
      ),
    );
    expect(secure.pushRequests, 0);
  });

  test('自托管 Git 后端要求身份验证时，内置 Git 可使用用户名和密码拉取与推送', () async {
    remote.requireAuthentication = true;
    expect(
      await synchronize('first authenticated sync'),
      'first authenticated sync',
    );
    expect(
      await synchronize('second authenticated sync'),
      'second authenticated sync',
    );
    expect(await remote.readState(), 'second authenticated sync');
    expect(remote.authenticatedFetches, greaterThan(0));
    expect(remote.pushRequests, 2);
    expect(remote.errors, isEmpty);
  });

  test('smart HTTP 拒绝分支更新时不能报告同步成功，也不暴露服务端详情', () async {
    expect(await synchronize('initial'), 'initial');
    final originalHead = await remote.head();
    await remote.hook('''
#!/bin/sh
echo 'fixture-private-server-detail' >&2
exit 1
''');
    remote.pushRequests = 0;

    await expectLater(
      synchronize('must not be reported as uploaded'),
      throwsA(
        isA<SyncFailure>()
            .having((error) => error.phase, 'failure phase', SyncPhase.push)
            .having(
              (error) => error.message,
              'safe push rejection',
              allOf(
                contains('远端拒绝'),
                isNot(contains('fixture-private-server-detail')),
                isNot(contains('fixture-token')),
              ),
            ),
      ),
    );
    expect(remote.pushRequests, 3, reason: '服务器拒绝也必须进入已有的重试流程');
    expect(await remote.head(), originalHead);
    expect(await remote.readState(), 'initial');
    expect(remote.errors, isEmpty);
  });

  test('smart HTTP 首次拒绝后重试获准，只有远端更新成功才返回结果', () async {
    await synchronize('initial');
    await remote.hook('''
#!/bin/sh
if [ ! -f hooks/rejected-once ]; then
  : > hooks/rejected-once
  exit 1
fi
exit 0
''');
    remote.pushRequests = 0;

    expect(await synchronize('accepted after retry'), 'accepted after retry');
    expect(remote.pushRequests, 2);
    expect(await remote.readState(), 'accepted after retry');
    expect(remote.errors, isEmpty);
  });

  for (final reason in {
    'storage quota exceeded': '容量',
    'file exceeds size limit': '大小限制',
    'protected branch update': '分支受保护',
  }.entries) {
    test('smart HTTP 保留拒绝原因类别 ${reason.key} 并隐藏原始详情', () async {
      await synchronize('initial');
      await remote.hook('''
#!/bin/sh
echo 'fixture-private-server-detail; fixture-token' >&2
exit 1
''');
      remote.rejectionReason = reason.key;

      await expectLater(
        synchronize('rejected'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'safe rejection category from receive-pack report-status',
            allOf(
              contains('远端拒绝'),
              contains(reason.value),
              isNot(contains('fixture-private-server-detail')),
              isNot(contains('fixture-token')),
            ),
          ),
        ),
      );
      expect(await remote.readState(), 'initial');
      expect(remote.errors, isEmpty);
    });
  }
}

// Only this test fixture uses system Git. The production client under test
// still performs every fetch/push through EmbeddedGitService and libgit2.
// A filesystem bare remote does not exercise receive-pack rejection reports.
class _SmartHttpRemote {
  _SmartHttpRemote(this.root, this.server, {required this.tls});

  final Directory root;
  final HttpServer server;
  final bool tls;
  final errors = <Object>[];
  final _requests = <Future<void>>{};
  int pushRequests = 0;
  bool requireAuthentication = false;
  int authenticatedFetches = 0;
  int? fetchStatus;
  String? rejectionReason;
  String? redirectHost;
  int redirects = 0;

  String get url =>
      '${tls ? 'https' : 'http'}://127.0.0.1:${server.port}/remote.git';
  String get repository => p.join(root.path, 'remote.git');

  static Map<String, String> get _environment => {
    'GIT_CONFIG_NOSYSTEM': '1',
    'GIT_CONFIG_GLOBAL': Platform.isWindows ? 'NUL' : '/dev/null',
    'GIT_TERMINAL_PROMPT': '0',
  };

  static Future<_SmartHttpRemote> create({bool tls = false}) async {
    SecurityContext? security;
    if (tls) {
      final pem = await File('test/fixtures/git-loopback-test.pem')
          .readAsBytes();
      security = SecurityContext()
        ..useCertificateChainBytes(pem)
        ..usePrivateKeyBytes(pem);
    }
    final root = await Directory.systemTemp.createTemp('idreaml-push-status-');
    final server = security == null
        ? await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
        : await HttpServer.bindSecure(
            InternetAddress.loopbackIPv4,
            0,
            security,
          );
    final fixture = _SmartHttpRemote(root, server, tls: tls);
    try {
      await fixture._git([
        'init',
        '--bare',
        '--initial-branch=main',
        fixture.repository,
      ]);
      await fixture._git([
        '--git-dir=${fixture.repository}',
        'config',
        'http.receivepack',
        'true',
      ]);
      server.listen((request) {
        final pending = fixture._serve(request);
        fixture._requests.add(pending);
        unawaited(
          pending.whenComplete(() => fixture._requests.remove(pending)),
        );
      });
      return fixture;
    } catch (_) {
      await fixture.close();
      rethrow;
    }
  }

  Future<String> _git(List<String> arguments) async {
    final result = await Process.run(
      'git',
      arguments,
      environment: _environment,
    );
    if (result.exitCode != 0) {
      throw StateError('Git fixture failed: ${result.stderr}');
    }
    return '${result.stdout}'.trim();
  }

  Future<void> hook(String content) async {
    final file = File(p.join(repository, 'hooks', 'pre-receive'));
    await file.writeAsString(content);
    if (!Platform.isWindows) {
      final result = await Process.run('chmod', ['+x', file.path]);
      if (result.exitCode != 0) throw StateError('Cannot enable fixture hook');
    }
  }

  Future<String> head() =>
      _git(['--git-dir=$repository', 'rev-parse', 'refs/heads/main']);
  Future<String> readState() =>
      _git(['--git-dir=$repository', 'show', 'refs/heads/main:state.txt']);
  Future<int> commitCount() async => int.parse(
    await _git(['--git-dir=$repository', 'rev-list', '--count', 'main']),
  );

  Future<void> _serve(HttpRequest request) async {
    try {
      if (fetchStatus != null &&
          request.uri.queryParameters['service'] == 'git-upload-pack') {
        request.response.statusCode = fetchStatus!;
        return;
      }
      if (redirectHost != null && request.requestedUri.host == '127.0.0.1') {
        redirects++;
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          Uri.parse(url)
              .resolveUri(request.uri)
              .replace(host: redirectHost)
              .toString(),
        );
        return;
      }
      if (requireAuthentication) {
        final expected =
            'Basic ${base64Encode(utf8.encode('fixture-user:fixture-token'))}';
        if (request.headers.value(HttpHeaders.authorizationHeader) !=
            expected) {
          request.response.statusCode = HttpStatus.unauthorized;
          request.response.headers.set(
            HttpHeaders.wwwAuthenticateHeader,
            'Basic realm="fixture"',
          );
          return;
        }
        if (request.uri.queryParameters['service'] == 'git-upload-pack' ||
            request.uri.path.endsWith('/git-upload-pack')) {
          authenticatedFetches++;
        }
      }
      if (request.method == 'POST' &&
          request.uri.path.endsWith('/git-receive-pack')) {
        pushRequests++;
      }
      final input = await request.fold(
        BytesBuilder(),
        (builder, bytes) => builder..add(bytes),
      );
      final process = await Process.start(
        'git',
        ['http-backend'],
        environment: {
          ..._environment,
          'GIT_PROJECT_ROOT': root.path,
          'GIT_HTTP_EXPORT_ALL': '1',
          'PATH_INFO': request.uri.path,
          'QUERY_STRING': request.uri.query,
          'REQUEST_METHOD': request.method,
          'CONTENT_TYPE': request.headers.contentType?.toString() ?? '',
          'CONTENT_LENGTH': '${input.length}',
          'REMOTE_USER': 'fixture-user',
          'REMOTE_ADDR': '127.0.0.1',
          'SERVER_PROTOCOL': 'HTTP/1.1',
          if (request.headers.value('git-protocol') case final String value)
            'HTTP_GIT_PROTOCOL': value,
        },
      );
      final output = process.stdout.fold(
        BytesBuilder(),
        (builder, bytes) => builder..add(bytes),
      );
      final stderr = process.stderr.transform(utf8.decoder).join();
      process.stdin.add(input.takeBytes());
      await process.stdin.close();
      final bytes = (await output).takeBytes();
      final errorText = await stderr;
      if (await process.exitCode != 0) {
        throw StateError('http-backend: $errorText');
      }
      var separator = -1;
      for (var i = 0; i + 3 < bytes.length; i++) {
        if (bytes[i] == 13 &&
            bytes[i + 1] == 10 &&
            bytes[i + 2] == 13 &&
            bytes[i + 3] == 10) {
          separator = i;
          break;
        }
      }
      if (separator < 0) throw StateError('Missing CGI response headers');
      for (final line
          in ascii.decode(bytes.sublist(0, separator)).split('\r\n')) {
        final colon = line.indexOf(':');
        if (colon < 0) continue;
        final name = line.substring(0, colon);
        final value = line.substring(colon + 1).trim();
        if (name.toLowerCase() == 'status') {
          request.response.statusCode = int.parse(value.split(' ').first);
        } else {
          request.response.headers.add(name, value);
        }
      }
      var body = bytes.sublist(separator + 4);
      if (request.method == 'POST' &&
          request.uri.path.endsWith('/git-receive-pack') &&
          rejectionReason != null) {
        // A hosting provider may give a more specific ng/ref-status message
        // than Git's generic hook refusal. Substitute equal-length ASCII so
        // nested Git pkt-line/sideband framing stays intact; the real hook
        // still rejects the update and libgit2 parses the real HTTP response.
        const hookReason = 'pre-receive hook declined';
        final wire = latin1.decode(body);
        if (!wire.contains(hookReason) ||
            rejectionReason!.length > hookReason.length) {
          throw StateError('Expected fixture hook rejection report');
        }
        body = Uint8List.fromList(
          latin1.encode(
            wire.replaceAll(
              hookReason,
              rejectionReason!.padRight(hookReason.length),
            ),
          ),
        );
      }
      request.response.add(body);
    } catch (error) {
      errors.add(error);
      request.response.statusCode = HttpStatus.internalServerError;
    } finally {
      await request.response.close();
    }
  }

  Future<void> close() async {
    await server.close(force: true);
    await Future.wait(_requests.toList());
    await root.delete(recursive: true);
  }
}
