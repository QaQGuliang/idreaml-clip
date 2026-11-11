import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../data/data_storage.dart';
import '../services/directory_picker.dart';
import 'common.dart';

class StorageDirectoryCard extends StatelessWidget {
  const StorageDirectoryCard({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) => AppCard(
    child: SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('数据存储目录', style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          const Text('统一保存文字记录、图片、软件设置和同步数据。'),
          const SizedBox(height: 8),
          SelectableText(controller.storagePath ?? ''),
          const SizedBox(height: 10),
          const Text('默认位于安装目录下的 data/idreaml_clip。更改后会迁移全部数据，并删除旧目录及其内容。'),
          if (controller.storageMessage != null) ...[
            const SizedBox(height: 8),
            Text(controller.storageMessage!),
          ],
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const ValueKey('change-storage-directory'),
            onPressed:
                controller.storageChanging || controller.administratorChanging
                ? null
                : () => showDialog<void>(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) =>
                        _StorageDirectoryDialog(controller: controller),
                  ),
            icon: const Icon(Icons.drive_file_move_outlined, size: 18),
            label: Text(controller.storageChanging ? '正在迁移…' : '更改目录'),
          ),
          const Divider(height: 28),
          const Text('目录内容说明', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          const _StorageContents(),
          const SizedBox(height: 4),
          const Text('数据库的日志、临时文件由应用自动维护。备份或迁移时请保留整个数据目录。'),
        ],
      ),
    ),
  );
}

class _StorageContents extends StatelessWidget {
  const _StorageContents();

  static const entries = [
    ('database/clipboard.db', '文字记录、收藏、图片索引、设备信息和截图回执'),
    ('database/desktop.db', '便签、待办及其本机设置和草稿'),
    ('images/', '剪切板图片和截图的原始文件'),
    ('config/settings.db', '软件设置、快捷键、窗口布局和同步配置'),
    ('credentials/', '加密保存的同步访问令牌'),
    ('sync/', '用于云同步的本地 Git 仓库缓存'),
    ('.idreaml-clip-data', '数据目录标识，用于迁移校验和旧目录清理'),
  ];

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final entry in entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: constraints.maxWidth >= 480
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 190, child: SelectableText(entry.$1)),
                      const SizedBox(width: 14),
                      Expanded(child: Text(entry.$2)),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectableText(entry.$1),
                      const SizedBox(height: 3),
                      Text(
                        entry.$2,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
          ),
      ],
    ),
  );
}

class _StorageDirectoryDialog extends StatefulWidget {
  const _StorageDirectoryDialog({required this.controller});
  final AppController controller;
  @override
  State<_StorageDirectoryDialog> createState() =>
      _StorageDirectoryDialogState();
}

class _StorageDirectoryDialogState extends State<_StorageDirectoryDialog> {
  late final _path = TextEditingController(text: widget.controller.storagePath);
  bool _busy = false;
  bool _moving = false;
  String? _error;

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  Future<void> _browse() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final selected = await DirectoryPicker.choose(
        initialDirectory: _path.text,
      );
      if (selected != null && mounted) {
        _path.value = TextEditingValue(
          text: selected,
          selection: TextSelection.collapsed(offset: selected.length),
        );
      }
    } catch (_) {
      if (mounted) setState(() => _error = '无法打开文件夹选择窗口，请重试或手动输入路径。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final controller = widget.controller;
      final destination = await controller.validateStoragePath(_path.text);
      if (!mounted) return;
      if (controller.repository.storage!.samePath(
        controller.storagePath!,
        destination,
      )) {
        Navigator.pop(context);
        return;
      }
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('确认迁移数据？'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('原目录'),
                  SelectableText(controller.storagePath!),
                  const SizedBox(height: 12),
                  const Text('新目录'),
                  SelectableText(destination),
                  const SizedBox(height: 16),
                  const Text('确认后会迁移全部数据。迁移完成并校验成功后，原目录及其所有内容将被删除。迁移期间请勿关闭应用。'),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey('confirm-storage-migration'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认迁移'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      setState(() => _moving = true);
      await controller.changeStoragePath(destination);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is StorageException
              ? error.message
              : '无法更改目录，请检查路径、可用空间和读写权限。',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _moving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: const Text('更改数据存储目录'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('storage-directory-input'),
                      controller: _path,
                      enabled: !_busy,
                      autofocus: true,
                      minLines: 1,
                      maxLines: 3,
                      decoration: InputDecoration(
                        labelText: '目录完整路径',
                        errorText: _error,
                        errorMaxLines: 8,
                      ),
                      onSubmitted: (_) => _save(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    key: const ValueKey('browse-storage-directory'),
                    onPressed: _busy ? null : _browse,
                    icon: const Icon(Icons.folder_open_outlined, size: 18),
                    label: const Text('选择文件夹'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text('可手动输入完整路径，或选择一个空文件夹；也可以输入尚未创建的文件夹路径。'),
              if (_moving) ...[
                const SizedBox(height: 16),
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
                const Text('正在等待当前操作完成并迁移数据，请勿关闭应用…'),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('保存')),
      ],
    ),
  );
}
