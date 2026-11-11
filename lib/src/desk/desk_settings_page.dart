import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../ui/app_theme.dart';
import '../ui/common.dart';
import 'desk_models.dart';
import 'desk_typography.dart';
import 'desktop_notes.dart';

class DeskSettingsPage extends StatefulWidget {
  const DeskSettingsPage({super.key, required this.notes});
  final DesktopNotes notes;

  @override
  State<DeskSettingsPage> createState() => _DeskSettingsPageState();
}

class _DeskSettingsPageState extends State<DeskSettingsPage> {
  DeskKind _kind = DeskKind.note;
  List<Map<String, dynamic>> _monitors = [];
  String? _error;
  final _lastGradient = <DeskKind, String>{};
  final _opacityPreview = <DeskKind, double>{};
  final _fontSizePreview = <DeskKind, double>{};

  @override
  void initState() {
    super.initState();
    _loadMonitors();
  }

  Future<void> _loadMonitors() async {
    try {
      final values = await widget.notes.monitors();
      if (mounted) {
        setState(() {
          _monitors = values;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '无法获取显示器，请刷新后重试。');
    }
  }

  Future<void> _attempt(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (mounted) showMessage(context, '$error');
    }
  }

  Future<void> _set(DeskKind kind, Map<String, Object?> changes) =>
      _attempt(() => widget.notes.updateSettings(kind, changes));

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.notes,
    builder: (context, _) {
      final kind = _kind;
      final config = widget.notes.config(kind);
      final preview = config.change({
        if (_opacityPreview[kind] != null) 'opacity': _opacityPreview[kind],
        if (_fontSizePreview[kind] != null) 'fontSize': _fontSizePreview[kind],
      });
      final buttonShape = RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      );
      return Theme(
        data: Theme.of(context).copyWith(
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: buttonShape,
              textStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          outlinedButtonTheme: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.text,
              side: const BorderSide(color: AppColors.line),
              shape: buttonShape,
              textStyle: const TextStyle(fontSize: 12),
            ),
          ),
          textButtonTheme: TextButtonThemeData(
            style: TextButton.styleFrom(
              foregroundColor: AppColors.primary,
              textStyle: const TextStyle(fontSize: 12),
            ),
          ),
          sliderTheme: SliderTheme.of(context).copyWith(
            activeTrackColor: AppColors.primary,
            inactiveTrackColor: AppColors.primarySoft,
            thumbColor: AppColors.primary,
            overlayColor: AppColors.primary.withValues(alpha: .1),
            trackHeight: 3,
          ),
        ),
        child: ListView(
          key: const PageStorageKey('desktop-settings-scroll'),
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            _tabs(),
            const SizedBox(height: 20),
            _header(kind, config),
            if (!config.enabled)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  '开启后显示桌面列表和快捷入口，已有内容与外观设置会继续保留。',
                  style: const TextStyle(
                    color: AppColors.muted,
                    fontSize: 12,
                    height: 1.6,
                  ),
                ),
              ),
            if (_error != null) _notice(_error!),
            if (widget.notes.error != null) _notice(widget.notes.error!),
            const SizedBox(height: 18),
            _section(
              '展示位置',
              Icons.desktop_windows_outlined,
              config.enabled,
              _position(kind, config),
            ),
            _section(
              '文字样式',
              Icons.text_fields_rounded,
              config.enabled,
              _typography(kind, config, preview),
            ),
            _section(
              '卡片外观',
              Icons.palette_outlined,
              config.enabled,
              LayoutBuilder(
                builder: (context, constraints) {
                  final fields = _appearance(kind, config, preview);
                  final sample = _ThemePreview(kind: kind, config: preview);
                  if (constraints.maxWidth < 620) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [fields, const SizedBox(height: 20), sample],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: fields),
                      const SizedBox(width: 24),
                      Expanded(child: sample),
                    ],
                  );
                },
              ),
            ),
            _section(
              '快速添加',
              Icons.keyboard_outlined,
              config.enabled,
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          kind == DeskKind.note ? '单按 F3 新增便签' : '双按 F3 新增待办',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 5),
                        const Text(
                          '也可从快捷剪切板或管理页面添加',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.muted,
                            height: 1.6,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.sidebar,
                      border: Border.all(color: AppColors.line),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Text(
                      kind == DeskKind.note ? 'F3' : 'F3 × 2',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.muted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            _section(
              '云同步',
              Icons.cloud_sync_outlined,
              config.enabled,
              Column(
                children: [
                  _line(
                    '同步${kind.label}',
                    _switch(
                      config.sync,
                      config.enabled
                          ? (value) => _set(kind, {'sync': value})
                          : null,
                      label: '同步${kind.label}',
                      key: ValueKey('desk-sync-${kind.name}'),
                    ),
                  ),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '使用“云同步”中已配置的仓库和同步频率，仅同步内容与状态。显示位置、主题和草稿保存在本机。',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.muted,
                        height: 1.7,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget _tabs() => Align(
    alignment: Alignment.centerLeft,
    child: Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final kind in DeskKind.values)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: TextButton.icon(
                key: ValueKey('desk-settings-tab-${kind.name}'),
                onPressed: () => setState(() => _kind = kind),
                style: TextButton.styleFrom(
                  backgroundColor: _kind == kind
                      ? AppColors.primarySoft
                      : Colors.transparent,
                  foregroundColor: _kind == kind
                      ? AppColors.primary
                      : AppColors.muted,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(9),
                  ),
                ),
                icon: Icon(
                  kind == DeskKind.note
                      ? Icons.sticky_note_2_outlined
                      : Icons.checklist_outlined,
                  size: 17,
                ),
                label: Text(
                  '${kind.label}设置',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: _kind == kind
                        ? FontWeight.w700
                        : FontWeight.w500,
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );

  Widget _header(DeskKind kind, DeskSettings config) => LayoutBuilder(
    builder: (context, constraints) {
      final title = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${kind.label}设置',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 5),
          const Text(
            '管理桌面展示、卡片外观与快捷添加',
            style: TextStyle(color: AppColors.muted, fontSize: 11, height: 1.6),
          ),
        ],
      );
      final toggle = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('启用${kind.label}', style: const TextStyle(fontSize: 12)),
          const SizedBox(width: 8),
          _switch(
            config.enabled,
            (value) => _set(kind, {'enabled': value}),
            label: '启用${kind.label}',
            key: ValueKey('desk-enabled-${kind.name}'),
          ),
        ],
      );
      if (constraints.maxWidth < 440) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [title, const SizedBox(height: 12), toggle],
        );
      }
      return Row(
        children: [
          Expanded(child: title),
          const SizedBox(width: 12),
          toggle,
        ],
      );
    },
  );

  Widget _notice(String message) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.info_outline, size: 16, color: AppColors.danger),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            message,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.danger,
              height: 1.5,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _section(String title, IconData icon, bool enabled, Widget child) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: AppCard(
          child: Opacity(
            opacity: enabled ? 1 : .55,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 17, color: AppColors.muted),
                    const SizedBox(width: 8),
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                child,
              ],
            ),
          ),
        ),
      );

  Widget _position(DeskKind kind, DeskSettings config) {
    final ids = _monitors.map((e) => e['id'] as String).toSet();
    final selector = DropdownButtonFormField<String>(
      key: ValueKey(
        'desk-monitor-${kind.name}-${config.monitor}-${_monitors.length}',
      ),
      isExpanded: true,
      initialValue: config.monitor,
      style: const TextStyle(fontSize: 12, color: AppColors.text),
      decoration: const InputDecoration(
        labelText: '显示器',
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 13),
      ),
      items: [
        const DropdownMenuItem(value: '', child: Text('主显示器')),
        for (final monitor in _monitors)
          DropdownMenuItem(
            value: monitor['id'] as String,
            child: Text(
              monitor['label'] as String,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        if (config.monitor.isNotEmpty && !ids.contains(config.monitor))
          DropdownMenuItem(
            value: config.monitor,
            child: const Text(
              '原显示器未连接（临时使用主屏）',
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: !config.enabled
          ? null
          : (value) {
              if (value != null) {
                _set(kind, {
                  'monitor': value,
                  'x': -1.0,
                  'y': -1.0,
                  'height': 0.0,
                });
              }
            },
    );
    final actions = Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        OutlinedButton.icon(
          key: ValueKey('desk-select-region-${kind.name}'),
          onPressed: !config.enabled
              ? null
              : () => _attempt(() => widget.notes.selectRegion(kind)),
          icon: const Icon(Icons.crop_free, size: 16),
          label: const Text('选取展示区域'),
        ),
        IconButton(
          tooltip: '刷新显示器',
          onPressed: config.enabled ? _loadMonitors : null,
          icon: const Icon(Icons.refresh, size: 18),
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 540) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [selector, const SizedBox(height: 12), actions],
              );
            }
            return Row(
              children: [
                Expanded(child: selector),
                const SizedBox(width: 16),
                actions,
              ],
            );
          },
        ),
        const SizedBox(height: 12),
        Text(
          config.height == 0
              ? (kind == DeskKind.note
                    ? '默认位于桌面左侧，避开任务栏'
                    : '默认位于桌面右上角，使用任务栏之外的可用高度')
              : '区域 ${config.width.round()} × ${config.height.round()} 像素 · 位置 ${config.x.round()}, ${config.y.round()}',
          style: const TextStyle(
            fontSize: 11,
            color: AppColors.muted,
            height: 1.6,
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: !config.enabled
                ? null
                : () => _set(kind, {
                    'x': -1.0,
                    'y': -1.0,
                    'width': 320.0,
                    'height': 0.0,
                  }),
            child: const Text('恢复默认区域'),
          ),
        ),
      ],
    );
  }

  Widget _typography(
    DeskKind kind,
    DeskSettings config,
    DeskSettings preview,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      DropdownButtonFormField<String>(
        key: ValueKey('desk-font-family-${kind.name}'),
        initialValue: config.fontFamily,
        isExpanded: true,
        style: const TextStyle(fontSize: 12, color: AppColors.text),
        decoration: const InputDecoration(labelText: '默认字体'),
        items: [
          for (final item in deskFontFamilies.entries)
            DropdownMenuItem(value: item.key, child: Text(item.value)),
          if (!deskFontFamilies.containsKey(config.fontFamily))
            DropdownMenuItem(
              value: config.fontFamily,
              child: Text(config.fontFamily, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: !config.enabled
            ? null
            : (value) {
                if (value != null) _set(kind, {'fontFamily': value});
              },
      ),
      const SizedBox(height: 18),
      Row(
        children: [
          const Expanded(child: Text('默认字号', style: TextStyle(fontSize: 12))),
          Text(
            '${preview.fontSize.round()}',
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      Slider(
        key: ValueKey('desk-font-size-${kind.name}'),
        value: preview.fontSize.clamp(10, 32),
        min: 10,
        max: 32,
        divisions: 22,
        label: '${preview.fontSize.round()}',
        onChanged: !config.enabled
            ? null
            : (value) => setState(() => _fontSizePreview[kind] = value),
        onChangeEnd: !config.enabled
            ? null
            : (value) async {
                await _set(kind, {'fontSize': value});
                if (mounted) setState(() => _fontSizePreview.remove(kind));
              },
      ),
      const SizedBox(height: 4),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          OutlinedButton.icon(
            key: ValueKey('desk-text-color-${kind.name}'),
            onPressed: !config.enabled
                ? null
                : () async {
                    final selected = await pickDeskTextColor(
                      context,
                      initialColor:
                          config.textColor ?? AppColors.text.toARGB32(),
                    );
                    if (selected != null && mounted) {
                      await _set(kind, {'textColor': selected});
                    }
                  },
            icon: Container(
              width: 19,
              height: 19,
              decoration: BoxDecoration(
                color: config.textColor == null
                    ? AppColors.primary
                    : Color(config.textColor!),
                border: Border.all(color: AppColors.line),
                borderRadius: BorderRadius.circular(5),
              ),
            ),
            label: Text(
              config.textColor == null
                  ? '文字颜色：自动匹配背景'
                  : '文字颜色：${deskColorHex(config.textColor!)}',
            ),
          ),
          if (config.textColor != null)
            TextButton(
              key: ValueKey('desk-text-color-reset-${kind.name}'),
              onPressed: !config.enabled
                  ? null
                  : () => _set(kind, {'textColor': null}),
              child: const Text('自动匹配背景'),
            ),
        ],
      ),
      const SizedBox(height: 10),
      const Text(
        '默认样式应用于整个桌面列表；单条内容可在新增或编辑时单独设置。',
        style: TextStyle(fontSize: 11, color: AppColors.muted, height: 1.6),
      ),
    ],
  );

  Widget _appearance(DeskKind kind, DeskSettings config, DeskSettings preview) {
    final gradient = config.gradient != 'none';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _colorLine(kind, config, 'color', '背景颜色', config.color),
        _line(
          '使用渐变',
          _switch(
            gradient,
            !config.enabled
                ? null
                : (value) {
                    if (!value && gradient) {
                      _lastGradient[kind] = config.gradient;
                    }
                    _set(kind, {
                      'gradient': value
                          ? _lastGradient[kind] ?? 'diagonal'
                          : 'none',
                    });
                  },
            label: '使用渐变',
            key: ValueKey('desk-gradient-enabled-${kind.name}'),
          ),
        ),
        if (gradient) ...[
          _colorLine(kind, config, 'color2', '第二种颜色', config.color2),
          _line(
            '渐变方式',
            SizedBox(
              width: 154,
              child: DropdownButtonFormField<String>(
                key: ValueKey('desk-gradient-${kind.name}-${config.gradient}'),
                initialValue: config.gradient,
                isExpanded: true,
                style: const TextStyle(fontSize: 12, color: AppColors.text),
                decoration: const InputDecoration(
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 10,
                  ),
                ),
                items: const [
                  DropdownMenuItem(value: 'diagonal', child: Text('左上 → 右下')),
                  DropdownMenuItem(value: 'vertical', child: Text('从上到下')),
                  DropdownMenuItem(value: 'horizontal', child: Text('从左到右')),
                  DropdownMenuItem(value: 'radial', child: Text('中心向外')),
                ],
                onChanged: !config.enabled
                    ? null
                    : (value) {
                        if (value != null) {
                          _lastGradient[kind] = value;
                          _set(kind, {'gradient': value});
                        }
                      },
              ),
            ),
          ),
        ],
        _line(
          '透明背景',
          _switch(
            config.transparent,
            !config.enabled
                ? null
                : (value) => _set(kind, {'transparent': value}),
            label: '透明背景',
            key: ValueKey('desk-transparent-${kind.name}'),
          ),
        ),
        if (config.transparent) ...[
          const SizedBox(height: 2),
          Row(
            children: [
              const Expanded(
                child: Text('透明度', style: TextStyle(fontSize: 12)),
              ),
              Text(
                '${((1 - preview.opacity) * 100).round()}%',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          Slider(
            key: ValueKey('desk-opacity-${kind.name}'),
            value: 1 - preview.opacity,
            divisions: 100,
            label: '${((1 - preview.opacity) * 100).round()}%',
            onChanged: !config.enabled
                ? null
                : (value) => setState(() => _opacityPreview[kind] = 1 - value),
            onChangeEnd: !config.enabled
                ? null
                : (value) async {
                    await _set(kind, {'opacity': 1 - value});
                    if (mounted) setState(() => _opacityPreview.remove(kind));
                  },
          ),
        ],
        const Text(
          '透明度只影响底色，毛玻璃与文字始终保留。',
          style: TextStyle(fontSize: 11, color: AppColors.muted, height: 1.6),
        ),
      ],
    );
  }

  Widget _colorLine(
    DeskKind kind,
    DeskSettings config,
    String field,
    String label,
    int value,
  ) => _line(
    label,
    SizedBox(
      key: ValueKey('desk-color-input-${kind.name}-$field'),
      width: 154,
      child: TextFormField(
        key: ValueKey('desk-color-${kind.name}-$field-$value'),
        enabled: config.enabled,
        initialValue: deskColorHex(value),
        style: const TextStyle(fontSize: 12),
        decoration: InputDecoration(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 10,
          ),
          helperText: '输入后按 Enter 应用',
          helperStyle: const TextStyle(fontSize: 10, color: AppColors.muted),
          suffixIcon: IconButton(
            tooltip: '选择$label',
            onPressed: !config.enabled
                ? null
                : () async {
                    final selected = await pickDeskColor(
                      context,
                      label: label,
                      initialColor: value,
                    );
                    if (selected != null && mounted) {
                      await _set(kind, {field: selected});
                    }
                  },
            icon: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: Color(value),
                border: Border.all(color: AppColors.line),
                borderRadius: BorderRadius.circular(6),
              ),
            ),
          ),
        ),
        onFieldSubmitted: (text) {
          final parsed = parseDeskColor(text);
          if (parsed == null) {
            showMessage(context, '请输入 6 位颜色值，例如 #FFFFFF');
            return;
          }
          _set(kind, {field: parsed});
        },
      ),
    ),
  );

  Widget _line(String label, Widget control) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      children: [
        Expanded(child: Text(label, style: const TextStyle(fontSize: 12))),
        const SizedBox(width: 12),
        control,
      ],
    ),
  );

  Widget _switch(
    bool value,
    ValueChanged<bool>? onChanged, {
    required String label,
    Key? key,
  }) => Semantics(
    label: label,
    child: Switch(
      key: key,
      value: value,
      onChanged: onChanged,
      activeThumbColor: Colors.white,
      activeTrackColor: AppColors.primary,
      inactiveThumbColor: AppColors.muted,
      inactiveTrackColor: AppColors.line,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
  );
}

class _ThemePreview extends StatelessWidget {
  const _ThemePreview({required this.kind, required this.config});
  final DeskKind kind;
  final DeskSettings config;

  @override
  Widget build(BuildContext context) {
    // The slider controls the tint, while a clear glass material retains its
    // backdrop blur and a small amount of colour even at 100% transparency.
    final alpha = config.transparent ? .10 + .90 * config.opacity : 1.0;
    final color = Color(config.color), color2 = Color(config.color2);
    final colors = [
      color.withValues(alpha: alpha),
      color2.withValues(alpha: alpha),
    ];
    final tint = config.gradient == 'none'
        ? color
        : Color.lerp(color, color2, .5)!;
    final composite = Color.alphaBlend(
      tint.withValues(alpha: alpha),
      const Color(0xFFD4C8DF),
    );
    final dark = composite.computeLuminance() < .20;
    final customInk = config.textColor == null
        ? null
        : Color(config.textColor!);
    final ink =
        customInk ?? (dark ? const Color(0xFFF4F0FA) : const Color(0xFF302B3C));
    final paragraph =
        customInk ?? (dark ? const Color(0xFFE7E2F0) : const Color(0xFF443C51));
    final muted =
        customInk ?? (dark ? const Color(0xFFD3C6E4) : const Color(0xFF62576F));
    final family = config.fontFamily.isEmpty ? null : config.fontFamily;
    final size = config.fontSize;
    final captionSize = (size - 1).clamp(10.0, 32.0);
    Gradient? gradient;
    if (config.gradient == 'radial') {
      gradient = RadialGradient(colors: colors, radius: .9);
    } else if (config.gradient != 'none') {
      gradient = LinearGradient(
        colors: colors,
        begin: config.gradient == 'horizontal'
            ? Alignment.centerLeft
            : config.gradient == 'vertical'
            ? Alignment.topCenter
            : Alignment.topLeft,
        end: config.gradient == 'horizontal'
            ? Alignment.centerRight
            : config.gradient == 'vertical'
            ? Alignment.bottomCenter
            : Alignment.bottomRight,
      );
    }
    final card = Container(
      key: ValueKey('desk-preview-card-${kind.name}'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: gradient == null ? colors.first : null,
        gradient: gradient,
        borderRadius: BorderRadius.circular(18),
      ),
      child: kind == DeskKind.note
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '刚刚',
                  style: TextStyle(
                    fontFamily: family,
                    fontSize: captionSize,
                    color: muted,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  '给想法一个落脚点',
                  style: TextStyle(
                    fontFamily: family,
                    fontSize: size + 2,
                    fontWeight: FontWeight.w600,
                    color: ink,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  '随手记录，在需要的时候看见。',
                  style: TextStyle(
                    fontFamily: family,
                    fontSize: size,
                    height: 1.8,
                    color: paragraph,
                  ),
                ),
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 3),
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    border: Border.all(color: muted, width: 1.5),
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '把今天的小事做好',
                        style: TextStyle(
                          fontFamily: family,
                          fontSize: size + 1,
                          height: 1.6,
                          fontWeight: FontWeight.w600,
                          color: ink,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '待完成',
                        style: TextStyle(
                          fontFamily: family,
                          fontSize: captionSize,
                          color: muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
    return ClipRRect(
      key: ValueKey('desk-theme-preview-${kind.name}'),
      borderRadius: BorderRadius.circular(12),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFD4D8EB), Color(0xFFC3BAD7)],
          ),
        ),
        child: Stack(
          children: [
            const Positioned(
              right: -36,
              top: -48,
              child: SizedBox.square(
                dimension: 200,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [Color(0xFFF5D7C6), Color(0x00F5D7C6)],
                    ),
                  ),
                ),
              ),
            ),
            const Positioned(
              left: -24,
              bottom: -38,
              child: SizedBox.square(
                dimension: 176,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFFB1C6DA),
                  ),
                ),
              ),
            ),
            Positioned(
              right: -24,
              top: 92,
              child: Transform.rotate(
                angle: -.55,
                child: Container(
                  width: 240,
                  height: 45,
                  decoration: BoxDecoration(
                    color: const Color(0xFFB8A8D0),
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 216),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      '桌面效果预览',
                      style: TextStyle(fontSize: 11, color: Color(0xFF6C6379)),
                    ),
                    const SizedBox(height: 13),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: config.transparent
                          ? BackdropFilter(
                              key: ValueKey('desk-glass-backdrop-${kind.name}'),
                              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                              child: card,
                            )
                          : card,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      config.transparent ? '毛玻璃保留，文字始终清晰显示' : '实色背景，文字始终清晰显示',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF6C6379),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
