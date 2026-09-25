import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/models/win_v_key_state.dart';

void main() {
  WinVKeyAction press(
    WinVKeyState keys, {
    bool down = true,
    bool win = true,
    bool ctrl = false,
    bool alt = false,
    bool shift = false,
  }) => keys.handle(
    isDown: down,
    windows: win,
    control: ctrl,
    alt: alt,
    shift: shift,
  );

  test('Win+V 只唤起一次，重复按下和松开都不传给系统', () {
    final keys = WinVKeyState();
    expect(press(keys), WinVKeyAction.activate);
    expect(press(keys), WinVKeyAction.suppress);
    // Win can be released before V, without leaking V to the foreground app.
    expect(press(keys, win: false), WinVKeyAction.suppress);
    expect(press(keys, down: false, win: false), WinVKeyAction.suppress);
    expect(press(keys), WinVKeyAction.activate);
  });

  test('普通 V、Ctrl+V 及带其他修饰键的组合照常传递', () {
    for (final modifiers in [
      (false, false, false, false),
      (false, true, false, false),
      (true, true, false, false),
      (true, false, true, false),
      (true, false, false, true),
    ]) {
      final keys = WinVKeyState();
      for (final down in [true, true, false]) {
        expect(
          press(
            keys,
            down: down,
            win: modifiers.$1,
            ctrl: modifiers.$2,
            alt: modifiers.$3,
            shift: modifiers.$4,
          ),
          WinVKeyAction.pass,
        );
      }
    }
  });

  test('先按 V 再按 Win，以及启用前已按住 V，不抢占已有按键', () {
    final keys = WinVKeyState();
    expect(press(keys, win: false), WinVKeyAction.pass);
    expect(press(keys), WinVKeyAction.pass);
    expect(press(keys, down: false), WinVKeyAction.pass);
    final held = WinVKeyState(vAlreadyDown: true);
    expect(press(held), WinVKeyAction.pass);
    expect(press(held, down: false), WinVKeyAction.pass);
    expect(press(held), WinVKeyAction.activate);
  });
}
