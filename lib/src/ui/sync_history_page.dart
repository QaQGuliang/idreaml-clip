import 'package:flutter/material.dart';

import '../models/sync_models.dart';
import 'app_theme.dart';
import 'common.dart';

enum SyncHistoryFilter {
  all('全部'),
  success('成功'),
  failed('失败');

  const SyncHistoryFilter(this.label);
  final String label;

  bool matches(SyncHistoryEntry entry) => switch (this) {
    SyncHistoryFilter.all => true,
    SyncHistoryFilter.success => entry.succeeded,
    SyncHistoryFilter.failed => !entry.succeeded,
  };
}

/// 展示本机保留的全部同步记录，按天分组并支持成功 / 失败筛选。
///
/// 只读取传入的记录快照，不会修改同步数据或触发同步。
class SyncHistoryPage extends StatefulWidget {
  const SyncHistoryPage({
    super.key,
    required this.entries,
    this.unavailable = false,
  });

  final List<SyncHistoryEntry> entries;
  final bool unavailable;

  @override
  State<SyncHistoryPage> createState() => _SyncHistoryPageState();
}

class _SyncHistoryPageState extends State<SyncHistoryPage> {
  SyncHistoryFilter _filter = SyncHistoryFilter.all;

  @override
  Widget build(BuildContext context) {
    final filtered = widget.entries.where(_filter.matches).toList();
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(
        title: const Text('同步记录'),
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: Theme.of(context).textTheme.titleMedium,
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: AppColors.line),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Row(
                children: [
                  SegmentedButton<SyncHistoryFilter>(
                    key: const ValueKey('sync-history-filter'),
                    showSelectedIcon: false,
                    segments: [
                      for (final filter in SyncHistoryFilter.values)
                        ButtonSegment(
                          value: filter,
                          label: Text(
                            filter.label,
                            key: ValueKey('sync-history-filter-${filter.name}'),
                          ),
                        ),
                    ],
                    selected: {_filter},
                    onSelectionChanged: (value) =>
                        setState(() => _filter = value.first),
                    style: ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      textStyle: const WidgetStatePropertyAll(
                        TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                      side: const WidgetStatePropertyAll(
                        BorderSide(color: AppColors.line),
                      ),
                      backgroundColor: WidgetStateProperty.resolveWith(
                        (states) => states.contains(WidgetState.selected)
                            ? AppColors.primarySoft
                            : AppColors.surface,
                      ),
                      foregroundColor: WidgetStateProperty.resolveWith(
                        (states) => states.contains(WidgetState.selected)
                            ? AppColors.primary
                            : AppColors.muted,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${filtered.length} 条',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            if (widget.unavailable)
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: Text(
                  '同步记录暂时无法保存或读取，请检查数据目录。',
                  style: TextStyle(color: AppColors.warning, fontSize: 12),
                ),
              ),
            Expanded(child: _body(context, filtered)),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, List<SyncHistoryEntry> filtered) {
    if (filtered.isEmpty) {
      final message = widget.entries.isEmpty
          ? ('暂无同步记录', '完成一次云同步后，这里会按天展示成功与失败记录。')
          : ('没有符合条件的记录', '切换上方筛选查看其他同步记录。');
      return _EmptyHistory(title: message.$1, subtitle: message.$2);
    }
    final groups = _groupByDay(filtered);
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      itemCount: groups.length,
      itemBuilder: (context, index) {
        final group = groups[index];
        return Padding(
          padding: EdgeInsets.only(top: index == 0 ? 4 : 14),
          child: AppCard(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      _dayLabel(group.day),
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 12.5,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${group.entries.length} 条',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                for (final (index, entry) in group.entries.indexed) ...[
                  if (index > 0) const Divider(height: 1),
                  _HistoryEntryTile(entry: entry),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  List<_DayGroup> _groupByDay(List<SyncHistoryEntry> entries) {
    final groups = <_DayGroup>[];
    for (final entry in entries) {
      final local = entry.completedAt.toLocal();
      final day = DateTime(local.year, local.month, local.day);
      if (groups.isNotEmpty && groups.last.day == day) {
        groups.last.entries.add(entry);
      } else {
        groups.add(_DayGroup(day, [entry]));
      }
    }
    return groups;
  }

  String _dayLabel(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final difference = today.difference(day).inDays;
    if (difference == 0) return '今天';
    if (difference == 1) return '昨天';
    return '${day.year}年${day.month}月${day.day}日';
  }
}

class _DayGroup {
  _DayGroup(this.day, this.entries);
  final DateTime day;
  final List<SyncHistoryEntry> entries;
}

class _HistoryEntryTile extends StatelessWidget {
  const _HistoryEntryTile({required this.entry});

  final SyncHistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final time = entry.completedAt.toLocal();
    final clock = '${_twoDigits(time.hour)}:${_twoDigits(time.minute)}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              StatusPill(
                label: entry.succeeded ? '成功' : '失败',
                color: entry.succeeded ? AppColors.success : AppColors.danger,
              ),
              Text('$clock · ${entry.trigger.label}'),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            entry.details,
            style: const TextStyle(color: AppColors.muted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: AppColors.primarySoft,
              borderRadius: BorderRadius.circular(17),
            ),
            child: const Icon(Icons.history_rounded, color: AppColors.primary),
          ),
          const SizedBox(height: 14),
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 5),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    ),
  );
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');
