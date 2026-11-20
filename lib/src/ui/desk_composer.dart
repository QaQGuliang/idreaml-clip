import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../desk/desk_management_list.dart';
import '../desk/desk_models.dart';
import '../desk/desk_typography.dart';
import '../desk/desktop_notes.dart';
import 'app_theme.dart';

/// 快速新增结束后交给窗口模式处理的结果。
enum DeskComposerResult { saved, cancelled, dismissed }

/// 草稿已按语义持久化（保存或清理），外层可以结束快速新增窗口。
typedef DeskComposerFinish = Future<void> Function(DeskComposerResult result);

/// 失焦或系统关闭时由外层驱动退出：草稿保留，不再恢复窗口焦点。
typedef DeskComposerDismiss = Future<void> Function({required bool clearDraft});

/// 快速新增的预设文字颜色，与原生窗口的七个色块保持一致。
const deskComposerSwatches = <({String label, int color})>[
  (label: '墨色', color: 0xFF302B3C),
  (label: '紫色', color: 0xFF6C57E5),
  (label: '红色', color: 0xFFD84461),
  (label: '橙色', color: 0xFFBA6518),
  (label: '绿色', color: 0xFF268064),
  (label: '蓝色', color: 0xFF347AC4),
  (label: '白色', color: 0xFFFFFFFF),
];

/// 快速新增便签/待办。窗口本身由 desktop_service 切换到无边框浮层，
/// 这里只负责卡片内容、校验、草稿与保存。
class DeskComposer extends StatefulWidget {
  const DeskComposer({
    super.key,
    required this.notes,
    required this.kind,
    this.draft = const {},
    this.onFinish,
    this.onDismissReady,
  });
  final DesktopNotes notes;
  final DeskKind kind;
  final Map<String, dynamic> draft;
  final DeskComposerFinish? onFinish;
  final ValueChanged<DeskComposerDismiss?>? onDismissReady;

  @override
  State<DeskComposer> createState() => _DeskComposerState();
}

class _DeskComposerState extends State<DeskComposer> {
  late final _title = TextEditingController(
    text: _draftText(widget.draft['title']),
  );
  late final _body = TextEditingController(
    text: _draftText(widget.draft['body']),
  );
  late final String? _fontFamily = _draftFontFamily(widget.draft['fontFamily']);
  late final double? _fontSize = _draftFontSize(widget.draft['fontSize']);
  late int? _textColor = _draftColor(widget.draft['textColor']);
  final _titleFocus = FocusNode();
  final _bodyFocus = FocusNode();
  Timer? _draftTimer;
  String? _titleError;
  String? _bodyError;
  String? _saveError;
  bool _saving = false;
  bool _finished = false;
  bool _paletteOpen = false;
  bool _pickingColor = false;

  bool get _note => widget.kind == DeskKind.note;
  DeskSettings get _settings => widget.notes.config(widget.kind);
  String get _titleTooLongMessage => '标题最多 $deskTitleMaxLength 字，请精简后保存';

  @override
  void initState() {
    super.initState();
    // 历史草稿可能超过新的标题上限，打开时先给出可修正的提示。
    if (_title.text.length > deskTitleMaxLength) {
      _titleError = _titleTooLongMessage;
    }
    HardwareKeyboard.instance.addHandler(_handleKey);
    widget.onDismissReady?.call(_dismiss);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _bodyFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    _draftTimer?.cancel();
    _title.dispose();
    _body.dispose();
    _titleFocus.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  bool _handleKey(KeyEvent event) {
    if (_finished || _saving) return false;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      // 选色弹层自行处理 Esc，避免同时关闭整个窗口。
      if (_pickingColor) return false;
      if (_paletteOpen) {
        setState(() => _paletteOpen = false);
        return true;
      }
      unawaited(_complete(DeskComposerResult.dismissed));
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter &&
        HardwareKeyboard.instance.isControlPressed) {
      if (event is KeyDownEvent) unawaited(_save());
      return true;
    }
    return false;
  }

  Future<void> _dismiss({required bool clearDraft}) async {
    // 保存进行中不响应失焦，避免复制序列与草稿状态互相覆盖。
    if (_saving || _finished) return;
    await _complete(
      clearDraft ? DeskComposerResult.cancelled : DeskComposerResult.dismissed,
    );
  }

  Future<void> _complete(DeskComposerResult result) async {
    if (_finished) return;
    _finished = true;
    _draftTimer?.cancel();
    try {
      // 保存成功与取消按既有语义清理草稿；关闭或离开窗口保留草稿。
      if (result == DeskComposerResult.dismissed) {
        await _persistDraft();
      } else {
        await widget.notes.storeDraft(widget.kind, '', '');
      }
    } catch (_) {
      // 草稿写入失败不能让窗口卡住，仍按原语义结束会话。
    }
    await widget.onFinish?.call(result);
  }

  Future<void> _persistDraft() => widget.notes.storeDraft(
    widget.kind,
    _title.text,
    _body.text,
    fontFamily: _fontFamily,
    fontSize: _fontSize,
    textColor: _textColor,
  );

  void _scheduleDraft() {
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 400), () {
      unawaited(_persistDraft());
    });
  }

  Future<void> _save() async {
    if (_saving || _finished) return;
    final title = _title.text;
    final body = _body.text;
    final bodyEmpty = body.trim().isEmpty;
    final titleTooLong = title.length > deskTitleMaxLength;
    if (bodyEmpty || titleTooLong) {
      setState(() {
        _bodyError = bodyEmpty ? '请先填写内容' : null;
        _titleError = titleTooLong ? _titleTooLongMessage : null;
        _saveError = null;
      });
      // 焦点跳到第一个错误字段，重新输入即清除提示。
      (titleTooLong ? _titleFocus : _bodyFocus).requestFocus();
      return;
    }
    setState(() {
      _saving = true;
      _saveError = null;
      _bodyError = null;
      _titleError = null;
      _paletteOpen = false;
    });
    try {
      await widget.notes.save(
        widget.kind,
        title: title.trim(),
        body: body,
        fontFamily: _fontFamily,
        fontSize: _fontSize,
        textColor: _textColor,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveError = '保存失败，请重试：${_errorMessage(error)}';
      });
      return;
    }
    await _complete(DeskComposerResult.saved);
  }

  String _errorMessage(Object error) => switch (error) {
    FormatException(:final message) => message,
    StateError(:final message) => message,
    _ => '$error',
  };

  Future<void> _chooseColor() async {
    if (_saving || _finished || _pickingColor) return;
    if (_paletteOpen) {
      setState(() => _paletteOpen = false);
      return;
    }
    setState(() => _paletteOpen = true);
  }

  void _selectColor(int? color) {
    setState(() {
      _textColor = color;
      _paletteOpen = false;
    });
    _scheduleDraft();
  }

  Future<void> _pickCustomColor() async {
    if (_saving || _pickingColor) return;
    _pickingColor = true;
    try {
      final selected = await pickDeskTextColor(
        context,
        initialColor:
            _textColor ?? _settings.textColor ?? AppColors.text.toARGB32(),
      );
      if (selected != null && mounted) _selectColor(selected);
    } finally {
      _pickingColor = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final typography = DeskEntryTypography(
      fontFamily: _fontFamily,
      fontSize: _fontSize,
      textColor: _textColor,
      settings: _settings,
    );
    final label = _note ? '内容' : '事项内容';
    // 输入框沿用条目/模块的字体与颜色；字号限制在可读范围，避免小窗口溢出。
    final inputSize = typography.size.clamp(12.0, 20.0).toDouble();
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.line),
        ),
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(),
            const SizedBox(height: 16),
            if (_note) ...[
              const _FieldLabel('标题（可选）'),
              const SizedBox(height: 6),
              TextField(
                key: const ValueKey('desk-composer-title'),
                controller: _title,
                focusNode: _titleFocus,
                maxLength: deskTitleMaxLength,
                enabled: !_saving,
                textInputAction: TextInputAction.next,
                style: typography.titleStyle.copyWith(
                  fontSize: inputSize + 2,
                  height: 1.3,
                ),
                decoration: _decoration(hint: '这一刻，想记下什么？', error: _titleError),
                onChanged: (_) {
                  if (_titleError != null) setState(() => _titleError = null);
                  _scheduleDraft();
                },
                onSubmitted: (_) => _bodyFocus.requestFocus(),
              ),
              if (_titleError != null)
                _errorText(
                  const ValueKey('desk-composer-title-error'),
                  _titleError!,
                ),
              const SizedBox(height: 14),
            ],
            _FieldLabel(label),
            const SizedBox(height: 6),
            Expanded(
              child: TextField(
                key: const ValueKey('desk-composer-body'),
                controller: _body,
                focusNode: _bodyFocus,
                enabled: !_saving,
                expands: true,
                maxLines: null,
                minLines: null,
                textAlignVertical: TextAlignVertical.top,
                keyboardType: TextInputType.multiline,
                style: typography.bodyStyle.copyWith(
                  fontSize: inputSize,
                  height: 1.5,
                ),
                decoration: _decoration(
                  hint: _note ? '写下来，让思绪轻一点…' : '接下来，想完成什么？',
                  error: _bodyError,
                  alignTop: true,
                ),
                onChanged: (_) {
                  if (_bodyError != null) setState(() => _bodyError = null);
                  _scheduleDraft();
                },
              ),
            ),
            if (_bodyError != null)
              _errorText(
                const ValueKey('desk-composer-body-error'),
                _bodyError!,
              ),
            const SizedBox(height: 12),
            _colorRow(),
            if (_paletteOpen) ...[const SizedBox(height: 8), _palette()],
            const SizedBox(height: 12),
            if (_saveError != null)
              _errorText(
                const ValueKey('desk-composer-save-error'),
                _saveError!,
              ),
            _footer(),
          ],
        ),
      ),
    );
  }

  Widget _header() => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '快速记录',
              style: TextStyle(fontSize: 11, color: AppColors.primary),
            ),
            const SizedBox(height: 4),
            Text(
              _note ? '新建便签' : '新建待办',
              key: const ValueKey('desk-composer-heading'),
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.text,
              ),
            ),
          ],
        ),
      ),
      _iconButton(
        key: const ValueKey('desk-composer-close'),
        tooltip: '关闭',
        icon: Icons.close_rounded,
        onPressed: _saving
            ? null
            : () => unawaited(_complete(DeskComposerResult.dismissed)),
      ),
    ],
  );

  Widget _iconButton({
    required Key key,
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
  }) => Tooltip(
    message: tooltip,
    child: SizedBox(
      width: 32,
      height: 32,
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          key: key,
          borderRadius: BorderRadius.circular(9),
          onTap: onPressed,
          child: Icon(icon, size: 16, color: AppColors.muted),
        ),
      ),
    ),
  );

  InputDecoration _decoration({
    required String hint,
    String? error,
    bool alignTop = false,
  }) => InputDecoration(
    hintText: hint,
    counterText: '',
    isDense: true,
    filled: true,
    fillColor: const Color(0xFFF8F8FB),
    contentPadding: EdgeInsets.fromLTRB(12, alignTop ? 10 : 12, 12, 10),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(
        color: error == null ? AppColors.line : AppColors.danger,
        width: error == null ? 1 : 1.4,
      ),
    ),
    disabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: AppColors.line),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: error == null
          ? const BorderSide(color: Color(0x596C57E5), width: 3)
          : const BorderSide(color: AppColors.danger, width: 1.4),
    ),
  );

  Widget _errorText(Key key, String message) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Text(
      message,
      key: key,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 11, color: AppColors.danger),
    ),
  );

  Widget _colorRow() {
    final color = _textColor;
    return SizedBox(
      height: 36,
      child: OutlinedButton(
        key: const ValueKey('desk-composer-color'),
        onPressed: _saving ? null : () => unawaited(_chooseColor()),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          foregroundColor: AppColors.text,
          side: const BorderSide(color: AppColors.line),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: color == null ? AppColors.primary : Color(color),
                border: Border.all(color: AppColors.line),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                color == null ? '文字颜色：跟随列表' : '文字颜色：${deskColorHex(color)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
            const Icon(Icons.expand_more_rounded, size: 16),
          ],
        ),
      ),
    );
  }

  Widget _palette() => Container(
    key: const ValueKey('desk-composer-palette'),
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: const Color(0xFFF8F8FB),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: AppColors.line),
    ),
    child: Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _followSwatch(),
        for (final swatch in deskComposerSwatches)
          _colorSwatch(swatch.label, swatch.color),
        OutlinedButton.icon(
          key: const ValueKey('desk-composer-color-custom'),
          onPressed: () => unawaited(_pickCustomColor()),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.text,
            side: const BorderSide(color: AppColors.line),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            minimumSize: const Size(0, 30),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(9),
            ),
          ),
          icon: const Icon(Icons.colorize_rounded, size: 13),
          label: const Text('自定义…', style: TextStyle(fontSize: 11)),
        ),
      ],
    ),
  );

  Widget _followSwatch() {
    final selected = _textColor == null;
    return Tooltip(
      message: '跟随列表',
      child: InkWell(
        key: const ValueKey('desk-composer-color-follow'),
        borderRadius: BorderRadius.circular(9),
        onTap: () => _selectColor(null),
        child: Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: selected ? AppColors.primary : AppColors.line,
              width: selected ? 1.6 : 1,
            ),
          ),
          child: Icon(
            Icons.format_color_text_rounded,
            size: 14,
            color: selected ? AppColors.primary : AppColors.muted,
          ),
        ),
      ),
    );
  }

  Widget _colorSwatch(String label, int color) {
    final selected = _textColor == color;
    return Tooltip(
      message: '$label ${deskColorHex(color)}',
      child: InkWell(
        key: ValueKey('desk-composer-color-${deskColorHex(color)}'),
        borderRadius: BorderRadius.circular(9),
        onTap: () => _selectColor(color),
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: Color(color),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: selected ? AppColors.primary : AppColors.line,
              width: selected ? 1.6 : 1,
            ),
          ),
          child: selected
              ? Icon(
                  Icons.check,
                  size: 16,
                  color: Color(color).computeLuminance() > .45
                      ? AppColors.primary
                      : Colors.white,
                )
              : null,
        ),
      ),
    );
  }

  Widget _footer() {
    final hint = Text(
      '离开窗口保留草稿 · Ctrl+Enter 保存',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 11, color: AppColors.muted),
    );
    return Row(
      children: [
        Expanded(child: hint),
        const SizedBox(width: 8),
        SizedBox(
          width: 76,
          height: 36,
          child: OutlinedButton(
            key: const ValueKey('desk-composer-cancel'),
            onPressed: _saving
                ? null
                : () => unawaited(_complete(DeskComposerResult.cancelled)),
            style: OutlinedButton.styleFrom(
              padding: EdgeInsets.zero,
              foregroundColor: AppColors.text,
              side: const BorderSide(color: AppColors.line),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text('取消', style: TextStyle(fontSize: 13)),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 76,
          height: 36,
          child: FilledButton(
            key: const ValueKey('desk-composer-save'),
            onPressed: _saving ? null : () => unawaited(_save()),
            style: FilledButton.styleFrom(
              padding: EdgeInsets.zero,
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              disabledBackgroundColor: const Color(0xFFBEB5F1),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Text(
              _saving ? '保存中…' : '保存',
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ),
      ],
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) =>
      Text(text, style: const TextStyle(fontSize: 12, color: AppColors.muted));
}

// 草稿来自本地 JSON，按模型规则清洗后再填入，避免损坏的字段让页面崩溃。
String _draftText(Object? value) => value is String ? value : '';

String? _draftFontFamily(Object? value) {
  if (!validDeskFontFamily(value) || value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

double? _draftFontSize(Object? value) =>
    validDeskFontSize(value) && value is num ? value.toDouble() : null;

int? _draftColor(Object? value) =>
    validDeskTextColor(value) && value is int ? value : null;
