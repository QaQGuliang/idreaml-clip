import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/screenshot_service.dart';
import '../services/sync_archive.dart';
import '../services/sync_service.dart';
import 'app_theme.dart';
import 'common.dart';

Future<void> showSyncArchiveBrowser(
  BuildContext context, {
  required SyncService sync,
  required ScreenshotService screenshots,
}) async {
  Directory? root;
  try {
    root = await sync.currentWorktree();
  } catch (error) {
    if (context.mounted) showMessage(context, '$error');
    return;
  }
  if (!context.mounted) return;
  if (root == null) {
    showMessage(context, '请先连接仓库，再查看仓库目录');
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (_) =>
        _ArchiveBrowserDialog(root: root!, screenshots: screenshots),
  );
}

class _ArchiveBrowserDialog extends StatefulWidget {
  const _ArchiveBrowserDialog({required this.root, required this.screenshots});
  final Directory root;
  final ScreenshotService screenshots;

  @override
  State<_ArchiveBrowserDialog> createState() => _ArchiveBrowserDialogState();
}

class _ArchiveBrowserDialogState extends State<_ArchiveBrowserDialog> {
  static const _maxBytes = 32 * 1024 * 1024;
  static const _maxPreviewChars = 20000;
  static const _imageExtensions = {
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.bmp',
  };

  late final SyncArchive _files = SyncArchive(widget.root);
  List<String>? _paths;
  String? _listError;
  String? _selected;
  Uint8List? _bytes;
  String? _previewError;
  bool _loading = false;
  bool _downloading = false;

  @override
  void initState() {
    super.initState();
    _loadList();
  }

  Future<void> _loadList() async {
    try {
      final paths = await _files.listFiles();
      if (!mounted) return;
      setState(() => _paths = paths);
      if (paths.isNotEmpty) await _select(paths.first);
    } catch (error) {
      if (mounted) setState(() => _listError = '$error');
    }
  }

  Future<void> _select(String path) async {
    setState(() {
      _selected = path;
      _bytes = null;
      _previewError = null;
      _loading = true;
    });
    try {
      final file = await _files.file(path);
      if (!await file.exists()) {
        throw const FormatException('文件不存在，可能已被新的同步移除');
      }
      if (await file.length() > _maxBytes) {
        throw const FormatException('文件超过 32 MB，无法预览或下载');
      }
      final bytes = await file.readAsBytes();
      if (!mounted || _selected != path) return;
      setState(() {
        _bytes = bytes;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || _selected != path) return;
      setState(() {
        _previewError = '$error';
        _loading = false;
      });
    }
  }

  Future<void> _download() async {
    final path = _selected;
    final bytes = _bytes;
    if (path == null || bytes == null || _downloading) return;
    setState(() => _downloading = true);
    try {
      final target = await widget.screenshots.chooseExportPath(
        p.basename(path),
      );
      if (target == null) return;
      await File(target).writeAsBytes(bytes, flush: true);
      if (mounted) showMessage(context, '已生成文件下载');
    } catch (error) {
      if (mounted) showMessage(context, '$error');
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  bool _isImage(String path) =>
      _imageExtensions.contains(p.extension(path).toLowerCase());

  @override
  Widget build(BuildContext context) {
    final paths = _paths;
    return AlertDialog(
      key: const ValueKey('archive-browser'),
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: AppColors.line),
      ),
      titleTextStyle: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: AppColors.text,
      ),
      title: const Text('仓库目录'),
      content: SizedBox(
        width: 780,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '查看最新快照中的原文、原图、Markdown 和配置文件。点击文件可以预览并下载。',
              style: TextStyle(fontSize: 12, color: AppColors.muted),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: _listError != null
                  ? Center(child: Text(_listError!))
                  : paths == null
                  ? const Center(child: CircularProgressIndicator())
                  : paths.isEmpty
                  ? const Center(
                      child: Text(
                        '仓库还没有同步文件，先执行一次同步。',
                        style: TextStyle(color: AppColors.muted),
                      ),
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: 260,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border.all(color: AppColors.line),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: _fileTree(paths),
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(child: _preview()),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _fileTree(List<String> paths) {
    final rows = <(String, String?)>[];
    String? folder;
    for (final path in paths) {
      final top = path.split('/').first;
      if (top != folder) {
        folder = top;
        rows.add(('$top/', null));
      }
      rows.add((path, path));
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final (label, path) = rows[index];
        if (path == null) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.text,
              ),
            ),
          );
        }
        final selected = path == _selected;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          child: Material(
            color: selected ? AppColors.primarySoft : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              key: ValueKey('archive-file-$path'),
              borderRadius: BorderRadius.circular(8),
              onTap: () => _select(path),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                child: Text(
                  path.substring(path.indexOf('/') + 1),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: selected ? AppColors.primary : AppColors.text,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _preview() {
    final path = _selected;
    if (path == null) return const SizedBox.shrink();
    final bytes = _bytes;
    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_previewError != null) {
      body = Center(
        child: Text(
          _previewError!,
          style: const TextStyle(color: AppColors.danger, fontSize: 12),
        ),
      );
    } else if (bytes == null) {
      body = const SizedBox.shrink();
    } else if (_isImage(path)) {
      body = SingleChildScrollView(
        child: Image.memory(
          bytes,
          key: const ValueKey('archive-image-preview'),
          errorBuilder: (context, _, _) => const Text(
            '图片无法解码，可下载后查看',
            style: TextStyle(color: AppColors.muted, fontSize: 12),
          ),
        ),
      );
    } else {
      var text = utf8.decode(bytes, allowMalformed: true);
      if (text.length > _maxPreviewChars) {
        text = '${text.substring(0, _maxPreviewChars)}\n…（预览已截断，下载查看完整内容）';
      }
      body = SingleChildScrollView(
        key: const ValueKey('archive-text-preview'),
        child: SelectableText(
          text,
          style: const TextStyle(
            fontSize: 12,
            height: 1.5,
            fontFamily: 'Consolas',
            color: AppColors.text,
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          path,
          style: const TextStyle(fontSize: 11, color: AppColors.muted),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.canvas,
              border: Border.all(color: AppColors.line),
              borderRadius: BorderRadius.circular(12),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Padding(padding: const EdgeInsets.all(12), child: body),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            key: const ValueKey('archive-download'),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: bytes == null || _downloading ? null : _download,
            icon: const Icon(Icons.download_rounded, size: 17),
            label: Text(_downloading ? '下载中…' : '下载此文件'),
          ),
        ),
      ],
    );
  }
}
