import 'package:flutter/material.dart';

import '../ui/app_theme.dart';

const Map<String, String> deskFontFamilies = {
  '': '系统默认',
  'Microsoft YaHei UI': '微软雅黑',
  'SimSun': '宋体',
  'SimHei': '黑体',
  'KaiTi': '楷体',
  'Arial': 'Arial',
  'Consolas': 'Consolas',
};

String deskColorHex(int color) =>
    '#${(color & 0xffffff).toRadixString(16).padLeft(6, '0').toUpperCase()}';

int? parseDeskColor(String text) {
  final value = text.trim().replaceFirst('#', '');
  return RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(value)
      ? 0xff000000 | int.parse(value, radix: 16)
      : null;
}

Future<int?> pickDeskColor(
  BuildContext context, {
  required int initialColor,
  required String label,
}) => showDialog<int>(
  context: context,
  builder: (_) => _ColorPickerDialog(label: label, initialColor: initialColor),
);

Future<int?> pickDeskTextColor(
  BuildContext context, {
  required int initialColor,
}) => pickDeskColor(context, initialColor: initialColor, label: '文字颜色');

/// Nullable overrides belong to an entry. A null field follows that module's
/// default independently of its other typography choices.
class DeskTextStyleFields extends StatelessWidget {
  const DeskTextStyleFields({
    super.key,
    required this.fontFamily,
    required this.fontSize,
    required this.textColor,
    required this.onFontFamily,
    required this.onFontSize,
    required this.onTextColor,
    this.enabled = true,
    this.inheritedFontSize = 12,
  });
  final String? fontFamily;
  final double? fontSize;
  final int? textColor;
  final ValueChanged<String?> onFontFamily;
  final ValueChanged<double?> onFontSize;
  final ValueChanged<int?> onTextColor;
  final bool enabled;
  final double inheritedFontSize;

  static const _inherit = '__inherit__';

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        '文字样式',
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 10),
      DropdownButtonFormField<String>(
        key: const ValueKey('desk-entry-font-family'),
        initialValue: fontFamily?.isNotEmpty == true ? fontFamily : _inherit,
        isExpanded: true,
        style: const TextStyle(fontSize: 12, color: AppColors.text),
        decoration: const InputDecoration(labelText: '字体'),
        items: [
          const DropdownMenuItem(value: _inherit, child: Text('跟随列表')),
          for (final item in deskFontFamilies.entries.where(
            (e) => e.key.isNotEmpty,
          ))
            DropdownMenuItem(value: item.key, child: Text(item.value)),
          if (fontFamily != null && !deskFontFamilies.containsKey(fontFamily))
            DropdownMenuItem(
              value: fontFamily,
              child: Text(fontFamily!, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: !enabled
            ? null
            : (value) {
                if (value != null) {
                  onFontFamily(value == _inherit ? null : value);
                }
              },
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: Text(
              fontSize == null ? '字号：跟随列表' : '字号：${fontSize!.round()}',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          const Text(
            '单独设置',
            style: TextStyle(fontSize: 11, color: AppColors.muted),
          ),
          const SizedBox(width: 4),
          Switch(
            key: const ValueKey('desk-entry-font-size-enabled'),
            value: fontSize != null,
            activeThumbColor: Colors.white,
            activeTrackColor: AppColors.primary,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: !enabled
                ? null
                : (value) => onFontSize(
                    value ? inheritedFontSize.clamp(10, 32).toDouble() : null,
                  ),
          ),
        ],
      ),
      if (fontSize != null)
        Slider(
          key: const ValueKey('desk-entry-font-size'),
          value: fontSize!.clamp(10, 32),
          min: 10,
          max: 32,
          divisions: 22,
          activeColor: AppColors.primary,
          inactiveColor: AppColors.primarySoft,
          label: '${fontSize!.round()}',
          onChanged: enabled ? onFontSize : null,
        ),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          OutlinedButton.icon(
            key: const ValueKey('desk-entry-text-color'),
            onPressed: !enabled
                ? null
                : () async {
                    final selected = await pickDeskTextColor(
                      context,
                      initialColor: textColor ?? AppColors.text.toARGB32(),
                    );
                    if (selected != null && context.mounted) {
                      onTextColor(selected);
                    }
                  },
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.text,
              side: const BorderSide(color: AppColors.line),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            icon: Container(
              width: 17,
              height: 17,
              decoration: BoxDecoration(
                color: textColor == null
                    ? AppColors.primary
                    : Color(textColor!),
                border: Border.all(color: AppColors.line),
                borderRadius: BorderRadius.circular(5),
              ),
            ),
            label: Text(
              textColor == null ? '文字颜色：跟随列表' : deskColorHex(textColor!),
              style: const TextStyle(fontSize: 12),
            ),
          ),
          if (textColor != null)
            TextButton(
              key: const ValueKey('desk-entry-text-color-reset'),
              onPressed: enabled ? () => onTextColor(null) : null,
              child: const Text('跟随列表', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    ],
  );
}

class _ColorPickerDialog extends StatefulWidget {
  const _ColorPickerDialog({required this.label, required this.initialColor});
  final String label;
  final int initialColor;
  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  late int _color = widget.initialColor;
  late final _controller = TextEditingController(text: deskColorHex(_color));
  String? _error;
  static const _swatches = [
    0xFFFFFFFF,
    0xFFF8F7FB,
    0xFFD8D0F8,
    0xFFF0EDFF,
    0xFFE8DAF4,
    0xFFF7DDE8,
    0xFFFFE3CF,
    0xFFFFF1C9,
    0xFFE2EDCB,
    0xFFD4EBDD,
    0xFFD7E9EF,
    0xFFD3DEF4,
    0xFF6C57E5,
    0xFF6B8F78,
    0xFF526887,
    0xFF393345,
    0xFF25232C,
    0xFF151419,
  ];
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: AppColors.surface,
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: const BorderSide(color: AppColors.line),
    ),
    title: Text(
      '选择${widget.label}',
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
    ),
    content: SizedBox(
      width: 310,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 60,
              decoration: BoxDecoration(
                color: Color(_color),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.line),
              ),
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 9,
              runSpacing: 9,
              children: [
                for (final color in _swatches)
                  Semantics(
                    label: deskColorHex(color),
                    selected: color == _color,
                    button: true,
                    child: InkWell(
                      onTap: () => setState(() {
                        _color = color;
                        _controller.text = deskColorHex(color);
                        _error = null;
                      }),
                      borderRadius: BorderRadius.circular(9),
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: Color(color),
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(
                            color: color == _color
                                ? AppColors.primary
                                : AppColors.line,
                            width: color == _color ? 2 : 1,
                          ),
                        ),
                        child: color == _color
                            ? Icon(
                                Icons.check,
                                size: 18,
                                color: Color(color).computeLuminance() > .45
                                    ? AppColors.primary
                                    : Colors.white,
                              )
                            : null,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            TextField(
              controller: _controller,
              maxLength: 7,
              decoration: InputDecoration(
                labelText: '自定义颜色',
                hintText: '#FFFFFF',
                errorText: _error,
                counterText: '',
              ),
              onChanged: (value) {
                final parsed = parseDeskColor(value);
                if (parsed != null) {
                  setState(() {
                    _color = parsed;
                    _error = null;
                  });
                }
              },
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        onPressed: () {
          final parsed = parseDeskColor(_controller.text);
          if (parsed == null) {
            setState(() => _error = '请输入 6 位颜色值，例如 #FFFFFF');
            return;
          }
          Navigator.pop(context, parsed);
        },
        child: const Text('使用此颜色'),
      ),
    ],
  );
}
