import 'package:flutter/material.dart';

import '../models/clipboard_item.dart';
import '../services/json_preview_formatter.dart';
import 'app_theme.dart';
import 'clipboard_image.dart';
import 'common.dart';

class QuickHoverPreview extends StatefulWidget {
  const QuickHoverPreview({
    super.key,
    required this.item,
    required this.onClose,
  });
  final ClipboardItem item;
  final VoidCallback onClose;

  @override
  State<QuickHoverPreview> createState() => _QuickHoverPreviewState();
}

class _QuickHoverPreviewState extends State<QuickHoverPreview> {
  Future<String>? _json;

  void _prepare() {
    _json = widget.item.isImage ? null : formatJsonPreview(widget.item.content);
  }

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void didUpdateWidget(covariant QuickHoverPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.contentHash != widget.item.contentHash) _prepare();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.item.isImage) {
      return ClipboardImage(item: widget.item);
    }
    return Padding(
      padding: const EdgeInsets.all(6),
      child: Material(
        color: AppColors.surface,
        elevation: 5,
        shadowColor: const Color(0x20292336),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: AppColors.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'JSON 预览',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  StatusPill(
                    label: widget.item.typeLabel,
                    color: AppColors.primary,
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: widget.onClose,
                    tooltip: '关闭预览',
                    icon: const Icon(Icons.close_rounded, size: 17),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.sidebar,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.line),
                  ),
                  child: FutureBuilder<String>(
                    future: _json,
                    builder: (context, snapshot) {
                      if (snapshot.hasError) {
                        return const Center(child: Text('JSON 无法预览'));
                      }
                      if (!snapshot.hasData) {
                        return const Center(
                          child: CircularProgressIndicator(strokeWidth: 2),
                        );
                      }
                      return SingleChildScrollView(
                        key: ValueKey(widget.item.contentHash),
                        child: SelectableText(
                          snapshot.data!,
                          key: const ValueKey('quick-json-preview'),
                          style: const TextStyle(
                            fontFamily: 'Consolas',
                            fontSize: 12,
                            height: 1.5,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
