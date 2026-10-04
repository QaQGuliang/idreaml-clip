import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../app_controller.dart';
import '../models/clipboard_item.dart';
import '../services/desktop_service.dart';
import '../services/clipboard_image_codec.dart';
import '../services/quick_panel_placement.dart';
import '../services/quick_preview_placement.dart';
import 'app_theme.dart';
import 'common.dart';
import 'clipboard_image.dart';
import 'quick_hover_preview.dart';

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
  static const _itemExtent = 62.0;
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  final _scrollController = ScrollController();
  bool _copying = false;
  bool _contextMenuOpen = false;
  Timer? _hoverTimer;
  Timer? _previewCloseTimer;
  int _hoverGeneration = 0;
  ClipboardItem? _previewItem;
  QuickPreviewPlacement? _previewPlacement;
  bool _previewFocused = false;
  ClipboardItem? _hoveredItem;
  BuildContext? _hoveredItemContext;
  final _previewRegionKey = GlobalKey();
  Offset? _pointerPosition;
  final _previewOperations = <int>{};
  int _previewCloseGeneration = 0;
  final _imageSizes = <String, Size?>{};

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKey);
    widget.desktopService.quickVisibility.addListener(_onVisibilityChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    widget.desktopService.quickVisibility.removeListener(_onVisibilityChanged);
    _hoverTimer?.cancel();
    _cancelPreviewClose();
    _searchController.dispose();
    _searchFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.escape &&
        (_contextMenuOpen ||
            _previewFocused ||
            !_searchController.value.composing.isCollapsed)) {
      return false;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _moveSelection(1);
        return true;
      case LogicalKeyboardKey.arrowUp:
        _moveSelection(-1);
        return true;
      case LogicalKeyboardKey.enter:
        if (event is KeyDownEvent) {
          unawaited(_useItem(widget.controller.selectedQuick));
        }
        return true;
      case LogicalKeyboardKey.escape:
        // Handle Escape even while the search field or context menu has focus.
        unawaited(_clearPreview());
        unawaited(widget.desktopService.hide());
        return true;
    }
    return false;
  }

  void _moveSelection(int delta) {
    unawaited(_clearPreview());
    widget.controller.moveQuickSelection(delta);
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final top = widget.controller.selectedQuickIndex * _itemExtent;
    final bottom = top + _itemExtent;
    var offset = position.pixels;
    if (top < offset) offset = top;
    if (bottom > offset + position.viewportDimension) {
      offset = bottom - position.viewportDimension;
    }
    _scrollController.jumpTo(offset.clamp(0, position.maxScrollExtent));
  }

  Future<void> _useItem(ClipboardItem? item, {bool paste = true}) async {
    if (_copying || item == null) return;
    _copying = true;
    final session = widget.controller.quickSession;
    unawaited(_clearPreview());
    try {
      final used = await widget.controller.useItem(item);
      if (session != widget.controller.quickSession) return;
      if (used) await widget.desktopService.completeQuickUse(paste: paste);
      if (!used && mounted) {
        showMessage(context, widget.controller.clipboardError ?? '复制失败');
      }
    } finally {
      _copying = false;
    }
  }

  void _onVisibilityChanged() {
    if (widget.desktopService.quickVisibility.value || !mounted) return;
    _hoverTimer?.cancel();
    _cancelPreviewClose();
    _hoverGeneration++;
    setState(() {
      _previewItem = null;
      _previewPlacement = null;
      _previewFocused = false;
      _hoveredItem = null;
      _hoveredItemContext = null;
    });
  }

  void _hoverItem(ClipboardItem item, BuildContext itemContext) {
    _cancelPreviewClose();
    _hoveredItemContext = itemContext;
    // Resizing a native window can synthesize exit/enter pairs even when the
    // physical pointer has not moved. Keep the pending or visible preview.
    if (_hoveredItem?.id == item.id &&
        _hoveredItem?.contentHash == item.contentHash &&
        ((_previewItem?.id == item.id &&
                _previewItem?.contentHash == item.contentHash) ||
            _hoverTimer?.isActive == true ||
            _previewOperations.contains(_hoverGeneration))) {
      return;
    }
    _hoverTimer?.cancel();
    _hoveredItem = item;
    final generation = ++_hoverGeneration;
    if (_contextMenuOpen || (!item.isImage && item.typeLabel != 'JSON')) {
      unawaited(_clearPreview());
      return;
    }
    _hoverTimer = Timer(const Duration(milliseconds: 350), () async {
      try {
        final pointer = await _readPointerPosition();
        if (!mounted || generation != _hoverGeneration) return;
        if (!itemContext.mounted) return;
        if (pointer != null && !_containsPointer(itemContext, pointer)) return;
        _previewOperations.add(generation);
        final imageSize = item.isImage
            ? _imageSizes.putIfAbsent(item.contentHash, () {
                final dimensions = clipboardImageDimensions(
                  item.payload.imageBytes,
                );
                return dimensions == null
                    ? null
                    : Size(dimensions.$1.toDouble(), dimensions.$2.toDouble());
              })
            : null;
        final placement = await widget.desktopService.expandQuickPreview(
          imageSize: imageSize,
        );
        if (!mounted || generation != _hoverGeneration || placement == null) {
          return;
        }
        setState(() {
          _previewItem = item;
          _previewPlacement = placement;
        });
      } catch (_) {
        if (mounted && generation == _hoverGeneration) {
          unawaited(_clearPreview());
        }
      } finally {
        _previewOperations.remove(generation);
      }
    });
  }

  void _leaveItem() {
    _hoverTimer?.cancel();
    _cancelPreviewClose();
    final request = _previewCloseGeneration;
    _previewCloseTimer = Timer(
      const Duration(milliseconds: 200),
      () => unawaited(_closePreviewIfOutside(request)),
    );
  }

  void _cancelPreviewClose() {
    _previewCloseTimer?.cancel();
    _previewCloseGeneration++;
  }

  bool _containsPointer(BuildContext? region, Offset pointer) {
    if (region == null || !region.mounted) return false;
    final box = region.findRenderObject();
    return box is RenderBox &&
        box.attached &&
        box.hasSize &&
        (Offset.zero & box.size).contains(box.globalToLocal(pointer));
  }

  Future<Offset?> _readPointerPosition() async {
    try {
      return await widget.desktopService.getQuickPointerPosition() ??
          _pointerPosition;
    } catch (_) {
      return _pointerPosition;
    }
  }

  Future<void> _closePreviewIfOutside(int request) async {
    if (!mounted) return;
    // Let the native resize and its Flutter layout finish before interpreting
    // an exit. Otherwise a left-side preview can repeatedly collapse itself.
    if (_previewOperations.isNotEmpty) {
      _leaveItem();
      return;
    }
    final generation = _hoverGeneration;
    final pointer = await _readPointerPosition();
    if (!mounted ||
        generation != _hoverGeneration ||
        request != _previewCloseGeneration) {
      return;
    }
    if (pointer != null &&
        (_containsPointer(_hoveredItemContext, pointer) ||
            _containsPointer(_previewRegionKey.currentContext, pointer))) {
      return;
    }
    await _clearPreview();
  }

  void _enterPreview() {
    _hoverTimer?.cancel();
    _cancelPreviewClose();
  }

  Future<void> _clearPreview() async {
    _hoverTimer?.cancel();
    _cancelPreviewClose();
    final generation = ++_hoverGeneration;
    _hoveredItem = null;
    _hoveredItemContext = null;
    if (mounted) {
      setState(() {
        _previewItem = null;
        _previewFocused = false;
      });
    }
    try {
      await widget.desktopService.collapseQuickPreview();
    } catch (_) {
      // A hidden or closing native window may reject the resize.
    } finally {
      if (mounted && generation == _hoverGeneration) {
        setState(() => _previewPlacement = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final panel =
          _previewPlacement?.panelLocal ??
          Rect.fromLTWH(
            0,
            0,
            math.min(constraints.maxWidth, quickPanelSize.width),
            math.min(constraints.maxHeight, quickPanelSize.height),
          );
      return MouseRegion(
        onEnter: (event) => _pointerPosition = event.position,
        onExit: (event) {
          _pointerPosition = event.position;
          _leaveItem();
        },
        child: Listener(
          onPointerHover: (event) => _pointerPosition = event.position,
          onPointerMove: (event) => _pointerPosition = event.position,
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.desktopService.hide,
                  child: const ColoredBox(color: Colors.transparent),
                ),
              ),
              Positioned.fromRect(rect: panel, child: _buildPanel(context)),
              if (_previewItem != null && _previewPlacement != null)
                Positioned.fromRect(
                  rect: _previewPlacement!.previewLocal,
                  child: MouseRegion(
                    key: _previewRegionKey,
                    onEnter: (_) => _enterPreview(),
                    onExit: (_) => _leaveItem(),
                    child: Focus(
                      onFocusChange: (focused) => _previewFocused = focused,
                      child: QuickHoverPreview(
                        item: _previewItem!,
                        onClose: () => unawaited(_clearPreview()),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );

  Widget _buildPanel(BuildContext context) {
    final controller = widget.controller;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.line),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              DragToMoveArea(
                child: _QuickHeader(
                  service: widget.desktopService,
                  recording: controller.recordingEnabled,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 7),
                child: TextField(
                  key: const ValueKey('quick-search'),
                  controller: _searchController,
                  focusNode: _searchFocus,
                  onChanged: (value) {
                    unawaited(_clearPreview());
                    controller.setQuickSearch(value);
                  },
                  style: const TextStyle(fontSize: 12),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search_rounded, size: 17),
                    prefixIconConstraints: BoxConstraints(minWidth: 34),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                    hintText: '搜索全部历史…',
                    suffixIcon: _KeyCap(label: 'Esc'),
                    suffixIconConstraints: BoxConstraints(minWidth: 38),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    _QuickTab(
                      label: '最近',
                      active: !controller.quickFavoritesOnly,
                      onTap: () {
                        unawaited(_clearPreview());
                        controller.setQuickFavoritesOnly(false);
                      },
                    ),
                    const SizedBox(width: 4),
                    _QuickTab(
                      label: '收藏',
                      active: controller.quickFavoritesOnly,
                      onTap: () {
                        unawaited(_clearPreview());
                        controller.setQuickFavoritesOnly(true);
                      },
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
              const SizedBox(height: 5),
              Expanded(
                child: controller.quickItems.isEmpty
                    ? EmptyState(
                        title: controller.quickSearch.isEmpty
                            ? '还没有剪切板记录'
                            : '没有找到匹配记录',
                        subtitle: controller.quickSearch.isEmpty
                            ? '复制文本后会出现在这里'
                            : '试试更短的关键词',
                      )
                    : NotificationListener<ScrollStartNotification>(
                        onNotification: (_) {
                          unawaited(_clearPreview());
                          return false;
                        },
                        child: ListView.builder(
                          key: const ValueKey('quick-list'),
                          controller: _scrollController,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          itemExtent: _itemExtent,
                          itemCount: controller.quickItems.length,
                          itemBuilder: (context, index) {
                            final item = controller.quickItems[index];
                            return _QuickItem(
                              key: ValueKey(item.id),
                              item: item,
                              selected: index == controller.selectedQuickIndex,
                              onUse: () => _useItem(item),
                              onCopy: () => _useItem(item, paste: false),
                              onHover: (context) => _hoverItem(item, context),
                              onExit: _leaveItem,
                              onDelete: () => controller.deleteItem(item.id),
                              onFavorite: () =>
                                  controller.toggleFavorite(item.id),
                              onMenuChanged: (open) {
                                _contextMenuOpen = open;
                                if (open) unawaited(_clearPreview());
                              },
                            );
                          },
                        ),
                      ),
              ),
              _QuickFooter(onOpenMain: widget.desktopService.showHistory),
            ],
          ),
        ),
      ),
    );
  }
}

class _QuickHeader extends StatelessWidget {
  const _QuickHeader({required this.service, required this.recording});
  final DesktopService service;
  final bool recording;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(11, 8, 5, 7),
    child: Row(
      children: [
        const BrandMark(size: 26),
        const SizedBox(width: 8),
        const Expanded(
          child: Text(
            'Idreaml Clip',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
        ),
        Tooltip(
          message: recording ? '正在记录' : '已暂停记录',
          child: Icon(
            Icons.circle,
            color: recording ? AppColors.success : AppColors.muted,
            size: 7,
          ),
        ),
        const SizedBox(width: 5),
        IconButton(
          tooltip: '关闭',
          onPressed: service.hide,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints.tightFor(width: 28, height: 28),
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.close_rounded, size: 17),
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
    borderRadius: BorderRadius.circular(7),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        color: active ? AppColors.primarySoft : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: active ? AppColors.primary : AppColors.muted,
          fontWeight: FontWeight.w600,
          fontSize: 11,
        ),
      ),
    ),
  );
}

class _QuickItem extends StatefulWidget {
  const _QuickItem({
    super.key,
    required this.item,
    required this.selected,
    required this.onUse,
    required this.onCopy,
    required this.onHover,
    required this.onExit,
    required this.onDelete,
    required this.onFavorite,
    required this.onMenuChanged,
  });

  final ClipboardItem item;
  final bool selected;
  final VoidCallback onUse;
  final VoidCallback onCopy;
  final ValueChanged<BuildContext> onHover;
  final VoidCallback onExit;
  final VoidCallback onDelete;
  final VoidCallback onFavorite;
  final ValueChanged<bool> onMenuChanged;

  @override
  State<_QuickItem> createState() => _QuickItemState();
}

class _QuickItemState extends State<_QuickItem> {
  final _menuController = MenuController();

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return MouseRegion(
      onEnter: (_) => widget.onHover(context),
      onExit: (_) => widget.onExit(),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: MenuAnchor(
          controller: _menuController,
          onOpen: () => widget.onMenuChanged(true),
          onClose: () => widget.onMenuChanged(false),
          style: const MenuStyle(
            minimumSize: WidgetStatePropertyAll(Size(130, 0)),
          ),
          menuChildren: [
            MenuItemButton(
              leadingIcon: const Icon(Icons.copy_rounded, size: 16),
              onPressed: widget.onCopy,
              child: const Text('复制'),
            ),
            MenuItemButton(
              leadingIcon: const Icon(Icons.delete_outline_rounded, size: 17),
              onPressed: widget.onDelete,
              child: const Text('删除'),
            ),
          ],
          builder: (context, menu, child) => Material(
            color: widget.selected
                ? const Color(0xFFF6F3FF)
                : Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(
                color: widget.selected
                    ? const Color(0xFFDFD8FF)
                    : Colors.transparent,
              ),
            ),
            child: InkWell(
              onTap: widget.onUse,
              onSecondaryTapDown: (details) =>
                  menu.open(position: details.localPosition),
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
                child: Row(
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: widget.selected
                            ? const Color(0xFFE9E4FF)
                            : const Color(0xFFF1F1F5),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      alignment: Alignment.center,
                      child: item.isImage
                          ? ClipboardImage(item: item, thumbnail: true)
                          : Text(
                              'T',
                              style: TextStyle(
                                color: widget.selected
                                    ? AppColors.primary
                                    : AppColors.muted,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.summary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '${relativeTime(item.lastUsedAt)} · ${item.copyCount} 次',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 10,
                              color: AppColors.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: item.favorite ? '取消收藏' : '收藏',
                      onPressed: widget.onFavorite,
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(
                        width: 30,
                        height: 30,
                      ),
                      padding: EdgeInsets.zero,
                      icon: Icon(
                        item.favorite
                            ? Icons.star_rounded
                            : Icons.star_border_rounded,
                        color: item.favorite
                            ? AppColors.warning
                            : AppColors.muted,
                        size: 18,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _QuickFooter extends StatelessWidget {
  const _QuickFooter({required this.onOpenMain});
  final VoidCallback onOpenMain;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: const BoxDecoration(
      color: Color(0xFFFAFAFC),
      border: Border(top: BorderSide(color: AppColors.line)),
    ),
    child: Row(
      children: [
        const _KeyCap(label: '↑↓'),
        const SizedBox(width: 4),
        const Text(
          '选择',
          style: TextStyle(fontSize: 10, color: AppColors.muted),
        ),
        const SizedBox(width: 8),
        const _KeyCap(label: 'Enter'),
        const SizedBox(width: 4),
        const Text(
          '使用',
          style: TextStyle(fontSize: 10, color: AppColors.muted),
        ),
        const Spacer(),
        TextButton(
          onPressed: onOpenMain,
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 28),
            padding: const EdgeInsets.symmetric(horizontal: 5),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('全部历史 →', style: TextStyle(fontSize: 10)),
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
    widthFactor: 1,
    heightFactor: 1,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFF0EFF4),
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 9, color: AppColors.muted),
      ),
    ),
  );
}
