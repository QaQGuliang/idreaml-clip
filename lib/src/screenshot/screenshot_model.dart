import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../models/arrow_style.dart';
import 'screenshot_arrow.dart';

export '../models/arrow_style.dart';

enum ScreenshotTool {
  select,
  rectangle,
  ellipse,
  line,
  arrow,
  pen,
  highlighter,
  text,
  mosaic,
  cover,
  number,
}

extension ScreenshotToolLabel on ScreenshotTool {
  String get label => const [
    '选择 / 调整',
    '矩形',
    '椭圆',
    '直线',
    '箭头',
    '画笔',
    '荧光笔',
    '文字',
    '马赛克',
    '实心遮盖',
    '自动编号',
  ][index];

  bool get usesWidth => switch (this) {
    ScreenshotTool.rectangle ||
    ScreenshotTool.ellipse ||
    ScreenshotTool.line ||
    ScreenshotTool.arrow ||
    ScreenshotTool.pen ||
    ScreenshotTool.highlighter ||
    ScreenshotTool.mosaic => true,
    _ => false,
  };

  bool get usesFontSize =>
      this == ScreenshotTool.text || this == ScreenshotTool.number;

  bool get usesColor =>
      this != ScreenshotTool.select && this != ScreenshotTool.mosaic;
}

@immutable
class ToolStyle {
  const ToolStyle({
    this.color = const Color(0xFFEF4444),
    this.width = 3,
    this.fontSize = 24,
    this.arrowStyle = ArrowStyle.single,
  });
  final Color color;
  final double width;
  final double fontSize;
  final ArrowStyle arrowStyle;
  ToolStyle copyWith({
    Color? color,
    double? width,
    double? fontSize,
    ArrowStyle? arrowStyle,
  }) => ToolStyle(
    color: color ?? this.color,
    width: width ?? this.width,
    fontSize: fontSize ?? this.fontSize,
    arrowStyle: arrowStyle ?? this.arrowStyle,
  );
  Map<String, dynamic> toJson() => {
    'color': color.toARGB32(),
    'width': width,
    'fontSize': fontSize,
    if (arrowStyle != ArrowStyle.single) 'arrowStyle': arrowStyle.name,
  };
  static ToolStyle fromJson(Map<String, dynamic> data) => ToolStyle(
    color: Color((data['color'] as num?)?.toInt() ?? 0xFFEF4444),
    width: ((data['width'] as num?)?.toDouble() ?? 3).clamp(1, 40),
    fontSize: ((data['fontSize'] as num?)?.toDouble() ?? 24).clamp(12, 96),
    arrowStyle: ArrowStyle.tryParse(data['arrowStyle']) ?? ArrowStyle.single,
  );
}

@immutable
class ScreenshotAnnotation {
  const ScreenshotAnnotation({
    required this.id,
    required this.tool,
    required this.points,
    required this.style,
    this.text = '',
    this.number = 0,
  });
  final int id;
  final ScreenshotTool tool;
  final List<Offset> points;
  final ToolStyle style;
  final String text;
  final int number;
  ArrowGeometry get arrowGeometry =>
      ArrowGeometry(points.first, points.last, style.width, style.arrowStyle);

  Rect get bounds {
    if (tool == ScreenshotTool.arrow) return arrowGeometry.bounds;
    if (tool == ScreenshotTool.text) {
      final painter = textPainter;
      return points.first &
          Size(
            math.max(16, painter.width),
            math.max(style.fontSize, painter.height),
          );
    }
    if (tool == ScreenshotTool.number) {
      return Rect.fromCircle(
        center: points.first,
        radius: style.fontSize * .75,
      );
    }
    return Rect.fromLTRB(
      points.map((p) => p.dx).reduce(math.min),
      points.map((p) => p.dy).reduce(math.min),
      points.map((p) => p.dx).reduce(math.max),
      points.map((p) => p.dy).reduce(math.max),
    );
  }

  TextPainter get textPainter => TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        color: style.color,
        fontSize: style.fontSize,
        fontFamily: 'Microsoft YaHei',
        height: 1.25,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  ScreenshotAnnotation copyWith({
    List<Offset>? points,
    ToolStyle? style,
    String? text,
  }) => ScreenshotAnnotation(
    id: id,
    tool: tool,
    points: points ?? this.points,
    style: style ?? this.style,
    text: text ?? this.text,
    number: number,
  );
  ScreenshotAnnotation move(Offset delta) =>
      copyWith(points: points.map((p) => p + delta).toList());
  bool hit(Offset point, double tolerance) {
    if (tool == ScreenshotTool.arrow) {
      return arrowGeometry.hit(point, tolerance);
    }
    if (!bounds.inflate(math.max(tolerance, style.width)).contains(point)) {
      return false;
    }
    if (tool == ScreenshotTool.line ||
        tool == ScreenshotTool.pen ||
        tool == ScreenshotTool.highlighter) {
      for (var i = 1; i < points.length; i++) {
        if (distanceToSegment(point, points[i - 1], points[i]) <=
            tolerance + style.width) {
          return true;
        }
      }
      return false;
    }
    return true;
  }
}

@immutable
class ScreenshotSnapshot {
  const ScreenshotSnapshot(this.selection, this.annotations);
  final Rect? selection;
  final List<ScreenshotAnnotation> annotations;
}

class ScreenshotModel extends ChangeNotifier {
  ScreenshotModel(
    this.size, {
    String styles = '{}',
    ArrowStyle? initialArrowStyle,
  }) : _sessionArrowStyle = initialArrowStyle {
    try {
      final decoded = jsonDecode(styles) as Map<String, dynamic>;
      for (final tool in ScreenshotTool.values) {
        if (decoded[tool.name] is Map) {
          toolStyles[tool] = ToolStyle.fromJson(
            Map<String, dynamic>.from(decoded[tool.name] as Map),
          );
        }
      }
    } on Object {
      /* Corrupt style preferences never block capture. */
    }
  }
  ScreenshotModel.forLongImage(this.size, ScreenshotModel previous)
    : _sessionArrowStyle = previous._sessionArrowStyle {
    toolStyles.addAll(previous.toolStyles);
  }

  // A fixed startup preference belongs to this capture. Keep the user's
  // last explicit choice available if they switch back to “use last”.
  ArrowStyle? _sessionArrowStyle;
  final Size size;
  Rect? selection;
  List<ScreenshotAnnotation> annotations = [];
  ScreenshotTool tool = ScreenshotTool.select;
  int? selectedId;
  int nextId = 1;
  int nextNumber = 1;
  int revision = 0;
  final toolStyles = <ScreenshotTool, ToolStyle>{};
  final _undo = <ScreenshotSnapshot>[];
  final _redo = <ScreenshotSnapshot>[];
  ScreenshotSnapshot? _gesture;
  Rect get screen => Offset.zero & size;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  bool get hasGesture => _gesture != null;
  ScreenshotAnnotation? get selected {
    for (final object in annotations) {
      if (object.id == selectedId) return object;
    }
    return null;
  }

  ToolStyle get style {
    final saved =
        toolStyles[tool] ??
        switch (tool) {
          ScreenshotTool.highlighter => const ToolStyle(
            color: Color(0xFFFFDE33),
            width: 18,
          ),
          ScreenshotTool.mosaic => const ToolStyle(width: 12),
          ScreenshotTool.cover => const ToolStyle(color: Color(0xFF111827)),
          _ => const ToolStyle(),
        };
    return tool == ScreenshotTool.arrow && _sessionArrowStyle != null
        ? saved.copyWith(arrowStyle: _sessionArrowStyle)
        : saved;
  }

  ScreenshotSnapshot get snapshot =>
      ScreenshotSnapshot(selection, List.of(annotations));
  String encodeStyles() => jsonEncode(
    toolStyles.map((tool, style) => MapEntry(tool.name, style.toJson())),
  );
  Offset clampPoint(Offset point) =>
      Offset(point.dx.clamp(0, size.width), point.dy.clamp(0, size.height));
  Rect clampSelection(Rect rect) {
    final clipped = rect.intersect(screen);
    // Logical coordinates at fractional DPI can straddle an integer pixel
    // by floating-point roundoff. Keep genuinely fractional edges outward.
    const epsilon = 1e-8;
    return Rect.fromLTRB(
      (clipped.left + epsilon).floorToDouble(),
      (clipped.top + epsilon).floorToDouble(),
      (clipped.right - epsilon).ceilToDouble(),
      (clipped.bottom - epsilon).ceilToDouble(),
    );
  }

  void changed() {
    revision++;
    notifyListeners();
  }

  void chooseTool(ScreenshotTool value) {
    tool = value;
    selectedId = null;
    changed();
  }

  void setStyle(ToolStyle value) {
    final object = selected;
    final target = object?.tool ?? tool;
    var preference = value;
    if (target == ScreenshotTool.arrow) {
      if (value.arrowStyle != (object?.style ?? style).arrowStyle) {
        _sessionArrowStyle = null;
      } else {
        // Changing the color/width of an arrow is not a new choice of shape.
        preference = value.copyWith(
          arrowStyle: toolStyles[target]?.arrowStyle ?? ArrowStyle.single,
        );
      }
    }
    toolStyles[target] = preference;
    if (object != null) {
      final separateEdit = !hasGesture;
      if (separateEdit) begin();
      replace(object.copyWith(style: value));
      if (separateEdit) end();
    } else {
      changed();
    }
  }

  /// Returns whether this tool handles a size shortcut, including at its limits.
  bool adjustSize(int direction) {
    final object = selected;
    final target = object?.tool ?? tool;
    final numbered = target == ScreenshotTool.number;
    if (direction == 0 || (!target.usesWidth && !numbered)) return false;
    final current = object?.style ?? style;
    final minimum = numbered
        ? 12.0
        : (target == ScreenshotTool.mosaic ? 2.0 : 1.0);
    final maximum = numbered ? 96.0 : 40.0;
    final size = (numbered ? current.fontSize : current.width).clamp(
      minimum,
      maximum,
    );
    final next = (size + direction.sign * (numbered ? 2 : 1)).clamp(
      minimum,
      maximum,
    );
    if (next != size) {
      setStyle(
        numbered
            ? current.copyWith(fontSize: next)
            : current.copyWith(width: next),
      );
    }
    return true;
  }

  void begin() {
    _gesture ??= snapshot;
  }

  void end() {
    final before = _gesture;
    _gesture = null;
    if (before == null) return;
    if (before.selection == selection &&
        listEquals(before.annotations, annotations)) {
      return;
    }
    _undo.add(before);
    if (_undo.length > 200) _undo.removeAt(0);
    _redo.clear();
    changed();
  }

  void cancelGesture() {
    final before = _gesture;
    _gesture = null;
    if (before != null) _restore(before);
  }

  void _restore(ScreenshotSnapshot value) {
    selection = value.selection;
    annotations = List.of(value.annotations);
    selectedId = null;
    changed();
  }

  void undo() {
    if (hasGesture) {
      cancelGesture();
      return;
    }
    if (_undo.isEmpty) return;
    _redo.add(snapshot);
    _restore(_undo.removeLast());
  }

  void redo() {
    if (_redo.isEmpty) return;
    _undo.add(snapshot);
    _restore(_redo.removeLast());
  }

  void setSelection(Rect rect) {
    selection = clampSelection(rect);
    changed();
  }

  void selectAll([Rect? bounds]) {
    begin();
    setSelection(bounds ?? screen);
    end();
  }

  void replace(ScreenshotAnnotation object) {
    annotations = [
      for (final a in annotations)
        if (a.id == object.id) object else a,
    ];
    changed();
  }

  void add(ScreenshotAnnotation object) {
    annotations = [...annotations, object];
    selectedId = object.id;
    changed();
  }

  void deleteSelected() {
    if (selectedId == null) return;
    begin();
    annotations = annotations.where((a) => a.id != selectedId).toList();
    selectedId = null;
    end();
  }

  void nudge(Offset delta) {
    begin();
    final object = selected;
    if (object != null) {
      replace(object.move(delta));
    } else if (selection != null) {
      setSelection(moveWithin(selection!, delta, screen));
    }
    end();
  }
}

Rect moveWithin(Rect rect, Offset delta, Rect bounds) => rect.shift(
  Offset(
    delta.dx.clamp(bounds.left - rect.left, bounds.right - rect.right),
    delta.dy.clamp(bounds.top - rect.top, bounds.bottom - rect.bottom),
  ),
);

List<Offset> rectangleHandles(Rect r) => [
  r.topLeft,
  r.topCenter,
  r.topRight,
  r.centerRight,
  r.bottomRight,
  r.bottomCenter,
  r.bottomLeft,
  r.centerLeft,
];

Rect resizeRectangle(Rect r, int handle, Offset point) {
  var left = r.left, top = r.top, right = r.right, bottom = r.bottom;
  if ([0, 6, 7].contains(handle)) left = point.dx;
  if ([0, 1, 2].contains(handle)) top = point.dy;
  if ([2, 3, 4].contains(handle)) right = point.dx;
  if ([4, 5, 6].contains(handle)) bottom = point.dy;
  return Rect.fromPoints(Offset(left, top), Offset(right, bottom));
}
