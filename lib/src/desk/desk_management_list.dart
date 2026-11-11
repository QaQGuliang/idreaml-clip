import 'package:flutter/material.dart';

import '../ui/app_theme.dart';
import '../ui/common.dart';
import 'desk_models.dart';
import 'desktop_notes.dart';

/// A single paper-like list, matching the approved desktop module prototype.
class DeskManagementList extends StatefulWidget {
  const DeskManagementList({
    super.key,
    required this.notes,
    required this.kind,
    required this.onCreate,
    required this.onEdit,
    required this.onDelete,
    required this.onResolve,
  });
  final DesktopNotes notes;
  final DeskKind kind;
  final VoidCallback onCreate;
  final ValueChanged<DeskEntry> onEdit, onDelete;
  final ValueChanged<String> onResolve;
  @override
  State<DeskManagementList> createState() => _DeskManagementListState();
}

class _DeskManagementListState extends State<DeskManagementList> {
  String _search = '';
  bool _completed = false;
  final _query = TextEditingController();
  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _toggle(DeskEntry row) async {
    try {
      await widget.notes.toggle(row);
    } catch (error) {
      if (mounted) showMessage(context, '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final kind = widget.kind;
    if (!widget.notes.enabled(kind)) {
      return _empty(
        Icons.desktop_access_disabled_outlined,
        '${kind.label}尚未开启，请到设置中开启',
        '开启后，就可以开始记录。',
      );
    }
    final all = widget.notes.items(kind);
    final rows = all
        .where(
          (e) =>
              (kind == DeskKind.note || e.done == _completed) &&
              '${e.title}\n${e.body}'.toLowerCase().contains(
                _search.toLowerCase(),
              ),
        )
        .toList();
    final conflicts = widget.notes.conflicts(kind);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 520;
        final search = TextField(
          controller: _query,
          onChanged: (v) => setState(() => _search = v),
          decoration: InputDecoration(
            hintText: '搜索${kind.label}内容',
            prefixIcon: const Icon(Icons.search_rounded, size: 18),
            suffixIcon: _search.isEmpty
                ? null
                : IconButton(
                    tooltip: '清空搜索',
                    onPressed: () {
                      _query.clear();
                      setState(() => _search = '');
                    },
                    icon: const Icon(Icons.close, size: 16),
                  ),
          ),
        );
        final add = FilledButton.icon(
          onPressed: widget.onCreate,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            minimumSize: const Size(0, 40),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          icon: const Icon(Icons.add, size: 17),
          label: Text('新建${kind.label}'),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (compact) ...[
              Align(alignment: Alignment.centerRight, child: add),
              const SizedBox(height: 10),
              search,
            ] else
              Row(
                children: [
                  Expanded(child: search),
                  const SizedBox(width: 12),
                  add,
                ],
              ),
            const SizedBox(height: 14),
            Row(
              children: [
                if (kind == DeskKind.todo) ...[
                  _tab('待完成', false),
                  const SizedBox(width: 4),
                  _tab('已完成', true),
                ] else ...[
                  const Icon(
                    Icons.sticky_note_2_outlined,
                    size: 16,
                    color: AppColors.muted,
                  ),
                  const SizedBox(width: 7),
                  const Text(
                    '全部便签',
                    style: TextStyle(fontSize: 12, color: AppColors.muted),
                  ),
                ],
                const Spacer(),
                Text(
                  _search.isEmpty
                      ? '${rows.length} ${kind == DeskKind.note ? '条便签' : '项待办'}'
                      : '找到 ${rows.length} 项',
                  style: const TextStyle(fontSize: 11, color: AppColors.muted),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: AppCard(
                padding: EdgeInsets.zero,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: rows.isEmpty && conflicts.isEmpty
                      ? _empty(
                          _search.isNotEmpty
                              ? Icons.search_off_rounded
                              : kind == DeskKind.note
                              ? Icons.edit_note_rounded
                              : Icons.task_alt_rounded,
                          _search.isNotEmpty
                              ? '没有匹配的内容'
                              : _completed
                              ? '暂无已完成待办'
                              : '还没有${kind.label}',
                          _search.isNotEmpty
                              ? '试试其他关键词。'
                              : _completed
                              ? '完成的事项会保留在这里，随时可以恢复。'
                              : '点击右上角，记录第一${kind == DeskKind.note ? '条想法' : '件事项'}。',
                        )
                      : ListView(
                          padding: const EdgeInsets.all(18),
                          children: [
                            if (conflicts.isNotEmpty) ...[
                              Container(
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: AppColors.warning.withValues(
                                    alpha: .08,
                                  ),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      '有多设备修改需要处理',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.warning,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    const Text(
                                      '双方版本均已保留，请选择要保留的内容。',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: AppColors.muted,
                                      ),
                                    ),
                                    for (final id in conflicts)
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              widget.notes
                                                  .versions(id)
                                                  .firstWhere(
                                                    (e) => !e.deleted,
                                                    orElse: () => widget.notes
                                                        .versions(id)
                                                        .first,
                                                  )
                                                  .body,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          TextButton(
                                            onPressed: () =>
                                                widget.onResolve(id),
                                            child: const Text('处理冲突'),
                                          ),
                                        ],
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 16),
                            ],
                            for (var i = 0; i < rows.length; i++) ...[
                              if (i > 0)
                                const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 16),
                                  child: Divider(
                                    height: 1,
                                    color: AppColors.line,
                                  ),
                                ),
                              _entry(rows[i], compact),
                            ],
                          ],
                        ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _tab(String label, bool value) => TextButton(
    onPressed: () => setState(() => _completed = value),
    style: TextButton.styleFrom(
      backgroundColor: _completed == value
          ? AppColors.primarySoft
          : Colors.transparent,
      foregroundColor: _completed == value
          ? AppColors.primary
          : AppColors.muted,
      minimumSize: const Size(72, 32),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
    ),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 12,
        fontWeight: _completed == value ? FontWeight.w700 : FontWeight.w400,
      ),
    ),
  );

  Widget _entry(DeskEntry row, bool compact) {
    final conflict = widget.notes.versions(row.id).length > 1;
    final todo = widget.kind == DeskKind.todo;
    final typography = DeskEntryTypography.fromEntry(
      row,
      widget.notes.config(widget.kind),
    );
    final date = DateTime.fromMillisecondsSinceEpoch(row.created).toLocal();
    final time =
        '${date.month}月${date.day}日 · ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    final actions = Wrap(
      spacing: 2,
      children: [
        _action(
          '编辑',
          Icons.edit_outlined,
          AppColors.primary,
          conflict ? null : () => widget.onEdit(row),
        ),
        _action(
          '删除',
          Icons.delete_outline,
          AppColors.danger,
          conflict ? null : () => widget.onDelete(row),
        ),
      ],
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (todo)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: SizedBox(
              width: 24,
              height: 26,
              child: Checkbox(
                value: row.done,
                onChanged: conflict ? null : (_) => _toggle(row),
                activeColor: AppColors.primary,
                side: const BorderSide(color: AppColors.muted, width: 1.3),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
            ),
          ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: typography.surface(
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            todo || row.title.isEmpty ? row.body : row.title,
                            key: ValueKey('desk-entry-content-${row.id}'),
                            maxLines: todo || row.title.isEmpty ? 3 : 2,
                            overflow: TextOverflow.ellipsis,
                            style: typography.titleStyle.copyWith(
                              fontSize: todo
                                  ? typography.size + 1
                                  : row.title.isEmpty
                                  ? typography.size
                                  : typography.size + 2,
                              fontWeight: todo || row.title.isNotEmpty
                                  ? FontWeight.w700
                                  : FontWeight.w400,
                              decoration: row.done
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                          ),
                          if (!todo && row.title.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(
                              row.body,
                              key: ValueKey('desk-entry-body-${row.id}'),
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                              style: typography.bodyStyle,
                            ),
                          ],
                          const SizedBox(height: 8),
                          Text(
                            todo
                                ? (row.done ? '已完成 · $time' : '待完成 · $time')
                                : time,
                            key: ValueKey('desk-entry-meta-${row.id}'),
                            style: typography.metadataStyle,
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (!compact) ...[const SizedBox(width: 12), actions],
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (conflict)
                    const Text(
                      '同步冲突',
                      style: TextStyle(fontSize: 11, color: AppColors.warning),
                    ),
                  InkWell(
                    onTap: () => showDeskEntry(
                      context,
                      widget.kind,
                      row,
                      settings: widget.notes.config(widget.kind),
                    ),
                    borderRadius: BorderRadius.circular(6),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 3),
                      child: Text(
                        '查看全文',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              if (compact)
                Padding(padding: const EdgeInsets.only(top: 8), child: actions),
            ],
          ),
        ),
      ],
    );
  }

  Widget _action(
    String label,
    IconData icon,
    Color color,
    VoidCallback? action,
  ) => TextButton.icon(
    onPressed: action,
    style: TextButton.styleFrom(
      foregroundColor: color,
      minimumSize: const Size(0, 32),
      padding: const EdgeInsets.symmetric(horizontal: 7),
      textStyle: const TextStyle(fontSize: 11),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    icon: Icon(icon, size: 14),
    label: Text(label),
  );

  Widget _empty(IconData icon, String title, String subtitle) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.primarySoft,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(icon, size: 30, color: AppColors.primary),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.text,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12,
              height: 1.6,
              color: AppColors.muted,
            ),
          ),
        ],
      ),
    ),
  );
}

/// Resolves entry overrides without altering the selected colour. Very light
/// text is shown on a dark reading surface inside the white management UI.
class DeskEntryTypography {
  DeskEntryTypography({
    String? fontFamily,
    double? fontSize,
    int? textColor,
    DeskSettings settings = const DeskSettings(),
  }) : family = (fontFamily ?? settings.fontFamily).isEmpty
           ? null
           : fontFamily ?? settings.fontFamily,
       size = fontSize ?? settings.fontSize,
       customColor = textColor ?? settings.textColor;

  factory DeskEntryTypography.fromEntry(
    DeskEntry entry,
    DeskSettings settings,
  ) => DeskEntryTypography(
    fontFamily: entry.fontFamily,
    fontSize: entry.fontSize,
    textColor: entry.textColor,
    settings: settings,
  );

  final String? family;
  final double size;
  final int? customColor;
  bool get needsDarkSurface =>
      customColor != null && Color(customColor!).computeLuminance() > .40;

  TextStyle get titleStyle => TextStyle(
    fontFamily: family,
    fontSize: size + 2,
    height: 1.6,
    fontWeight: FontWeight.w700,
    color: customColor == null ? AppColors.text : Color(customColor!),
  );
  TextStyle get bodyStyle => titleStyle.copyWith(
    fontSize: size,
    height: 1.7,
    fontWeight: FontWeight.w400,
  );
  TextStyle get metadataStyle => bodyStyle.copyWith(
    fontSize: (size - 1).clamp(10.0, 31.0).toDouble(),
    color: customColor == null ? AppColors.muted : Color(customColor!),
  );

  Widget surface(Widget child) => needsDarkSurface
      ? Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF302B3C),
            borderRadius: BorderRadius.circular(12),
          ),
          child: child,
        )
      : child;
}

Future<void> showDeskEntry(
  BuildContext context,
  DeskKind kind,
  DeskEntry entry, {
  DeskSettings settings = const DeskSettings(),
}) {
  final typography = DeskEntryTypography.fromEntry(entry, settings);
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: AppColors.line),
      ),
      title: Text(
        '${kind.label}全文',
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
      content: SizedBox(
        width: 510,
        child: SingleChildScrollView(
          child: typography.surface(
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (entry.title.isNotEmpty) ...[
                  Text(
                    entry.title,
                    key: const ValueKey('desk-reading-title'),
                    style: typography.titleStyle,
                  ),
                  const SizedBox(height: 12),
                ],
                Text(
                  entry.body,
                  key: const ValueKey('desk-reading-body'),
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
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}
