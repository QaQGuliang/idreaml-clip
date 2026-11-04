import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:git2dart/git2dart.dart';

import '../models/sync_models.dart';

class EmbeddedGitService {
  Future<T> synchronize<T>({
    required Directory directory,
    required SyncConfig config,
    required String token,
    required Future<T> Function() reconcile,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await _transfer(directory.path, config, token, push: false);
        final value = await reconcile();
        await _transfer(directory.path, config, token, push: true);
        return value;
      } catch (error) {
        lastError = error;
        if (attempt < 2) await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    throw StateError(_safeMessage(lastError));
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
      final remote = Remote.lookup(repo: repo, name: 'origin');
      arena.onReleaseAll(remote.free);
      final callbacks = Callbacks(
        credentials: UserPass(
          username: config.username.isEmpty ? 'git' : config.username,
          password: token,
        ),
      );
      final branch = config.branch;
      if (push) {
        _commitChanges(arena, repo, branch);
        remote.push(
          refspecs: ['refs/heads/$branch:refs/heads/$branch'],
          callbacks: callbacks,
        );
      } else {
        remote.fetch(
          refspecs: ['+refs/heads/$branch:refs/remotes/origin/$branch'],
          callbacks: callbacks,
        );
        _resetToRemote(arena, repo, branch);
      }
    });
  });

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
    Checkout.head(repo: repo, strategy: {GitCheckout.force});
  }

  static void _commitChanges(Arena arena, Repository repo, String branch) {
    // libgit2 may report an empty status map for an unborn branch even when
    // the worktree already contains the first files.
    if (!repo.isBranchUnborn && repo.status.isEmpty) return;
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

  String _safeMessage(Object? error) {
    final message = '$error';
    if (message.contains('401') || message.contains('authentication')) {
      return 'Git 身份验证失败，请检查用户名和访问令牌。';
    }
    if (message.contains('non-fast-forward')) {
      return '远端数据刚刚发生变化，请稍后重试。';
    }
    return 'Git 同步失败：${message.length > 180 ? message.substring(0, 180) : message}';
  }
}
