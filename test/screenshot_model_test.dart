import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:idreaml_clip/src/screenshot/screenshot_model.dart';
import 'package:idreaml_clip/src/screenshot/screenshot_renderer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ScreenshotAnnotation rectangle(int id) => ScreenshotAnnotation(
    id: id,
    tool: ScreenshotTool.rectangle,
    points: const [Offset(10, 10), Offset(30, 30)],
    style: const ToolStyle(),
  );

  test('标注之后调整选区不会移动对象，选区和对象可分别撤销重做', () {
    final m = ScreenshotModel(const Size(100, 80));
    m.selectAll();
    m.begin();
    m.add(rectangle(1));
    m.end();
    m.begin();
    m.setSelection(const Rect.fromLTWH(20, 20, 30, 30));
    m.end();
    expect(m.annotations.single.points.first, const Offset(10, 10));
    m.undo();
    expect(m.selection, m.screen);
    expect(m.annotations, hasLength(1));
    m.undo();
    expect(m.annotations, isEmpty);
    m.redo();
    m.redo();
    expect(m.selection, const Rect.fromLTWH(20, 20, 30, 30));
    m.dispose();
  });

  test('一次拖动只有一个撤销项，新的修改清空重做分支', () {
    final m = ScreenshotModel(const Size(100, 100));
    m.selectAll();
    m.begin();
    for (var i = 20; i < 50; i++) {
      m.setSelection(Rect.fromLTWH(0, 0, i.toDouble(), 20));
    }
    m.end();
    m.undo();
    expect(m.selection, m.screen);
    m.begin();
    m.add(rectangle(1));
    m.end();
    expect(m.canRedo, isFalse);
    m.dispose();
  });

  test('选区裁剪到屏幕像素边界，移动不改变尺寸', () {
    final m = ScreenshotModel(const Size(100, 80));
    m.setSelection(const Rect.fromLTRB(-3, -5, 60.2, 92));
    expect(m.selection, const Rect.fromLTRB(0, 0, 61, 80));
    m.nudge(const Offset(100, 1));
    expect(m.selection, const Rect.fromLTRB(39, 0, 100, 80));
    m.dispose();
  });

  test('编号删除不重排，撤销重做保留编号，新会话重新计数', () {
    final m = ScreenshotModel(const Size(100, 100));
    for (var i = 0; i < 3; i++) {
      m.begin();
      m.add(
        ScreenshotAnnotation(
          id: m.nextId++,
          tool: ScreenshotTool.number,
          points: [Offset(20.0 * i, 20)],
          style: const ToolStyle(),
          number: m.nextNumber++,
        ),
      );
      m.end();
    }
    m.selectedId = 2;
    m.deleteSelected();
    expect(m.annotations.map((a) => a.number), [1, 3]);
    m.undo();
    expect(m.annotations.map((a) => a.number), [1, 2, 3]);
    m.redo();
    expect(m.nextNumber, 4);
    final next = ScreenshotModel(m.size);
    expect(next.nextNumber, 1);
    next.dispose();
    m.dispose();
  });

  test('工具样式分别持久化，损坏数据回退默认值', () {
    final m = ScreenshotModel(const Size(100, 100));
    m.chooseTool(ScreenshotTool.pen);
    m.setStyle(const ToolStyle(color: Colors.blue, width: 8));
    m.chooseTool(ScreenshotTool.text);
    m.setStyle(const ToolStyle(fontSize: 40));
    final next = ScreenshotModel(m.size, styles: m.encodeStyles());
    next.chooseTool(ScreenshotTool.pen);
    expect(next.style.width, 8);
    expect(next.style.color.toARGB32(), Colors.blue.toARGB32());
    next.chooseTool(ScreenshotTool.text);
    expect(next.style.fontSize, 40);
    final corrupt = ScreenshotModel(m.size, styles: 'bad');
    expect(corrupt.style.width, 3);
    m.dispose();
    next.dispose();
    corrupt.dispose();
  });

  test('取消正在进行的编辑恢复原状，不产生撤销项', () {
    final m = ScreenshotModel(const Size(100, 100));
    m.begin();
    m.add(rectangle(1));
    m.cancelGesture();
    expect(m.annotations, isEmpty);
    expect(m.canUndo, isFalse);
    m.dispose();
  });

  test('正在绘制时连续调整粗细仍是一笔，撤销重做保留最终粗细和路径', () {
    for (final tool in [
      ScreenshotTool.rectangle,
      ScreenshotTool.ellipse,
      ScreenshotTool.line,
      ScreenshotTool.arrow,
      ScreenshotTool.pen,
      ScreenshotTool.highlighter,
    ]) {
      final model = ScreenshotModel(const Size(200, 200))..chooseTool(tool);
      const initial = ToolStyle(
        color: Colors.blue,
        width: 3,
        fontSize: 48,
        arrowStyle: ArrowStyle.outlined,
      );
      model.setStyle(initial);
      model.begin();
      model.add(
        ScreenshotAnnotation(
          id: 1,
          tool: tool,
          points: const [Offset(20, 20), Offset(30, 30)],
          style: model.style,
        ),
      );
      expect(model.adjustSize(1), isTrue);
      expect(model.adjustSize(1), isTrue);
      expect(model.adjustSize(-1), isTrue);
      expect(model.hasGesture, isTrue);
      expect(model.canUndo, isFalse);
      expect(model.selected!.style.width, 4);
      expect(model.selected!.style.color, initial.color);
      expect(model.selected!.style.fontSize, initial.fontSize);
      expect(model.selected!.style.arrowStyle, initial.arrowStyle);
      model.replace(
        model.selected!.copyWith(
          points: const [Offset(20, 20), Offset(80, 100)],
        ),
      );
      model.end();
      model.undo();
      expect(model.annotations, isEmpty);
      expect(model.canUndo, isFalse);
      model.redo();
      expect(model.annotations.single.points.last, const Offset(80, 100));
      expect(model.annotations.single.style.width, 4);
      final next = ScreenshotModel(model.size, styles: model.encodeStyles())
        ..chooseTool(tool);
      expect(next.style.width, 4);
      expect(next.style.color.toARGB32(), Colors.blue.toARGB32());
      next.dispose();
      model.dispose();
    }
  });

  test('选择工具对已有对象调整尺寸，边界不产生修改，尺寸调整可单独撤销', () {
    for (final (tool, minimum, maximum) in [
      (ScreenshotTool.rectangle, 1.0, 40.0),
      (ScreenshotTool.mosaic, 2.0, 40.0),
      (ScreenshotTool.number, 12.0, 96.0),
    ]) {
      final numbered = tool == ScreenshotTool.number;
      for (final (size, direction) in [(minimum, -1), (maximum, 1)]) {
        final model = ScreenshotModel(const Size(200, 200));
        final object = ScreenshotAnnotation(
          id: 1,
          tool: tool,
          points: const [Offset(30, 30), Offset(60, 60)],
          style: ToolStyle(
            width: numbered ? 3 : size,
            fontSize: numbered ? size : 24,
          ),
          number: 7,
        );
        model.add(object);
        expect(model.tool, ScreenshotTool.select);
        expect(model.adjustSize(direction), isTrue);
        expect(model.annotations.single, same(object));
        expect(model.canUndo, isFalse);
        expect(model.adjustSize(-direction), isTrue);
        final changed = model.annotations.single;
        expect(
          numbered ? changed.style.fontSize : changed.style.width,
          size - direction * (numbered ? 2 : 1),
        );
        expect(changed.points, object.points);
        expect(changed.number, 7);
        if (numbered) expect(changed.bounds.size, isNot(object.bounds.size));
        model.undo();
        expect(model.annotations.single, same(object));
        expect(model.canUndo, isFalse);
        model.redo();
        expect(model.annotations.single, same(changed));
        model.dispose();
      }
    }
  });

  test('旧马赛克粗细按实际块大小调整，文字和遮盖不会响应尺寸快捷键', () {
    final model = ScreenshotModel(
      const Size(100, 100),
      styles: '{"mosaic":{"width":1,"fontSize":56}}',
    )..chooseTool(ScreenshotTool.mosaic);
    expect(model.adjustSize(-1), isTrue);
    expect(model.canUndo, isFalse);
    expect(model.adjustSize(1), isTrue);
    expect(model.style.width, 3);
    expect(model.style.fontSize, 56);
    for (final tool in [
      ScreenshotTool.select,
      ScreenshotTool.text,
      ScreenshotTool.cover,
    ]) {
      model.chooseTool(tool);
      final before = model.encodeStyles();
      expect(model.adjustSize(1), isFalse);
      expect(model.adjustSize(-1), isFalse);
      expect(model.encodeStyles(), before);
    }
    model.dispose();
  });

  test('取消含粗细调整的笔画恢复画布，固定默认箭头不会覆盖上次选款', () {
    final model = ScreenshotModel(
      const Size(100, 100),
      styles: '{"arrow":{"arrowStyle":"dashed","width":7}}',
      initialArrowStyle: ArrowStyle.filled,
    )..chooseTool(ScreenshotTool.arrow);
    model.begin();
    model.add(
      ScreenshotAnnotation(
        id: 1,
        tool: ScreenshotTool.arrow,
        points: const [Offset(20, 20), Offset(70, 70)],
        style: model.style,
      ),
    );
    model.adjustSize(1);
    expect(model.selected!.style.arrowStyle, ArrowStyle.filled);
    model.cancelGesture();
    expect(model.annotations, isEmpty);
    expect(model.canUndo, isFalse);
    final reopened = ScreenshotModel(model.size, styles: model.encodeStyles())
      ..chooseTool(ScreenshotTool.arrow);
    expect(reopened.style.arrowStyle, ArrowStyle.dashed);
    expect(reopened.style.width, 8);
    reopened.dispose();
    model.dispose();
  });

  test('旧版样式、未知箭头和指定默认值均保留原来的颜色和粗细', () {
    for (final extra in [
      '',
      ',"arrowStyle":"newerVersion"',
      ',"arrowStyle":42',
    ]) {
      final saved = '{"arrow":{"color":4278190335,"width":7$extra}}';
      final old = ScreenshotModel(const Size(100, 100), styles: saved)
        ..chooseTool(ScreenshotTool.arrow);
      expect(old.style.arrowStyle, ArrowStyle.single);
      final preset = ScreenshotModel(
        old.size,
        styles: saved,
        initialArrowStyle: ArrowStyle.filled,
      )..chooseTool(ScreenshotTool.arrow);
      expect(preset.style.arrowStyle, ArrowStyle.filled);
      expect(preset.style.color.toARGB32(), 4278190335);
      expect(preset.style.width, 7);
      final next = ScreenshotModel(old.size, styles: preset.encodeStyles())
        ..chooseTool(ScreenshotTool.arrow);
      expect(next.style.arrowStyle, ArrowStyle.single);
      old.dispose();
      preset.dispose();
      next.dispose();
    }
  });

  test('固定样式只用于本次编辑；转长图继承当前样式，主动选款才改写上次选择', () {
    const saved = '{"arrow":{"arrowStyle":"dashed","width":7}}';
    final normal = ScreenshotModel(
      const Size(100, 80),
      styles: saved,
      initialArrowStyle: ArrowStyle.filled,
    )..chooseTool(ScreenshotTool.arrow);
    ArrowStyle savedShape(ScreenshotModel m) {
      final reopened = ScreenshotModel(m.size, styles: m.encodeStyles())
        ..chooseTool(ScreenshotTool.arrow);
      final result = reopened.style.arrowStyle;
      reopened.dispose();
      return result;
    }

    expect(normal.style.arrowStyle, ArrowStyle.filled);
    expect(savedShape(normal), ArrowStyle.dashed); // Open and cancel.
    normal.setStyle(normal.style.copyWith(color: Colors.blue));
    expect(savedShape(normal), ArrowStyle.dashed);
    final long = ScreenshotModel.forLongImage(const Size(100, 300), normal)
      ..chooseTool(ScreenshotTool.arrow);
    expect(long.style.arrowStyle, ArrowStyle.filled);
    expect(long.style.width, 7);
    expect(long.style.color, Colors.blue);
    expect(savedShape(long), ArrowStyle.dashed);
    long.setStyle(long.style.copyWith(arrowStyle: ArrowStyle.elbow));
    expect(long.style.arrowStyle, ArrowStyle.elbow);
    expect(savedShape(long), ArrowStyle.elbow);
    normal.dispose();
    long.dispose();
  });

  test('选中箭头可修改形状并撤销重做，端点与其他标注不变', () {
    final m = ScreenshotModel(const Size(200, 200));
    final other = rectangle(1);
    const arrow = ScreenshotAnnotation(
      id: 2,
      tool: ScreenshotTool.arrow,
      points: [Offset(20, 20), Offset(100, 70)],
      style: ToolStyle(width: 6),
    );
    m.add(other);
    m.add(arrow);
    m.setStyle(arrow.style.copyWith(arrowStyle: ArrowStyle.elbow));
    expect(m.annotations.first, same(other));
    expect(m.annotations.last.points, arrow.points);
    expect(m.annotations.last.hit(const Offset(20, 52), 0), isTrue);
    expect(m.annotations.last.hit(const Offset(60, 45), 0), isFalse);
    m.undo();
    expect(m.annotations.last, same(arrow));
    expect(m.annotations.last.hit(const Offset(60, 45), 0), isTrue);
    m.redo();
    expect(m.annotations.last.style.arrowStyle, ArrowStyle.elbow);
    m.dispose();
  });

  test('各粗细箭头在垂直、反向、极短和零长度拖动时仍可选取', () {
    const origin = Offset(80, 80);
    for (final shape in ArrowStyle.values) {
      for (final width in [1.0, 3.0, 12.0, 24.0]) {
        for (final end in [
          origin,
          const Offset(80, 20),
          const Offset(22, 65),
          const Offset(80.1, 80.2),
        ]) {
          final arrow = ScreenshotAnnotation(
            id: 1,
            tool: ScreenshotTool.arrow,
            points: [origin, end],
            style: ToolStyle(width: width, arrowStyle: shape),
          );
          expect(arrow.bounds.isFinite, isTrue);
          expect(arrow.hit(origin, 1), isTrue);
          expect(arrow.hit(end, 1), isTrue);
          expect(arrow.hit(const Offset(5, 170), 2), isFalse);
          if (end != origin) {
            // Very short drags scale the complete arrow, even at a thick width.
            expect(
              arrow.bounds.longestSide,
              lessThan((end - origin).distance * 1.3),
            );
          }
        }
      }
    }
  });

  test('六种箭头导出不同轮廓，实心头、尖尾、空心和转折均可命中', () async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(Colors.white, BlendMode.src);
    final picture = recorder.endRecording();
    final height = ArrowStyle.values.length * 40;
    final background = await picture.toImage(128, height);
    picture.dispose();
    addTearDown(background.dispose);
    final arrows = [
      for (final shape in ArrowStyle.values)
        ScreenshotAnnotation(
          id: shape.index,
          tool: ScreenshotTool.arrow,
          points: [
            Offset(20, 15.0 + 40 * shape.index),
            Offset(
              100,
              15.0 + 40 * shape.index + (shape == ArrowStyle.elbow ? 14 : 0),
            ),
          ],
          style: ToolStyle(width: 4, color: Colors.black, arrowStyle: shape),
        ),
    ];
    final bytes = await exportScreenshot(
      background,
      ScreenshotSnapshot(Rect.fromLTWH(0, 0, 128, height.toDouble()), arrows),
    );
    final png = img.decodePng(bytes)!;
    bool ink(int x, int y) => png.getPixel(x, y).r < 100;
    expect(ink(87, 18), isTrue); // Standard triangle has a filled interior.
    expect(ink(87, 21), isFalse);
    expect(ink(30, 16), isTrue); // Standard shaft keeps an even thickness.
    expect(ink(30, 56), isFalse); // The solid style tapers to a point.
    expect(ink(87, 58), isTrue);
    expect(ink(87, 95), isFalse); // Outline has a transparent head interior.
    expect(ink(86, 99), isTrue);
    expect(
      arrows[ArrowStyle.outlined.index].hit(const Offset(87, 95), 0),
      isFalse,
    );
    expect(ink(33, 138), isTrue); // Second head near the start.
    expect(ink(33, 18), isFalse);
    expect([
      for (var x = 21; x < 82; x++) ink(x, 175),
    ], containsAll([true, false]));
    expect(ink(20, 223), isTrue); // Right angle.
    expect(ink(47, 229), isTrue);
    expect(ink(47, 220), isFalse);
    for (final arrow in arrows) {
      final row = arrow.style.arrowStyle.index * 40;
      for (var y = row; y < row + 40; y++) {
        for (var x = 0; x < png.width; x++) {
          if (ink(x, y)) {
            final pixel = Offset(x + .5, y + .5);
            expect(arrow.bounds.inflate(1).contains(pixel), isTrue);
            expect(arrow.hit(pixel, 1), isTrue);
          }
        }
      }
    }
  });

  test('粗细变化保持空心留白，半透明箭头接缝不叠色且轮廓均可命中', () async {
    const widths = [1.0, 3.0, 12.0, 24.0];
    final height = ArrowStyle.values.length * widths.length * 50;
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(Colors.white, BlendMode.src);
    final picture = recorder.endRecording();
    final background = await picture.toImage(160, height);
    picture.dispose();
    addTearDown(background.dispose);
    final arrows = <ScreenshotAnnotation>[];
    for (final style in ArrowStyle.values) {
      for (final width in widths) {
        final center = arrows.length * 50 + 25.0;
        arrows.add(
          ScreenshotAnnotation(
            id: arrows.length,
            tool: ScreenshotTool.arrow,
            points: [Offset(20, center), Offset(120, center)],
            style: ToolStyle(
              width: width,
              color: const Color(0x80000000),
              arrowStyle: style,
            ),
          ),
        );
      }
    }
    final bytes = await exportScreenshot(
      background,
      ScreenshotSnapshot(Rect.fromLTWH(0, 0, 160, height.toDouble()), arrows),
    );
    final png = img.decodePng(bytes)!;
    for (final arrow in arrows) {
      final row = arrow.id * 50;
      var visiblePixels = 0;
      for (var y = row; y < row + 50; y++) {
        for (var x = 0; x < png.width; x++) {
          final pixel = png.getPixel(x, y);
          expect(pixel.r, greaterThanOrEqualTo(126));
          if (pixel.r < 240) {
            visiblePixels++;
            final point = Offset(x + .5, y + .5);
            expect(arrow.bounds.inflate(1).contains(point), isTrue);
            expect(arrow.hit(point, 1), isTrue);
          }
        }
      }
      expect(visiblePixels, greaterThan(0));
      if (arrow.style.arrowStyle == ArrowStyle.outlined) {
        final headLength = math.min(arrow.style.width * 14 / 3, 48.0);
        final interior = Offset(120 - headLength * .6, row + 25);
        expect(arrow.hit(interior, 0), isFalse);
        if (arrow.style.width >= 3) {
          expect(png.getPixel(interior.dx.round(), row + 25).r, 255);
        }
      }
    }
    const outlined = ToolStyle(arrowStyle: ArrowStyle.outlined);
    expect(
      ToolStyle.fromJson(outlined.toJson()).arrowStyle,
      ArrowStyle.outlined,
    );
  });

  test('最终输出按新选区裁剪，实心遮盖烧录进像素', () async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(Colors.white, BlendMode.src);
    final picture = recorder.endRecording();
    final background = await picture.toImage(100, 80);
    picture.dispose();
    final bytes = await exportScreenshot(
      background,
      const ScreenshotSnapshot(Rect.fromLTWH(20, 10, 40, 30), [
        ScreenshotAnnotation(
          id: 1,
          tool: ScreenshotTool.cover,
          points: [Offset(25, 15), Offset(35, 25)],
          style: ToolStyle(color: Colors.black),
        ),
      ]),
    );
    final output = img.decodePng(bytes)!;
    expect(output.width, 40);
    expect(output.height, 30);
    expect(output.getPixel(10, 10).r, 0);
    expect(output.getPixel(0, 0).r, 255);
    background.dispose();
  });

  test('马赛克采样已经合成的标注，输出不包含原全屏区域', () async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(Colors.white, BlendMode.src);
    final picture = recorder.endRecording();
    final background = await picture.toImage(40, 40);
    picture.dispose();
    final bytes = await exportScreenshot(
      background,
      const ScreenshotSnapshot(Rect.fromLTWH(0, 0, 20, 20), [
        ScreenshotAnnotation(
          id: 1,
          tool: ScreenshotTool.cover,
          points: [Offset(0, 0), Offset(20, 20)],
          style: ToolStyle(color: Colors.black),
        ),
        ScreenshotAnnotation(
          id: 2,
          tool: ScreenshotTool.mosaic,
          points: [Offset(0, 0), Offset(20, 20)],
          style: ToolStyle(width: 10),
        ),
      ]),
    );
    final output = img.decodePng(bytes)!;
    expect(output.width, 20);
    expect(output.getPixel(10, 10).r, 0);
    background.dispose();
  });
}
