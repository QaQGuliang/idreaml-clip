import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/screenshot/screenshot_toolbar_placement.dart';

void main() {
  const screen = Size(800, 600);

  test('工具栏优先贴选区下方，放不下时到上方', () {
    final below = placeScreenshotToolbar(
      screen: screen,
      toolbar: const Size(300, 40),
      selection: const Rect.fromLTRB(100, 100, 400, 300),
    );
    expect(below.offset, const Offset(100, 300));
    expect(below.edgeHugging, isFalse);

    final above = placeScreenshotToolbar(
      screen: screen,
      toolbar: const Size(300, 40),
      selection: const Rect.fromLTRB(100, 400, 400, 560),
    );
    expect(above.offset, const Offset(100, 360));
    expect(above.edgeHugging, isFalse);
  });

  test('上下都没有空间时放到选区右侧，其次左侧', () {
    final right = placeScreenshotToolbar(
      screen: screen,
      toolbar: const Size(200, 40),
      selection: const Rect.fromLTRB(100, 20, 400, 560),
    );
    expect(right.offset, const Offset(400, 20));
    expect(right.edgeHugging, isFalse);

    final left = placeScreenshotToolbar(
      screen: screen,
      toolbar: const Size(200, 40),
      selection: const Rect.fromLTRB(500, 20, 700, 560),
    );
    expect(left.offset, const Offset(300, 20));
    expect(left.edgeHugging, isFalse);
  });

  test('靠边时横向夹紧工具栏但不越过选区左边', () {
    final placed = placeScreenshotToolbar(
      screen: screen,
      toolbar: const Size(300, 40),
      selection: const Rect.fromLTRB(600, 100, 780, 300),
    );
    expect(placed.offset, const Offset(500, 300));
  });

  test('四向都放不下时贴最近屏幕边缘并标记为贴边形态', () {
    final left = placeScreenshotToolbar(
      screen: screen,
      toolbar: const Size(300, 40),
      selection: const Rect.fromLTRB(5, 20, 795, 580),
    );
    expect(left.edge, ScreenshotToolbarEdge.left);
    expect(left.offset, const Offset(8, 280));

    final top = placeScreenshotToolbar(
      screen: screen,
      toolbar: const Size(300, 40),
      selection: const Rect.fromLTRB(100, 10, 700, 590),
    );
    expect(top.edge, ScreenshotToolbarEdge.top);
    expect(top.offset, const Offset(250, 8));

    final bottom = placeScreenshotToolbar(
      screen: screen,
      toolbar: const Size(100, 40),
      selection: const Rect.fromLTRB(100, 20, 790, 595),
    );
    expect(bottom.edge, ScreenshotToolbarEdge.bottom);
    expect(bottom.offset, const Offset(395, 552));

    final right = placeScreenshotToolbar(
      screen: screen,
      toolbar: const Size(100, 40),
      selection: const Rect.fromLTRB(10, 20, 795, 560),
    );
    expect(right.edge, ScreenshotToolbarEdge.right);
    expect(right.offset, const Offset(692, 270));
  });

  test('除贴边回退外，任何结果都不与选区重叠', () {
    const toolbar = Size(240, 42);
    for (final selection in const [
      Rect.fromLTRB(20, 20, 380, 280),
      Rect.fromLTRB(20, 300, 760, 580),
      Rect.fromLTRB(500, 60, 780, 300),
      Rect.fromLTRB(0, 0, 100, 100),
      Rect.fromLTRB(300, 30, 460, 560),
    ]) {
      final placed = placeScreenshotToolbar(
        screen: screen,
        toolbar: toolbar,
        selection: selection,
      );
      expect(placed.edgeHugging, isFalse, reason: '$selection 仍有空位');
      expect(
        (placed.offset & toolbar).overlaps(selection),
        isFalse,
        reason: '$selection 被工具栏压住',
      );
      expect(
        Rect.fromLTWH(
          0,
          0,
          screen.width,
          screen.height,
        ).contains(placed.offset),
        isTrue,
      );
    }
  });

  test('拖动偏移被限制在屏幕内，并优先于自动布局', () {
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

  test('没有选区时停在左上角，仍受屏幕约束', () {
    final placed = placeScreenshotToolbar(
      screen: screen,
      toolbar: const Size(300, 40),
    );
    expect(placed.offset, const Offset(8, 8));
    expect(placed.edgeHugging, isFalse);
  });
}
