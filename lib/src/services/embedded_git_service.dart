import 'dart:async';
import 'dart:io';

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
      Repository? repo;
      Remote? remote;
      try {
        repo = await _open(directory, config.remoteUrl, config.branch);
        final callbacks = Callbacks(
          credentials: UserPass(
            username: config.username.isEmpty ? 'git' : config.username,
            password: token,
          ),
        );
        remote = Remote.lookup(repo: repo, name: 'origin');
        remote.fetch(
          refspecs: [
            '+refs/heads/${config.branch}:refs/remotes/origin/${config.branch}',
          ],
          callbacks: callbacks,
        );
        _resetToRemote(repo, config.branch);
        final value = await reconcile();
        _commitChanges(repo, config.branch);
        remote.push(
          refspecs: ['refs/heads/${config.branch}:refs/heads/${config.branch}'],
          callbacks: callbacks,
        );
        return value;
      } catch (error) {
        lastError = error;
        if (attempt < 2) await Future<void>.delayed(const Duration(seconds: 1));
      } finally {
        remote?.free();
        repo?.free();
      }
    }
    throw StateError(_safeMessage(lastError));
  }

  Future<Repository> _open(
    Directory directory,
    String remoteUrl,
    String branch,
  ) async {
    await directory.create(recursive: true);
    final gitDirectory = Directory(
      '${directory.path}${Platform.pathSeparator}.git',
    );
    final repo = gitDirectory.existsSync()
        ? Repository.open(directory.path)
        : Repository.init(path: directory.path, initialHead: branch);
    if (Remote.list(repo).contains('origin')) {
      Remote.setUrl(repo: repo, remote: 'origin', url: remoteUrl);
    } else {
      Remote.create(repo: repo, name: 'origin', url: remoteUrl).free();
    }
    return repo;
  }

  void _resetToRemote(Repository repo, String branch) {
    final remoteRef = 'refs/remotes/origin/$branch';
    if (!Reference.list(repo).contains(remoteRef)) return;
    final remoteReference = Reference.lookup(repo: repo, name: remoteRef);
    final target = remoteReference.target;
    Reference.create(
      repo: repo,
      name: 'refs/heads/$branch',
      target: target,
      force: true,
    ).free();
    remoteReference.free();
    repo.setHead('refs/heads/$branch');
    Checkout.head(repo: repo, strategy: {GitCheckout.force});
  }

  void _commitChanges(Repository repo, String branch) {
    // libgit2 may report an empty status map for an unborn branch even when
    // the worktree already contains the first files.
    if (!repo.isBranchUnborn && repo.status.isEmpty) return;
    final index = repo.index;
    index.addAll(['*']);
    index.updateAll(['*']);
    index.write();
    final treeOid = index.writeTree();
    final tree = Tree.lookup(repo: repo, oid: treeOid);
    final signature = Signature.create(
      name: 'Idreaml Clip',
      email: 'sync@idreaml.local',
    );
    final parents = <Commit>[];
    if (!repo.isBranchUnborn) {
      parents.add(Commit.lookup(repo: repo, oid: repo.head.target));
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
    );
    for (final parent in parents) {
      parent.free();
    }
    signature.free();
    tree.free();
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
