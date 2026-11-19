import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:git2dart/git2dart.dart';
// git2dart 0.5.6 exposes fetch but does not expose its depth option.
// Reuse its credential and certificate callbacks with the bundled FFI API.
// ignore: implementation_imports
import 'package:git2dart/src/bindings/remote_callbacks.dart';
import 'package:git2dart_binaries/git2dart_binaries.dart' as native;

import '../models/sync_models.dart';

class EmbeddedGitService {
  Future<void> fetchOnly({
    required Directory directory,
    required SyncConfig config,
    required String token,
  }) async {
    native.libgit2Runtime.ensureInitialized();
    try {
      await _transfer(directory.path, config, token, push: false);
    } catch (error) {
      if (error is SyncFailure) rethrow;
      throw SyncFailure(
        SyncPhase.fetch,
        _safeMessage(error, SyncPhase.fetch, config),
      );
    }
  }

  Future<T> synchronize<T>({
    required Directory directory,
    required SyncConfig config,
    required String token,
    required Future<T> Function() reconcile,
  }) async {
    // Retain the caller's native lease so short-lived workers do not tear
    // down and reinitialize libgit2's process-wide TLS backend between calls.
    native.libgit2Runtime.ensureInitialized();
    SyncFailure? lastFailure;
    for (var attempt = 0; attempt < 3; attempt++) {
      var phase = SyncPhase.fetch;
      try {
        await _transfer(directory.path, config, token, push: false);
        phase = SyncPhase.reconcile;
        final value = await reconcile();
        phase = SyncPhase.push;
        await _transfer(directory.path, config, token, push: true);
        return value;
      } catch (error) {
        if (error is SyncFailure) rethrow;
        if (phase == SyncPhase.reconcile) {
          throw SyncFailure(phase, '无法读取或生成本次同步的数据。');
        }
        lastFailure = SyncFailure(phase, _safeMessage(error, phase, config));
        if (attempt < 2) await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    throw lastFailure!;
  }

  // libgit2 network calls are synchronous. Keep the database reconciliation on
  // its original isolate and open native handles only inside each worker.
  static Future<void> _transfer(
    String path,
    SyncConfig config,
    String token, {
    required bool push,
  }) => Isolate.run(() {
    final directory = Directory(path)..createSync(recursive: true);
    using((arena) {
      arena.onReleaseAll(Libgit2.shutdown);
      final repo =
          Directory('${directory.path}${Platform.pathSeparator}.git')
              .existsSync()
          ? Repository.open(path)
          : Repository.init(path: path, initialHead: config.branch);
      arena.onReleaseAll(repo.free);
      final repoConfig = repo.config;
      arena.onReleaseAll(repoConfig.free);
      repoConfig['core.autocrlf'] = false;
      if (!push) {
        if (Remote.list(repo).contains('origin')) {
          Remote.setUrl(repo: repo, remote: 'origin', url: config.remoteUrl);
        } else {
          Remote.create(
            repo: repo,
            name: 'origin',
            url: config.remoteUrl,
          ).free();
        }
      }
      final exceptionHost = config.skipCertificateVerification
          ? Uri.parse(config.remoteUrl).host.toLowerCase()
          : null;
      Remote openRemote() {
        final remote = Remote.lookup(repo: repo, name: 'origin');
        arena.onReleaseAll(remote.free);
        if (exceptionHost != null) {
          // Keep the exception on the configured HTTPS endpoint even if the
          // local Git cache has a different push URL or URL rewrite.
          remote.url = config.remoteUrl;
          remote.pushUrl = config.remoteUrl;
        }
        return remote;
      }

      final rejectedUpdates = <String>[];
      final callbacks = Callbacks(
        credentials: UserPass(
          username: config.username.isEmpty ? 'git' : config.username,
          password: token,
        ),
        certificateCheck: exceptionHost == null
            ? null
            : (_, host, {required valid}) =>
                  host.toLowerCase() == exceptionHost,
        // A successful transport does not mean the server accepted the ref.
        // Never throw through a native callback; inspect its reports below.
        pushUpdateReference: (_, message) {
          if (message.isNotEmpty) rejectedUpdates.add(message);
        },
      );
      final branch = config.branch;
      if (push) {
        _commitChanges(arena, repo, branch);
        openRemote().push(
          refspecs: ['refs/heads/$branch:refs/heads/$branch'],
          callbacks: callbacks,
        );
        if (rejectedUpdates.isNotEmpty) {
          throw _PushRejected(
            _pushRejectionMessage(rejectedUpdates.join('\n')),
          );
        }
      } else {
        final refspec = '+refs/heads/$branch:refs/remotes/origin/$branch';
        final scheme = Uri.tryParse(config.remoteUrl)?.scheme;
        final hasBranch = Reference.list(repo)
            .contains('refs/remotes/origin/$branch');
        if (config.provider == SyncProvider.custom &&
            (scheme == 'http' || scheme == 'https') &&
            (repo.isShallow || !hasBranch)) {
          _fetchSnapshot(arena, repo, config, refspec, callbacks);
        } else {
          openRemote().fetch(refspecs: [refspec], callbacks: callbacks);
        }
        _resetToRemote(arena, repo, branch);
      }
    });
  });

  static void _fetchSnapshot(
    Arena arena,
    Repository repo,
    SyncConfig config,
    String refspec,
    Callbacks callbacks,
  ) {
    final git = native.libgit2Runtime.bindings;
    void check(int status) {
      if (status < 0) {
        final error = git.git_error_last();
        final message = error == nullptr || error.ref.message == nullptr
            ? 'Git fetch failed without an error message'
            : error.ref.message.cast<Utf8>().toDartString();
        throw _GitTransferFailure(message);
      }
    }

    final remoteOut = arena<Pointer<native.git_remote>>();
    check(
      git.git_remote_lookup(
        remoteOut,
        // The handle stays borrowed for this synchronous native fetch.
        // ignore: invalid_use_of_internal_member
        repo.pointer,
        'origin'.toNativeUtf8(allocator: arena).cast(),
      ),
    );
    final remote = remoteOut.value;
    arena.onReleaseAll(() => git.git_remote_free(remote));
    if (config.skipCertificateVerification) {
      check(
        git.git_remote_set_instance_url(
          remote,
          config.remoteUrl.toNativeUtf8(allocator: arena).cast(),
        ),
      );
    }
    final options = arena<native.git_fetch_options>();
    check(
      git.git_fetch_options_init(options, native.GIT_FETCH_OPTIONS_VERSION),
    );
    options.ref
      ..depth = 1
      ..download_tagsAsInt = native
          .git_remote_autotag_option_t
          .GIT_REMOTE_DOWNLOAD_TAGS_NONE
          .value;
    final strings = arena<Pointer<Char>>();
    strings.value = refspec.toNativeUtf8(allocator: arena).cast();
    final refspecs = arena<native.git_strarray>();
    refspecs.ref
      ..count = 1
      ..strings = strings;
    RemoteCallbacks.withCallbackState<void>(
      callbacksOptions: options.ref.callbacks,
      callbacks: callbacks,
      operation: () =>
          check(git.git_remote_fetch(remote, refspecs, options, nullptr)),
    );
  }

  static void _resetToRemote(Arena arena, Repository repo, String branch) {
    final remoteRef = 'refs/remotes/origin/$branch';
    if (!Reference.list(repo).contains(remoteRef)) return;
    final remoteReference = Reference.lookup(repo: repo, name: remoteRef);
    arena.onReleaseAll(remoteReference.free);
    final target = remoteReference.target;
    arena.onReleaseAll(target.free);
    Reference.create(
      repo: repo,
      name: 'refs/heads/$branch',
      target: target,
      force: true,
    ).free();
    repo.setHead('refs/heads/$branch');
    // This is the application's dedicated sync cache. Drop untracked exports
    // left by a failed attempt before reading the fetched commit.
    Checkout.head(
      repo: repo,
      strategy: {GitCheckout.force, GitCheckout.removeUntracked},
    );
  }

  static void _commitChanges(Arena arena, Repository repo, String branch) {
    // Stage first: the binding's status options can omit untracked files,
    // including a new device snapshot inside an already tracked directory.
    // Compare trees afterwards to avoid commits when nothing has changed.
    final index = repo.index;
    arena.onReleaseAll(index.free);
    index.addAll(['*']);
    index.updateAll(['*']);
    index.write();
    final treeOid = index.writeTree();
    arena.onReleaseAll(treeOid.free);
    final tree = Tree.lookup(repo: repo, oid: treeOid);
    arena.onReleaseAll(tree.free);
    final signature = Signature.create(
      name: 'Idreaml Clip',
      email: 'sync@idreaml.local',
    );
    arena.onReleaseAll(signature.free);
    final parents = <Commit>[];
    if (!repo.isBranchUnborn) {
      final head = repo.head;
      arena.onReleaseAll(head.free);
      final oid = head.target;
      arena.onReleaseAll(oid.free);
      final parent = Commit.lookup(repo: repo, oid: oid);
      arena.onReleaseAll(parent.free);
      final parentTree = parent.treeOid;
      arena.onReleaseAll(parentTree.free);
      if (parentTree.sha == treeOid.sha) return;
      parents.add(parent);
    } else {
      repo.setHead('refs/heads/$branch');
    }
    Commit.create(
      repo: repo,
      updateRef: 'HEAD',
      author: signature,
      committer: signature,
      message: 'Idreaml Clip sync',
      tree: tree,
      parents: parents,
    ).free();
  }

  String _safeMessage(Object error, SyncPhase phase, SyncConfig config) {
    if (error is _PushRejected) return error.message;
    final message = '$error'.toLowerCase();
    final status = RegExp(
      r'(?:http(?: status(?: code)?)?|returned error|status code)[:\s]+(5\d\d)\b',
    ).firstMatch(message)?.group(1);
    if (status != null) {
      return '服务器或反向代理返回 HTTP $status。请查看该时段的 Git 服务和反向代理日志。';
    }
    if (message.contains('401') || message.contains('authentication')) {
      return 'Git 身份验证失败，请检查用户名和连接凭据。';
    }
    if (message.contains('403') || message.contains('forbidden')) {
      return '远端拒绝访问，请检查账号的仓库权限和连接凭据。';
    }
    if (message.contains('404') || message.contains('repository not found')) {
      return '找不到仓库，或当前账号无权访问，请检查仓库地址和访问权限。';
    }
    if (message.contains('413')) {
      return '远端拒绝接收上传包，上传数据超过大小限制。';
    }
    if (message.contains('non-fast-forward')) {
      return '远端数据刚刚发生变化，请稍后重试。';
    }
    if (phase == SyncPhase.fetch &&
        [
          'early eof',
          'unexpected eof',
          'unexpected disconnect',
          'unexpected end',
          'index-pack',
          'failed to read pack',
          'connection reset',
          'connection was closed',
        ].any(message.contains)) {
      return '下载 Git 数据包时连接中断。请重试，或查看 Git 服务和反向代理的传输日志。';
    }
    if (message.contains('certificate') ||
        message.contains('ssl') ||
        message.contains('tls')) {
      if (config.provider == SyncProvider.custom &&
          !config.skipCertificateVerification) {
        return '无法验证自托管服务器的 HTTPS 证书。请检查证书，或在确认信任该服务器后编辑连接并开启“跳过 HTTPS 证书校验”。';
      }
      return '无法验证远端 HTTPS 连接，请检查系统时间、证书和网络代理。';
    }
    if (message.contains('could not resolve') ||
        message.contains('timed out') ||
        message.contains('failed to connect') ||
        message.contains('connection reset')) {
      return '无法连接远端或连接超时，请检查网络后重试。';
    }
    if (error is FileSystemException) {
      return '无法访问本机同步缓存，请检查数据目录权限和磁盘空间。';
    }
    return phase == SyncPhase.push
        ? '远端未确认上传成功，请检查网络和仓库写入状态。'
        : '无法拉取远端分支，请检查网络、仓库地址和分支设置。';
  }
}

class _GitTransferFailure implements Exception {
  const _GitTransferFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

// Only fixed descriptions cross the worker boundary. Remote hooks can include
// repository paths, URLs, or credentials in their output.
String _pushRejectionMessage(String diagnostics) {
  final message = diagnostics.toLowerCase();
  bool hasAny(List<String> values) => values.any(message.contains);
  if (hasAny([
    'quota',
    'capacity',
    'storage limit',
    'repository size',
    '仓库容量',
    '仓库大小',
    '存储空间',
  ])) {
    return '远端拒绝同步：仓库存储容量或配额已达限制，请检查远端仓库空间。';
  }
  if (hasAny(['too large', 'large file', 'size limit', 'file size', '文件大小'])) {
    return '远端拒绝同步：上传文件或数据包超过大小限制，请检查远端仓库限制。';
  }
  if (hasAny([
    'protected branch',
    'branch is protected',
    'branch protection',
    '保护分支',
    '分支保护',
  ])) {
    return '远端拒绝同步：同步分支受保护，请检查远端分支保护规则。';
  }
  if (hasAny([
    'permission',
    'not allowed',
    'forbidden',
    'access denied',
    '权限',
  ])) {
    return '远端拒绝同步：没有分支写入权限，请检查账号权限和访问令牌。';
  }
  if (message.contains('non-fast-forward')) {
    return '远端拒绝同步：远端数据刚刚发生变化，请稍后重试。';
  }
  return '远端拒绝更新同步分支，请检查仓库容量、写入权限及分支保护设置。';
}

class _PushRejected implements Exception {
  const _PushRejected(this.message);

  final String message;

  @override
  String toString() => message;
}
