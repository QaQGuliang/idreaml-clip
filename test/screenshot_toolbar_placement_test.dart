import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/screenshot/screenshot_toolbar_placement.dart';

void main() {
  const screen = Size(800, 600);

  test('默认放在选区左下角，允许与选区重叠', () {
    final placed = placeScreenshotToolbar(
      screen: screen,
      toolbar: const Size(300, 40),
      selection: const Rect.fromLTRB(100, 100, 400, 300),
    );
    expect(placed.offset, const Offset(100, 260));
    expect(
      (placed.offset & const Size(300, 40)).overlaps(
        const Rect.fromLTRB(100, 100, 400, 300),
      ),
      isTrue,
    );
  });

  test('选区靠右或靠下时工具栏夹紧在屏幕内', () {
    final placed = placeScreenshotToolbar(
      screen: screen,
      toolbar: const Size(300, 40),
      selection: const Rect.fromLTRB(600, 100, 780, 300),
    );
    expect(placed.offset, const Offset(492, 260));
  });

  test('没有选区时放在屏幕左下角', () {
    final placed = placeScreenshotToolbar(
      screen: screen,
      toolbar: const Size(300, 40),
    );
    expect(placed.offset, const Offset(8, 552));
  });

  test('全屏选区等同于屏幕左下角', () {
    final placed = placeScreenshotToolbar(
      screen: screen,
      toolbar: const Size(300, 40),
      selection: const Rect.fromLTRB(0, 0, 800, 600),
    );
    expect(placed.offset, const Offset(8, 552));
  });

  test('手动拖动优先于默认位置，并限制在屏幕内', () {
    final dragged = placeScreenshotToolbar(
      screen: screen,
      toolbar: const Size(300, 40),
      selection: const Rect.fromLTRB(100, 100, 400, 300),
      dragOffset: const Offset(-40, 900),
    );
    expect(dragged.offset, const Offset(8, 552));

    final inside = placeScreenshotToolbar(
      screen: screen,
      toolbar: const Size(300, 40),
      selection: const Rect.fromLTRB(100, 100, 400, 300),
      dragOffset: const Offset(120, 120),
    );
    expect(inside.offset, const Offset(120, 120));
  });

  test('没有选区时拖动同样生效', () {
    final dragged = placeScreenshotToolbar(
      screen: screen,
      toolbar: const Size(300, 40),
      dragOffset: const Offset(500, 300),
    );
    expect(dragged.offset, const Offset(492, 300));
  });
}
