import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../app_controller.dart';
import '../desk/desk_models.dart';
import '../desk/desk_pages.dart';
import '../models/arrow_style.dart';
import '../models/clipboard_item.dart';
import '../models/json_document.dart';
import '../models/pinned_image_border.dart';
import '../services/json_preview_formatter.dart';
import '../models/sync_models.dart';
import '../models/workspace_layout.dart';
import '../screenshot/arrow_style_picker.dart';
import '../services/desktop_service.dart';
import '../services/directory_picker.dart';
import 'app_theme.dart';
import 'common.dart';
import 'clipboard_image.dart';
import 'shortcut_dialog.dart';
import 'shortcut_help.dart';
import 'resize_divider.dart';
import 'history_limit_picker.dart';
import 'json_split_preview.dart';
import 'release_info_card.dart';
import 'storage_directory_card.dart';
import 'sync_archive_browser.dart';

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
  _SettingsSection? _settingsSection;
  double _sidebarDragStartWidth = 216;
  late int _lastSettingsRequest = widget.controller.settingsSectionRequest;
  late final _searchController = TextEditingController(
    text: widget.controller.historySearch,
  );

  @override
  void didUpdateWidget(covariant MainShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller.page != AppPage.settings) _settingsSection = null;
    final request = widget.controller.settingsSectionRequest;
    if (request != _lastSettingsRequest) {
      _lastSettingsRequest = request;
      final section = widget.controller.requestedSettingsSection;
      if (section != null) {
        _settingsSection = _SettingsSection.values.byName(section);
      }
    }
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
                          _settingsSection = null;
                          _searchController.clear();
                          controller.historySearch = '';
                          controller.setPage(page);
                          if (page == AppPage.settings) {
                            widget.desktopService.refreshStartupState();
                          }
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
                            settingsSection: _settingsSection,
                            onSettingsBack: () =>
                                setState(() => _settingsSection = null),
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
                                settingsSection: _settingsSection,
                                onSettingsSection: (value) =>
                                    setState(() => _settingsSection = value),
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
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              children: [
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
                if (!compact &&
                    DeskKind.values.any(
                      (kind) => controller.desktopNotes?.enabled(kind) == true,
                    ))
                  const _NavLabel('桌面'),
                for (final kind in DeskKind.values)
                  if (controller.desktopNotes?.enabled(kind) == true)
                    _NavItem(
                      compact: compact,
                      icon: kind == DeskKind.note
                          ? Icons.sticky_note_2_outlined
                          : Icons.checklist_outlined,
                      label: kind.label,
                      trailing:
                          '${controller.desktopNotes!.items(kind).where((entry) => kind == DeskKind.note || !entry.done).length}',
                      selected:
                          controller.page ==
                          (kind == DeskKind.note
                              ? AppPage.notes
                              : AppPage.todos),
                      onTap: () => onPage(
                        kind == DeskKind.note ? AppPage.notes : AppPage.todos,
                      ),
                    ),
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
              ],
            ),
          ),
        ),
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
                            ? '配置你自己的 Git 仓库'
                            : '${_providerLabel(controller.syncService.config!.provider)} · 每 ${controller.syncService.config!.intervalMinutes} 分钟同步',
                        style: const TextStyle(
                          fontSize: 9.5,
                          color: AppColors.muted,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FutureBuilder<Map<String, dynamic>>(
                    future: releaseInfo,
                    builder: (context, snapshot) {
                      final version = snapshot.data?['version'];
                      return Text(
                        '本地优先，内容由你掌控${version == null ? '' : '\nv$version'}',
                        key: const ValueKey('sidebar-version-hint'),
                        style: const TextStyle(
                          fontSize: 9.5,
                          color: AppColors.muted,
                          height: 1.6,
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

String _providerLabel(SyncProvider provider) => switch (provider) {
  SyncProvider.gitee => 'Gitee',
  SyncProvider.github => 'GitHub',
  SyncProvider.gitlab => 'GitLab',
  SyncProvider.custom => '自托管 Git',
};

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
    required this.settingsSection,
    required this.onSettingsBack,
  });
  final AppController controller;
  final TextEditingController searchController;
  final DesktopService desktopService;
  final _SettingsSection? settingsSection;
  final VoidCallback onSettingsBack;

  static const titles = {
    AppPage.history: ('全部历史', '长期保存的本地剪切板记录'),
    AppPage.favorites: ('我的收藏', '长期保留的重要内容'),
    AppPage.notes: ('便签', '随手记录，独立保存'),
    AppPage.todos: ('待办', '安排事项，记录完成进度'),
    AppPage.sync: ('云同步', '使用你自己的 Git 仓库'),
    AppPage.devices: ('设备', '管理参与同步的设备'),
    AppPage.privacy: ('隐私', '本地优先，内容由你掌控'),
    AppPage.settings: ('设置', '按类别管理使用偏好'),
  };

  @override
  Widget build(BuildContext context) {
    final section = settingsSection;
    final title = section == null
        ? titles[controller.page]!
        : (section.title, section.description(desktopService));
    final showSearch =
        controller.page == AppPage.history ||
        controller.page == AppPage.favorites;
    return SizedBox(
      height: 84,
      child: Row(
        children: [
          if (section != null)
            Padding(
              padding: const EdgeInsets.only(left: 14),
              child: IconButton(
                tooltip: '返回设置首页',
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: onSettingsBack,
              ),
            ),
          Expanded(
            child: DragToMoveArea(
              child: Padding(
                padding: EdgeInsets.only(left: section == null ? 22 : 6),
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
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
  const _CurrentPage({
    required this.controller,
    required this.desktopService,
    required this.settingsSection,
    required this.onSettingsSection,
  });
  final AppController controller;
  final DesktopService desktopService;
  final _SettingsSection? settingsSection;
  final ValueChanged<_SettingsSection> onSettingsSection;

  @override
  Widget build(BuildContext context) {
    switch (controller.page) {
      case AppPage.history:
      case AppPage.favorites:
        return _HistoryWorkspace(
          controller: controller,
          desktopService: desktopService,
        );
      case AppPage.sync:
        return _SyncPage(
          controller: controller,
          desktopService: desktopService,
        );
      case AppPage.notes:
      case AppPage.todos:
        final notes = controller.desktopNotes;
        if (notes == null) return const Center(child: Text('当前平台暂未支持'));
        return DeskPage(
          key: ValueKey(controller.page),
          notes: notes,
          kind: controller.page == AppPage.notes
              ? DeskKind.note
              : DeskKind.todo,
          selectedId: controller.selectedDeskId,
          viewRequest: controller.deskViewRequest,
          onViewed: () => controller.selectedDeskId = null,
        );
      case AppPage.devices:
        return _DevicesPage(controller: controller);
      case AppPage.privacy:
        return _PrivacyPage(controller: controller);
      case AppPage.settings:
        return _SettingsPage(
          controller: controller,
          desktopService: desktopService,
          section: settingsSection,
          onSection: onSettingsSection,
        );
    }
  }
}

class _HistoryWorkspace extends StatefulWidget {
  const _HistoryWorkspace({
    required this.controller,
    required this.desktopService,
  });
  final AppController controller;
  final DesktopService desktopService;

  @override
  State<_HistoryWorkspace> createState() => _HistoryWorkspaceState();
}

class _HistoryWorkspaceState extends State<_HistoryWorkspace> {
  double _historyDragStartWidth = 0;
  AppController get controller => widget.controller;

  Future<void> _pinItem(ClipboardItem item) async {
    try {
      await widget.desktopService.pinHistoryImage(item);
    } catch (error) {
      if (mounted) showMessage(context, '$error');
    }
  }

  Future<void> _showRowMenu(
    BuildContext context,
    ClipboardItem item,
    Offset position,
  ) async {
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        const PopupMenuItem(value: 'copy', child: Text('复制')),
        PopupMenuItem(
          value: 'favorite',
          child: Text(item.favorite ? '取消收藏' : '收藏'),
        ),
        if (controller.page != AppPage.favorites)
          const PopupMenuItem(value: 'delete', child: Text('删除历史记录')),
        if (item.isImage) const PopupMenuItem(value: 'pin', child: Text('贴图')),
      ],
    );
    if (!context.mounted || selected == null) return;
    switch (selected) {
      case 'copy':
        final copied = await controller.useItem(item);
        if (context.mounted) {
          showMessage(
            context,
            copied ? '已复制到系统剪切板' : controller.clipboardError ?? '复制失败',
          );
        }
      case 'favorite':
        final wasFavorite = item.favorite;
        await controller.toggleFavorite(item.id);
        if (context.mounted) {
          showMessage(context, wasFavorite ? '已取消收藏' : '已收藏');
        }
      case 'delete':
        await controller.deleteItem(item.id);
        if (context.mounted) {
          showMessage(context, item.favorite ? '历史记录已删除，收藏内容保留' : '历史记录已删除');
        }
      case 'pin':
        await _pinItem(item);
    }
  }

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
                          '${controller.historyMatchCount} 条${controller.page == AppPage.favorites ? '收藏' : '记录'}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        if (controller.historyPage > 0 ||
                            controller.hasNextHistoryPage) ...[
                          const SizedBox(width: 6),
                          ListPageButtons(
                            page: controller.historyPage,
                            hasNext: controller.hasNextHistoryPage,
                            onChange: controller.changeHistoryPage,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: controller.history.isEmpty
                        ? EmptyState(
                            title: controller.historySearch.isNotEmpty
                                ? '没有找到匹配记录'
                                : controller.page == AppPage.favorites
                                ? '还没有收藏内容'
                                : '还没有剪切板记录',
                            subtitle: controller.historySearch.isNotEmpty
                                ? '试试更短的关键词'
                                : controller.page == AppPage.favorites
                                ? '点击记录旁的星标，保存重要内容'
                                : '复制文本或图片后会自动保存在本机',
                          )
                        : ListView.separated(
                            key: ValueKey(controller.historyPage),
                            padding: const EdgeInsets.all(8),
                            itemCount: controller.history.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 2),
                            itemBuilder: (context, index) {
                              final item = controller.history[index];
                              final source = item.sourceApp?.trim();
                              return _HistoryItem(
                                key: ValueKey(item.id),
                                item: item,
                                metaLabel:
                                    '${relativeTime(item.lastUsedAt)} · ${item.copyCount} 次 · '
                                    '${source == null || source.isEmpty ? deviceLabel(item, localDeviceId: controller.repository.localDeviceId) : source}',
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
                                onFavorite: () async {
                                  final wasFavorite = item.favorite;
                                  await controller.toggleFavorite(item.id);
                                  if (context.mounted) {
                                    showMessage(
                                      context,
                                      wasFavorite ? '已取消收藏' : '已收藏',
                                    );
                                  }
                                },
                                onDelete: controller.page == AppPage.favorites
                                    ? null
                                    : () async {
                                        await controller.deleteItem(item.id);
                                        if (context.mounted) {
                                          showMessage(
                                            context,
                                            item.favorite
                                                ? '历史记录已删除，收藏内容保留'
                                                : '历史记录已删除',
                                          );
                                        }
                                      },
                                onContextMenu: (position) =>
                                    _showRowMenu(context, item, position),
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
                key: ValueKey(controller.selectedHistory?.contentHash),
                item: controller.selectedHistory,
                sourceDevice: controller.selectedHistory == null
                    ? null
                    : deviceLabel(
                        controller.selectedHistory!,
                        localDeviceId: controller.repository.localDeviceId,
                      ),
                onCopyFormatted: controller.selectedHistory == null
                    ? null
                    : (text) => controller.useFormattedText(
                        controller.selectedHistory!,
                        text,
                      ),
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
                    : () async {
                        final item = controller.selectedHistory!;
                        final wasFavorite = item.favorite;
                        await controller.toggleFavorite(item.id);
                        if (context.mounted) {
                          showMessage(context, wasFavorite ? '已取消收藏' : '已收藏');
                        }
                      },
                onDelete:
                    controller.page == AppPage.favorites ||
                        controller.selectedHistory == null
                    ? null
                    : () async {
                        final item = controller.selectedHistory!;
                        await controller.deleteItem(item.id);
                        if (context.mounted) {
                          showMessage(
                            context,
                            item.favorite ? '历史记录已删除，收藏内容保留' : '历史记录已删除',
                          );
                        }
                      },
                onPin: controller.selectedHistory?.isImage == true
                    ? () => _pinItem(controller.selectedHistory!)
                    : null,
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

class _HistoryItem extends StatefulWidget {
  const _HistoryItem({
    super.key,
    required this.item,
    required this.metaLabel,
    required this.selected,
    required this.onTap,
    required this.onUse,
    required this.onFavorite,
    required this.onDelete,
    this.onContextMenu,
  });
  final ClipboardItem item;
  final String metaLabel;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onUse;
  final VoidCallback onFavorite;
  final VoidCallback? onDelete;
  final void Function(Offset position)? onContextMenu;

  @override
  State<_HistoryItem> createState() => _HistoryItemState();
}

class _HistoryItemState extends State<_HistoryItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return LayoutBuilder(
      builder: (context, constraints) {
        final previewWidth = (constraints.maxWidth * .28).clamp(104.0, 144.0);
        final compactActions = item.isImage && constraints.maxWidth < 420;
        final showDelete = _hover || widget.selected;
        final actions = [
          IconButton(
            tooltip: item.favorite ? '取消收藏' : '收藏',
            onPressed: widget.onFavorite,
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
          if (widget.onDelete != null)
            SizedBox(
              width: 36,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 120),
                opacity: showDelete ? 1 : 0,
                child: IgnorePointer(
                  ignoring: !showDelete,
                  child: IconButton(
                    tooltip: '删除历史记录',
                    onPressed: widget.onDelete,
                    constraints: compactActions
                        ? const BoxConstraints.tightFor(width: 32, height: 32)
                        : null,
                    padding: compactActions ? EdgeInsets.zero : null,
                    icon: const Icon(
                      Icons.delete_outline_rounded,
                      size: 18,
                      color: AppColors.muted,
                    ),
                  ),
                ),
              ),
            ),
        ];
        return FocusableActionDetector(
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onUse();
                return null;
              },
            ),
          },
          child: MouseRegion(
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: Material(
              color: widget.selected
                  ? const Color(0xFFF7F5FF)
                  : Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(13),
                side: BorderSide(
                  color: widget.selected
                      ? const Color(0xFFE2DCFF)
                      : Colors.transparent,
                ),
              ),
              child: InkWell(
                onTap: widget.onTap,
                onDoubleTap: widget.onUse,
                onSecondaryTapUp: widget.onContextMenu == null
                    ? null
                    : (details) =>
                          widget.onContextMenu!(details.globalPosition),
                borderRadius: BorderRadius.circular(13),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      if (item.isImage)
                        Container(
                          key: ValueKey('history-image-preview-${item.id}'),
                          width: previewWidth,
                          height: previewWidth * .625,
                          decoration: BoxDecoration(
                            color: widget.selected
                                ? const Color(0xFFEFEAFF)
                                : const Color(0xFFF0F1F5),
                            border: Border.all(
                              color: widget.selected
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
                            color: widget.selected
                                ? const Color(0xFFE9E5FF)
                                : const Color(0xFFF0F1F5),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            item.isImage == false && item.typeLabel == 'JSON'
                                ? '{}'
                                : 'T',
                            style: TextStyle(
                              color: widget.selected
                                  ? AppColors.primary
                                  : AppColors.muted,
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
                              widget.metaLabel,
                              maxLines: item.isImage ? 2 : 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      if (compactActions)
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: actions,
                        )
                      else
                        ...actions,
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DetailCard extends StatefulWidget {
  const _DetailCard({
    super.key,
    required this.item,
    required this.onUse,
    required this.onFavorite,
    this.sourceDevice,
    this.onCopyFormatted,
    this.onDelete,
    this.onPin,
  });
  final ClipboardItem? item;
  final VoidCallback onUse;
  final VoidCallback? onFavorite;
  final String? sourceDevice;
  final Future<bool> Function(String formatted)? onCopyFormatted;
  final VoidCallback? onDelete;
  final VoidCallback? onPin;

  @override
  State<_DetailCard> createState() => _DetailCardState();
}

class _DetailCardState extends State<_DetailCard> {
  ClipboardItem? get item => widget.item;
  late final _preview = item == null || item!.isImage
      ? null
      : identifyJsonPreview(item!.content);

  @override
  Widget build(BuildContext context) => FutureBuilder<JsonDocument?>(
    future: _preview,
    builder: (context, snapshot) => _card(
      snapshot.data,
      parsing: snapshot.connectionState == ConnectionState.waiting,
    ),
  );

  Widget _card(JsonDocument? document, {required bool parsing}) => AppCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('内容详情', style: TextStyle(fontWeight: FontWeight.w700)),
            const Spacer(),
            StatusPill(
              label: item == null || parsing
                  ? '—'
                  : item!.isImage
                  ? item!.typeLabel
                  : document == null
                  ? 'TEXT'
                  : 'JSON',
              color: AppColors.primary,
              icon: item?.isImage == true
                  ? Icons.image_outlined
                  : document != null
                  ? Icons.data_object_rounded
                  : Icons.text_fields_rounded,
            ),
          ],
        ),
        const SizedBox(height: 14),
        Expanded(
          child: Container(
            width: double.infinity,
            padding: document != null
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
                : parsing
                ? const Center(child: CircularProgressIndicator())
                : document != null
                ? JsonSplitPreview(
                    key: ValueKey(item!.contentHash),
                    content: item!.content,
                    document: document,
                    onCopyFormatted: widget.onCopyFormatted,
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
          label: '创建时间',
          value: item == null ? '-' : relativeTime(item!.createdAt),
        ),
        const SizedBox(height: 7),
        _MetaRow(
          label: '最近使用',
          value: item == null ? '-' : relativeTime(item!.lastUsedAt),
        ),
        const SizedBox(height: 7),
        _MetaRow(
          label: '来源设备',
          value: item == null ? '-' : widget.sourceDevice ?? '-',
        ),
        const SizedBox(height: 7),
        _MetaRow(
          label: '使用次数',
          value: item == null ? '-' : '${item!.copyCount} 次',
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: item == null ? null : widget.onUse,
                icon: const Icon(Icons.copy_rounded, size: 16),
                label: Text(item?.isImage == true ? '复制图片' : '复制内容'),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.outlined(
              tooltip: item?.favorite == true ? '取消收藏' : '收藏',
              onPressed: widget.onFavorite,
              icon: Icon(
                item?.favorite == true
                    ? Icons.star_rounded
                    : Icons.star_border_rounded,
                color: item?.favorite == true ? AppColors.warning : null,
              ),
            ),
            if (widget.onDelete != null) ...[
              const SizedBox(width: 8),
              IconButton.outlined(
                tooltip: '删除历史记录',
                onPressed: widget.onDelete,
                icon: const Icon(
                  Icons.delete_outline_rounded,
                  color: AppColors.danger,
                ),
              ),
            ],
            if (widget.onPin != null) ...[
              const SizedBox(width: 8),
              IconButton.outlined(
                tooltip: '贴图',
                onPressed: widget.onPin,
                icon: const Icon(Icons.picture_in_picture_alt_rounded),
              ),
            ],
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
  const _SyncPage({required this.controller, required this.desktopService});
  final AppController controller;
  final DesktopService desktopService;

  Future<void> _importLegacy(BuildContext context) async {
    final connected = controller.syncService.config != null;
    final source = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入旧仓库'),
        content: const Text('将旧版仓库最新快照与本机数据合并。导入后，可以连接一个新的私有仓库上传。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          if (Platform.isWindows)
            TextButton(
              onPressed: () => Navigator.pop(context, 'folder'),
              child: const Text('选择仓库目录'),
            ),
          if (connected)
            FilledButton(
              onPressed: () => Navigator.pop(context, 'remote'),
              child: const Text('从当前连接导入'),
            ),
        ],
      ),
    );
    if (source == null || !context.mounted) return;
    try {
      Directory? checkout;
      if (source == 'folder') {
        final path = await DirectoryPicker.choose();
        if (path == null || !context.mounted) return;
        checkout = Directory(path);
      }
      final count = await controller.syncService.importRepository(
        checkout: checkout,
      );
      if (context.mounted) showMessage(context, '导入完成，合并了 $count 项变更。');
    } catch (error) {
      if (context.mounted) {
        showMessage(context, error is StateError ? error.message : '无法导入旧仓库。');
      }
    }
  }

  Future<void> _editConnection(
    BuildContext context,
    SyncProvider provider,
  ) async {
    final current = controller.syncService.config;
    final existing = current?.provider == provider ? current : null;
    final remote = TextEditingController(text: existing?.remoteUrl ?? '');
    final username = TextEditingController(text: existing?.username ?? '');
    final branch = TextEditingController(text: existing?.branch ?? 'main');
    final token = TextEditingController();
    final isSelfHosted = provider == SyncProvider.custom;
    final credentialLabel = isSelfHosted ? '密码或访问令牌' : '访问令牌';
    final example = switch (provider) {
      SyncProvider.gitee => 'https://gitee.com/账号/仓库.git',
      SyncProvider.github => 'https://github.com/账号/仓库.git',
      SyncProvider.gitlab => 'https://gitlab.com/账号/仓库.git',
      SyncProvider.custom => 'https://git.example.com/团队/仓库.git',
    };
    String? error;
    var saving = false;
    var skipCertificate = existing?.skipCertificateVerification ?? false;
    var scheme = Uri.tryParse(remote.text.trim())?.scheme;
    final route = DialogRoute<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text('${_providerName(provider)} 仓库连接'),
          scrollable: true,
          content: SizedBox(
            width: 500,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: remote,
                  onChanged: isSelfHosted
                      ? (value) => setState(() {
                          scheme = Uri.tryParse(value.trim())?.scheme;
                        })
                      : null,
                  decoration: InputDecoration(
                    labelText: isSelfHosted
                        ? 'HTTP / HTTPS 克隆地址'
                        : 'HTTPS 克隆地址',
                    hintText: example,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: username,
                        decoration: const InputDecoration(labelText: 'Git 用户名'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: branch,
                        decoration: const InputDecoration(labelText: '同步分支'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: token,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: credentialLabel,
                    helperText: existing == null
                        ? '凭据加密保存在本机。'
                        : '仓库和账号不变时，可留空沿用已保存的凭据。',
                  ),
                ),
                if (isSelfHosted && scheme == 'https') ...[
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('跳过 HTTPS 证书校验'),
                    subtitle: const Text('仅用于你信任的服务器。开启后，应用无法验证服务器身份。'),
                    value: skipCertificate,
                    onChanged: saving
                        ? null
                        : (value) => setState(() => skipCertificate = value),
                  ),
                ],
                if (isSelfHosted && scheme == 'http') ...[
                  const SizedBox(height: 8),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'HTTP 会明文传输凭据和同步数据，请在可信网络中使用。',
                      style: TextStyle(color: AppColors.muted, fontSize: 12),
                    ),
                  ),
                ],
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
              onPressed: saving
                  ? null
                  : () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      setState(() {
                        saving = true;
                        error = null;
                      });
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
                            certificateExceptionUrl:
                                scheme == 'https' && skipCertificate
                                ? remote.text.trim()
                                : null,
                          ),
                          token: token.text,
                        );
                        if (dialogContext.mounted) {
                          Navigator.pop(dialogContext, true);
                        }
                      } catch (value) {
                        if (!dialogContext.mounted) return;
                        setState(() {
                          saving = false;
                          error = value is FormatException
                              ? value.message
                              : '无法保存连接，请检查本机数据目录后重试。';
                        });
                      }
                    },
              child: const Text('保存连接'),
            ),
          ],
        ),
      ),
    );
    final saved = await Navigator.of(context, rootNavigator: true).push(route);
    await route.completed;
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
    SyncProvider.custom => '自托管 Git',
  };

  @override
  Widget build(BuildContext context) => ListView(
    key: const ValueKey('cloud-sync-page'),
    children: [
      if (controller.syncService.config case final sync?) ...[
        AppCard(
          key: const ValueKey('sync-connected-header'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.cloud_done_outlined,
                    size: 22,
                    color: AppColors.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '云同步已连接',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${_providerLabel(sync.provider)} · ${sync.branch} 分支',
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  _syncStatusPill(),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: AppColors.canvas,
                  border: Border.all(color: AppColors.line),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  sync.remoteUrl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: AppColors.muted),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
      ],
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
              (
                SyncProvider.custom,
                '自托管 Git',
                '支持自己服务器上的 HTTP 和 HTTPS 克隆地址',
                'Git',
              ),
            ])
              _ProviderRow(
                provider: provider,
                connected:
                    controller.syncService.config?.provider == provider.$1,
                onTap: () => _editConnection(context, provider.$1),
              ),
            if (Platform.isWindows || controller.syncService.config != null)
              TextButton.icon(
                onPressed:
                    controller.syncService.status == CloudSyncStatus.syncing
                    ? null
                    : () => _importLegacy(context),
                icon: const Icon(Icons.folder_open_rounded, size: 16),
                label: const Text('导入旧仓库'),
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
            _SettingRow(
              title: 'Git 云同步',
              subtitle: _syncSubtitle(),
              trailing: _syncStatusPill(),
            ),
            if (controller.syncService.config?.skipCertificateVerification ==
                true)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  '当前连接已跳过 HTTPS 证书校验',
                  style: TextStyle(color: AppColors.danger, fontSize: 12),
                ),
              ),
            const Divider(height: 1),
            _moduleSyncRow(
              '剪切板',
              SyncModuleState.participating,
              controller.syncService.lastResult?.clipboard,
            ),
            for (final kind in DeskKind.values) ...[
              const Divider(height: 1),
              _moduleSyncRow(
                kind.label,
                controller.desktopNotes?.syncState(kind) ??
                    SyncModuleState.unavailable,
                kind == DeskKind.note
                    ? controller.syncService.lastResult?.notes
                    : controller.syncService.lastResult?.todos,
                onConfigure: () => controller.openSettingsSection('desktop'),
              ),
            ],
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                '导入统计本次合入的变更，导出快照统计写入仓库的完整记录数（含删除状态）。',
                style: TextStyle(color: AppColors.muted, fontSize: 12),
              ),
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
              _SettingRow(
                title: '启动时自动同步',
                subtitle: '应用启动并连接仓库后，立即执行一次同步',
                trailing: Switch(
                  key: const ValueKey('sync-on-startup'),
                  value: controller.syncService.config!.syncOnStartup,
                  onChanged: (value) => controller.saveSyncConfig(
                    controller.syncService.config!.copyWith(
                      syncOnStartup: value,
                    ),
                  ),
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
                      key: const ValueKey('open-archive-browser'),
                      onPressed: () => showSyncArchiveBrowser(
                        context,
                        sync: controller.syncService,
                        screenshots: desktopService.screenshots,
                      ),
                      child: const Text('查看仓库目录'),
                    ),
                    TextButton(
                      onPressed: () async {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('断开同步连接？'),
                            content: const Text(
                              '断开后，本机历史与收藏仍保留在本机，云端仓库不受影响；本机保存的凭据会被移除。',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: const Text('取消'),
                              ),
                              FilledButton(
                                style: FilledButton.styleFrom(
                                  backgroundColor: AppColors.danger,
                                ),
                                onPressed: () => Navigator.pop(context, true),
                                child: const Text('断开连接'),
                              ),
                            ],
                          ),
                        );
                        if (confirmed != true || !context.mounted) return;
                        try {
                          await controller.disconnectSync();
                          if (context.mounted) {
                            showMessage(context, '已断开云同步并移除本机凭据');
                          }
                        } catch (_) {
                          if (context.mounted) {
                            showMessage(context, '未能完成断开操作，请检查本机数据目录。');
                          }
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
                                      : '同步完成\n${result.description}',
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
      const SizedBox(height: 14),
      _SyncHistoryCard(
        entries: controller.syncService.history,
        unavailable: controller.syncService.historyUnavailable,
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

  Widget _moduleSyncRow(
    String name,
    SyncModuleState state,
    SyncModuleResult? previous, {
    VoidCallback? onConfigure,
  }) {
    final cloud = controller.syncService.config;
    var label = state.label;
    var detail = switch (state) {
      SyncModuleState.featureDisabled => '在设置 → 便签与待办中启用$name。',
      SyncModuleState.syncDisabled => '在设置 → 便签与待办中开启“同步$name”。',
      SyncModuleState.unavailable => '当前平台未提供此模块。',
      SyncModuleState.participating => '本机每次云同步都会导入并导出$name。',
    };
    if (state == SyncModuleState.participating && cloud == null) {
      label = '未配置仓库';
      detail = '保存上方仓库连接后，$name将参与同步。';
    } else if (state == SyncModuleState.participating &&
        cloud?.enabled == false) {
      label = '云同步已暂停';
      detail = '开启下方云同步开关后，$name将参与同步。';
    }
    if (previous != null) detail += '\n上次完成 · ${previous.description}';
    final row = _SettingRow(
      title: '$name同步',
      subtitle: detail,
      trailing: StatusPill(
        label: label,
        color: state == SyncModuleState.participating && cloud?.enabled == true
            ? AppColors.success
            : AppColors.muted,
      ),
    );
    if (onConfigure == null) return row;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row,
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: ValueKey('module-settings-$name'),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              foregroundColor: AppColors.primary,
              textStyle: const TextStyle(fontSize: 12),
            ),
            onPressed: onConfigure,
            child: const Text('前往模块设置 →'),
          ),
        ),
      ],
    );
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

class _SyncHistoryCard extends StatelessWidget {
  const _SyncHistoryCard({required this.entries, required this.unavailable});

  final List<SyncHistoryEntry> entries;
  final bool unavailable;

  @override
  Widget build(BuildContext context) => AppCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: _SectionTitle(title: '同步记录', subtitle: '本机保留最近 7 天'),
            ),
            Text(
              '${entries.length} 条',
              key: const ValueKey('sync-history-count'),
              style: const TextStyle(fontSize: 11, color: AppColors.muted),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (unavailable)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('同步记录暂时无法保存或读取，请检查数据目录。'),
          ),
        if (entries.isEmpty)
          const Text(
            '完成第一次同步后，记录会显示在这里。',
            style: TextStyle(color: AppColors.muted),
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: ListView.separated(
              primary: false,
              shrinkWrap: true,
              itemCount: entries.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final entry = entries[index];
                final localizations = MaterialLocalizations.of(context);
                final time = entry.completedAt.toLocal();
                final date = localizations.formatCompactDate(time);
                final clock = localizations.formatTimeOfDay(
                  TimeOfDay.fromDateTime(time),
                  alwaysUse24HourFormat: true,
                );
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 8,
                    horizontal: 2,
                  ),
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
                            color: entry.succeeded
                                ? AppColors.success
                                : AppColors.danger,
                          ),
                          Text('$date $clock · ${entry.trigger.label}'),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        entry.details,
                        style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    ),
  );
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
  Widget build(BuildContext context) {
    // Legacy rows without a machine id cannot be merged by number.
    final devices = controller.devices
        .where((device) => device.shortMachineId != null)
        .toList();
    return ListView(
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SectionTitle(
                title: '我的设备',
                subtitle: controller.syncService.config == null
                    ? '当前为纯本地模式，共 ${devices.length} 台设备'
                    : '从同步仓库识别到 ${devices.length} 台设备',
              ),
              const SizedBox(height: 14),
              if (devices.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 10),
                  child: Text(
                    '还没有带设备编号的设备记录。安装新版本后，设备会自动登记编号并出现在这里。',
                    style: TextStyle(fontSize: 12, color: AppColors.muted),
                  ),
                ),
              for (final device in devices)
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
                                '设备编号 ${device.shortMachineId}',
                                style: const TextStyle(
                                  fontSize: 10.5,
                                  color: AppColors.muted,
                                ),
                              ),
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
                        StatusPill(
                          label: device.isCurrent ? '当前设备' : '已记录',
                          color: device.isCurrent
                              ? AppColors.primary
                              : AppColors.muted,
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 4),
              const Text(
                '按完整设备编号合并。同名且编号不同的设备分别显示，改名后展示最新名称。',
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.muted,
                  height: 1.6,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PrivacyPage extends StatelessWidget {
  const _PrivacyPage({required this.controller});
  final AppController controller;

  Future<void> _confirmClear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空全部历史？'),
        content: const Text('全部历史中的所有记录都会移除，已收藏的内容仍可在收藏中查看。历史删除状态会同步到其他设备。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空全部历史'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await controller.clearHistory();
      if (context.mounted) showMessage(context, '已清空全部历史，收藏内容已保留');
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    children: [
      AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionTitle(title: '隐私控制', subtitle: '管理历史清空与本地统计'),
            const SizedBox(height: 8),
            _SettingRow(
              title: '清空历史',
              subtitle: '移除全部历史中的记录，收藏列表保留',
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
                    label: '全部历史',
                    value: '${controller.stats.history}',
                    caption: '条本机记录',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _StatBox(
                    label: '我的收藏',
                    value: '${controller.stats.favorites}',
                    caption: '条长期保留',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _StatBox(
                    label: '独立桌面内容',
                    value:
                        '${(controller.desktopNotes?.items(DeskKind.note).length ?? 0) + (controller.desktopNotes?.items(DeskKind.todo).length ?? 0)}',
                    caption: '条便签与待办',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.shield_outlined, size: 18, color: AppColors.primary),
                SizedBox(width: 8),
                Text(
                  '你的内容，由你掌控',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              '文字、图片和设置保存在本地。便签与待办独立于剪切板历史。启用云同步后，选择的内容会保存到你配置的 Git 仓库。',
              style: TextStyle(
                fontSize: 11.5,
                color: AppColors.muted,
                height: 1.7,
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

enum _SettingsSection {
  shortcuts('快捷键', Icons.keyboard_alt_outlined),
  history('快捷面板与历史', Icons.history_rounded),
  screenshot('截图与贴图', Icons.screenshot_monitor_outlined),
  desktop('便签与待办', Icons.sticky_note_2_outlined),
  startup('启动与权限', Icons.power_settings_new_rounded),
  release('版本信息', Icons.info_outline_rounded);

  const _SettingsSection(this.title, this.icon);
  final String title;
  final IconData icon;

  String description(DesktopService desktop) => switch (this) {
    shortcuts => [
      '快捷剪切板',
      if (desktop.supportsWinV) 'Win + V',
      if (desktop.screenshots.supported) '截图快捷键',
    ].join('、'),
    history => '显示数量、搜索范围、历史保存与数据存储',
    screenshot => '取色器、长截图、箭头样式与贴图边框',
    _SettingsSection.desktop => '功能开关、桌面区域、主题与独立同步',
    startup => desktop.administrator.supported ? '开机自动启动、管理员权限' : '开机自动启动',
    release => '查看当前版本及更新记录',
  };
}

class _SettingsPage extends StatelessWidget {
  const _SettingsPage({
    required this.controller,
    required this.desktopService,
    required this.section,
    required this.onSection,
  });
  final AppController controller;
  final DesktopService desktopService;
  final _SettingsSection? section;
  final ValueChanged<_SettingsSection> onSection;

  @override
  Widget build(BuildContext context) {
    final current = section;
    if (current == null) {
      final sections = [
        _SettingsSection.shortcuts,
        _SettingsSection.history,
        if (desktopService.screenshots.supported) _SettingsSection.screenshot,
        if (controller.desktopNotes != null) _SettingsSection.desktop,
        _SettingsSection.startup,
        _SettingsSection.release,
      ];
      return LayoutBuilder(
        builder: (context, constraints) {
          // Keep every card at least 260 wide so text never squashes into
          // extra lines while the window is being resized or snapped.
          final columns = ((constraints.maxWidth + 14) / 274).floor().clamp(
            1,
            3,
          );
          final width = (constraints.maxWidth - 14 * (columns - 1)) / columns;
          return ListView(
            key: const PageStorageKey('settings-index'),
            children: [
              Wrap(
                spacing: 14,
                runSpacing: 14,
                children: [
                  for (final group in sections)
                    SizedBox(
                      width: width,
                      height: 92,
                      child: AppCard(
                        padding: EdgeInsets.zero,
                        child: InkWell(
                          key: ValueKey('settings-card-${group.name}'),
                          borderRadius: BorderRadius.circular(18),
                          onTap: () => onSection(group),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Row(
                              children: [
                                Container(
                                  width: 38,
                                  height: 38,
                                  decoration: BoxDecoration(
                                    color: AppColors.primarySoft,
                                    borderRadius: BorderRadius.circular(11),
                                  ),
                                  child: Icon(
                                    group.icon,
                                    size: 19,
                                    color: AppColors.primary,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        group.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        group.description(desktopService),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 11,
                                          height: 1.5,
                                          color: AppColors.muted,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const Icon(
                                  Icons.chevron_right_rounded,
                                  size: 18,
                                  color: AppColors.muted,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      );
    }
    if (current == _SettingsSection.desktop &&
        controller.desktopNotes != null) {
      return DeskSettingsPage(notes: controller.desktopNotes!);
    }
    final rows = _rows(context, current);
    return ListView(
      key: PageStorageKey(current),
      children: [
        if (current == _SettingsSection.release) const ReleaseInfoCard(),
        if (rows.isNotEmpty)
          AppCard(
            child: Column(
              children: [
                for (final (index, row) in rows.indexed) ...[
                  if (index > 0) const Divider(height: 1),
                  row,
                ],
              ],
            ),
          ),
        if (current == _SettingsSection.history &&
            controller.storagePath != null) ...[
          const SizedBox(height: 14),
          StorageDirectoryCard(
            controller: controller,
            onRestart: desktopService.restartApplication,
          ),
        ],
      ],
    );
  }

  List<Widget> _rows(
    BuildContext context,
    _SettingsSection group,
  ) => switch (group) {
    _SettingsSection.desktop => [],
    _SettingsSection.shortcuts => [
      if (desktopService.supportsWinV)
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
                    final error = await desktopService.setWinVShortcutEnabled(
                      value,
                    );
                    if (context.mounted && error != null) {
                      showMessage(context, error);
                    }
                  },
          ),
        ),
      _SettingRow(
        title: '全局快捷键',
        enabled: !desktopService.usesWinV && !controller.shortcutModeChanging,
        subtitle: desktopService.usesWinV
            ? '当前仅使用 Win + V，原组合已保留，关闭上方开关后恢复'
            : controller.shortcutError ?? '在任何应用上方呼出快捷剪切板，点击右侧修改',
        trailing: OutlinedButton.icon(
          key: const ValueKey('custom-shortcut-button'),
          onPressed: desktopService.usesWinV || controller.shortcutModeChanging
              ? null
              : () async {
                  final error = await desktopService.beginShortcutRecording();
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
      if (desktopService.screenshots.supported)
        _SettingRow(
          title: '截图快捷键',
          subtitle: controller.screenshotError ?? '默认 F1，独立于快捷剪切板快捷键',
          trailing: OutlinedButton.icon(
            key: const ValueKey('screenshot-shortcut-button'),
            onPressed: () async {
              final error = await desktopService.beginShortcutRecording(
                screenshot: true,
              );
              if (error != null) {
                if (context.mounted) showMessage(context, error);
                return;
              }
              try {
                if (!context.mounted) return;
                final saved = await showDialog<bool>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => ShortcutDialog(
                    desktopService: desktopService,
                    screenshot: true,
                  ),
                );
                if (saved == true && context.mounted) {
                  showMessage(context, '快捷键已更新');
                }
              } finally {
                await desktopService.endShortcutRecording();
              }
            },
            icon: const Icon(Icons.screenshot_monitor_outlined, size: 18),
            label: Text(controller.screenshotShortcut.label()),
          ),
        ),
      if (controller.desktopNotes != null)
        _SettingRow(
          title: '便签与待办快捷键',
          subtitle: '单按 F3 新建便签，快速双按 F3 新建待办',
          trailing: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: AppColors.canvas,
              border: Border.all(color: AppColors.line),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Text(
              'F3',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.text,
              ),
            ),
          ),
        ),
      _SettingRow(
        title: '全部快捷键说明',
        subtitle: '按使用场景查看操作说明，自定义快捷键随设置同步更新',
        trailing: OutlinedButton.icon(
          key: const ValueKey('all-shortcut-help-button'),
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => AllShortcutHelpDialog(
              controller: controller,
              supportsWinV: desktopService.supportsWinV,
              supportsScreenshots: desktopService.screenshots.supported,
            ),
          ),
          icon: const Icon(Icons.help_outline_rounded, size: 18),
          label: const Text('查看说明'),
        ),
      ),
    ],
    _SettingsSection.screenshot => [
      _SettingRow(
        title: '开始截图时显示取色器',
        subtitle: '截图中按 F2 临时显示或隐藏，按 C 复制当前 HEX 色值并退出',
        trailing: Switch(
          value: controller.showScreenshotColorPicker,
          onChanged: (enabled) async {
            try {
              await controller.saveShowScreenshotColorPicker(enabled);
            } catch (_) {
              if (context.mounted) {
                showMessage(context, '取色器设置保存失败，请重试');
              }
            }
          },
        ),
      ),
      _SettingRow(
        title: '长截图滚动方式',
        subtitle: '自动滚动停止后可以查看预览，点击完成才进入编辑',
        trailing: DropdownButton<bool>(
          key: const ValueKey('scroll-capture-mode'),
          value: controller.autoScrollCapture,
          underline: const SizedBox.shrink(),
          items: const [
            DropdownMenuItem(value: false, child: Text('手动滚动')),
            DropdownMenuItem(value: true, child: Text('自动滚动')),
          ],
          onChanged: (value) async {
            if (value == null || value == controller.autoScrollCapture) {
              return;
            }
            try {
              await controller.saveAutoScrollCapture(value);
            } catch (_) {
              if (context.mounted) {
                showMessage(context, '长截图滚动方式保存失败，请重试');
              }
            }
          },
        ),
      ),
      _SettingRow(
        title: '默认箭头样式',
        subtitle: '「默认」沿用上次选择的样式，编辑时也可以临时切换',
        trailing: DropdownButton<String>(
          value: controller.defaultArrowStyle?.name ?? 'last',
          underline: const SizedBox.shrink(),
          borderRadius: BorderRadius.circular(10),
          items: [
            const DropdownMenuItem(value: 'last', child: Text('默认')),
            for (final style in ArrowStyle.values)
              DropdownMenuItem(
                value: style.name,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ArrowStylePreview(style: style),
                    const SizedBox(width: 8),
                    Text(style.label),
                  ],
                ),
              ),
          ],
          onChanged: (name) async {
            if (name == null) return;
            try {
              await controller.saveDefaultArrowStyle(ArrowStyle.tryParse(name));
            } catch (_) {
              if (context.mounted) showMessage(context, '默认箭头样式保存失败，请重试');
            }
          },
        ),
      ),
      _SettingRow(
        title: '贴图默认边框',
        subtitle: '应用到新贴图和已选择「跟随全局设置」的贴图',
        trailing: DropdownButton<PinnedImageBorder>(
          value: controller.pinnedImageBorder,
          underline: const SizedBox.shrink(),
          borderRadius: BorderRadius.circular(10),
          items: [
            for (final border in PinnedImageBorder.values)
              DropdownMenuItem(
                value: border,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 16,
                      height: 16,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: border.color,
                        border: Border.all(color: AppColors.line),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: border == PinnedImageBorder.none
                          ? const Icon(
                              Icons.block,
                              size: 12,
                              color: AppColors.muted,
                            )
                          : null,
                    ),
                    const SizedBox(width: 8),
                    Text(border.label),
                  ],
                ),
              ),
          ],
          onChanged: (border) async {
            if (border == null) return;
            try {
              await desktopService.screenshots.savePinBorderDefault(border);
            } catch (_) {
              if (context.mounted) {
                showMessage(context, '贴图边框更新失败，请重试');
              }
            }
          },
        ),
      ),
      if (desktopService.screenshots.supported)
        _SettingRow(
          title: '体验截图与贴图',
          subtitle: '可框选、绘图、取色、长截图，并将结果加入历史',
          trailing: Builder(
            builder: (buttonContext) => FilledButton.icon(
              key: const ValueKey('try-screenshot-button'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                final box = buttonContext.findRenderObject()! as RenderBox;
                final point =
                    box.localToGlobal(box.size.center(Offset.zero)) *
                    View.of(buttonContext).devicePixelRatio;
                desktopService.screenshots.start(buttonPoint: point);
              },
              icon: const Icon(Icons.screenshot_monitor_outlined, size: 17),
              label: const Text('开始截图'),
            ),
          ),
        ),
    ],
    _SettingsSection.history => [
      _SettingRow(
        title: '快捷面板显示数量',
        subtitle: '无搜索词时只查询最近记录',
        trailing: DropdownButton<int>(
          value: controller.quickCount,
          underline: const SizedBox.shrink(),
          borderRadius: BorderRadius.circular(10),
          items: const [20, 30, 40, 50]
              .map(
                (value) =>
                    DropdownMenuItem(value: value, child: Text('$value 条')),
              )
              .toList(),
          onChanged: (value) {
            if (value != null) controller.setQuickCount(value);
          },
        ),
      ),
      const _SettingRow(
        title: '搜索范围',
        subtitle: '输入关键词后自动切换到全部历史搜索',
        trailing: StatusPill(
          label: '智能搜索',
          color: AppColors.primary,
          icon: Icons.auto_awesome_outlined,
        ),
      ),
      _SettingRow(
        title: '历史保存数量',
        subtitle: '超出限制时自动清理最旧的非收藏记录',
        trailing: HistoryLimitPicker(controller: controller),
      ),
      _SettingRow(
        title: '自动清理历史',
        subtitle: '按保存时长定期清理历史记录，收藏内容不会被自动清理',
        trailing: DropdownButton<int>(
          key: const ValueKey('auto-cleanup-days'),
          value: controller.autoCleanupDays,
          underline: const SizedBox.shrink(),
          borderRadius: BorderRadius.circular(10),
          items: const [
            DropdownMenuItem(value: 0, child: Text('不自动清理')),
            DropdownMenuItem(value: 7, child: Text('7 天')),
            DropdownMenuItem(value: 30, child: Text('30 天')),
            DropdownMenuItem(value: 90, child: Text('90 天')),
            DropdownMenuItem(value: 180, child: Text('180 天')),
          ],
          onChanged: (value) {
            if (value != null) controller.setAutoCleanupDays(value);
          },
        ),
      ),
    ],
    _SettingsSection.startup => [
      _SettingRow(
        title: '开机自动启动',
        subtitle: controller.launchAtStartupChanging
            ? '正在保存并校验开机启动设置…'
            : controller.launchAtStartupMessage ?? '登录系统后自动启动 Idreaml Clip',
        trailing: Switch(
          key: const ValueKey('launch-at-startup-switch'),
          value: controller.launchAtStartupEnabled,
          onChanged:
              controller.launchAtStartupChanging ||
                  controller.administratorChanging
              ? null
              : (value) async {
                  try {
                    await desktopService.setLaunchAtStartup(value);
                  } catch (_) {
                    if (context.mounted) {
                      showMessage(
                        context,
                        controller.launchAtStartupMessage ?? '无法修改开机启动设置',
                      );
                    }
                  }
                },
        ),
      ),
      if (desktopService.administrator.supported)
        _SettingRow(
          title: '以管理员身份启动',
          subtitle: controller.administratorChanging
              ? '正在等待 Windows 授权并准备重启…'
              : '${controller.isAdministrator ? '当前：管理员。' : '当前：普通权限。'}'
                    '${controller.administratorMessage ?? '开启后立即请求授权并重启，以后每次启动默认请求管理员权限。'}',
          trailing: Switch(
            key: const ValueKey('run-as-administrator-switch'),
            value: controller.runAsAdministratorEnabled,
            onChanged:
                controller.administratorChanging || controller.storageChanging
                ? null
                : (value) async {
                    final message = await desktopService
                        .setRunAsAdministratorEnabled(value);
                    if (context.mounted && message != null) {
                      showMessage(context, message);
                    }
                  },
          ),
        ),
    ],
    _SettingsSection.release => [],
  };
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
  const _StatBox({required this.label, required this.value, this.caption});
  final String label;
  final String value;
  final String? caption;

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
        if (caption != null) ...[
          const SizedBox(height: 4),
          Text(caption!, style: Theme.of(context).textTheme.bodySmall),
        ],
      ],
    ),
  );
}
