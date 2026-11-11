import 'package:flutter/material.dart';

import '../app_controller.dart';

/// Shared by the screenshot editor and the complete shortcut reference.
/// The host owns scrolling so this content also fits a small screenshot window.
class ScreenshotHelpContent extends StatelessWidget {
  const ScreenshotHelpContent({super.key, required this.screenshotShortcut});

  final String screenshotShortcut;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _HelpSection(
        title: '截图与长截图',
        description:
            '拖动框选范围，或单击选择窗口。选区确定后，可拖动选区或边缘手柄调整范围，再使用工具栏标注。'
            '\n长截图可在设置中选择手动或自动滚动。自动滚动到底后会停留在预览，点击“完成”进入编辑。',
        entries: [
          _HelpEntry(screenshotShortcut, '唤起截图（可在设置中修改）'),
          const _HelpEntry('Enter', '完成截图，复制到剪切板并保存到历史记录'),
          const _HelpEntry('Esc', '依次取消当前拖动或绘制、取消选中的标注，再退出截图；输入文字时确认文字并回到画布'),
          const _HelpEntry(
            '长截图采集中',
            '点击“完成”进入长图编辑；Esc 取消采集。截图窗口有键盘焦点时，也可按 Enter 完成采集',
          ),
          const _HelpEntry(
            '长图编辑',
            '滚轮上下查看，Shift + 滚轮横向查看；顶部的加减按钮调整缩放，“适应宽度”适配窗口',
          ),
        ],
      ),
      const SizedBox(height: 16),
      const _HelpSection(
        title: '标注与选择',
        description: '以下画布快捷键适用于普通截图和长图编辑。输入文字时，数字键、方向键和撤销等按文字编辑处理，Enter 换行。',
        entries: [
          _HelpEntry('按住 Ctrl', '临时切换到选择工具，松开恢复原工具；如果正在拖动或绘制，会在本次操作结束后切换'),
          _HelpEntry(
            '1 / 2',
            '1 变细、2 加粗，支持长按和数字小键盘。矩形、椭圆、直线、箭头、画笔和荧光笔调整线宽；马赛克调整块大小；自动编号调整大小',
          ),
          _HelpEntry('Ctrl + Z', '撤销；正在拖动或绘制时先取消当前操作'),
          _HelpEntry('Ctrl + Y / Ctrl + Shift + Z', '重做；正在拖动或绘制时先取消当前操作'),
          _HelpEntry('Delete / Backspace', '删除选中的标注'),
          _HelpEntry('↑ / ↓ / ← / →', '将选中的标注或截图选区移动 1 个原始像素'),
          _HelpEntry('双击文字', '修改已有的文字标注'),
        ],
      ),
      const SizedBox(height: 16),
      const _HelpSection(
        title: '取色器（普通截图）',
        entries: [
          _HelpEntry('F2', '显示或隐藏取色器'),
          _HelpEntry('C', '取色器显示时，复制鼠标位置的 HEX 色值并退出截图'),
        ],
      ),
    ],
  );
}

class AllShortcutHelpDialog extends StatelessWidget {
  const AllShortcutHelpDialog({
    super.key,
    required this.controller,
    required this.supportsWinV,
    required this.supportsScreenshots,
  });

  final AppController controller;
  final bool supportsWinV;
  final bool supportsScreenshots;

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720, maxHeight: 720),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 18, 12, 14),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '全部快捷键说明',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: '关闭快捷键说明',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: SingleChildScrollView(
              key: const ValueKey('all-shortcut-help-scroll'),
              padding: const EdgeInsets.all(24),
              child: ListenableBuilder(
                listenable: controller,
                builder: (context, _) {
                  final usesWinV =
                      supportsWinV && controller.winVShortcutEnabled;
                  final textModifier =
                      Theme.of(context).platform == TargetPlatform.macOS
                      ? 'Command'
                      : 'Ctrl';
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _HelpSection(
                        title: '全局快捷键',
                        description: usesWinV
                            ? '当前已启用固定 Win + V。自定义组合已停用，关闭固定快捷键后恢复。'
                            : '可自定义的快捷键会随设置同步更新。',
                        entries: [
                          _HelpEntry(
                            usesWinV
                                ? 'Win + V'
                                : controller.quickShortcut.label(),
                            '在其他应用上方唤起快捷剪切板',
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const _HelpSection(
                        title: '快捷剪切板',
                        description:
                            '输入文字即可搜索。输入法组词、菜单或预览控件操作期间，方向键和 Enter 优先交给对应控件。',
                        entries: [
                          _HelpEntry('↑ / ↓', '选择上一条或下一条记录'),
                          _HelpEntry('Enter', '使用当前记录，并尝试粘贴到原输入位置'),
                          _HelpEntry('Esc', '关闭快捷剪切板'),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _HelpSection(
                        title: '预览与文字编辑',
                        description: '文字快捷键作用于当前获得焦点的输入框或选中的文字。只读预览支持选择和复制。',
                        entries: [
                          const _HelpEntry('图片预览', '鼠标滚轮缩放，拖动平移图片'),
                          const _HelpEntry(
                            'Shift + 滚轮',
                            '横向查看可横向滚动的内容，例如 JSON 树',
                          ),
                          _HelpEntry('$textModifier + A', '全选文字'),
                          _HelpEntry(
                            '$textModifier + C / X / V',
                            '复制 / 剪切 / 粘贴文字',
                          ),
                          _HelpEntry('$textModifier + Z', '撤销文字编辑'),
                          _HelpEntry('$textModifier + Shift + Z', '重做文字编辑'),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const _HelpSection(
                        title: '自定义快捷键录入',
                        description:
                            '进入快捷键修改后，按下所需的组合键并全部松开，再点击“保存”。可录入单个普通按键或带修饰键的组合。',
                        entries: [
                          _HelpEntry('Esc', '取消当前录入'),
                          _HelpEntry('Tab / Enter / 方向键', '录入时作为快捷键内容，不会导航或保存'),
                        ],
                      ),
                      if (supportsScreenshots) ...[
                        const SizedBox(height: 16),
                        ScreenshotHelpContent(
                          screenshotShortcut: controller.screenshotShortcut
                              .label(),
                        ),
                        const SizedBox(height: 16),
                        const _HelpSection(
                          title: '贴图窗口',
                          entries: [
                            _HelpEntry('左键拖动', '移动贴图，可拖到其他显示器'),
                            _HelpEntry('鼠标滚轮', '缩放贴图'),
                            _HelpEntry('Ctrl + C', '复制贴图'),
                            _HelpEntry('Esc', '关闭贴图'),
                            _HelpEntry('右键', '打开贴图操作菜单'),
                          ],
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _HelpEntry {
  const _HelpEntry(this.keys, this.description);
  final String keys;
  final String description;
}

class _HelpSection extends StatelessWidget {
  const _HelpSection({
    required this.title,
    required this.entries,
    this.description,
  });

  final String title;
  final String? description;
  final List<_HelpEntry> entries;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        title,
        style: Theme.of(context).textTheme.titleSmall
            ?.copyWith(fontWeight: FontWeight.w700),
      ),
      if (description != null) ...[
        const SizedBox(height: 6),
        Text(description!, style: Theme.of(context).textTheme.bodySmall),
      ],
      const SizedBox(height: 8),
      DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Column(
            children: [
              for (final (index, entry) in entries.indexed) ...[
                if (index > 0) const Divider(height: 1),
                _HelpEntryRow(entry: entry),
              ],
            ],
          ),
        ),
      ),
    ],
  );
}

class _HelpEntryRow extends StatelessWidget {
  const _HelpEntryRow({required this.entry});
  final _HelpEntry entry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final keys = Text(
          entry.keys,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.primary,
          ),
        );
        final description = Text(entry.description);
        if (constraints.maxWidth < 480) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [keys, const SizedBox(height: 5), description],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 190, child: keys),
            const SizedBox(width: 14),
            Expanded(child: description),
          ],
        );
      },
    ),
  );
}
