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
