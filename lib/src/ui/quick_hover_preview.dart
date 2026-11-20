import 'package:flutter/material.dart';

import '../models/clipboard_item.dart';
import 'app_theme.dart';
import 'clipboard_image.dart';
import 'common.dart';

class QuickHoverPreview extends StatelessWidget {
  const QuickHoverPreview({
    super.key,
    required this.item,
    required this.formattedJson,
    required this.onClose,
  });
  final ClipboardItem item;
  final String? formattedJson;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    if (item.isImage) {
      // 图片预览只画图片本身：预览区域就是图片等比贴合后的窗口区域，任何
      // 底色、边框或模糊都会像给图片套了一层卡片（窗口级效果见
      // DesktopService 的快捷窗口配置）。
      return ClipboardImage(item: item);
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
                  const StatusPill(label: 'JSON', color: AppColors.primary),
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: onClose,
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
                  child: SingleChildScrollView(
                    key: ValueKey(item.contentHash),
                    child: SelectableText(
                      formattedJson!,
                      key: const ValueKey('quick-json-preview'),
                      style: const TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
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
