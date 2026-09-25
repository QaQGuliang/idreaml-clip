import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'app_theme.dart';

/// A full-height handle reporting movement relative to the start of a drag.
class ResizeDivider extends StatefulWidget {
  const ResizeDivider({
    super.key,
    required this.label,
    required this.onResizeStart,
    required this.onResize,
    required this.onResizeEnd,
    this.width = 16,
  });

  final String label;
  final double width;
  final VoidCallback onResizeStart;
  final ValueChanged<double> onResize;
  final VoidCallback onResizeEnd;

  @override
  State<ResizeDivider> createState() => _ResizeDividerState();
}

class _ResizeDividerState extends State<ResizeDivider> {
  bool _hovered = false;
  double? _dragStart;

  void _endResize() {
    if (_dragStart == null) return;
    setState(() => _dragStart = null);
    widget.onResizeEnd();
  }

  @override
  Widget build(BuildContext context) {
    final active = _hovered || _dragStart != null;
    return Semantics(
      label: widget.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Tooltip(
          message: widget.label,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            dragStartBehavior: DragStartBehavior.down,
            onHorizontalDragStart: (details) {
              setState(() => _dragStart = details.globalPosition.dx);
              widget.onResizeStart();
            },
            onHorizontalDragUpdate: (details) =>
                widget.onResize(details.globalPosition.dx - _dragStart!),
            onHorizontalDragEnd: (_) => _endResize(),
            onHorizontalDragCancel: _endResize,
            child: SizedBox(
              width: widget.width,
              height: double.infinity,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (active)
                    Container(
                      width: 2,
                      color: AppColors.primary.withValues(alpha: .35),
                    ),
                  Container(
                    width: 3,
                    height: 32,
                    decoration: BoxDecoration(
                      color: active ? AppColors.primary : AppColors.line,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
