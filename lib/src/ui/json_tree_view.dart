import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/json_document.dart';
import '../models/json_tree.dart';
import 'app_theme.dart';
import 'common.dart';

const _levels = [
  Color(0xFF7252CC),
  Color(0xFF168B91),
  Color(0xFFBD7826),
  Color(0xFFBA5286),
];
const _indent = 18.0;
const _gutter = 32.0;

class JsonTreeView extends StatefulWidget {
  const JsonTreeView({super.key, required this.document});
  final JsonDocument document;

  @override
  State<JsonTreeView> createState() => _JsonTreeViewState();
}

class _JsonTreeViewState extends State<JsonTreeView> {
  final _vertical = ScrollController();
  final _horizontal = ScrollController();
  final _collapsed = <int>{};
  late List<JsonTreeLine> _lines;
  late List<JsonTreeLine> _visible;
  double _width = 0;

  @override
  void initState() {
    super.initState();
    _lines = jsonTreeLines(widget.document);
    _refresh();
  }

  @override
  void didUpdateWidget(covariant JsonTreeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.document != widget.document) {
      _collapsed.clear();
      _lines = jsonTreeLines(widget.document);
      _refresh();
      if (_vertical.hasClients) _vertical.jumpTo(0);
      if (_horizontal.hasClients) _horizontal.jumpTo(0);
    }
  }

  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  void _refresh() {
    _visible = visibleJsonLines(_lines, _collapsed);
    _width = 0;
    for (final line in _visible) {
      final length =
          line.prefix.length +
          (_collapsed.contains(line.index) ? 16 : line.text.length) +
          1;
      // Leave room for wide Unicode characters; exceptionally long strings wrap.
      _width = math.max(
        _width,
        _gutter + line.depth * _indent + 32 + math.min(1500, length * 12.0),
      );
    }
  }

  void _toggle(JsonTreeLine line) => setState(() {
    if (!_collapsed.add(line.index)) _collapsed.remove(line.index);
    _refresh();
  });

  void _foldAll(bool fold) => setState(() {
    _collapsed.clear();
    if (fold) {
      _collapsed.addAll(
        _lines.where((line) => line.canFold).map((line) => line.index),
      );
    }
    _refresh();
  });

  Future<void> _copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.document.formatted));
      if (mounted) showMessage(context, '已复制格式化 JSON');
    } catch (_) {
      if (mounted) showMessage(context, '复制失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Container(
        height: 32,
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.line)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            _tool('展开全部', Icons.unfold_more_rounded, () => _foldAll(false)),
            _tool('折叠全部', Icons.unfold_less_rounded, () => _foldAll(true)),
            _tool('复制格式化 JSON', Icons.copy_rounded, _copy),
            const SizedBox(width: 4),
          ],
        ),
      ),
      Expanded(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final scale = MediaQuery.textScalerOf(context).scale(12) / 12;
            return ScrollConfiguration(
              behavior: ScrollConfiguration.of(context)
                  .copyWith(scrollbars: false),
              child: Scrollbar(
                controller: _vertical,
                thumbVisibility: true,
                notificationPredicate: (notification) =>
                    notification.metrics.axis == Axis.vertical,
                child: Scrollbar(
                  controller: _horizontal,
                  thumbVisibility: true,
                  notificationPredicate: (notification) =>
                      notification.metrics.axis == Axis.horizontal,
                  child: SingleChildScrollView(
                    key: const ValueKey('json-tree-horizontal'),
                    controller: _horizontal,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: math.max(constraints.maxWidth, _width * scale),
                      height: constraints.maxHeight,
                      child: SelectionArea(
                        child: ListView.builder(
                          key: const ValueKey('json-tree-scroll'),
                          controller: _vertical,
                          primary: false,
                          padding: const EdgeInsets.only(
                            top: 6,
                            bottom: 16,
                            right: 8,
                          ),
                          itemCount: _visible.length,
                          itemBuilder: (context, index) {
                            final line = _visible[index];
                            return _TreeRow(
                              key: ValueKey('json-tree-line-${line.index}'),
                              line: line,
                              folded: _collapsed.contains(line.index),
                              onToggle: () => _toggle(line),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ],
  );

  Widget _tool(String label, IconData icon, VoidCallback onPressed) =>
      SizedBox.square(
        dimension: 28,
        child: IconButton(
          tooltip: label,
          onPressed: onPressed,
          icon: Icon(icon, size: 16),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 28, height: 28),
          visualDensity: VisualDensity.compact,
          color: AppColors.muted,
        ),
      );
}

class _TreeRow extends StatelessWidget {
  const _TreeRow({
    super.key,
    required this.line,
    required this.folded,
    required this.onToggle,
  });
  final JsonTreeLine line;
  final bool folded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final bracket = _levels[line.depth % _levels.length];
    final color = switch (line.token) {
      JsonTreeToken.object || JsonTreeToken.array => bracket,
      JsonTreeToken.string => const Color(0xFF287648),
      JsonTreeToken.number => const Color(0xFFAA651C),
      JsonTreeToken.boolean => const Color(0xFF9550B2),
      JsonTreeToken.nil => AppColors.muted,
    };
    return CustomPaint(
      painter: _Guides(line.depth),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: _gutter,
              child: SelectionContainer.disabled(
                child: Text(
                  '${line.index + 1}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 10,
                    height: 2,
                    color: AppColors.muted,
                  ),
                ),
              ),
            ),
            SizedBox(width: line.depth * _indent),
            SizedBox(
              width: 20,
              height: 20,
              child: line.canFold
                  ? IconButton(
                      key: ValueKey('json-fold-${line.index}'),
                      tooltip:
                          '${folded ? '展开' : '折叠'}${line.token == JsonTreeToken.object ? '对象' : '数组'}${line.name == null ? '' : ' ${line.name}'}',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 20,
                        height: 20,
                      ),
                      onPressed: onToggle,
                      icon: Icon(
                        folded
                            ? Icons.chevron_right_rounded
                            : Icons.expand_more_rounded,
                        size: 17,
                        color: bracket,
                      ),
                    )
                  : null,
            ),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    if (line.name != null)
                      TextSpan(
                        text: line.prefix,
                        style: const TextStyle(color: Color(0xFF356AAF)),
                      ),
                    TextSpan(
                      text: line.text,
                      style: TextStyle(color: color),
                    ),
                    if (folded) ...[
                      const TextSpan(
                        text: ' … ',
                        style: TextStyle(color: AppColors.muted),
                      ),
                      TextSpan(
                        text: line.token == JsonTreeToken.object ? '}' : ']',
                        style: TextStyle(color: bracket),
                      ),
                    ],
                    if (line.comma && (!line.canFold || folded))
                      const TextSpan(text: ','),
                    if (folded)
                      TextSpan(
                        text: '  ${line.count} 项',
                        style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 10,
                        ),
                      ),
                  ],
                ),
                key: ValueKey('json-code-${line.index}'),
                style: const TextStyle(
                  fontFamily: 'Consolas',
                  fontFamilyFallback: [
                    'Microsoft YaHei UI',
                    'PingFang SC',
                    'Noto Sans CJK SC',
                    'Menlo',
                    'monospace',
                  ],
                  fontSize: 12,
                  height: 1.65,
                  color: AppColors.text,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Guides extends CustomPainter {
  const _Guides(this.depth);
  final int depth;

  @override
  void paint(Canvas canvas, Size size) {
    for (var level = 0; level < depth; level++) {
      final x = _gutter + level * _indent + 10;
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = _levels[level % _levels.length].withValues(alpha: .22)
          ..strokeWidth = 1,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _Guides oldDelegate) =>
      oldDelegate.depth != depth;
}
