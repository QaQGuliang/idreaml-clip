import 'package:flutter/material.dart';

import '../ui/app_theme.dart';
import '../ui/common.dart';
import 'desk_models.dart';
import 'desk_typography.dart';
import 'desktop_notes.dart';
import 'desk_management_list.dart';

export 'desk_settings_page.dart';

Future<void> _attempt(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (error) {
    if (context.mounted) showMessage(context, '$error');
  }
}

class DeskPage extends StatefulWidget {
  const DeskPage({
    super.key,
    required this.notes,
    required this.kind,
    this.selectedId,
    this.viewRequest = 0,
    this.onViewed,
  });
  final DesktopNotes notes;
  final DeskKind kind;
  final String? selectedId;
  final int viewRequest;
  final VoidCallback? onViewed;
  @override
  State<DeskPage> createState() => _DeskPageState();
}

class _DeskPageState extends State<DeskPage> {
  bool _viewing = false;
  @override
  void initState() {
    super.initState();
    _viewSelected();
  }

  @override
  void didUpdateWidget(covariant DeskPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedId != widget.selectedId ||
        oldWidget.viewRequest != widget.viewRequest) {
      _viewSelected();
    }
  }

  void _viewSelected() {
    final id = widget.selectedId;
    if (id == null || id.isEmpty || _viewing) return;
    _viewing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      widget.onViewed?.call();
      final values = widget.notes.versions(id).where((e) => !e.deleted);
      if (values.isEmpty) {
        _viewing = false;
        return;
      }
      final entry = values.first;
      await showDeskEntry(
        context,
        widget.kind,
        entry,
        settings: widget.notes.config(widget.kind),
      );
      _viewing = false;
    });
  }

  @override
  Widget build(BuildContext context) => DeskManagementList(
    notes: widget.notes,
    kind: widget.kind,
    onCreate: () => _edit(context),
    onEdit: (entry) => _edit(context, entry: entry),
    onDelete: (entry) => _delete(context, entry),
    onResolve: (id) => _resolve(context, id),
  );

  Future<void> _edit(BuildContext context, {DeskEntry? entry}) async {
    final notes = widget.notes;
    final kind = widget.kind;
    final draft = entry == null ? await notes.draft(kind) : <String, dynamic>{};
    if (!context.mounted) return;
    final title = TextEditingController(
      text: entry?.title ?? draft['title'] as String? ?? '',
    );
    final body = TextEditingController(
      text: entry?.body ?? draft['body'] as String? ?? '',
    );
    String? fontFamily = entry == null
        ? draft['fontFamily'] as String?
        : entry.fontFamily;
    double? fontSize = entry == null
        ? (draft['fontSize'] as num?)?.toDouble()
        : entry.fontSize;
    int? textColor = entry == null
        ? draft['textColor'] as int?
        : entry.textColor;
    final settings = notes.config(kind);
    var saving = false;
    await notes.editing(true);
    try {
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) {
            final typography = DeskEntryTypography(
              fontFamily: fontFamily,
              fontSize: fontSize,
              textColor: textColor,
              settings: settings,
            );
            return AlertDialog(
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
              title: Text('${entry == null ? '新建' : '编辑'}${kind.label}'),
              content: SizedBox(
                width: 362,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (kind == DeskKind.note)
                        TextField(
                          key: const ValueKey('desk-editor-title'),
                          controller: title,
                          onChanged: (_) => setDialogState(() {}),
                          maxLength: 200,
                          decoration: const InputDecoration(
                            labelText: '标题（可选）',
                            hintText: '这一刻，想记下什么？',
                          ),
                        ),
                      TextField(
                        key: const ValueKey('desk-editor-body'),
                        controller: body,
                        onChanged: (_) => setDialogState(() {}),
                        autofocus: true,
                        minLines: 5,
                        maxLines: 12,
                        maxLength: 20000,
                        decoration: InputDecoration(
                          labelText: kind == DeskKind.note ? '内容' : '事项内容',
                          hintText: kind == DeskKind.note
                              ? '写下来，让思绪轻一点…'
                              : '接下来，想完成什么？',
                        ),
                      ),
                      const SizedBox(height: 16),
                      DeskTextStyleFields(
                        fontFamily: fontFamily,
                        fontSize: fontSize,
                        textColor: textColor,
                        inheritedFontSize: settings.fontSize,
                        enabled: !saving,
                        onFontFamily: (value) =>
                            setDialogState(() => fontFamily = value),
                        onFontSize: (value) =>
                            setDialogState(() => fontSize = value),
                        onTextColor: (value) =>
                            setDialogState(() => textColor = value),
                      ),
                      const SizedBox(height: 14),
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '文字效果预览',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.muted,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      KeyedSubtree(
                        key: const ValueKey('desk-editor-typography-preview'),
                        child: typography.surface(
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (kind == DeskKind.note &&
                                  title.text.isNotEmpty) ...[
                                Text(
                                  title.text,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: typography.titleStyle,
                                ),
                                const SizedBox(height: 6),
                              ],
                              Text(
                                body.text.isEmpty ? '清晰记录每一个想法' : body.text,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: kind == DeskKind.todo
                                    ? typography.titleStyle.copyWith(
                                        fontSize: typography.size + 1,
                                      )
                                    : typography.bodyStyle,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: saving ? null : () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                FilledButton(
                  key: const ValueKey('desk-editor-save'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: saving
                      ? null
                      : () async {
                          setDialogState(() => saving = true);
                          try {
                            await notes.save(
                              kind,
                              id: entry?.id,
                              title: title.text.trim(),
                              body: body.text,
                              done: entry?.done ?? false,
                              fontFamily: fontFamily,
                              fontSize: fontSize,
                              textColor: textColor,
                              expected: entry == null ? null : {entry.revision},
                            );
                            if (context.mounted) Navigator.pop(context);
                          } catch (error) {
                            if (context.mounted) {
                              setDialogState(() => saving = false);
                              showMessage(context, '$error');
                            }
                          }
                        },
                  child: Text(saving ? '保存中…' : '保存'),
                ),
              ],
            );
          },
        ),
      );
    } finally {
      await notes.editing(false);
    }
    if (entry == null) await notes.storeDraft(kind, '', '');
    // Dialog route animation can still reference the controllers for a frame.
    Future<void>.delayed(const Duration(milliseconds: 250), () {
      title.dispose();
      body.dispose();
    });
  }

  Future<void> _delete(BuildContext context, DeskEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
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
        title: Text('永久删除${widget.kind.label}？'),
        content: const Text(
          '删除后无法在应用内恢复。已开启同步时，删除会传播到其他设备。Git 仓库的既有历史版本不会自动清除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('永久删除'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await _attempt(context, () => widget.notes.remove(entry));
    }
  }

  Future<void> _resolve(BuildContext context, String id) async {
    final versions = widget.notes.versions(id);
    final selected = await showDialog<DeskEntry>(
      context: context,
      builder: (context) => AlertDialog(
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
        title: const Text('选择要保留的版本'),
        content: SizedBox(
          width: 540,
          height: 400,
          child: ListView(
            children: [
              const Text('下方版本均已保留。选择后，以所选内容合并这些版本；选择删除版本会删除此条内容。'),
              for (final entry in versions) _versionOption(context, entry),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('稍后处理'),
          ),
        ],
      ),
    );
    if (selected != null && context.mounted) {
      await _attempt(
        context,
        () => widget.notes.save(
          widget.kind,
          id: id,
          title: selected.title,
          body: selected.body,
          done: selected.done,
          deleted: selected.deleted,
          fontFamily: selected.fontFamily,
          fontSize: selected.fontSize,
          textColor: selected.textColor,
          expected: versions.map((e) => e.revision).toSet(),
        ),
      );
    }
  }

  Widget _versionOption(BuildContext context, DeskEntry entry) {
    final typography = DeskEntryTypography.fromEntry(
      entry,
      widget.notes.config(widget.kind),
    );
    final familyLabel = entry.fontFamily == null
        ? '跟随列表'
        : deskFontFamilies[entry.fontFamily] ?? entry.fontFamily!;
    final sizeLabel = entry.fontSize == null
        ? '跟随列表'
        : '${entry.fontSize!.round()}';
    final colorLabel = entry.textColor == null
        ? '跟随列表'
        : '#${(entry.textColor! & 0xffffff).toRadixString(16).padLeft(6, '0').toUpperCase()}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              entry.deleted ? '删除版本' : '内容版本',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            Text(
              '修改时间：${DateTime.fromMillisecondsSinceEpoch(entry.updated).toLocal()}',
            ),
            if (!entry.deleted) ...[
              const SizedBox(height: 8),
              typography.surface(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (entry.title.isNotEmpty)
                      Text(entry.title, style: typography.titleStyle),
                    Text(
                      '${entry.done ? '已完成\n' : ''}${entry.body}',
                      style: typography.bodyStyle,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '字体：$familyLabel · 字号：$sizeLabel · 颜色：$colorLabel',
                style: const TextStyle(fontSize: 11, color: AppColors.muted),
              ),
            ],
            TextButton(
              onPressed: () => Navigator.pop(context, entry),
              child: Text(entry.deleted ? '采用删除' : '保留此版本'),
            ),
          ],
        ),
      ),
    );
  }
}
