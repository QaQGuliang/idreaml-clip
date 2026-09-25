import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../app_controller.dart';
import '../models/clipboard_item.dart';
import '../models/sync_models.dart';
import '../models/workspace_layout.dart';
import '../services/desktop_service.dart';
import 'app_theme.dart';
import 'common.dart';
import 'clipboard_image.dart';
import 'shortcut_dialog.dart';
import 'resize_divider.dart';
import 'history_limit_picker.dart';
import 'json_split_preview.dart';
import 'release_info_card.dart';

class MainShell extends StatefulWidget {
  const MainShell({
    super.key,
    required this.controller,
    required this.desktopService,
  });

  final AppController controller;
  final DesktopService desktopService;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  double _sidebarDragStartWidth = 226;
  late final _searchController = TextEditingController(
    text: widget.controller.historySearch,
  );

  @override
  void didUpdateWidget(covariant MainShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    final search = widget.controller.historySearch;
    if (_searchController.text != search) {
      _searchController.value = TextEditingValue(
        text: search,
        selection: TextSelection.collapsed(offset: search.length),
      );
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final maxSidebarWidth = (constraints.maxWidth - 640).clamp(
              WorkspaceLayout.minSidebarWidth,
              WorkspaceLayout.maxSidebarWidth,
            );
            final sidebarWidth = controller.workspaceLayout.sidebarWidth.clamp(
              WorkspaceLayout.minSidebarWidth,
              maxSidebarWidth,
            );
            return Stack(
              children: [
                Row(
                  children: [
                    SizedBox(
                      key: const ValueKey('main-sidebar'),
                      width: sidebarWidth,
                      child: _Sidebar(
                        controller: controller,
                        compact:
                            sidebarWidth < WorkspaceLayout.compactSidebarWidth,
                        onPage: (page) {
                          _searchController.clear();
                          controller.historySearch = '';
                          controller.setPage(page);
                        },
                      ),
                    ),
                    Expanded(
                      child: Column(
                        children: [
                          _TopBar(
                            controller: controller,
                            searchController: _searchController,
                            desktopService: widget.desktopService,
                          ),
                          if (controller.clipboardError != null)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 4,
                              ),
                              child: Text(
                                controller.clipboardError!,
                                style: const TextStyle(
                                  color: AppColors.warning,
                                ),
                              ),
                            ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                              child: _CurrentPage(
                                controller: controller,
                                desktopService: widget.desktopService,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                Positioned(
                  left: sidebarWidth - 4,
                  top: 0,
                  bottom: 0,
                  child: ResizeDivider(
                    key: const ValueKey('sidebar-divider'),
                    width: 8,
                    label: '拖动调整导航栏宽度，缩窄后显示图标',
                    onResizeStart: () => _sidebarDragStartWidth = sidebarWidth,
                    onResize: (delta) => controller.resizeWorkspace(
                      sidebarWidth: (_sidebarDragStartWidth + delta).clamp(
                        WorkspaceLayout.minSidebarWidth,
                        maxSidebarWidth,
                      ),
                    ),
                    onResizeEnd: () =>
                        _saveWorkspaceLayout(context, controller),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

Future<void> _saveWorkspaceLayout(
  BuildContext context,
  AppController controller,
) async {
  try {
    await controller.saveWorkspaceLayout();
  } catch (_) {
    if (context.mounted) showMessage(context, '布局已调整，但保存失败，请稍后重试');
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.controller,
    required this.onPage,
    required this.compact,
  });
  final AppController controller;
  final ValueChanged<AppPage> onPage;
  final bool compact;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      color: AppColors.sidebar,
      border: Border(right: BorderSide(color: AppColors.line)),
    ),
    child: Column(
      children: [
        if (compact)
          const DragToMoveArea(
            child: SizedBox(
              height: 84,
              width: double.infinity,
              child: Center(child: BrandMark(size: 32)),
            ),
          )
        else
          const DragToMoveArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(20, 20, 16, 22),
              child: Row(
                children: [
                  BrandMark(),
                  SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Idreaml Clip',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          '理梦剪藏',
                          style: TextStyle(
                            fontSize: 10,
                            color: AppColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (!compact) const _NavLabel('剪切板'),
        _NavItem(
          compact: compact,
          icon: Icons.space_dashboard_outlined,
          label: '全部历史',
          selected: controller.page == AppPage.history,
          onTap: () => onPage(AppPage.history),
        ),
        _NavItem(
          compact: compact,
          icon: Icons.star_outline_rounded,
          label: '我的收藏',
          trailing: '${controller.stats.favorites}',
          selected: controller.page == AppPage.favorites,
          onTap: () => onPage(AppPage.favorites),
        ),
        const SizedBox(height: 12),
        if (!compact) const _NavLabel('管理'),
        _NavItem(
          compact: compact,
          icon: Icons.sync_rounded,
          label: '云同步',
          selected: controller.page == AppPage.sync,
          onTap: () => onPage(AppPage.sync),
        ),
        _NavItem(
          compact: compact,
          icon: Icons.devices_outlined,
          label: '设备',
          selected: controller.page == AppPage.devices,
          onTap: () => onPage(AppPage.devices),
        ),
        _NavItem(
          compact: compact,
          icon: Icons.shield_outlined,
          label: '隐私',
          selected: controller.page == AppPage.privacy,
          onTap: () => onPage(AppPage.privacy),
        ),
        _NavItem(
          compact: compact,
          icon: Icons.settings_outlined,
          label: '设置',
          selected: controller.page == AppPage.settings,
          onTap: () => onPage(AppPage.settings),
        ),
        const Spacer(),
        if (compact)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Column(
              children: [
                IconButton(
                  tooltip: controller.syncService.config == null
                      ? '仅本地模式 · 配置云同步'
                      : '云同步已连接',
                  onPressed: () => onPage(AppPage.sync),
                  icon: Icon(
                    controller.syncService.config == null
                        ? Icons.cloud_off_outlined
                        : Icons.cloud_done_outlined,
                    size: 20,
                    color: controller.syncService.config == null
                        ? AppColors.muted
                        : AppColors.success,
                  ),
                ),
                const SizedBox(height: 9),
                IconButton.outlined(
                  tooltip: controller.recordingEnabled ? '暂停记录' : '恢复记录',
                  onPressed: () =>
                      controller.setRecording(!controller.recordingEnabled),
                  icon: Icon(
                    controller.recordingEnabled
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    size: 20,
                  ),
                ),
              ],
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: AppColors.line),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            controller.syncService.config == null
                                ? Icons.cloud_off_outlined
                                : Icons.cloud_done_outlined,
                            size: 15,
                            color: controller.syncService.config == null
                                ? AppColors.muted
                                : AppColors.success,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            controller.syncService.config == null
                                ? '仅本地模式'
                                : '云同步已连接',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Text(
                        controller.syncService.config == null
                            ? '数据保存在本机，云同步尚未配置'
                            : '本地优先 · 每  ${controller.syncService.config!.intervalMinutes} 分钟同步',
                        style: const TextStyle(
                          fontSize: 9.5,
                          color: AppColors.muted,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 9),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () =>
                        controller.setRecording(!controller.recordingEnabled),
                    icon: Icon(
                      controller.recordingEnabled
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      size: 16,
                    ),
                    label: Text(controller.recordingEnabled ? '暂停记录' : '恢复记录'),
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

class _NavLabel extends StatelessWidget {
  const _NavLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(21, 4, 21, 7),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(
        label,
        style: const TextStyle(
          color: AppColors.muted,
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
          letterSpacing: .8,
        ),
      ),
    ),
  );
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.compact,
    this.trailing,
  });
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool compact;
  final String? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 11, vertical: 2),
    child: Tooltip(
      message: label,
      child: Semantics(
        label: compact ? label : null,
        selected: selected,
        button: true,
        child: Material(
          color: selected ? AppColors.primarySoft : Colors.transparent,
          borderRadius: BorderRadius.circular(11),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(11),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
              child: Row(
                mainAxisAlignment: compact
                    ? MainAxisAlignment.center
                    : MainAxisAlignment.start,
                children: [
                  Icon(
                    icon,
                    size: 18,
                    color: selected ? AppColors.primary : AppColors.muted,
                  ),
                  if (!compact) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected ? AppColors.primary : AppColors.text,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    if (trailing != null)
                      Text(
                        trailing!,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.controller,
    required this.searchController,
    required this.desktopService,
  });
  final AppController controller;
  final TextEditingController searchController;
  final DesktopService desktopService;

  static const titles = {
    AppPage.history: ('全部历史', '长期保存的本地剪切板记录'),
    AppPage.favorites: ('我的收藏', '长期保留的重要内容'),
    AppPage.sync: ('云同步', '使用你自己的 Git 仓库'),
    AppPage.devices: ('设备', '管理参与同步的设备'),
    AppPage.privacy: ('隐私', '本地优先，内容由你掌控'),
    AppPage.settings: ('设置', '快捷面板与桌面行为'),
  };

  @override
  Widget build(BuildContext context) {
    final title = titles[controller.page]!;
    final showSearch =
        controller.page == AppPage.history ||
        controller.page == AppPage.favorites;
    return SizedBox(
      height: 84,
      child: Row(
        children: [
          Expanded(
            child: DragToMoveArea(
              child: Padding(
                padding: const EdgeInsets.only(left: 22),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title.$1,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        title.$2,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (showSearch)
            SizedBox(
              width: 290,
              child: TextField(
                controller: searchController,
                onChanged: controller.setHistorySearch,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search_rounded, size: 19),
                  hintText: '搜索剪切板内容…',
                ),
              ),
            ),
          const SizedBox(width: 12),
          IconButton(
            tooltip: '最小化',
            onPressed: windowManager.minimize,
            icon: const Icon(Icons.remove_rounded, size: 18),
          ),
          IconButton(
            tooltip: '最大化/还原',
            onPressed: () async {
              if (await windowManager.isMaximized()) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            },
            icon: const Icon(Icons.crop_square_rounded, size: 16),
          ),
          IconButton(
            tooltip: '关闭到托盘',
            onPressed: desktopService.hide,
            icon: const Icon(Icons.close_rounded, size: 18),
          ),
          const SizedBox(width: 7),
        ],
      ),
    );
  }
}

class _CurrentPage extends StatelessWidget {
  const _CurrentPage({required this.controller, required this.desktopService});
  final AppController controller;
  final DesktopService desktopService;

  @override
  Widget build(BuildContext context) {
    switch (controller.page) {
      case AppPage.history:
      case AppPage.favorites:
        return _HistoryWorkspace(controller: controller);
      case AppPage.sync:
        return _SyncPage(controller: controller);
      case AppPage.devices:
        return _DevicesPage(controller: controller);
      case AppPage.privacy:
        return _PrivacyPage(controller: controller);
      case AppPage.settings:
        return _SettingsPage(
          controller: controller,
          desktopService: desktopService,
        );
    }
  }
}

class _HistoryWorkspace extends StatefulWidget {
  const _HistoryWorkspace({required this.controller});
  final AppController controller;

  @override
  State<_HistoryWorkspace> createState() => _HistoryWorkspaceState();
}

class _HistoryWorkspaceState extends State<_HistoryWorkspace> {
  double _historyDragStartWidth = 0;
  AppController get controller => widget.controller;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      const dividerWidth = 16.0;
      final showDetail =
          constraints.maxWidth >=
          WorkspaceLayout.minHistoryWidth +
              WorkspaceLayout.minDetailWidth +
              dividerWidth;
      final availableWidth = constraints.maxWidth - dividerWidth;
      final historyWidth = showDetail
          ? (availableWidth * controller.workspaceLayout.historyFraction).clamp(
              WorkspaceLayout.minHistoryWidth,
              availableWidth - WorkspaceLayout.minDetailWidth,
            )
          : constraints.maxWidth;
      return Row(
        children: [
          SizedBox(
            key: const ValueKey('history-list'),
            width: historyWidth,
            child: AppCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 9),
                    child: Row(
                      children: [
                        _FilterChip(
                          label: controller.page == AppPage.favorites
                              ? '收藏'
                              : '全部',
                          active: !controller.historyTodayOnly,
                          onTap: () => controller.setHistoryTodayOnly(false),
                        ),
                        const SizedBox(width: 6),
                        _FilterChip(
                          label: '今天',
                          active: controller.historyTodayOnly,
                          onTap: () => controller.setHistoryTodayOnly(true),
                        ),
                        const Spacer(),
                        Text(
                          '${controller.history.length} 条记录',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: controller.history.isEmpty
                        ? EmptyState(
                            title: controller.historySearch.isEmpty
                                ? '还没有剪切板记录'
                                : '没有找到匹配记录',
                            subtitle: controller.historySearch.isEmpty
                                ? '复制文本或图片后会自动保存在本机'
                                : '试试更短的关键词',
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.all(8),
                            itemCount: controller.history.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 2),
                            itemBuilder: (context, index) {
                              final item = controller.history[index];
                              return _HistoryItem(
                                item: item,
                                selected:
                                    item.id == controller.selectedHistoryId,
                                onTap: () => controller.selectHistory(item.id),
                                onUse: () async {
                                  final copied = await controller.useItem(item);
                                  if (context.mounted) {
                                    showMessage(
                                      context,
                                      copied
                                          ? '已复制到系统剪切板'
                                          : controller.clipboardError ?? '复制失败',
                                    );
                                  }
                                },
                                onFavorite: () =>
                                    controller.toggleFavorite(item.id),
                                onDelete: () => controller.deleteItem(item.id),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
          if (showDetail) ...[
            ResizeDivider(
              key: const ValueKey('history-divider'),
              label: '拖动调整历史列表与预览宽度',
              width: dividerWidth,
              onResizeStart: () => _historyDragStartWidth = historyWidth,
              onResize: (delta) => controller.resizeWorkspace(
                historyFraction:
                    (_historyDragStartWidth + delta).clamp(
                      WorkspaceLayout.minHistoryWidth,
                      availableWidth - WorkspaceLayout.minDetailWidth,
                    ) /
                    availableWidth,
              ),
              onResizeEnd: () => _saveWorkspaceLayout(context, controller),
            ),
            Expanded(
              key: const ValueKey('content-preview'),
              child: _DetailCard(
                item: controller.selectedHistory,
                onUse: () async {
                  final copied = await controller.useItem(
                    controller.selectedHistory,
                  );
                  if (context.mounted) {
                    showMessage(
                      context,
                      copied
                          ? '已复制到系统剪切板'
                          : controller.clipboardError ?? '复制失败',
                    );
                  }
                },
                onFavorite: controller.selectedHistory == null
                    ? null
                    : () => controller.toggleFavorite(
                        controller.selectedHistory!.id,
                      ),
              ),
            ),
          ],
        ],
      );
    },
  );
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
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
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: active ? AppColors.primarySoft : const Color(0xFFF7F7FA),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: active ? AppColors.primary : AppColors.muted,
        ),
      ),
    ),
  );
}

class _HistoryItem extends StatelessWidget {
  const _HistoryItem({
    required this.item,
    required this.selected,
    required this.onTap,
    required this.onUse,
    required this.onFavorite,
    required this.onDelete,
  });
  final ClipboardItem item;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onUse;
  final VoidCallback onFavorite;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final previewWidth = (constraints.maxWidth * .28).clamp(104.0, 144.0);
      final compactActions = item.isImage && constraints.maxWidth < 420;
      final actions = [
        IconButton(
          tooltip: item.favorite ? '取消收藏' : '收藏',
          onPressed: onFavorite,
          constraints: compactActions
              ? const BoxConstraints.tightFor(width: 32, height: 32)
              : null,
          padding: compactActions ? EdgeInsets.zero : null,
          icon: Icon(
            item.favorite ? Icons.star_rounded : Icons.star_border_rounded,
            size: 18,
            color: item.favorite ? AppColors.warning : AppColors.muted,
          ),
        ),
        IconButton(
          tooltip: '删除',
          onPressed: onDelete,
          constraints: compactActions
              ? const BoxConstraints.tightFor(width: 32, height: 32)
              : null,
          padding: compactActions ? EdgeInsets.zero : null,
          icon: const Icon(
            Icons.close_rounded,
            size: 17,
            color: AppColors.muted,
          ),
        ),
      ];
      return Material(
        color: selected ? const Color(0xFFF7F5FF) : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(13),
          side: BorderSide(
            color: selected ? const Color(0xFFE2DCFF) : Colors.transparent,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          onDoubleTap: onUse,
          borderRadius: BorderRadius.circular(13),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
            child: Row(
              children: [
                if (item.isImage)
                  Container(
                    key: ValueKey('history-image-preview-${item.id}'),
                    width: previewWidth,
                    height: previewWidth * .625,
                    decoration: BoxDecoration(
                      color: selected
                          ? const Color(0xFFEFEAFF)
                          : const Color(0xFFF0F1F5),
                      border: Border.all(
                        color: selected
                            ? const Color(0xFFE2DCFF)
                            : AppColors.line,
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    padding: const EdgeInsets.all(3),
                    alignment: Alignment.center,
                    child: ClipboardImage(
                      item: item,
                      thumbnail: true,
                      thumbnailSize: const Size(144, 90),
                    ),
                  )
                else
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: selected
                          ? const Color(0xFFE9E5FF)
                          : const Color(0xFFF0F1F5),
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
                        item.summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        '${relativeTime(item.lastUsedAt)}  ·  ${deviceLabel(item)}  ·  ${item.copyCount} 次',
                        maxLines: item.isImage ? 2 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (compactActions)
                  Column(mainAxisSize: MainAxisSize.min, children: actions)
                else
                  ...actions,
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _DetailCard extends StatelessWidget {
  const _DetailCard({
    required this.item,
    required this.onUse,
    required this.onFavorite,
  });
  final ClipboardItem? item;
  final VoidCallback onUse;
  final VoidCallback? onFavorite;

  @override
  Widget build(BuildContext context) => AppCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('内容详情', style: TextStyle(fontWeight: FontWeight.w700)),
            const Spacer(),
            StatusPill(
              label: item?.typeLabel ?? '—',
              color: AppColors.primary,
              icon: item?.isImage == true
                  ? Icons.image_outlined
                  : item?.typeLabel == 'JSON'
                  ? Icons.data_object_rounded
                  : Icons.text_fields_rounded,
            ),
          ],
        ),
        const SizedBox(height: 14),
        Expanded(
          child: Container(
            width: double.infinity,
            padding: item?.typeLabel == 'JSON'
                ? EdgeInsets.zero
                : const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFF8F8FA),
              border: Border.all(color: AppColors.line),
              borderRadius: BorderRadius.circular(14),
            ),
            clipBehavior: Clip.antiAlias,
            child: item?.isImage == true
                ? ClipboardImage(item: item!)
                : item?.typeLabel == 'JSON'
                ? JsonSplitPreview(
                    key: ValueKey(item!.contentHash),
                    content: item!.content,
                  )
                : SingleChildScrollView(
                    child: SelectableText(
                      item?.content ?? '请选择一条剪切板记录',
                      style: TextStyle(
                        color: item == null ? AppColors.muted : AppColors.text,
                        height: 1.55,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 12),
        _MetaRow(
          label: '最近使用',
          value: item == null ? '-' : relativeTime(item!.lastUsedAt),
        ),
        const SizedBox(height: 7),
        _MetaRow(label: '来源设备', value: item == null ? '-' : deviceLabel(item!)),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: item == null ? null : onUse,
                icon: const Icon(Icons.copy_rounded, size: 16),
                label: const Text('复制内容'),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.outlined(
              tooltip: item?.favorite == true ? '取消收藏' : '收藏',
              onPressed: onFavorite,
              icon: Icon(
                item?.favorite == true
                    ? Icons.star_rounded
                    : Icons.star_border_rounded,
                color: item?.favorite == true ? AppColors.warning : null,
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Text(label, style: Theme.of(context).textTheme.bodySmall),
      const Spacer(),
      Flexible(
        child: Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600),
        ),
      ),
    ],
  );
}

class _SyncPage extends StatelessWidget {
  const _SyncPage({required this.controller});
  final AppController controller;

  Future<void> _editConnection(
    BuildContext context,
    SyncProvider provider,
  ) async {
    final current = controller.syncService.config;
    final remote = TextEditingController(text: current?.remoteUrl ?? '');
    final username = TextEditingController(text: current?.username ?? '');
    final branch = TextEditingController(text: current?.branch ?? 'main');
    final token = TextEditingController();
    String? error;
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text('${_providerName(provider)} 仓库连接'),
          content: SizedBox(
            width: 500,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: remote,
                  decoration: const InputDecoration(
                    labelText: 'HTTPS 仓库地址',
                    hintText: 'https://gitee.com/你的账号/仓库.git',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: username,
                  decoration: const InputDecoration(labelText: 'Git 用户名'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: token,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: current == null ? '访问令牌' : '访问令牌（留空则不修改）',
                    helperText: '令牌仅保存到系统安全凭证库，不进入 SQLite 或 Git。',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: branch,
                  decoration: const InputDecoration(labelText: '同步分支'),
                ),
                if (error != null) ...[
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      error!,
                      style: const TextStyle(color: AppColors.danger),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                if (current == null && token.text.trim().isEmpty) {
                  setState(() => error = '首次连接需要填写访问令牌。');
                  return;
                }
                try {
                  await controller.saveSyncConfig(
                    SyncConfig(
                      provider: provider,
                      remoteUrl: remote.text.trim(),
                      username: username.text.trim(),
                      branch: branch.text.trim(),
                      intervalMinutes: current?.intervalMinutes ?? 10,
                      enabled: current?.enabled ?? true,
                      syncOnStartup: current?.syncOnStartup ?? true,
                    ),
                    token: token.text,
                  );
                  if (dialogContext.mounted) Navigator.pop(dialogContext, true);
                } catch (value) {
                  setState(
                    () =>
                        error = '$value'.replaceFirst('FormatException: ', ''),
                  );
                }
              },
              child: const Text('保存连接'),
            ),
          ],
        ),
      ),
    );
    remote.dispose();
    username.dispose();
    branch.dispose();
    token.dispose();
    if (saved == true && context.mounted) {
      showMessage(context, '连接已保存，可以立即同步');
    }
  }

  String _providerName(SyncProvider provider) => switch (provider) {
    SyncProvider.gitee => 'Gitee',
    SyncProvider.github => 'GitHub',
    SyncProvider.gitlab => 'GitLab',
    SyncProvider.custom => '自定义 Git',
  };

  @override
  Widget build(BuildContext context) => ListView(
    children: [
      const _LocalFirstBanner(),
      const SizedBox(height: 14),
      AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionTitle(
              title: '连接 Git 仓库',
              subtitle: '使用内置 Git 连接你的私有仓库，不依赖系统 Git',
            ),
            const SizedBox(height: 12),
            for (final provider in const [
              (SyncProvider.gitee, 'Gitee', '国内访问友好，推荐首选', 'G'),
              (SyncProvider.github, 'GitHub', '使用个人访问令牌连接', 'GH'),
              (SyncProvider.gitlab, 'GitLab', '使用个人访问令牌连接', 'GL'),
            ])
              _ProviderRow(
                provider: provider,
                connected:
                    controller.syncService.config?.provider == provider.$1,
                onTap: () => _editConnection(context, provider.$1),
              ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionTitle(title: '当前同步状态', subtitle: '本地数据库始终是主数据源'),
            const SizedBox(height: 14),
            const _SettingRow(
              title: '本地剪切板',
              subtitle: '监听、历史、搜索、收藏和删除均可离线使用',
              trailing: StatusPill(label: '运行中'),
            ),
            const Divider(height: 1),
            _SettingRow(
              title: 'Git 云同步',
              subtitle: _syncSubtitle(),
              trailing: _syncStatusPill(),
            ),
            if (controller.syncService.config != null) ...[
              const Divider(height: 1),
              _SettingRow(
                title: '自动同步',
                subtitle: '启动后延迟同步，并按选定间隔定时同步',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButton<int>(
                      value: controller.syncService.config!.intervalMinutes,
                      underline: const SizedBox.shrink(),
                      items: const [5, 10, 30]
                          .map(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text('$value 分钟'),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value != null) {
                          controller.saveSyncConfig(
                            controller.syncService.config!.copyWith(
                              intervalMinutes: value,
                            ),
                          );
                        }
                      },
                    ),
                    const SizedBox(width: 12),
                    Switch(
                      value: controller.syncService.config!.enabled,
                      onChanged: (value) => controller.saveSyncConfig(
                        controller.syncService.config!.copyWith(enabled: value),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Row(
                  children: [
                    TextButton(
                      onPressed: () => _editConnection(
                        context,
                        controller.syncService.config!.provider,
                      ),
                      child: const Text('编辑连接'),
                    ),
                    TextButton(
                      onPressed: () async {
                        await controller.disconnectSync();
                        if (context.mounted) {
                          showMessage(context, '已断开云同步并移除本机令牌');
                        }
                      },
                      child: const Text('断开连接'),
                    ),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed:
                          controller.syncService.status ==
                                  CloudSyncStatus.syncing ||
                              !controller.syncService.config!.enabled
                          ? null
                          : () async {
                              final result = await controller.syncNow();
                              if (context.mounted) {
                                showMessage(
                                  context,
                                  result == null
                                      ? controller.syncService.lastError ??
                                            '同步失败'
                                      : '同步完成：导入 ${result.imported} 项，导出 ${result.exported} 项',
                                );
                              }
                            },
                      icon:
                          controller.syncService.status ==
                              CloudSyncStatus.syncing
                          ? const SizedBox.square(
                              dimension: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.sync_rounded, size: 17),
                      label: Text(
                        controller.syncService.status == CloudSyncStatus.syncing
                            ? '同步中…'
                            : '立即同步',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    ],
  );

  String _syncSubtitle() {
    final sync = controller.syncService;
    if (sync.config == null) return '选择上方服务并填写私有仓库与访问令牌';
    if (sync.lastError != null) return sync.lastError!;
    if (sync.lastSyncedAt != null) {
      return '上次同步：${relativeTime(sync.lastSyncedAt!)}';
    }
    return '${_providerName(sync.config!.provider)} · ${sync.config!.branch} 分支';
  }

  StatusPill _syncStatusPill() => switch (controller.syncService.status) {
    CloudSyncStatus.syncing => const StatusPill(
      label: '同步中',
      color: AppColors.primary,
      icon: Icons.sync_rounded,
    ),
    CloudSyncStatus.success => const StatusPill(
      label: '已同步',
      icon: Icons.cloud_done_outlined,
    ),
    CloudSyncStatus.error => const StatusPill(
      label: '同步失败',
      color: AppColors.danger,
      icon: Icons.error_outline_rounded,
    ),
    CloudSyncStatus.idle => StatusPill(
      label: controller.syncService.config == null ? '未配置' : '等待同步',
      color: AppColors.muted,
      icon: Icons.schedule_rounded,
    ),
  };
}

class _LocalFirstBanner extends StatelessWidget {
  const _LocalFirstBanner();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(17),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        colors: [Color(0xFF6C57E5), Color(0xFF8A74F2)],
      ),
      borderRadius: BorderRadius.circular(18),
    ),
    child: const Row(
      children: [
        Icon(Icons.cloud_done_outlined, color: Colors.white, size: 28),
        SizedBox(width: 13),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Local First · 本地优先',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
              SizedBox(height: 4),
              Text(
                '不登录、不联网、不配置 Git，也可以完整使用剪切板功能。',
                style: TextStyle(color: Color(0xFFECE8FF), fontSize: 11),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _ProviderRow extends StatelessWidget {
  const _ProviderRow({
    required this.provider,
    required this.connected,
    required this.onTap,
  });
  final (SyncProvider, String, String, String) provider;
  final bool connected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF9F9FB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.primarySoft,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Text(
              provider.$4,
              style: const TextStyle(
                color: AppColors.primary,
                fontWeight: FontWeight.w800,
                fontSize: 11,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  provider.$2,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(provider.$3, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: onTap,
            icon: Icon(
              connected ? Icons.check_circle_outline : Icons.link_rounded,
              size: 16,
            ),
            label: Text(connected ? '已连接' : '连接'),
          ),
        ],
      ),
    ),
  );
}

class _DevicesPage extends StatelessWidget {
  const _DevicesPage({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) => ListView(
    children: [
      AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionTitle(
              title: '我的设备',
              subtitle: controller.syncService.config == null
                  ? '当前为纯本地模式，共 ${controller.devices.length} 台设备'
                  : '从同步仓库识别到 ${controller.devices.length} 台设备',
            ),
            const SizedBox(height: 14),
            for (final device in controller.devices)
              Padding(
                padding: const EdgeInsets.only(bottom: 9),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF9F9FB),
                    border: Border.all(color: AppColors.line),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.desktop_windows_outlined,
                        color: AppColors.primary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              device.isCurrent
                                  ? '${device.name}（本机）'
                                  : device.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '${device.platform} · 最近同步 ${relativeTime(device.lastSeenAt)}',
                              style: const TextStyle(
                                fontSize: 10.5,
                                color: AppColors.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      StatusPill(label: device.isCurrent ? '当前' : '已同步'),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    ],
  );
}

class _PrivacyPage extends StatelessWidget {
  const _PrivacyPage({required this.controller});
  final AppController controller;

  Future<void> _confirmClear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空全部历史？'),
        content: const Text('全部记录（包括收藏）会被软删除，以便未来同步删除状态。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认清空'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await controller.clearHistory();
      if (context.mounted) showMessage(context, '已清空全部历史');
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    children: [
      AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionTitle(title: '隐私控制', subtitle: '随时暂停或恢复记录'),
            const SizedBox(height: 8),
            _SettingRow(
              title: '自动记录剪切板',
              subtitle: '关闭后不再捕获新的文本和图片',
              trailing: Switch(
                value: controller.recordingEnabled,
                onChanged: controller.setRecording,
              ),
            ),
            const Divider(height: 1),
            _SettingRow(
              title: '自动清理历史',
              subtitle: '收藏内容不会被自动清理',
              trailing: DropdownButton<int>(
                value: controller.autoCleanupDays,
                underline: const SizedBox.shrink(),
                borderRadius: BorderRadius.circular(10),
                items: const [
                  DropdownMenuItem(value: 0, child: Text('永不')),
                  DropdownMenuItem(value: 30, child: Text('30 天')),
                  DropdownMenuItem(value: 90, child: Text('90 天')),
                  DropdownMenuItem(value: 180, child: Text('180 天')),
                ],
                onChanged: (value) {
                  if (value != null) controller.setAutoCleanupDays(value);
                },
              ),
            ),
            const Divider(height: 1),
            _SettingRow(
              title: '清空历史',
              subtitle: '清空全部记录，并为未来同步保留删除状态',
              trailing: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.danger,
                ),
                onPressed: () => _confirmClear(context),
                icon: const Icon(Icons.delete_outline_rounded, size: 16),
                label: const Text('清空'),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionTitle(title: '本地统计', subtitle: '统计不会上传给开发者'),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _StatBox(
                    label: '本地历史',
                    value: '${controller.stats.history}',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _StatBox(
                    label: '收藏',
                    value: '${controller.stats.favorites}',
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: _StatBox(label: '设备', value: '1'),
                ),
              ],
            ),
          ],
        ),
      ),
    ],
  );
}

class _SettingsPage extends StatelessWidget {
  const _SettingsPage({required this.controller, required this.desktopService});
  final AppController controller;
  final DesktopService desktopService;

  @override
  Widget build(BuildContext context) => ListView(
    children: [
      AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionTitle(title: '快捷剪切板', subtitle: '日常高频使用入口'),
            const SizedBox(height: 8),
            if (desktopService.supportsWinV) ...[
              _SettingRow(
                title: '固定 Win + V 快捷键',
                subtitle:
                    controller.shortcutError ??
                    (desktopService.usesWinV
                        ? '已接管 Win + V，自定义快捷键已停用'
                        : '开启后使用 Win + V，关闭后恢复原自定义快捷键'),
                trailing: Switch(
                  key: const ValueKey('win-v-shortcut-switch'),
                  value: desktopService.usesWinV,
                  onChanged: controller.shortcutModeChanging
                      ? null
                      : (value) async {
                          final error = await desktopService
                              .setWinVShortcutEnabled(value);
                          if (context.mounted && error != null) {
                            showMessage(context, error);
                          }
                        },
                ),
              ),
              const Divider(height: 1),
            ],
            _SettingRow(
              title: '全局快捷键',
              enabled:
                  !desktopService.usesWinV && !controller.shortcutModeChanging,
              subtitle: desktopService.usesWinV
                  ? '当前仅使用 Win + V，原组合已保留，关闭上方开关后恢复'
                  : controller.shortcutError ?? '在任何应用上方呼出快捷剪切板，点击右侧修改',
              trailing: OutlinedButton.icon(
                key: const ValueKey('custom-shortcut-button'),
                onPressed:
                    desktopService.usesWinV || controller.shortcutModeChanging
                    ? null
                    : () async {
                        final error = await desktopService
                            .beginShortcutRecording();
                        if (error != null) {
                          if (context.mounted) showMessage(context, error);
                          return;
                        }
                        try {
                          if (!context.mounted) return;
                          final saved = await showDialog<bool>(
                            context: context,
                            barrierDismissible: false,
                            builder: (_) =>
                                ShortcutDialog(desktopService: desktopService),
                          );
                          if (saved == true && context.mounted) {
                            showMessage(context, '快捷键已更新');
                          }
                        } finally {
                          await desktopService.endShortcutRecording();
                        }
                      },
                label: Text(controller.quickShortcut.label()),
                icon: const Icon(Icons.keyboard_outlined, size: 18),
              ),
            ),
            const Divider(height: 1),
            _SettingRow(
              title: '快捷面板显示数量',
              subtitle: '无搜索词时只查询最近记录',
              trailing: DropdownButton<int>(
                value: controller.quickCount,
                underline: const SizedBox.shrink(),
                borderRadius: BorderRadius.circular(10),
                items: const [20, 30, 40, 50]
                    .map(
                      (value) => DropdownMenuItem(
                        value: value,
                        child: Text('$value 条'),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) controller.setQuickCount(value);
                },
              ),
            ),
            const Divider(height: 1),
            const _SettingRow(
              title: '搜索范围',
              subtitle: '输入关键词后自动切换到全部历史搜索',
              trailing: StatusPill(
                label: '智能搜索',
                color: AppColors.primary,
                icon: Icons.auto_awesome_outlined,
              ),
            ),
            const Divider(height: 1),
            _SettingRow(
              title: '历史保存数量',
              subtitle: '超出限制时自动清理最旧的非收藏记录',
              trailing: HistoryLimitPicker(controller: controller),
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionTitle(title: '应用行为', subtitle: '桌面端体验'),
            const SizedBox(height: 8),
            _SettingRow(
              title: '开机自动启动',
              subtitle: '登录系统后在后台启动 Idreaml Clip',
              trailing: Switch(
                value: controller.launchAtStartupEnabled,
                onChanged: (value) async {
                  try {
                    await desktopService.setLaunchAtStartup(value);
                  } catch (_) {
                    if (context.mounted) showMessage(context, '无法修改开机启动设置');
                  }
                },
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      const ReleaseInfoCard(),
    ],
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.subtitle});
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5),
      ),
      const SizedBox(height: 3),
      Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
    ],
  );
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    required this.title,
    required this.subtitle,
    required this.trailing,
    this.enabled = true,
  });
  final String title;
  final String subtitle;
  final Widget trailing;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: enabled ? 1 : 0.45,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 4),
                Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: 18),
          trailing,
        ],
      ),
    ),
  );
}

class _StatBox extends StatelessWidget {
  const _StatBox({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xFFF8F8FA),
      borderRadius: BorderRadius.circular(13),
      border: Border.all(color: AppColors.line),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 7),
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 20),
        ),
      ],
    ),
  );
}
