import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:idreaml_clip/src/services/quick_panel_placement.dart';

void main() {
  const primary = Rect.fromLTWH(0, 0, 1920, 1040);

  test('在鼠标右下方展示缩小后的面板', () {
    final bounds = placeQuickPanel(
      pointer: const Offset(500, 300),
      workAreas: [primary],
    );
    expect(bounds.topLeft, const Offset(512, 312));
    expect(bounds.size, const Size(347, 427));
  });

  test('靠近右下角时翻转到左上方并避开任务栏', () {
    final bounds = placeQuickPanel(
      pointer: const Offset(1910, 1030),
      workAreas: [primary],
    );
    expect(bounds.right, lessThan(1910));
    expect(bounds.bottom, lessThan(1030));
    expect(primary.intersect(bounds), bounds);
  });

  test('使用鼠标所在的负坐标副屏', () {
    const secondary = Rect.fromLTWH(-1600, -200, 1600, 900);
    final bounds = placeQuickPanel(
      pointer: const Offset(-800, 100),
      workAreas: [primary, secondary],
    );
    expect(secondary.intersect(bounds), bounds);
    expect(bounds.topLeft, const Offset(-788, 112));
  });

  test('鼠标在任务栏上时选择最近屏幕并夹在可用区域内', () {
    final bounds = placeQuickPanel(
      pointer: const Offset(1910, 1075),
      workAreas: [primary],
    );
    expect(primary.intersect(bounds), bounds);
  });

  test('按目标屏幕 DPI 缩放尺寸和指针间距', () {
    final bounds = placeQuickPanel(
      pointer: const Offset(2200, 200),
      workAreas: [const Rect.fromLTWH(1920, 0, 2560, 1400)],
      scale: 1.5,
    );
    expect(bounds.size, quickPanelSize * 1.5);
    expect(bounds.topLeft, const Offset(2218, 218));
  });

  test('屏幕可用空间不足时仍完整保留在屏幕内', () {
    const small = Rect.fromLTWH(0, 0, 320, 400);
    final bounds = placeQuickPanel(
      pointer: const Offset(310, 390),
      workAreas: [small],
    );
    expect(small.intersect(bounds), bounds);
    expect(bounds.width, lessThan(320));
    expect(bounds.height, lessThan(400));
  });
}
