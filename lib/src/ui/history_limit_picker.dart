import 'package:flutter/material.dart';

import '../app_controller.dart';
import 'common.dart';

class HistoryLimitPicker extends StatefulWidget {
  const HistoryLimitPicker({super.key, required this.controller});

  final AppController controller;

  @override
  State<HistoryLimitPicker> createState() => _HistoryLimitPickerState();
}

class _HistoryLimitPickerState extends State<HistoryLimitPicker> {
  static const _presets = [1000, 5000, 10000, 50000];
  bool _saving = false;

  String _label(int value) =>
      '${value.toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (match) => '${match[1]},')} 条';

  Future<void> _select(int? value) async {
    if (value == null || _saving) return;
    if (value == 0) {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _CustomHistoryLimitDialog(
          initialValue: widget.controller.historyLimit,
          onSave: widget.controller.setHistoryLimit,
        ),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.controller.setHistoryLimit(value);
    } catch (_) {
      if (mounted) showMessage(context, '历史保存数量设置失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final limit = widget.controller.historyLimit;
    final custom = !_presets.contains(limit);
    return SizedBox(
      width: 180,
      child: DropdownButton<int>(
        key: const ValueKey('history-limit-picker'),
        value: custom ? 0 : limit,
        isExpanded: true,
        underline: const SizedBox.shrink(),
        borderRadius: BorderRadius.circular(10),
        selectedItemBuilder: (_) => [
          for (final value in _presets)
            Align(alignment: Alignment.centerRight, child: Text(_label(value))),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              '${_label(limit)}（自定义）',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
        items: [
          for (final value in _presets)
            DropdownMenuItem(value: value, child: Text(_label(value))),
          const DropdownMenuItem(value: 0, child: Text('自定义…')),
        ],
        onChanged: _saving ? null : _select,
      ),
    );
  }
}

class _CustomHistoryLimitDialog extends StatefulWidget {
  const _CustomHistoryLimitDialog({
    required this.initialValue,
    required this.onSave,
  });

  final int initialValue;
  final Future<void> Function(int value) onSave;

  @override
  State<_CustomHistoryLimitDialog> createState() =>
      _CustomHistoryLimitDialogState();
}

class _CustomHistoryLimitDialogState extends State<_CustomHistoryLimitDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _input = TextEditingController(text: '${widget.initialValue}')
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: '${widget.initialValue}'.length,
    );
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    final value = int.parse(_input.text.trim());
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(value);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) setState(() => _error = '保存失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: const Text('自定义历史保存数量'),
      content: SizedBox(
        width: 360,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                key: const ValueKey('custom-history-limit'),
                controller: _input,
                autofocus: true,
                enabled: !_saving,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _save(),
                autovalidateMode: AutovalidateMode.onUserInteraction,
                decoration: const InputDecoration(
                  labelText: '保存数量',
                  suffixText: '条',
                ),
                validator: (text) {
                  final input = text?.trim() ?? '';
                  final value = int.tryParse(input);
                  if (!RegExp(r'^[0-9]+$').hasMatch(input) ||
                      value == null ||
                      value < 1) {
                    return '请输入大于 0 的整数';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 14),
              Text(
                '保存后立即生效。超出数量的最旧非收藏记录会被自动清理，收藏记录会保留。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '保存中…' : '保存'),
        ),
      ],
    ),
  );
}
