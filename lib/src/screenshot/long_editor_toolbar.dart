part of 'screenshot_editor.dart';

class _EditorCommand {
  const _EditorCommand(
    this.icon,
    this.label,
    this.run, {
    this.active = false,
    this.tool,
  });

  final IconData icon;
  final String label;
  final VoidCallback? run;
  final bool active;
  final ScreenshotTool? tool;
}

extension _EditorToolbar on _ScreenshotEditorState {
  List<_EditorCommand> _annotationCommands(ScreenshotModel m) => [
    for (final tool in ScreenshotTool.values)
      _EditorCommand(
        _toolIcon(tool),
        tool.label,
        !_editable
            ? null
            : () {
                _commitText();
                _chooseTool(tool);
              },
        active: m.tool == tool,
        tool: tool,
      ),
  ];

  List<_EditorCommand> _historyCommands(ScreenshotModel m) => [
    _EditorCommand(
      Icons.undo,
      '撤销（Ctrl + Z）',
      _editable && m.canUndo
          ? () {
              _commitText();
              m.undo();
            }
          : null,
    ),
    _EditorCommand(
      Icons.redo,
      '重做（Ctrl + Y）',
      _editable && m.canRedo ? m.redo : null,
    ),
    if (m.selected != null)
      _EditorCommand(
        Icons.delete_outline,
        '删除标注',
        _editable ? m.deleteSelected : null,
      ),
    if (m.selected?.tool == ScreenshotTool.text)
      _EditorCommand(
        Icons.edit,
        '修改文字',
        !_editable
            ? null
            : () => _editText(m.selected, m.selected!.points.first),
      ),
  ];

  void _windowAction(String action) {
    unawaited(
      _channel.invokeMethod<void>('longEditorWindow', {
        'session': widget.snapshot['session'],
        'action': action,
      }),
    );
  }

  Widget _longToolbar(ScreenshotModel m, double width) {
    const title = '理梦剪藏 · 长图编辑';
    final dimensions = '${m.size.width.toInt()} × ${m.size.height.toInt()} px';
    final percent = '${(_scale * 100).round()}%';
    final zoom = [
      _EditorCommand(
        Icons.remove,
        '缩小长图',
        () => _setLongZoom(_longZoom / 1.25),
      ),
      _EditorCommand(Icons.add, '放大长图', () => _setLongZoom(_longZoom * 1.25)),
      _EditorCommand(Icons.fit_screen_outlined, '适应宽度', () => _setLongZoom(1)),
    ];
    final canFinish = !_busy && m.selection != null && _longFinishArmed;
    final pin = _EditorCommand(
      Icons.push_pin_rounded,
      '贴图',
      canFinish && _editable
          ? () => _finish(action: _ScreenshotAction.pin)
          : null,
    );
    final save = _EditorCommand(
      Icons.save_alt,
      '另存为并完成',
      canFinish && !_locked
          ? () => _finish(action: _ScreenshotAction.saveAs)
          : null,
    );
    final finish = _EditorCommand(
      Icons.check,
      _locked ? '重试完成' : '完成（Enter）',
      canFinish ? _finish : null,
    );
    final history = _historyCommands(m);
    final showStyle = m.tool != ScreenshotTool.select || m.selected != null;
    final showArrowStyles =
        (m.selected?.tool ?? m.tool) == ScreenshotTool.arrow;
    final showDimensions = width >= 780;
    final textScale = MediaQuery.textScalerOf(context).scale(13) / 13;
    final compactTitle = width < 650 && textScale > 1.25;
    final fullView = width >= 620,
        showPin = width >= 560,
        showSave = width >= 900;
    final showHistory = width >= 640;
    final tools = _annotationCommands(m);
    final extra = [
      _EditorCommand(
        Icons.fullscreen,
        '选择整张长图',
        !_editable
            ? null
            : () {
                _commitText();
                m.selectAll(m.screen);
              },
      ),
      ...history.skip(showHistory ? 2 : 0),
    ];
    // Allocate the title/drag zone and window controls first. Only whole
    // editing buttons are moved to the menu; the window never gains a row.
    const slot = 32.0;
    final captionWidth = width < 520 ? 32.0 : 36.0;
    final titleWidth = math.min(
      width * .42,
      14 +
          (showDimensions
                  ? 201
                  : compactTitle
                  ? 62
                  : 124) *
              textScale,
    );
    final reserved =
        titleWidth +
        3 * captionWidth +
        3 * 8 +
        (fullView ? 170 : 64) +
        (showPin ? 66 : 0) +
        (showSave ? slot : 0) +
        2 * slot + // Help and selection stay adjacent, even in narrow windows.
        slot +
        (showHistory ? 2 * slot : 0) +
        (showArrowStyles ? ArrowStylePicker.compactWidth : 0) +
        (showStyle ? slot : 0);
    final slots = math.max(0, ((width - reserved) / slot).floor());
    final options = [...tools.skip(1), ...extra];
    final outputMenu = [if (!showPin) pin, if (!showSave) save];
    final count = slots >= options.length && outputMenu.isEmpty
        ? options.length
        : (slots - 1).clamp(0, options.length);
    final visible = options.take(count).toList();
    final active = tools.firstWhere((tool) => tool.active);
    if (visible.isNotEmpty &&
        active.tool != ScreenshotTool.select &&
        !visible.contains(active)) {
      visible.last = active;
    }
    final hidden = [
      ...options.where((tool) => !visible.contains(tool)),
      ...outputMenu,
    ];

    Widget command(_EditorCommand cmd, {bool primary = false, Widget? glyph}) =>
        SizedBox(
          width: slot,
          height: slot,
          child: IconButton(
            tooltip: cmd.label,
            onPressed: cmd.run,
            isSelected: cmd.active,
            style: IconButton.styleFrom(
              padding: EdgeInsets.zero,
              foregroundColor: primary
                  ? Colors.white
                  : cmd.active
                  ? const Color(0xFF5631A1)
                  : const Color(0xFF30333D),
              disabledForegroundColor: const Color(0xFF979AA3),
              backgroundColor: primary
                  ? const Color(0xFF6540AC)
                  : cmd.active
                  ? const Color(0xFFEDE6F9)
                  : null,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(5),
              ),
            ),
            icon: glyph ?? Icon(cmd.icon, size: 18),
          ),
        );
    Widget menu(
      String tooltip,
      List<_EditorCommand> items,
      Widget child,
      double buttonWidth,
    ) => SizedBox(
      width: buttonWidth,
      child: PopupMenuButton<_EditorCommand>(
        tooltip: tooltip,
        position: PopupMenuPosition.under,
        onSelected: (item) => item.run?.call(),
        itemBuilder: (_) => [
          for (final item in items)
            PopupMenuItem(
              value: item,
              enabled: item.run != null,
              height: 36,
              child: Row(
                children: [
                  Icon(item.icon, size: 17),
                  const SizedBox(width: 10),
                  Expanded(child: Text(item.label)),
                  if (item.active) const Icon(Icons.check, size: 16),
                ],
              ),
            ),
        ],
        child: SizedBox(
          height: slot,
          child: Center(child: child),
        ),
      ),
    );
    Widget divider() => const SizedBox(
      width: 8,
      child: Center(
        child: SizedBox(
          height: 18,
          width: 1,
          child: ColoredBox(color: Color(0xFFDFE1E7)),
        ),
      ),
    );
    Widget caption(
      String label,
      IconData icon,
      VoidCallback? action, {
      bool close = false,
    }) => SizedBox(
      width: captionWidth,
      height: 44,
      child: IconButton(
        tooltip: label,
        onPressed: action,
        style: ButtonStyle(
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => close && s.contains(WidgetState.hovered)
                ? Colors.white
                : const Color(0xFF353742),
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.hovered)
                ? close
                      ? const Color(0xFFC42B1C)
                      : const Color(0xFFEDEEF0)
                : null,
          ),
        ),
        icon: Icon(icon, size: 17),
      ),
    );
    return Theme(
      data: _longToolbarTheme,
      child: Material(
        color: Colors.white,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Color(0xFFE0E1E6))),
          ),
          child: SizedBox(
            key: const ValueKey('long-editor-toolbar'),
            height: 44,
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    key: const ValueKey('long-editor-title'),
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (_) => _windowAction('drag'),
                    onDoubleTap: () => _windowAction('toggleMaximize'),
                    child: Padding(
                      padding: const EdgeInsetsDirectional.only(
                        start: 10,
                        end: 4,
                      ),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Tooltip(
                          message: '$title · $dimensions',
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(text: compactTitle ? '长图编辑' : title),
                                if (showDimensions)
                                  TextSpan(
                                    text: '   $dimensions',
                                    style: const TextStyle(
                                      color: Color(0xFF626674),
                                      fontSize: 11,
                                      fontWeight: FontWeight.normal,
                                    ),
                                  ),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFF242631),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                command(
                  _EditorCommand(
                    Icons.help_outline,
                    '截图帮助',
                    _busy ? null : _showScreenshotHelp,
                  ),
                  glyph: _helpGlyph(light: true),
                ),
                command(tools.first),
                for (final item in visible) ...[
                  command(item),
                  if (showArrowStyles && item.tool == ScreenshotTool.arrow)
                    _arrowStylePicker(m),
                ],
                if (showArrowStyles &&
                    !visible.any((item) => item.tool == ScreenshotTool.arrow))
                  _arrowStylePicker(m),
                if (showStyle)
                  SizedBox(
                    width: slot,
                    child: PopupMenuButton<void>(
                      tooltip: '标注样式',
                      enabled: _editable,
                      position: PopupMenuPosition.under,
                      constraints: const BoxConstraints(maxWidth: 312),
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.tune, size: 18),
                      itemBuilder: (_) => [
                        PopupMenuItem<void>(
                          child: ListenableBuilder(
                            listenable: m,
                            builder: (_, _) => _styleControls(m),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (showHistory)
                  for (final item in history.take(2)) command(item),
                if (hidden.isNotEmpty)
                  menu(
                    '更多工具',
                    hidden,
                    Icon(
                      visible.isEmpty && m.tool != ScreenshotTool.select
                          ? active.icon
                          : Icons.more_horiz,
                      size: 19,
                    ),
                    slot,
                  ),
                divider(),
                if (fullView) ...[
                  command(zoom[0]),
                  SizedBox(
                    width: 42,
                    child: Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          percent,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                  ),
                  command(zoom[1]),
                  SizedBox(
                    width: 64,
                    child: TextButton(
                      onPressed: zoom[2].run,
                      style: TextButton.styleFrom(padding: EdgeInsets.zero),
                      child: const FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('适应宽度'),
                      ),
                    ),
                  ),
                ] else
                  menu(
                    '缩放选项',
                    zoom,
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(percent, style: const TextStyle(fontSize: 12)),
                          const Icon(Icons.arrow_drop_down, size: 16),
                        ],
                      ),
                    ),
                    64,
                  ),
                divider(),
                if (showPin)
                  SizedBox(
                    width: 66,
                    child: _pinButton(enabled: pin.run != null, light: true),
                  ),
                if (showSave) command(save),
                command(finish, primary: true),
                divider(),
                caption('最小化', Icons.minimize, () => _windowAction('minimize')),
                caption(
                  _maximized ? '还原' : '最大化',
                  _maximized ? Icons.filter_none : Icons.crop_square,
                  () => _windowAction('toggleMaximize'),
                ),
                caption('关闭', Icons.close, _busy ? null : _close, close: true),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final _longToolbarTheme = ThemeData(
  colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6540AC)),
  fontFamily: 'Microsoft YaHei',
  visualDensity: VisualDensity.compact,
  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
);
