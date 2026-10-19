import 'package:flutter/material.dart';

import '../services/directory_picker.dart';
import 'app_theme.dart';

class StorageStartupError extends StatefulWidget {
  const StorageStartupError({
    super.key,
    required this.message,
    required this.retry,
    this.title = '无法打开数据目录',
    this.instructions =
        '请检查磁盘连接、剩余空间和目录读写权限，然后重试。首次使用时，也可以指定一个可写的空目录。已有数据不会被重置。',
    this.allowChooseDirectory = true,
  });
  final String message;
  final Future<void> Function(String? path) retry;
  final String title;
  final String instructions;
  final bool allowChooseDirectory;
  @override
  State<StorageStartupError> createState() => _StorageStartupErrorState();
}

class _StorageStartupErrorState extends State<StorageStartupError> {
  final _path = TextEditingController();
  bool _busy = false;
  String? _pickerError;
  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  Future<void> _retry(String? path) async {
    setState(() => _busy = true);
    await widget.retry(path);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _browse() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _pickerError = null;
    });
    try {
      final selected = await DirectoryPicker.choose(
        initialDirectory: _path.text,
      );
      if (selected != null && mounted) _path.text = selected;
    } catch (_) {
      if (mounted) setState(() => _pickerError = '无法打开文件夹选择窗口，请重试或手动输入路径。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ListView(
              shrinkWrap: true,
              children: [
                Text(
                  widget.title,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                Text(widget.message),
                const SizedBox(height: 12),
                Text(widget.instructions),
                const SizedBox(height: 16),
                if (widget.allowChooseDirectory)
                  TextField(
                    controller: _path,
                    enabled: !_busy,
                    decoration: InputDecoration(
                      labelText: '首次使用的数据目录完整路径（可选）',
                      errorText: _pickerError,
                      errorMaxLines: 3,
                      suffixIcon: IconButton(
                        tooltip: '选择文件夹',
                        onPressed: _busy ? null : _browse,
                        icon: const Icon(Icons.folder_open_outlined),
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: _busy ? null : () => _retry(null),
                      child: const Text('重试'),
                    ),
                    if (widget.allowChooseDirectory)
                      FilledButton(
                        onPressed: _busy ? null : () => _retry(_path.text),
                        child: const Text('使用此目录'),
                      ),
                  ],
                ),
                if (_busy) const LinearProgressIndicator(),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
