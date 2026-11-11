import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'screenshot_model.dart';
import 'screenshot_renderer.dart';

/// Uses the annotation renderer so the menu samples match the exported arrows.
class ArrowStylePreview extends StatelessWidget {
  const ArrowStylePreview({super.key, required this.style, this.width = 46});

  final ArrowStyle style;
  final double width;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size(width, 22),
    painter: _ArrowPreviewPainter(
      style,
      Theme.of(context).colorScheme.onSurface,
    ),
  );
}

class _ArrowPreviewPainter extends CustomPainter {
  const _ArrowPreviewPainter(this.style, this.color);
  final ArrowStyle style;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    paintAnnotation(
      canvas,
      ScreenshotAnnotation(
        id: 0,
        tool: ScreenshotTool.arrow,
        points: [Offset(3, size.height - 5), Offset(size.width - 3, 5)],
        style: ToolStyle(arrowStyle: style, color: color, width: 2),
      ),
    );
  }

  @override
  bool shouldRepaint(_ArrowPreviewPainter old) =>
      old.style != style || old.color != color;
}

class ArrowStylePicker extends StatelessWidget {
  const ArrowStylePicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.monitor,
  });

  final ArrowStyle value;
  final ValueChanged<ArrowStyle>? onChanged;

  // The regular capture overlay spans the virtual desktop. A floating menu
  // anchored to its toolbar must stay on the same real monitor as the button.
  final Rect? monitor;
  static const compactWidth = 48.0;

  Future<void> _open(BuildContext context) async {
    final button = context.findRenderObject()! as RenderBox;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final bounds = (monitor ?? Offset.zero & overlay.size).deflate(8);
    final fontSize = MediaQuery.textScalerOf(context).scale(14);
    final menuWidth = math.min(
      bounds.width,
      math.max(192.0, 110 + 4 * fontSize),
    );
    final itemHeight = math.max(38.0, fontSize + 12);
    final menuHeight = math.min(
      bounds.height,
      16 + itemHeight * ArrowStyle.values.length,
    );
    final anchor =
        button.localToGlobal(Offset.zero, ancestor: overlay) & button.size;
    final left = anchor.left.clamp(bounds.left, bounds.right - menuWidth);
    final preferredTop = anchor.bottom + menuHeight <= bounds.bottom
        ? anchor.bottom
        : anchor.top - menuHeight;
    final top = preferredTop.clamp(bounds.top, bounds.bottom - menuHeight);
    final result = await showMenu<ArrowStyle>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(left, top, menuWidth, 0),
        Offset.zero & overlay.size,
      ),
      constraints: BoxConstraints.tightFor(width: menuWidth)
          .copyWith(maxHeight: menuHeight),
      menuPadding: const EdgeInsets.symmetric(vertical: 8),
      items: [
        for (final style in ArrowStyle.values)
          PopupMenuItem(
            value: style,
            height: itemHeight,
            child: Row(
              children: [
                ArrowStylePreview(style: style),
                const SizedBox(width: 8),
                Expanded(child: Text(style.label)),
                if (value == style) const Icon(Icons.check, size: 16),
              ],
            ),
          ),
      ],
    );
    if (context.mounted && result != null && result != value) {
      onChanged?.call(result);
    }
  }

  @override
  Widget build(BuildContext context) => Tooltip(
    message: '箭头样式',
    child: Semantics(
      label: '箭头样式，当前为${value.label}',
      child: TextButton(
        onPressed: onChanged == null ? null : () => _open(context),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          minimumSize: const Size(compactWidth, 32),
          foregroundColor: Theme.of(context).colorScheme.onSurface,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ArrowStylePreview(style: value, width: 28),
            const Icon(Icons.arrow_drop_down, size: 14),
          ],
        ),
      ),
    ),
  );
}
