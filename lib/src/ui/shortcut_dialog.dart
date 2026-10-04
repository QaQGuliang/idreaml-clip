import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/quick_shortcut.dart';
import '../services/desktop_service.dart';
import 'app_theme.dart';

class ShortcutDialog extends StatefulWidget {
  const ShortcutDialog({super.key, required this.desktopService});
  final DesktopService desktopService;

  @override
  State<ShortcutDialog> createState() => _ShortcutDialogState();
}

class _ShortcutDialogState extends State<ShortcutDialog> {
  late QuickShortcut _shortcut = widget.desktopService.controller.quickShortcut;
  final _recordFocus = FocusNode(debugLabel: 'shortcut recorder');
  QuickShortcut? _candidate;
  bool _recording = false;
  bool _invalidChord = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _recordFocus.dispose();
    super.dispose();
  }

  void _startRecording() {
    setState(() {
      _recording = true;
      _candidate = null;
      _invalidChord = false;
      _error = null;
    });
    _recordFocus.requestFocus();
  }

  void _cancelRecording() {
    if (!_recording) return;
    setState(() {
      _recording = false;
      _candidate = null;
      _invalidChord = false;
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!_recording || _saving) return KeyEventResult.ignored;
    if (event.synthesized) return KeyEventResult.handled;
    final pressed = HardwareKeyboard.instance.physicalKeysPressed;
    if (event is KeyDownEvent) {
      if (event.physicalKey == PhysicalKeyboardKey.escape &&
          pressed.length == 1) {
        _cancelRecording();
        return KeyEventResult.handled;
      }
      final ordinary = pressed.where(
        (key) => !QuickShortcut.modifierKeys.contains(key),
      );
      if (ordinary.length > 1) {
        setState(() {
          _candidate = null;
          _invalidChord = true;
          _error = '一次录入一个组合：修饰键加一个普通键，或单个按键';
        });
      } else if (ordinary.length == 1 && !_invalidChord) {
        final candidate = QuickShortcut.fromPressedKeys(
          ordinary.single,
          pressed,
        );
        setState(() {
          if (candidate.isValid) {
            _candidate = candidate;
            _error = null;
          } else {
            _candidate = null;
            _invalidChord = true;
            _error = '系统不支持这个按键，请重新录入';
          }
        });
      }
    } else if (event is KeyUpEvent && pressed.isEmpty) {
      setState(() {
        if (_candidate != null && !_invalidChord) {
          _shortcut = _candidate!;
          _recording = false;
        }
        _candidate = null;
        _invalidChord = false;
      });
    }
    // Consume Tab, Enter and arrow keys so recording never navigates or saves.
    return KeyEventResult.handled;
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final error = await widget.desktopService.updateQuickShortcut(_shortcut);
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      _saving = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: const Text('自定义快捷键'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('点击下方区域，再按下你想使用的完整组合。'),
            const SizedBox(height: 16),
            Focus(
              focusNode: _recordFocus,
              onKeyEvent: _onKey,
              onFocusChange: (focused) {
                if (!focused) _cancelRecording();
              },
              child: Semantics(
                button: true,
                label: '录入完整快捷键',
                child: InkWell(
                  key: const ValueKey('shortcut-recorder'),
                  canRequestFocus: false,
                  onTap: _saving ? null : _startRecording,
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 26,
                    ),
                    decoration: BoxDecoration(
                      color: _recording
                          ? AppColors.primarySoft
                          : const Color(0xFFF8F8FA),
                      border: Border.all(
                        color: _recording ? AppColors.primary : AppColors.line,
                        width: _recording ? 2 : 1,
                      ),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      children: [
                        const Icon(
                          Icons.keyboard_outlined,
                          color: AppColors.primary,
                          size: 28,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _recording
                              ? (_candidate?.label() ?? '请按下快捷键…')
                              : _shortcut.label(),
                          key: const ValueKey('recorded-shortcut'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 18,
                            color: AppColors.primary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _recording ? '松开全部按键完成录入 · Esc 取消录入' : '点击此处录入或重新录入',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Text('修饰键和主键均可更换，保存后立即生效。'),
            const SizedBox(height: 8),
            Text(
              '默认：${QuickShortcut.platformDefault().label()}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: const TextStyle(color: AppColors.danger),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving
              ? null
              : () {
                  _cancelRecording();
                  setState(() {
                    _shortcut = QuickShortcut.platformDefault();
                    _error = null;
                  });
                },
          child: const Text('恢复默认'),
        ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving || _recording ? null : _save,
          child: Text(_saving ? '保存中…' : '保存'),
        ),
      ],
    ),
  );
}
