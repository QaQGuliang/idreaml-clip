import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../app_controller.dart';
import '../models/clipboard_item.dart';
import '../services/desktop_service.dart';
import 'app_theme.dart';
import 'common.dart';

class QuickPanel extends StatefulWidget {
  const QuickPanel({
    super.key,
    required this.controller,
    required this.desktopService,
  });

  final AppController controller;
  final DesktopService desktopService;

  @override
  State<QuickPanel> createState() => _QuickPanelState();
}

class _QuickPanelState extends State<QuickPanel> {
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _searchFocus.requestFocus(),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        widget.controller.moveQuickSelection(1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        widget.controller.moveQuickSelection(-1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
        _useSelected();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        widget.desktopService.hide();
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _useSelected() async {
    final used = await widget.controller.useItem(
      widget.controller.selectedQuick,
    );
    if (used) await widget.desktopService.hide();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Focus(
      onKeyEvent: _handleKey,
      child: Scaffold(
        backgroundColor: AppColors.canvas,
        body: SafeArea(
          child: Container(
            margin: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.line),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x24211C38),
                  blurRadius: 32,
                  offset: Offset(0, 12),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                DragToMoveArea(
                  child: _QuickHeader(service: widget.desktopService),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                  child: TextField(
                    key: const ValueKey('quick-search'),
                    controller: _searchController,
                    focusNode: _searchFocus,
                    onChanged: controller.setQuickSearch,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search_rounded, size: 19),
                      hintText: '搜索最近记录；输入后搜索全部历史…',
                      suffixIcon: _KeyCap(label: 'Esc'),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      _QuickTab(
                        label: '最近',
                        active: !controller.quickFavoritesOnly,
                        onTap: () => controller.setQuickFavoritesOnly(false),
                      ),
                      const SizedBox(width: 6),
                      _QuickTab(
                        label: '收藏',
                        active: controller.quickFavoritesOnly,
                        onTap: () => controller.setQuickFavoritesOnly(true),
                      ),
                      const Spacer(),
                      Text(
                        controller.quickSearch.trim().isEmpty
                            ? '最近 ${controller.quickCount} 条'
                            : '全部历史搜索',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: controller.quickItems.isEmpty
                      ? const EmptyState(
                          title: '还没有剪切板记录',
                          subtitle: '复制一段文本后，它会自动出现在这里',
                        )
                      : ListView.builder(
                          key: const ValueKey('quick-list'),
                          padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                          itemCount: controller.quickItems.length,
                          itemBuilder: (context, index) => _QuickItem(
                            item: controller.quickItems[index],
                            selected: index == controller.selectedQuickIndex,
                            onTap: () {
                              final delta =
                                  index - controller.selectedQuickIndex;
                              controller.moveQuickSelection(delta);
                            },
                            onUse: _useSelected,
                            onFavorite: () => controller.toggleFavorite(
                              controller.quickItems[index].id,
                            ),
                          ),
                        ),
                ),
                _QuickFooter(onOpenMain: widget.desktopService.showMain),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QuickHeader extends StatelessWidget {
  const _QuickHeader({required this.service});
  final DesktopService service;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 15, 10, 10),
    child: Row(
      children: [
        const BrandMark(size: 34),
        const SizedBox(width: 10),
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '快捷剪切板',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            SizedBox(height: 1),
            Text(
              'Idreaml Clip · 理梦剪藏',
              style: TextStyle(fontSize: 10, color: AppColors.muted),
            ),
          ],
        ),
        const Spacer(),
        const StatusPill(label: '正在记录'),
        const SizedBox(width: 5),
        IconButton(
          tooltip: '关闭',
          onPressed: service.hide,
          icon: const Icon(Icons.close_rounded, size: 18),
        ),
      ],
    ),
  );
}

class _QuickTab extends StatelessWidget {
  const _QuickTab({
    required this.label,
    required this.active,
    required this.onTap,
  });
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(9),
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: active ? AppColors.primarySoft : Colors.transparent,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: active ? AppColors.primary : AppColors.muted,
          fontWeight: FontWeight.w600,
          fontSize: 11.5,
        ),
      ),
    ),
  );
}

class _QuickItem extends StatelessWidget {
  const _QuickItem({
    required this.item,
    required this.selected,
    required this.onTap,
    required this.onUse,
    required this.onFavorite,
  });

  final ClipboardItem item;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onUse;
  final VoidCallback onFavorite;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Material(
      color: selected ? const Color(0xFFF6F3FF) : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: selected ? const Color(0xFFDFD8FF) : Colors.transparent,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        onDoubleTap: onUse,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(11),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: selected
                      ? const Color(0xFFE9E4FF)
                      : const Color(0xFFF1F1F5),
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: Text(
                  'T',
                  style: TextStyle(
                    color: selected ? AppColors.primary : AppColors.muted,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.content.replaceAll('\n', ' '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${relativeTime(item.lastUsedAt)}  ·  已复制 ${item.copyCount} 次',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: item.favorite ? '取消收藏' : '收藏',
                onPressed: onFavorite,
                icon: Icon(
                  item.favorite
                      ? Icons.star_rounded
                      : Icons.star_border_rounded,
                  color: item.favorite ? AppColors.warning : AppColors.muted,
                  size: 19,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _QuickFooter extends StatelessWidget {
  const _QuickFooter({required this.onOpenMain});
  final VoidCallback onOpenMain;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
    decoration: const BoxDecoration(
      color: Color(0xFFFAFAFC),
      border: Border(top: BorderSide(color: AppColors.line)),
    ),
    child: Row(
      children: [
        const _KeyCap(label: '↑'),
        const SizedBox(width: 3),
        const _KeyCap(label: '↓'),
        const SizedBox(width: 5),
        const Text(
          '选择',
          style: TextStyle(fontSize: 10, color: AppColors.muted),
        ),
        const SizedBox(width: 12),
        const _KeyCap(label: 'Enter'),
        const SizedBox(width: 5),
        const Text(
          '使用',
          style: TextStyle(fontSize: 10, color: AppColors.muted),
        ),
        const Spacer(),
        TextButton(
          onPressed: onOpenMain,
          child: const Text('查看全部历史  →', style: TextStyle(fontSize: 11)),
        ),
      ],
    ),
  );
}

class _KeyCap extends StatelessWidget {
  const _KeyCap({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFF0EFF4),
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 9, color: AppColors.muted),
      ),
    ),
  );
}
