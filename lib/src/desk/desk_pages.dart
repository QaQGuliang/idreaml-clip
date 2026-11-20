import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/app_theme.dart';
import '../ui/common.dart';
import 'desk_models.dart';
import 'desk_typography.dart';
import 'desktop_notes.dart';
import 'desk_management_list.dart';

export 'desk_settings_page.dart';

/// 待办时间与提醒的编辑值；全部为 null 表示不安排时间。
///
/// 与 [DeskEntry] 的四个时间字段一一对应，管理页与快速新增共用同一套
/// 编辑、校验与预览逻辑。
@immutable
class DeskSchedule {
  const DeskSchedule({
    this.startAt,
    this.endAt,
    this.remindAt,
    this.remindBeforeMinutes,
  });
  static const empty = DeskSchedule();
  final int? startAt;
  final int? endAt;
  final int? remindAt;
  final int? remindBeforeMinutes;

  bool get isEmpty =>
      startAt == null &&
      endAt == null &&
      remindAt == null &&
      remindBeforeMinutes == null;

  factory DeskSchedule.fromEntry(DeskEntry entry) => DeskSchedule(
    startAt: entry.startAt,
    endAt: entry.endAt,
    remindAt: entry.remindAt,
    remindBeforeMinutes: entry.remindBeforeMinutes,
  );

  /// 草稿来自本地 JSON，按模型规则清洗，损坏的字段视为未设置。
  factory DeskSchedule.fromDraft(Map<String, dynamic> draft) => DeskSchedule(
    startAt: _scheduleStamp(draft['startAt']),
    endAt: _scheduleStamp(draft['endAt']),
    remindAt: _scheduleStamp(draft['remindAt']),
    remindBeforeMinutes: _scheduleMinutes(draft['remindBeforeMinutes']),
  );
}

int? _scheduleStamp(Object? value) =>
    validDeskTimestamp(value) && value is int ? value : null;

int? _scheduleMinutes(Object? value) =>
    value is int && value >= 1 && value <= deskRemindBeforeMinutesMax
    ? value
    : null;

/// 时间与提醒的字段级错误；与输入控件一一对应，便于就近提示与聚焦。
class DeskScheduleErrors {
  const DeskScheduleErrors({this.end, this.remind});
  final String? end;
  final String? remind;
  bool get isEmpty => end == null && remind == null;
  String? get first => end ?? remind;
}

/// 管理页与快速新增统一的字段级校验口径，规则与 [validateDeskSchedule] 一致。
DeskScheduleErrors validateDeskScheduleFields(DeskSchedule value) {
  String? end;
  String? remind;
  if (value.startAt != null &&
      value.endAt != null &&
      value.endAt! < value.startAt!) {
    end = '结束时间不能早于开始时间';
  }
  if (value.remindAt != null && value.remindBeforeMinutes != null) {
    remind = '提醒只能保留一种方式，请清除后重新设置';
  } else if (value.remindBeforeMinutes != null) {
    final minutes = value.remindBeforeMinutes!;
    if (value.startAt == null) {
      remind = '提前提醒需要先设置开始时间';
    } else if (minutes < 1 || minutes > deskRemindBeforeMinutesMax) {
      remind = '提前提醒须为 1–10080 分钟';
    }
  }
  return DeskScheduleErrors(end: end, remind: remind);
}

/// 实际触发提醒的时间（epoch 毫秒），与提醒调度口径一致。
int? deskScheduleReminderAt(DeskSchedule value) {
  final before = value.remindBeforeMinutes;
  if (before != null) {
    final start = value.startAt;
    return start == null
        ? null
        : start - before * Duration.millisecondsPerMinute;
  }
  return value.remindAt;
}

String _two(int value) => value.toString().padLeft(2, '0');

String deskDateText(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-${_two(value.month)}-${_two(value.day)}';

String deskTimeText(DateTime value) =>
    '${_two(value.hour)}:${_two(value.minute)}';

String deskScheduleStamp(int epochMs) =>
    '${deskDateText(DateTime.fromMillisecondsSinceEpoch(epochMs))} ${deskTimeText(DateTime.fromMillisecondsSinceEpoch(epochMs))}';

String deskReminderPreview(DeskSchedule value) {
  final at = deskScheduleReminderAt(value);
  if (at == null) return '未设置提醒';
  final stamp = deskScheduleStamp(at);
  return at <= DateTime.now().millisecondsSinceEpoch
      ? '提醒时间已过（$stamp）'
      : '将在 $stamp 提醒';
}

/// 一行摘要，用于编辑入口与同步冲突版本卡片。
String deskScheduleSummary(DeskSchedule value) {
  final parts = <String>[];
  if (value.startAt != null) {
    parts.add('开始 ${deskScheduleStamp(value.startAt!)}');
  }
  if (value.endAt != null) {
    parts.add('结束 ${deskScheduleStamp(value.endAt!)}');
  }
  if (value.remindBeforeMinutes != null) {
    parts.add('提前 ${value.remindBeforeMinutes} 分钟提醒');
  } else if (value.remindAt != null) {
    parts.add('${deskScheduleStamp(value.remindAt!)} 提醒');
  }
  return parts.isEmpty ? '未设置' : parts.join(' · ');
}

/// 解析 yyyy-MM-dd；不存在的日期（如 2 月 30 日）同样视为无效。
DateTime? parseDeskDate(String text) {
  final match = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$')
      .firstMatch(text.trim());
  if (match == null) return null;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final value = DateTime(year, month, day);
  return value.year == year && value.month == month && value.day == day
      ? value
      : null;
}

/// 应用内轻量日期时间选择：今天/明天快捷项 + yyyy-MM-dd 文本 + 时/分输入。
///
/// 应用未配置 Material 中文本地化，因此不使用带英文的 Material 日期选择器；
/// 键盘可用，Esc 关闭。
Future<DateTime?> showDeskDateTimeDialog(
  BuildContext context, {
  required String title,
  required DateTime initial,
}) => showDialog<DateTime>(
  context: context,
  builder: (_) => _DeskDateTimeDialog(title: title, initial: initial),
);

class _DeskDateTimeDialog extends StatefulWidget {
  const _DeskDateTimeDialog({required this.title, required this.initial});
  final String title;
  final DateTime initial;
  @override
  State<_DeskDateTimeDialog> createState() => _DeskDateTimeDialogState();
}

class _DeskDateTimeDialogState extends State<_DeskDateTimeDialog> {
  late final _date = TextEditingController(text: deskDateText(widget.initial));
  late final _hour = TextEditingController(text: _two(widget.initial.hour));
  late final _minute = TextEditingController(text: _two(widget.initial.minute));
  String? _dateError;
  String? _timeError;

  @override
  void dispose() {
    _date.dispose();
    _hour.dispose();
    _minute.dispose();
    super.dispose();
  }

  void _setDate(DateTime value) => setState(() {
    _date.text = deskDateText(value);
    _dateError = null;
  });

  int? _part(TextEditingController controller, int max) {
    final value = int.tryParse(controller.text.trim());
    return value != null && value >= 0 && value <= max ? value : null;
  }

  void _confirm() {
    final date = parseDeskDate(_date.text);
    final hour = _part(_hour, 23);
    final minute = _part(_minute, 59);
    if (date == null || hour == null || minute == null) {
      setState(() {
        _dateError = date == null ? '日期格式应为 yyyy-MM-dd，且须为有效日期' : null;
        _timeError = hour == null || minute == null
            ? '小时须为 0–23，分钟须为 0–59'
            : null;
      });
      return;
    }
    Navigator.pop(
      context,
      DateTime(date.year, date.month, date.day, hour, minute),
    );
  }

  InputDecoration _decoration(String? error) => InputDecoration(
    isDense: true,
    filled: true,
    fillColor: const Color(0xFFF8F8FB),
    counterText: '',
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    enabledBorder: _border(error),
    focusedBorder: _border(error, focused: true),
  );

  OutlineInputBorder _border(String? error, {bool focused = false}) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(
          color: error != null
              ? AppColors.danger
              : focused
              ? AppColors.primary
              : AppColors.line,
          width: error != null ? 1.4 : 1,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.maybePop(context),
      },
      child: AlertDialog(
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
        title: Text(widget.title),
        content: SizedBox(
          width: 318,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    ActionChip(
                      key: const ValueKey('desk-time-today'),
                      label: const Text('今天', style: TextStyle(fontSize: 12)),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _setDate(today),
                    ),
                    const SizedBox(width: 8),
                    ActionChip(
                      key: const ValueKey('desk-time-tomorrow'),
                      label: const Text('明天', style: TextStyle(fontSize: 12)),
                      visualDensity: VisualDensity.compact,
                      onPressed: () =>
                          _setDate(today.add(const Duration(days: 1))),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('desk-time-date'),
                  controller: _date,
                  maxLength: 10,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9-]')),
                  ],
                  decoration: _decoration(_dateError)
                      .copyWith(labelText: '日期', hintText: 'yyyy-MM-dd'),
                  onChanged: (_) {
                    if (_dateError != null) setState(() => _dateError = null);
                  },
                ),
                if (_dateError != null)
                  _scheduleErrorText(
                    const ValueKey('desk-time-date-error'),
                    _dateError!,
                  ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const SizedBox(
                      width: 44,
                      child: Text(
                        '时间',
                        style: TextStyle(fontSize: 12, color: AppColors.muted),
                      ),
                    ),
                    SizedBox(
                      width: 62,
                      child: TextField(
                        key: const ValueKey('desk-time-hour'),
                        controller: _hour,
                        maxLength: 2,
                        textAlign: TextAlign.center,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: _decoration(_timeError),
                        onChanged: (_) {
                          if (_timeError != null) {
                            setState(() => _timeError = null);
                          }
                        },
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6),
                      child: Text(':', style: TextStyle(fontSize: 14)),
                    ),
                    SizedBox(
                      width: 62,
                      child: TextField(
                        key: const ValueKey('desk-time-minute'),
                        controller: _minute,
                        maxLength: 2,
                        textAlign: TextAlign.center,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: _decoration(_timeError),
                        onChanged: (_) {
                          if (_timeError != null) {
                            setState(() => _timeError = null);
                          }
                        },
                        onSubmitted: (_) => _confirm(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        '24 小时制',
                        style: TextStyle(fontSize: 11, color: AppColors.muted),
                      ),
                    ),
                  ],
                ),
                if (_timeError != null)
                  _scheduleErrorText(
                    const ValueKey('desk-time-time-error'),
                    _timeError!,
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.maybePop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('desk-time-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: _confirm,
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }
}

Widget _scheduleErrorText(Key key, String message) => Padding(
  padding: const EdgeInsets.only(top: 4),
  child: Text(
    message,
    key: key,
    maxLines: 2,
    overflow: TextOverflow.ellipsis,
    style: const TextStyle(fontSize: 11, color: AppColors.danger),
  ),
);

InputDecoration _editorDecoration({
  required String labelText,
  required String hintText,
  String? error,
}) => InputDecoration(
  labelText: labelText,
  hintText: hintText,
  isDense: true,
  filled: true,
  fillColor: const Color(0xFFF8F8FB),
  enabledBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide(
      color: error == null ? AppColors.line : AppColors.danger,
      width: error == null ? 1 : 1.4,
    ),
  ),
  focusedBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide(
      color: error == null ? AppColors.primary : AppColors.danger,
      width: 1.4,
    ),
  ),
);

/// 自定义提前分钟输入；返回 1–10080 的分钟数。
Future<int?> showDeskRemindMinutesDialog(
  BuildContext context, {
  int? initial,
}) => showDialog<int>(
  context: context,
  builder: (_) => _DeskRemindMinutesDialog(initial: initial),
);

class _DeskRemindMinutesDialog extends StatefulWidget {
  const _DeskRemindMinutesDialog({this.initial});
  final int? initial;
  @override
  State<_DeskRemindMinutesDialog> createState() =>
      _DeskRemindMinutesDialogState();
}

class _DeskRemindMinutesDialogState extends State<_DeskRemindMinutesDialog> {
  late final _controller = TextEditingController(
    text: widget.initial?.toString() ?? '',
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int? get _minutes {
    final value = int.tryParse(_controller.text.trim());
    return value != null && value >= 1 && value <= deskRemindBeforeMinutesMax
        ? value
        : null;
  }

  void _confirm() {
    final value = _minutes;
    if (value == null) {
      setState(() => _error = '提前分钟须为 1–10080');
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): () =>
          Navigator.maybePop(context),
    },
    child: AlertDialog(
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
      title: const Text('自定义提前提醒'),
      content: SizedBox(
        width: 260,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('desk-remind-minutes'),
              controller: _controller,
              autofocus: true,
              maxLength: 5,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: '开始前分钟数',
                hintText: '例如 45',
                counterText: '',
                isDense: true,
                filled: true,
                fillColor: const Color(0xFFF8F8FB),
                enabledBorder: _border,
                focusedBorder: _border,
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: (_) => _confirm(),
            ),
            if (_error != null)
              _scheduleErrorText(
                const ValueKey('desk-remind-minutes-error'),
                _error!,
              ),
            const SizedBox(height: 6),
            const Text(
              '范围 1–10080 分钟（最多 7 天）',
              style: TextStyle(fontSize: 11, color: AppColors.muted),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.maybePop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('desk-remind-minutes-confirm'),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onPressed: _confirm,
          child: const Text('确定'),
        ),
      ],
    ),
  );

  OutlineInputBorder get _border => OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide(
      color: _error != null ? AppColors.danger : AppColors.line,
      width: _error != null ? 1.4 : 1,
    ),
  );
}

enum _DeskRemindMode {
  none,
  before5,
  before15,
  before30,
  before60,
  custom,
  absolute,
}

/// 待办的时间与提醒字段，管理页内嵌与快速新增对话框共用。
///
/// 有开始时间时提供「开始前 5/15/30/60 分钟 + 自定义分钟」与「指定日期时间」；
/// 无开始时间时只提供绝对提醒；两种提醒互斥并由 [validateDeskScheduleFields]
/// 校验。
class DeskScheduleFields extends StatelessWidget {
  const DeskScheduleFields({
    super.key,
    required this.value,
    required this.onChanged,
    this.errors = const DeskScheduleErrors(),
    this.enabled = true,
    this.startFocus,
    this.endFocus,
    this.remindFocus,
  });
  final DeskSchedule value;
  final ValueChanged<DeskSchedule> onChanged;
  final DeskScheduleErrors errors;
  final bool enabled;
  final FocusNode? startFocus;
  final FocusNode? endFocus;
  final FocusNode? remindFocus;

  DeskSchedule _with({
    int? startAt,
    int? endAt,
    int? remindAt,
    int? remindBeforeMinutes,
  }) => DeskSchedule(
    startAt: startAt,
    endAt: endAt,
    remindAt: remindAt,
    remindBeforeMinutes: remindBeforeMinutes,
  );

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          const Expanded(
            child: Text(
              '时间与提醒（可选）',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          if (!value.isEmpty)
            TextButton(
              key: const ValueKey('desk-schedule-clear'),
              onPressed: enabled ? () => onChanged(DeskSchedule.empty) : null,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('清除全部', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
      const SizedBox(height: 8),
      _timeRow(
        context,
        label: '开始时间',
        keyName: 'desk-schedule-start',
        current: value.startAt,
        focusNode: startFocus,
        initial: DateTime.now(),
        onPicked: (stamp) => onChanged(
          _with(
            startAt: stamp,
            endAt: value.endAt,
            remindAt: value.remindAt,
            remindBeforeMinutes: value.remindBeforeMinutes,
          ),
        ),
        onClear: () => onChanged(
          _with(
            endAt: value.endAt,
            remindAt: value.remindAt,
            remindBeforeMinutes: value.remindBeforeMinutes,
          ),
        ),
      ),
      const SizedBox(height: 8),
      _timeRow(
        context,
        label: '结束时间',
        keyName: 'desk-schedule-end',
        current: value.endAt,
        focusNode: endFocus,
        error: errors.end,
        initial: value.startAt == null
            ? DateTime.now()
            : DateTime.fromMillisecondsSinceEpoch(value.startAt!),
        onPicked: (stamp) => onChanged(
          _with(
            startAt: value.startAt,
            endAt: stamp,
            remindAt: value.remindAt,
            remindBeforeMinutes: value.remindBeforeMinutes,
          ),
        ),
        onClear: () => onChanged(
          _with(
            startAt: value.startAt,
            remindAt: value.remindAt,
            remindBeforeMinutes: value.remindBeforeMinutes,
          ),
        ),
      ),
      const SizedBox(height: 10),
      _reminderControl(context),
    ],
  );

  Widget _timeRow(
    BuildContext context, {
    required String label,
    required String keyName,
    required int? current,
    required FocusNode? focusNode,
    required DateTime initial,
    required ValueChanged<int> onPicked,
    required VoidCallback onClear,
    String? error,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: AppColors.muted),
            ),
          ),
          Expanded(
            child: OutlinedButton(
              key: ValueKey(keyName),
              focusNode: focusNode,
              onPressed: enabled
                  ? () async {
                      final picked = await showDeskDateTimeDialog(
                        context,
                        title: '选择$label',
                        initial: current == null
                            ? initial
                            : DateTime.fromMillisecondsSinceEpoch(current),
                      );
                      if (picked != null) {
                        onPicked(picked.millisecondsSinceEpoch);
                      }
                    }
                  : null,
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                foregroundColor: AppColors.text,
                minimumSize: const Size(0, 38),
                side: BorderSide(
                  color: error == null ? AppColors.line : AppColors.danger,
                  width: error == null ? 1 : 1.4,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.event_outlined,
                    size: 14,
                    color: error == null ? AppColors.muted : AppColors.danger,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      current == null ? '未设置' : deskScheduleStamp(current),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: current == null
                            ? AppColors.muted
                            : AppColors.text,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (current != null)
            Tooltip(
              message: '清除$label',
              child: SizedBox(
                width: 32,
                height: 32,
                child: Material(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(9),
                  child: InkWell(
                    key: ValueKey('$keyName-clear'),
                    borderRadius: BorderRadius.circular(9),
                    onTap: enabled ? onClear : null,
                    child: const Icon(
                      Icons.close_rounded,
                      size: 15,
                      color: AppColors.muted,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      if (error != null) _scheduleErrorText(ValueKey('$keyName-error'), error),
    ],
  );

  _DeskRemindMode get _mode {
    final before = value.remindBeforeMinutes;
    if (before != null) {
      return switch (before) {
        5 => _DeskRemindMode.before5,
        15 => _DeskRemindMode.before15,
        30 => _DeskRemindMode.before30,
        60 => _DeskRemindMode.before60,
        _ => _DeskRemindMode.custom,
      };
    }
    return value.remindAt != null
        ? _DeskRemindMode.absolute
        : _DeskRemindMode.none;
  }

  Widget _reminderControl(BuildContext context) {
    final start = value.startAt;
    final mode = _mode;
    final hasStart = start != null;
    final preset = <_DeskRemindMode, int>{
      _DeskRemindMode.before5: 5,
      _DeskRemindMode.before15: 15,
      _DeskRemindMode.before30: 30,
      _DeskRemindMode.before60: 60,
    };
    final items = <DropdownMenuItem<_DeskRemindMode>>[
      const DropdownMenuItem(
        value: _DeskRemindMode.none,
        child: Text('不提醒', style: TextStyle(fontSize: 12)),
      ),
      for (final item in preset.entries)
        DropdownMenuItem(
          value: item.key,
          enabled: enabled && hasStart,
          child: Text(
            hasStart ? '开始前 ${item.value} 分钟' : '开始前 ${item.value} 分钟（需先设开始时间）',
            style: const TextStyle(fontSize: 12),
          ),
        ),
      DropdownMenuItem(
        value: _DeskRemindMode.custom,
        enabled: enabled && hasStart,
        child: Text(
          mode == _DeskRemindMode.custom && value.remindBeforeMinutes != null
              ? '开始前 ${value.remindBeforeMinutes} 分钟（自定义）'
              : '自定义提前分钟…',
          style: const TextStyle(fontSize: 12),
        ),
      ),
      const DropdownMenuItem(
        value: _DeskRemindMode.absolute,
        child: Text('指定日期时间…', style: TextStyle(fontSize: 12)),
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KeyedSubtree(
          key: ValueKey(
            'desk-schedule-remind-value-${mode.name}-${value.remindBeforeMinutes}-${value.remindAt}',
          ),
          child: DropdownButtonFormField<_DeskRemindMode>(
            key: const ValueKey('desk-schedule-remind'),
            initialValue: mode,
            focusNode: remindFocus,
            isExpanded: true,
            style: const TextStyle(fontSize: 12, color: AppColors.text),
            decoration: InputDecoration(
              labelText: '提醒',
              isDense: true,
              filled: true,
              fillColor: const Color(0xFFF8F8FB),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              enabledBorder: _fieldBorder(),
              focusedBorder: _fieldBorder(focused: true),
            ),
            items: items,
            onChanged: enabled
                ? (next) {
                    if (next == null) return;
                    _chooseMode(context, next);
                  }
                : null,
          ),
        ),
        if (value.remindAt != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              SizedBox(
                width: 64,
                child: Text(
                  mode == _DeskRemindMode.absolute ? '' : '指定时间',
                  style: const TextStyle(fontSize: 12, color: AppColors.muted),
                ),
              ),
              Expanded(
                child: OutlinedButton(
                  key: const ValueKey('desk-schedule-remind-time'),
                  onPressed: enabled
                      ? () async {
                          final picked = await showDeskDateTimeDialog(
                            context,
                            title: '选择提醒时间',
                            initial: DateTime.fromMillisecondsSinceEpoch(
                              value.remindAt!,
                            ),
                          );
                          if (picked != null) {
                            onChanged(
                              _with(
                                startAt: value.startAt,
                                endAt: value.endAt,
                                remindAt: picked.millisecondsSinceEpoch,
                              ),
                            );
                          }
                        }
                      : null,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    foregroundColor: AppColors.text,
                    minimumSize: const Size(0, 36),
                    side: BorderSide(
                      color: errors.remind == null
                          ? AppColors.line
                          : AppColors.danger,
                      width: errors.remind == null ? 1 : 1.4,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.notifications_none_rounded,
                        size: 14,
                        color: AppColors.muted,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          deskScheduleStamp(value.remindAt!),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Tooltip(
                message: '清除提醒',
                child: SizedBox(
                  width: 32,
                  height: 32,
                  child: Material(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(9),
                    child: InkWell(
                      key: const ValueKey('desk-schedule-remind-clear'),
                      borderRadius: BorderRadius.circular(9),
                      onTap: enabled
                          ? () => onChanged(
                              _with(startAt: value.startAt, endAt: value.endAt),
                            )
                          : null,
                      child: const Icon(
                        Icons.close_rounded,
                        size: 15,
                        color: AppColors.muted,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
        if (!value.isEmpty) ...[
          const SizedBox(height: 6),
          Text(
            deskReminderPreview(value),
            key: const ValueKey('desk-schedule-preview'),
            style: TextStyle(
              fontSize: 11,
              color:
                  deskScheduleReminderAt(value) != null &&
                      deskScheduleReminderAt(value)! <=
                          DateTime.now().millisecondsSinceEpoch
                  ? AppColors.warning
                  : AppColors.muted,
            ),
          ),
        ],
        if (errors.remind != null)
          _scheduleErrorText(
            const ValueKey('desk-schedule-remind-error'),
            errors.remind!,
          ),
      ],
    );
  }

  Future<void> _chooseMode(BuildContext context, _DeskRemindMode mode) async {
    switch (mode) {
      case _DeskRemindMode.none:
        onChanged(_with(startAt: value.startAt, endAt: value.endAt));
      case _DeskRemindMode.before5:
      case _DeskRemindMode.before15:
      case _DeskRemindMode.before30:
      case _DeskRemindMode.before60:
        final minutes = switch (mode) {
          _DeskRemindMode.before5 => 5,
          _DeskRemindMode.before15 => 15,
          _DeskRemindMode.before30 => 30,
          _ => 60,
        };
        onChanged(
          _with(
            startAt: value.startAt,
            endAt: value.endAt,
            remindBeforeMinutes: minutes,
          ),
        );
      case _DeskRemindMode.custom:
        final minutes = await showDeskRemindMinutesDialog(
          context,
          initial: value.remindBeforeMinutes,
        );
        if (minutes != null) {
          onChanged(
            _with(
              startAt: value.startAt,
              endAt: value.endAt,
              remindBeforeMinutes: minutes,
            ),
          );
        }
      case _DeskRemindMode.absolute:
        final picked = await showDeskDateTimeDialog(
          context,
          title: '选择提醒时间',
          initial: value.remindAt == null
              ? DateTime.now()
              : DateTime.fromMillisecondsSinceEpoch(value.remindAt!),
        );
        if (picked != null) {
          onChanged(
            _with(
              startAt: value.startAt,
              endAt: value.endAt,
              remindAt: picked.millisecondsSinceEpoch,
            ),
          );
        }
    }
  }

  OutlineInputBorder _fieldBorder({bool focused = false}) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide(
      color: errors.remind != null
          ? AppColors.danger
          : focused
          ? AppColors.primary
          : AppColors.line,
      width: errors.remind != null ? 1.4 : 1,
    ),
  );
}

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
        onEdit: () => _edit(context, entry: entry),
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
    var schedule = kind == DeskKind.todo
        ? (entry == null
              ? DeskSchedule.fromDraft(draft)
              : DeskSchedule.fromEntry(entry))
        : DeskSchedule.empty;
    var scheduleErrors = const DeskScheduleErrors();
    String? titleError;
    String? bodyError;
    final titleFocus = FocusNode();
    final bodyFocus = FocusNode();
    final startFocus = FocusNode();
    final endFocus = FocusNode();
    final remindFocus = FocusNode();
    final settings = notes.config(kind);
    var saving = false;
    var cancelled = false;
    var saved = false;
    Timer? draftTimer;
    void storeDraft() {
      if (entry != null) return;
      draftTimer?.cancel();
      draftTimer = Timer(const Duration(milliseconds: 400), () {
        unawaited(
          notes.storeDraft(
            kind,
            title.text,
            body.text,
            fontFamily: fontFamily,
            fontSize: fontSize,
            textColor: textColor,
            startAt: schedule.startAt,
            endAt: schedule.endAt,
            remindAt: schedule.remindAt,
            remindBeforeMinutes: schedule.remindBeforeMinutes,
          ),
        );
      });
    }

    void scheduleDraft() {
      if (entry != null) return;
      storeDraft();
    }

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
                      if (kind == DeskKind.note) ...[
                        TextField(
                          key: const ValueKey('desk-editor-title'),
                          controller: title,
                          focusNode: titleFocus,
                          onChanged: (_) {
                            setDialogState(() => titleError = null);
                            scheduleDraft();
                          },
                          maxLength: deskTitleMaxLength,
                          decoration: _editorDecoration(
                            labelText: '标题（可选）',
                            hintText: '这一刻，想记下什么？',
                            error: titleError,
                          ),
                        ),
                        if (titleError != null)
                          _scheduleErrorText(
                            const ValueKey('desk-editor-title-error'),
                            titleError!,
                          ),
                      ],
                      TextField(
                        key: const ValueKey('desk-editor-body'),
                        controller: body,
                        focusNode: bodyFocus,
                        onChanged: (_) {
                          setDialogState(() => bodyError = null);
                          scheduleDraft();
                        },
                        autofocus: true,
                        minLines: 5,
                        maxLines: 12,
                        maxLength: deskBodyMaxLength,
                        decoration: _editorDecoration(
                          labelText: kind == DeskKind.note ? '内容' : '事项内容',
                          hintText: kind == DeskKind.note
                              ? '写下来，让思绪轻一点…'
                              : '接下来，想完成什么？',
                          error: bodyError,
                        ),
                      ),
                      if (bodyError != null)
                        _scheduleErrorText(
                          const ValueKey('desk-editor-body-error'),
                          bodyError!,
                        ),
                      if (kind == DeskKind.todo) ...[
                        const SizedBox(height: 14),
                        DeskScheduleFields(
                          value: schedule,
                          errors: scheduleErrors,
                          enabled: !saving,
                          startFocus: startFocus,
                          endFocus: endFocus,
                          remindFocus: remindFocus,
                          onChanged: (value) {
                            setDialogState(() {
                              schedule = value;
                              scheduleErrors = const DeskScheduleErrors();
                            });
                            scheduleDraft();
                          },
                        ),
                      ],
                      const SizedBox(height: 16),
                      DeskTextStyleFields(
                        fontFamily: fontFamily,
                        fontSize: fontSize,
                        textColor: textColor,
                        inheritedFontSize: settings.fontSize,
                        enabled: !saving,
                        onFontFamily: (value) {
                          setDialogState(() => fontFamily = value);
                          scheduleDraft();
                        },
                        onFontSize: (value) {
                          setDialogState(() => fontSize = value);
                          scheduleDraft();
                        },
                        onTextColor: (value) {
                          setDialogState(() => textColor = value);
                          scheduleDraft();
                        },
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
                  onPressed: saving
                      ? null
                      : () {
                          cancelled = true;
                          Navigator.pop(context);
                        },
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
                          final trimmedTitle = title.text.trim();
                          final titleTooLong =
                              trimmedTitle.length > deskTitleMaxLength;
                          final bodyEmpty = body.text.trim().isEmpty;
                          final errors = kind == DeskKind.todo
                              ? validateDeskScheduleFields(schedule)
                              : const DeskScheduleErrors();
                          if (titleTooLong || bodyEmpty || !errors.isEmpty) {
                            setDialogState(() {
                              titleError = titleTooLong
                                  ? '标题最多 $deskTitleMaxLength 字，请精简后保存'
                                  : null;
                              bodyError = bodyEmpty ? '请先填写内容' : null;
                              scheduleErrors = errors;
                            });
                            // 焦点跳到首个错误字段，重新编辑即时清除提示。
                            if (titleTooLong) {
                              titleFocus.requestFocus();
                            } else if (bodyEmpty) {
                              bodyFocus.requestFocus();
                            } else if (errors.end != null) {
                              endFocus.requestFocus();
                            } else {
                              remindFocus.requestFocus();
                            }
                            return;
                          }
                          setDialogState(() {
                            saving = true;
                            titleError = null;
                            bodyError = null;
                            scheduleErrors = const DeskScheduleErrors();
                          });
                          try {
                            await notes.save(
                              kind,
                              id: entry?.id,
                              title: trimmedTitle,
                              body: body.text,
                              done: entry?.done ?? false,
                              fontFamily: fontFamily,
                              fontSize: fontSize,
                              textColor: textColor,
                              startAt: kind == DeskKind.todo
                                  ? schedule.startAt
                                  : null,
                              endAt: kind == DeskKind.todo
                                  ? schedule.endAt
                                  : null,
                              remindAt: kind == DeskKind.todo
                                  ? schedule.remindAt
                                  : null,
                              remindBeforeMinutes: kind == DeskKind.todo
                                  ? schedule.remindBeforeMinutes
                                  : null,
                              expected: entry == null ? null : {entry.revision},
                            );
                            saved = true;
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
      draftTimer?.cancel();
      await notes.editing(false);
    }
    if (entry == null) {
      if (cancelled || saved) {
        await notes.storeDraft(kind, '', '');
      } else {
        await notes.storeDraft(
          kind,
          title.text,
          body.text,
          fontFamily: fontFamily,
          fontSize: fontSize,
          textColor: textColor,
          startAt: schedule.startAt,
          endAt: schedule.endAt,
          remindAt: schedule.remindAt,
          remindBeforeMinutes: schedule.remindBeforeMinutes,
        );
      }
    }
    // Dialog route animation can still reference the controllers for a frame.
    Future<void>.delayed(const Duration(milliseconds: 250), () {
      title.dispose();
      body.dispose();
      titleFocus.dispose();
      bodyFocus.dispose();
      startFocus.dispose();
      endFocus.dispose();
      remindFocus.dispose();
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
        title: Text('删除${widget.kind.label}？'),
        content: const Text('内容删除后会同步到其他设备，已有 Git 历史提交仍可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.danger,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      try {
        await widget.notes.remove(entry);
        if (context.mounted) showMessage(context, '内容已删除');
      } catch (error) {
        if (context.mounted) showMessage(context, '$error');
      }
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
          // 采用某个版本时回传该版本的时间与提醒，避免时间在合并后丢失。
          startAt: selected.startAt,
          endAt: selected.endAt,
          remindAt: selected.remindAt,
          remindBeforeMinutes: selected.remindBeforeMinutes,
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
              if (entry.kind == DeskKind.todo &&
                  !DeskSchedule.fromEntry(entry).isEmpty)
                Text(
                  '时间与提醒：${deskScheduleSummary(DeskSchedule.fromEntry(entry))}',
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
