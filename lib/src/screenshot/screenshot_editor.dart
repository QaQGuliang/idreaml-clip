import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screenshot_color_picker.dart';
import 'screenshot_model.dart';
import 'screenshot_renderer.dart';
import 'scroll_capture_controller.dart';

const _channel = MethodChannel('idreaml_clip/screenshot');

enum _ScreenshotAction { copy, saveAs, pin }

class ScreenshotEditorApp extends StatelessWidget {
  const ScreenshotEditorApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF8B5CF6),
        brightness: Brightness.dark,
      ),
      useMaterial3: true,
      fontFamily: 'Microsoft YaHei',
    ),
    home: const _ScreenshotSessionHost(),
  );
}

// The engine stays warm while the session widget (and all its images) is replaced.
class _ScreenshotSessionHost extends StatefulWidget {
  const _ScreenshotSessionHost();

  @override
  State<_ScreenshotSessionHost> createState() => _ScreenshotSessionHostState();
}

class _ScreenshotSessionHostState extends State<_ScreenshotSessionHost> {
  Map<String, dynamic>? _snapshot;
  GlobalKey<_ScreenshotEditorState>? _editorKey;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler(_handle);
    unawaited(_loadPending());
  }

  Future<void> _loadPending() async {
    final data = await _channel.invokeMapMethod<String, dynamic>('load');
    if (data != null) _start(data);
  }

  void _start(Map<String, dynamic> data) {
    final session = data['session'] as int;
    if (!mounted || session <= _generation) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    setState(() {
      _generation = session;
      _snapshot = data;
      _editorKey = GlobalKey<_ScreenshotEditorState>();
    });
    // A reused hidden Windows view may have normal frame scheduling suspended.
    WidgetsBinding.instance.scheduleWarmUpFrame();
  }

  Future<void> _handle(MethodCall call) async {
    if (call.method == 'start') {
      _start(Map<String, dynamic>.from(call.arguments as Map));
    } else if (call.method == 'localShortcut') {
      final args = call.arguments as Map;
      if (args['session'] == _generation && _snapshot != null) {
        _editorKey?.currentState?._handleLocalShortcut(args['key'] as String);
      }
    } else if (call.method == 'reset') {
      final session = call.arguments as int;
      if (mounted && session >= _generation) {
        Navigator.of(context).popUntil((route) => route.isFirst);
        setState(() {
          _generation = session;
          _snapshot = null;
          _editorKey = null;
        });
        WidgetsBinding.instance.scheduleWarmUpFrame();
      }
    }
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _snapshot == null
      ? const SizedBox.shrink()
      : ScreenshotEditor(key: _editorKey, snapshot: _snapshot!);
}

class ScreenshotEditor extends StatefulWidget {
  const ScreenshotEditor({super.key, required this.snapshot});
  final Map<String, dynamic> snapshot;
  @override
  State<ScreenshotEditor> createState() => _ScreenshotEditorState();
}

class _ScreenshotEditorState extends State<ScreenshotEditor> {
  ui.Image? _background, _composite;
  ScreenshotModel? _model;
  List<Rect> _windows = [];
  final _focus = FocusNode();
  final _textFocus = FocusNode();
  final _text = TextEditingController();
  final _canvasKey = GlobalKey();
  final _toolbarKey = GlobalKey();
  Offset? _toolbarOffset;
  bool _draggingToolbar = false;
  int? _textId;
  Offset? _textOrigin;
  Offset _pointer = Offset.zero;
  Uint8List? _frozenPixels;
  bool _showColorPicker = true;
  bool _currentRoute = true, _localShortcutsEnabled = true;
  Offset? _down;
  Rect? _originalRect;
  ScreenshotAnnotation? _originalObject;
  int? _drawingId;
  int _handle = -1;
  String _drag = '';
  double _scale = 1;
  bool _busy = false, _locked = false, _rendering = false, _renderAgain = false;
  _ScreenshotAction _pendingAction = _ScreenshotAction.copy;
  Offset _captureOrigin = Offset.zero;
  String? _error;
  Timer? _renderTimer;
  List<ScreenshotAnnotation>? _renderedObjects;
  ScrollCaptureController? _scrollCapture;
  bool _longImage = false, _longFinishArmed = true;
  double _longZoom = 1;
  final _longVertical = ScrollController();
  final _longHorizontal = ScrollController();
  Timer? _finishArmTimer;
  Rect? get _candidate {
    for (final rect in _windows) {
      if (rect.contains(_pointer)) return rect;
    }
    return _model?.screen;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _currentRoute = ModalRoute.isCurrentOf(context) ?? true;
    _updateLocalShortcuts();
  }

  void _updateLocalShortcuts() {
    final enabled = _textOrigin == null && _currentRoute;
    if (enabled == _localShortcutsEnabled) return;
    _localShortcutsEnabled = enabled;
    unawaited(
      _channel.invokeMethod<void>('setLocalShortcuts', {
        'session': widget.snapshot['session'],
        'enabled': enabled,
      }),
    );
  }

  Future<void> _load() async {
    try {
      final data = widget.snapshot;
      _showColorPicker = data['showColorPicker'] as bool? ?? true;
      _pointer = Offset(
        (data['initialCursorX'] as num? ?? 0).toDouble(),
        (data['initialCursorY'] as num? ?? 0).toDouble(),
      );
      _frozenPixels = data.remove('pixels') as Uint8List;
      final ready = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        _frozenPixels!,
        data['width'] as int,
        data['height'] as int,
        ui.PixelFormat.bgra8888,
        ready.complete,
      );
      final background = await ready.future;
      if (!mounted) {
        background.dispose();
        return;
      }
      _background = background;
      _model = ScreenshotModel(
        Size(background.width.toDouble(), background.height.toDouble()),
        styles: data['styles'] as String? ?? '{}',
      )..addListener(_changed);
      _windows = (data['windows'] as List).map((raw) {
        final r = (raw as List).cast<num>();
        return Rect.fromLTRB(
          r[0].toDouble(),
          r[1].toDouble(),
          r[2].toDouble(),
          r[3].toDouble(),
        );
      }).toList();
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await _channel.invokeMethod<void>('ready', data['session']);
        if (mounted) _focus.requestFocus();
      });
      WidgetsBinding.instance.scheduleWarmUpFrame();
    } on Object {
      if (!mounted) return;
      setState(() => _error = '无法打开截图，请关闭后重试');
      await _channel.invokeMethod<void>('ready', widget.snapshot['session']);
    }
  }

  void _changed() {
    if (!mounted) return;
    if (_model!.selection != _model!.screen) _toolbarOffset = null;
    setState(() {});
    if (!listEquals(_renderedObjects, _model!.annotations)) {
      _renderTimer ??= Timer(const Duration(milliseconds: 24), () {
        _renderTimer = null;
        unawaited(_render());
      });
    }
  }

  Future<void> _render() async {
    if (_rendering) {
      _renderAgain = true;
      return;
    }
    _rendering = true;
    final renderingBackground = _background;
    try {
      do {
        _renderAgain = false;
        final objects = List<ScreenshotAnnotation>.of(_model!.annotations);
        final image = await renderScreenshot(_background!, objects);
        if (!mounted || _background != renderingBackground) {
          image.dispose();
          return;
        }
        final old = _composite;
        setState(() {
          _composite = image;
          _renderedObjects = objects;
        });
        old?.dispose();
        if (!listEquals(objects, _model!.annotations)) _renderAgain = true;
      } while (_renderAgain);
    } on Object {
      if (mounted && _background == renderingBackground) {
        setState(() => _error = '编辑预览失败，可撤销后重试');
      }
    } finally {
      _rendering = false;
    }
  }

  Offset _point(Offset local) => _model!.clampPoint(local / _scale);

  // A physical pixel mapped through fractional display scaling can round
  // just below its original integer position.
  Offset get _samplePixel => Offset(
    (_pointer.dx + precisionErrorTolerance).floorToDouble().clamp(
      0,
      _background!.width - 1.0,
    ),
    (_pointer.dy + precisionErrorTolerance).floorToDouble().clamp(
      0,
      _background!.height - 1.0,
    ),
  );

  int get _sampleRgb {
    final pixel = _samplePixel;
    final i = (pixel.dy.toInt() * _background!.width + pixel.dx.toInt()) * 4;
    final bgra = _frozenPixels!;
    return (bgra[i + 2] << 16) | (bgra[i + 1] << 8) | bgra[i];
  }

  void _trackPointer(PointerEvent event) {
    final point = _point(event.localPosition);
    if (point != _pointer) setState(() => _pointer = point);
  }

  Future<void> _copyColor() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _channel.invokeMethod<void>('copyColor', {
        'token': widget.snapshot['session'],
        'hex': screenshotHex(_sampleRgb),
      });
      if (mounted) await _saveStylesAndClose();
    } on Object {
      if (mounted) setState(() => _error = '色值复制失败，按 C 重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _startToolbarDrag(DragStartDetails details) {
    final canvas = _canvasKey.currentContext!.findRenderObject()! as RenderBox;
    final toolbar =
        _toolbarKey.currentContext!.findRenderObject()! as RenderBox;
    setState(() {
      _toolbarOffset = toolbar.localToGlobal(Offset.zero, ancestor: canvas);
      _draggingToolbar = true;
    });
  }

  void _moveToolbar(DragUpdateDetails details) {
    final canvas = _canvasKey.currentContext!.findRenderObject()! as RenderBox;
    final toolbar =
        _toolbarKey.currentContext!.findRenderObject()! as RenderBox;
    setState(() {
      _toolbarOffset = _keepToolbarOnScreen(
        _toolbarOffset! + details.delta,
        canvas.size,
        toolbar.size,
      );
    });
  }

  void _endToolbarDrag() => setState(() => _draggingToolbar = false);

  Future<void> _startLongScreenshot() async {
    final m = _model;
    if (!_editable ||
        m?.selection == null ||
        _scrollCapture != null ||
        _longImage) {
      return;
    }
    _commitText();
    if (m!.annotations.isNotEmpty) {
      setState(() => _error = '请先撤销或删除标注，再进入长截图');
      return;
    }
    final selection = m.selection!;
    if (selection.width < 16 || selection.height < 32) {
      setState(() => _error = '请框选更大的滚动内容区域');
      return;
    }
    late final ScrollCaptureController capture;
    capture = ScrollCaptureController(
      channel: _channel,
      session: widget.snapshot['session'] as int,
      selection: selection,
      panel: placeScrollControls(selection, m.size, _scale),
      onEdit: (pixels, width, height, limited) =>
          _openLongEditor(capture, pixels, width, height, limited),
    )..addListener(_scrollChanged);
    setState(() {
      _scrollCapture = capture;
      _error = null;
    });
    try {
      await capture.start();
    } catch (error) {
      if (!mounted || _scrollCapture != capture) return;
      capture.removeListener(_scrollChanged);
      capture.dispose();
      setState(() {
        _scrollCapture = null;
        _error = error is PlatformException ? error.message : '长截图启动失败，请重试';
      });
      await _channel.invokeMethod<void>('ready', widget.snapshot['session']);
    }
  }

  void _scrollChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _openLongEditor(
    ScrollCaptureController capture,
    Uint8List pixels,
    int width,
    int height,
    bool limited,
  ) async {
    final background = await decodeScrollPixels(pixels, width, height);
    if (!mounted || _scrollCapture != capture) {
      background.dispose();
      return;
    }
    final styles = _model!.encodeStyles();
    _renderTimer?.cancel();
    _renderTimer = null;
    _model!.removeListener(_changed);
    _captureOrigin = capture.selection.topLeft;
    _model!.dispose();
    _background?.dispose();
    _composite?.dispose();
    _composite = null;
    _renderedObjects = null;
    _background = background;
    _frozenPixels = null;
    _model =
        ScreenshotModel(
            Size(width.toDouble(), height.toDouble()),
            styles: styles,
          )
          ..selection = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble())
          ..addListener(_changed);
    capture.removeListener(_scrollChanged);
    setState(() {
      _scrollCapture = null;
      _longImage = true;
      _longFinishArmed = false;
      _toolbarOffset = null;
      _windows = [];
      _down = null;
      _drag = '';
      _error = limited ? '已达到长图上限，已保留完整内容，请编辑后完成' : null;
    });
    capture.dispose();
    // A double-click or held Enter from capture must not immediately commit.
    _finishArmTimer = Timer(const Duration(milliseconds: 650), () {
      if (mounted) setState(() => _longFinishArmed = true);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _channel.invokeMethod<void>('ready', widget.snapshot['session']);
      if (mounted) _focus.requestFocus();
    });
    WidgetsBinding.instance.scheduleWarmUpFrame();
  }

  bool get _editable => !_busy && !_locked;
  void _start(Offset local) {
    if (!_editable || _model == null) return;
    _commitText();
    _focus.requestFocus();
    final m = _model!;
    final point = _point(local);
    _pointer = point;
    _down = point;
    _handle = -1;
    _originalObject = null;
    _drawingId = null;
    m.begin();
    if (m.selection == null) {
      _drag = 'newSelection';
      return;
    }
    if (m.tool == ScreenshotTool.select) {
      final object = m.selected;
      final resizeAllowed =
          object != null &&
          [
            ScreenshotTool.rectangle,
            ScreenshotTool.ellipse,
            ScreenshotTool.line,
            ScreenshotTool.arrow,
            ScreenshotTool.mosaic,
            ScreenshotTool.cover,
          ].contains(object.tool);
      final handles = resizeAllowed
          ? ((object.tool == ScreenshotTool.line ||
                    object.tool == ScreenshotTool.arrow)
                ? [object.points.first, object.points.last]
                : rectangleHandles(object.bounds))
          : object == null
          ? rectangleHandles(m.selection!)
          : <Offset>[];
      _handle = handles.indexWhere((p) => (p - point).distance < 8 / _scale);
      if (_handle >= 0) {
        _originalObject = resizeAllowed ? object : null;
        _originalRect = object?.bounds ?? m.selection;
        _drag = 'resize';
        return;
      }
      for (final a in m.annotations.reversed) {
        if (a.hit(point, 5 / _scale) && m.selection!.contains(point)) {
          m.selectedId = a.id;
          _originalObject = a;
          _drag = 'object';
          m.changed();
          return;
        }
      }
      m.selectedId = null;
      if (m.selection!.contains(point)) {
        _originalRect = m.selection;
        _drag = 'selection';
      } else {
        _drag = 'newSelection';
      }
      m.changed();
      return;
    }
    if (!m.selection!.contains(point)) {
      m.cancelGesture();
      _drag = '';
      return;
    }
    if (m.tool == ScreenshotTool.text) {
      m.cancelGesture();
      _drag = '';
      _down = null;
      _editText(null, point);
      return;
    }
    final object = ScreenshotAnnotation(
      id: m.nextId++,
      tool: m.tool,
      points: [point, point],
      style: m.style,
      number: m.tool == ScreenshotTool.number ? m.nextNumber++ : 0,
    );
    m.add(object);
    _drawingId = object.id;
    _drag = 'draw';
  }

  void _move(Offset local) {
    final m = _model;
    if (!_editable || m == null || _down == null || _drag.isEmpty) return;
    final point = _point(local);
    _pointer = point;
    switch (_drag) {
      case 'newSelection':
        m.setSelection(Rect.fromPoints(_down!, point));
      case 'selection':
        m.setSelection(moveWithin(_originalRect!, point - _down!, m.screen));
      case 'object':
        m.replace(_originalObject!.move(point - _down!));
      case 'resize':
        final object = _originalObject;
        if (object == null) {
          m.setSelection(resizeRectangle(_originalRect!, _handle, point));
        } else if (object.tool == ScreenshotTool.line ||
            object.tool == ScreenshotTool.arrow) {
          m.replace(
            object.copyWith(
              points: _handle == 0
                  ? [point, object.points.last]
                  : [object.points.first, point],
            ),
          );
        } else {
          final rect = resizeRectangle(_originalRect!, _handle, point);
          m.replace(object.copyWith(points: [rect.topLeft, rect.bottomRight]));
        }
      case 'draw':
        final object = m.annotations.firstWhere((a) => a.id == _drawingId);
        if (object.tool == ScreenshotTool.number) break;
        m.replace(
          object.copyWith(
            points: [
              if ([
                ScreenshotTool.pen,
                ScreenshotTool.highlighter,
              ].contains(object.tool))
                ...object.points
              else
                object.points.first,
              point,
            ],
          ),
        );
    }
  }

  void _end() {
    final m = _model;
    if (m == null || _down == null) return;
    if (_drag == 'newSelection' && (_pointer - _down!).distance < 3 / _scale) {
      m.setSelection(_candidate ?? m.screen);
    }
    if (m.selection?.isEmpty == true) {
      m.cancelGesture();
    } else {
      m.end();
    }
    _down = null;
    _drag = '';
    _drawingId = null;
  }

  void _editText(ScreenshotAnnotation? object, Offset origin) {
    if (!_editable) return;
    _commitText();
    _textId = object?.id;
    _textOrigin = origin;
    _updateLocalShortcuts();
    _text.text = object?.text ?? '';
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _textFocus.requestFocus();
    });
  }

  void _commitText() {
    if (_textOrigin == null) return;
    final m = _model!;
    m.begin();
    if (_textId != null) {
      final object = m.annotations.firstWhere((a) => a.id == _textId);
      if (_text.text.trim().isEmpty) {
        m.selectedId = _textId;
        m.deleteSelected();
      } else {
        m.replace(object.copyWith(text: _text.text));
      }
    } else if (_text.text.trim().isNotEmpty) {
      m.add(
        ScreenshotAnnotation(
          id: m.nextId++,
          tool: ScreenshotTool.text,
          points: [_textOrigin!],
          style: m.toolStyles[ScreenshotTool.text] ?? const ToolStyle(),
          text: _text.text,
        ),
      );
    }
    _textOrigin = null;
    _updateLocalShortcuts();
    _textId = null;
    m.end();
    _textFocus.unfocus();
    setState(() {});
  }

  Future<void> _close() async {
    if (_busy) return;
    if (_locked) {
      final leave = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('退出截图结果处理？'),
          content: Text('${_error ?? '截图有部分步骤已完成'}\n退出后将保留已完成的操作。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('继续处理'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('退出'),
            ),
          ],
        ),
      );
      if (leave != true) return;
    }
    await _saveStylesAndClose();
  }

  Future<void> _saveStylesAndClose() async {
    final session = widget.snapshot['session'];
    try {
      if (_model != null) {
        await _channel.invokeMethod<void>('styles', _model!.encodeStyles());
      }
    } on Object {
      /* Style persistence must not prevent cancellation. */
    }
    await _channel.invokeMethod<void>('close', session);
  }

  Future<void> _finish({
    _ScreenshotAction action = _ScreenshotAction.copy,
  }) async {
    final m = _model;
    if (_busy ||
        m == null ||
        m.hasGesture ||
        (_longImage && !_longFinishArmed)) {
      return;
    }
    _commitText();
    if (m.selection == null || m.selection!.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final png = await exportScreenshot(_background!, m.snapshot);
      if (!_locked) _pendingAction = action;
      final origin = _longImage ? _captureOrigin : m.selection!.topLeft;
      final response = await _channel.invokeMapMethod<String, dynamic>(
        'commit',
        {
          'png': png,
          'saveAs': _pendingAction == _ScreenshotAction.saveAs,
          if (_pendingAction == _ScreenshotAction.pin) ...{
            'pin': true,
            'x': origin.dx.round(),
            'y': origin.dy.round(),
          },
        },
      );
      if (!mounted) return;
      if (response?['success'] == true) {
        try {
          await _channel.invokeMethod<void>('styles', m.encodeStyles());
        } on Object {
          /* Optional preference. */
        }
        await _channel.invokeMethod<void>('close', widget.snapshot['session']);
        return;
      }
      setState(() {
        _locked = response?['locked'] == true;
        _error = response?['error'] as String?;
      });
    } on Object {
      if (mounted) setState(() => _error = '无法完成截图，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _handleLocalShortcut(String command) {
    // Recheck on delivery: the native key may have been queued before a text
    // field or popup took over, or while the editor was completing a capture.
    if (_busy ||
        _textOrigin != null ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    switch (command) {
      case 'escape':
        _escapeCanvas();
      case 'copyColor':
        if (_canPickColor && _showColorPicker) unawaited(_copyColor());
      case 'togglePicker':
        if (_canPickColor) _togglePicker();
    }
  }

  bool get _canPickColor =>
      _model != null && _editable && !_longImage && _scrollCapture == null;

  void _togglePicker() => setState(() => _showColorPicker = !_showColorPicker);

  void _escapeCanvas() {
    final m = _model;
    if (m != null && m.hasGesture && _scrollCapture == null) {
      m.cancelGesture();
      _down = null;
      _drag = '';
    } else if (m?.selectedId != null && _scrollCapture == null) {
      m!.selectedId = null;
      m.changed();
    } else {
      unawaited(_close());
    }
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_busy || _model == null) return KeyEventResult.handled;
    if (_scrollCapture != null) {
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        unawaited(_close());
      } else if (event.logicalKey == LogicalKeyboardKey.enter &&
          event is KeyDownEvent) {
        unawaited(_scrollCapture!.finish());
      }
      return KeyEventResult.handled;
    }
    final m = _model!;
    final key = event.logicalKey;
    if (_textOrigin != null) {
      if (key == LogicalKeyboardKey.escape && !_text.value.composing.isValid) {
        _commitText();
        _focus.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (_canPickColor &&
        !keyboard.isControlPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isShiftPressed &&
        !keyboard.isMetaPressed) {
      if (key == LogicalKeyboardKey.f2) {
        if (event is KeyDownEvent) {
          _togglePicker();
        }
        return KeyEventResult.handled;
      }
      if (_showColorPicker && key == LogicalKeyboardKey.keyC) {
        if (event is KeyDownEvent) unawaited(_copyColor());
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.escape) {
      _escapeCanvas();
    } else if (key == LogicalKeyboardKey.enter) {
      if (!_longImage || event is KeyDownEvent) unawaited(_finish());
    } else if (!_editable) {
      return KeyEventResult.handled;
    } else if (HardwareKeyboard.instance.isControlPressed &&
        key == LogicalKeyboardKey.keyZ) {
      HardwareKeyboard.instance.isShiftPressed ? m.redo() : m.undo();
    } else if (HardwareKeyboard.instance.isControlPressed &&
        key == LogicalKeyboardKey.keyY) {
      m.redo();
    } else if (key == LogicalKeyboardKey.delete ||
        key == LogicalKeyboardKey.backspace) {
      m.deleteSelected();
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      m.nudge(const Offset(-1, 0));
    } else if (key == LogicalKeyboardKey.arrowRight) {
      m.nudge(const Offset(1, 0));
    } else if (key == LogicalKeyboardKey.arrowUp) {
      m.nudge(const Offset(0, -1));
    } else if (key == LogicalKeyboardKey.arrowDown) {
      m.nudge(const Offset(0, 1));
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _key,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final m = _model;
          if (m == null) {
            return Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!),
                        TextButton(onPressed: _close, child: const Text('关闭')),
                      ],
                    ),
            );
          }
          _scale = constraints.maxWidth / m.size.width;
          if (_scrollCapture != null) return _captureView(_scrollCapture!);
          if (_longImage) return _longEditor(m);
          final selected = m.selection;
          final rect = selected == null
              ? null
              : Rect.fromLTRB(
                  selected.left * _scale,
                  selected.top * _scale,
                  selected.right * _scale,
                  selected.bottom * _scale,
                );
          final fullScreen = selected == m.screen;
          final textObject = _textId == null
              ? null
              : m.annotations.firstWhere((a) => a.id == _textId);
          final canvas = Stack(
            key: _canvasKey,
            children: [
              Positioned.fill(
                child: MouseRegion(
                  cursor: m.tool == ScreenshotTool.select && selected != null
                      ? SystemMouseCursors.basic
                      : SystemMouseCursors.precise,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onDoubleTapDown: (details) {
                      if (!_editable) return;
                      final point = _point(details.localPosition);
                      for (final object in m.annotations.reversed) {
                        if (object.tool == ScreenshotTool.text &&
                            object.hit(point, 4 / _scale)) {
                          _editText(object, object.points.first);
                          break;
                        }
                      }
                    },
                    child: Listener(
                      onPointerDown: (e) {
                        if (e.buttons == 1) _start(e.localPosition);
                      },
                      onPointerMove: (e) => _move(e.localPosition),
                      onPointerUp: (_) => _end(),
                      onPointerCancel: (_) {
                        m.cancelGesture();
                        _down = null;
                        _drag = '';
                      },
                      child: CustomPaint(
                        painter: _EditorPainter(
                          image: _composite ?? _background!,
                          model: m,
                          scale: _scale,
                          candidate: selected == null ? _candidate : null,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (_textOrigin != null)
                Positioned(
                  left: (_textOrigin!.dx * _scale).clamp(
                    0,
                    constraints.maxWidth - 40,
                  ),
                  top: (_textOrigin!.dy * _scale).clamp(
                    0,
                    constraints.maxHeight - 40,
                  ),
                  width: math.min(
                    math.max(
                      240.0,
                      (textObject?.bounds.width ?? 0) * _scale + 24,
                    ),
                    math.max(
                      40,
                      constraints.maxWidth - _textOrigin!.dx * _scale,
                    ),
                  ),
                  child: TextField(
                    controller: _text,
                    focusNode: _textFocus,
                    maxLines: null,
                    style: TextStyle(
                      fontSize:
                          (textObject?.style.fontSize ?? m.style.fontSize) *
                          _scale,
                      color: textObject?.style.color ?? m.style.color,
                      height: 1.25,
                    ),
                    decoration: const InputDecoration(
                      isDense: true,
                      filled: true,
                      fillColor: Color(0xCC18181B),
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.all(4),
                    ),
                  ),
                ),
              Positioned.fill(
                child: CustomMultiChildLayout(
                  delegate: _ScreenshotToolbarLayout(
                    selection: rect,
                    fullScreen: fullScreen,
                    draggedOffset: fullScreen ? _toolbarOffset : null,
                  ),
                  children: [
                    LayoutId(
                      id: _ToolbarPart.tools,
                      child: SizedBox(
                        key: const ValueKey('screenshot-toolbar'),
                        child: _toolbar(m, selected != null, fullScreen),
                      ),
                    ),
                    if (rect != null)
                      LayoutId(
                        id: _ToolbarPart.dimensions,
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: const Color(0xDD18181B),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              child: Text(
                                '${selected!.width.toInt()} × ${selected.height.toInt()} px',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (selected == null)
                const Positioned(
                  bottom: 24,
                  left: 24,
                  child: IgnorePointer(
                    child: Text('拖动框选 · 单击选择窗口 · F2 取色器 · Esc 取消'),
                  ),
                ),
              if (_showColorPicker)
                Positioned.fill(
                  child: ScreenshotColorPicker(
                    image: _background!,
                    pixel: _samplePixel,
                    rgb: _sampleRgb,
                    anchor: _pointer * _scale,
                  ),
                ),
              if (_error != null)
                Positioned(
                  bottom: 16,
                  left: 24,
                  right: 24,
                  child: Material(
                    color: const Color(0xFF512B32),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(_error!),
                    ),
                  ),
                ),
            ],
          );
          return Listener(
            onPointerHover: _trackPointer,
            onPointerMove: _trackPointer,
            child: canvas,
          );
        },
      ),
    ),
  );

  Rect _scaledRect(Rect rect) => Rect.fromLTWH(
    rect.left * _scale,
    rect.top * _scale,
    rect.width * _scale,
    rect.height * _scale,
  );

  Widget _captureView(ScrollCaptureController capture) => Stack(
    children: [
      Positioned.fromRect(
        rect: _scaledRect(capture.selection),
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(
                color: const Color(0xFF9F7AEA),
                width: 2 * _scale,
                strokeAlign: BorderSide.strokeAlignOutside,
              ),
            ),
          ),
        ),
      ),
      Positioned.fromRect(
        rect: _scaledRect(capture.panel),
        child: Material(
          key: const ValueKey('scroll-capture-controls'),
          color: const Color(0xFF202129),
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.swipe_down_alt, size: 20),
                    const SizedBox(width: 8),
                    const Text(
                      '长截图',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const Spacer(),
                    Text(
                      '${capture.width} × ${capture.height} px',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ColoredBox(
                    color: const Color(0xFF14151A),
                    child: capture.preview == null
                        ? const Center(child: CircularProgressIndicator())
                        : RawImage(image: capture.preview, fit: BoxFit.contain),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 42,
                  child: Text(
                    capture.message,
                    maxLines: 3,
                    style: TextStyle(
                      fontSize: 12,
                      color: capture.warning
                          ? const Color(0xFFFBBF24)
                          : Colors.white70,
                    ),
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (capture.finishing || capture.starting)
                      const Padding(
                        padding: EdgeInsets.only(right: 12),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    IconButton(
                      tooltip: '取消长截图（Esc）',
                      onPressed: _close,
                      icon: const Icon(Icons.close),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      tooltip: '完成采集，进入编辑',
                      onPressed: capture.starting || capture.finishing
                          ? null
                          : capture.finish,
                      icon: const Icon(Icons.check),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );

  Widget _longEditor(ScreenshotModel m) => LayoutBuilder(
    builder: (context, constraints) {
      _scale =
          math.min(1.0, (constraints.maxWidth - 24) / m.size.width) * _longZoom;
      final imageWidth = m.size.width * _scale;
      final imageHeight = m.size.height * _scale;
      return Column(
        key: const ValueKey('long-screenshot-editor'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '长图编辑 · ${m.size.width.toInt()} × ${m.size.height.toInt()} px',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: '缩小长图',
                  onPressed: () {
                    _commitText();
                    setState(
                      () => _longZoom = (_longZoom / 1.25).clamp(.25, 4.0),
                    );
                  },
                  icon: const Icon(Icons.remove, size: 18),
                ),
                Text(
                  '${(_scale * 100).round()}%',
                  style: const TextStyle(fontSize: 12),
                ),
                IconButton(
                  tooltip: '放大长图',
                  onPressed: () {
                    _commitText();
                    setState(
                      () => _longZoom = (_longZoom * 1.25).clamp(.25, 4.0),
                    );
                  },
                  icon: const Icon(Icons.add, size: 18),
                ),
                TextButton(
                  onPressed: () {
                    _commitText();
                    setState(() => _longZoom = 1);
                  },
                  child: const Text('适应宽度'),
                ),
              ],
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: constraints.maxHeight * .4),
            child: _toolbar(m, m.selection != null, false),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: LayoutBuilder(
              builder: (context, viewport) => Scrollbar(
                controller: _longHorizontal,
                thumbVisibility: true,
                scrollbarOrientation: ScrollbarOrientation.bottom,
                notificationPredicate: (notification) =>
                    notification.depth == 1,
                child: SingleChildScrollView(
                  controller: _longHorizontal,
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: math.max(viewport.maxWidth, imageWidth + 24),
                    height: viewport.maxHeight,
                    child: Scrollbar(
                      controller: _longVertical,
                      thumbVisibility: true,
                      child: SingleChildScrollView(
                        controller: _longVertical,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Align(
                            alignment: Alignment.topLeft,
                            child: SizedBox(
                              key: const ValueKey('long-screenshot-canvas'),
                              width: imageWidth,
                              height: imageHeight,
                              child: _longCanvas(m),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                _error!,
                style: const TextStyle(color: Color(0xFFFBBF24)),
              ),
            ),
        ],
      );
    },
  );

  Widget _longCanvas(ScreenshotModel m) {
    final textObject = _textId == null
        ? null
        : m.annotations.firstWhere((a) => a.id == _textId);
    return Stack(
      key: _canvasKey,
      children: [
        Positioned.fill(
          child: MouseRegion(
            cursor: m.tool == ScreenshotTool.select
                ? SystemMouseCursors.basic
                : SystemMouseCursors.precise,
            child: GestureDetector(
              onDoubleTapDown: (details) {
                if (!_editable) return;
                final point = _point(details.localPosition);
                for (final object in m.annotations.reversed) {
                  if (object.tool == ScreenshotTool.text &&
                      object.hit(point, 4 / _scale)) {
                    _editText(object, object.points.first);
                    break;
                  }
                }
              },
              child: Listener(
                onPointerDown: (event) {
                  if (event.buttons == 1) _start(event.localPosition);
                },
                onPointerMove: (event) => _move(event.localPosition),
                onPointerUp: (_) => _end(),
                onPointerCancel: (_) {
                  m.cancelGesture();
                  _down = null;
                  _drag = '';
                },
                child: CustomPaint(
                  painter: _EditorPainter(
                    image: _composite ?? _background!,
                    model: m,
                    scale: _scale,
                    candidate: null,
                  ),
                ),
              ),
            ),
          ),
        ),
        if (_textOrigin != null)
          Positioned(
            left: _textOrigin!.dx * _scale,
            top: _textOrigin!.dy * _scale,
            width: math.max(
              40,
              math.min(300, (m.size.width - _textOrigin!.dx) * _scale),
            ),
            child: TextField(
              controller: _text,
              focusNode: _textFocus,
              maxLines: null,
              style: TextStyle(
                fontSize:
                    (textObject?.style.fontSize ?? m.style.fontSize) * _scale,
                color: textObject?.style.color ?? m.style.color,
                height: 1.25,
              ),
              decoration: const InputDecoration(
                isDense: true,
                filled: true,
                fillColor: Color(0xCC18181B),
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.all(4),
              ),
            ),
          ),
      ],
    );
  }

  Widget _toolbar(ScreenshotModel m, bool selected, bool fullScreen) {
    final style = m.selected?.style ?? m.style;
    Widget button(
      IconData icon,
      String tooltip,
      VoidCallback? action, {
      bool active = false,
    }) => IconButton(
      tooltip: tooltip,
      onPressed: _busy ? null : action,
      style: IconButton.styleFrom(
        backgroundColor: active ? const Color(0xFF6D28D9) : null,
        minimumSize: const Size(32, 32),
        padding: const EdgeInsets.all(6),
      ),
      icon: Icon(icon, size: 19),
    );
    return Material(
      key: _toolbarKey,
      color: const Color(0xF21F2027),
      elevation: 8,
      borderRadius: BorderRadius.circular(10),
      child: SingleChildScrollView(
        child: Stack(
          children: [
            // Only the background accepts drags. Buttons and style controls
            // above it keep their own gestures, including long presses.
            if (fullScreen)
              Positioned.fill(
                child: MouseRegion(
                  cursor: _busy
                      ? SystemMouseCursors.basic
                      : _draggingToolbar
                      ? SystemMouseCursors.grabbing
                      : SystemMouseCursors.grab,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: _busy ? null : _startToolbarDrag,
                    onPanUpdate: _busy ? null : _moveToolbar,
                    onPanEnd: (_) => _endToolbarDrag(),
                    onPanCancel: _endToolbarDrag,
                  ),
                ),
              ),
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: fullScreen ? 30 : 8,
                vertical: 6,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Wrap(
                    spacing: 2,
                    runSpacing: 2,
                    alignment: WrapAlignment.center,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (selected)
                        for (final tool in ScreenshotTool.values)
                          button(
                            _toolIcon(tool),
                            tool.label,
                            !_editable
                                ? null
                                : () {
                                    _commitText();
                                    m.chooseTool(tool);
                                    _focus.requestFocus();
                                  },
                            active: m.tool == tool,
                          ),
                      button(
                        Icons.fullscreen,
                        _longImage ? '选择整张长图' : '当前屏幕全屏',
                        !_editable
                            ? null
                            : () {
                                _commitText();
                                m.selectAll();
                              },
                      ),
                      if (!_longImage)
                        button(
                          Icons.swipe_down_alt,
                          '长截图',
                          selected && _editable ? _startLongScreenshot : null,
                        ),
                      button(
                        Icons.undo,
                        '撤销（Ctrl + Z）',
                        _editable && m.canUndo
                            ? () {
                                _commitText();
                                m.undo();
                              }
                            : null,
                      ),
                      button(
                        Icons.redo,
                        '重做（Ctrl + Y）',
                        _editable && m.canRedo ? m.redo : null,
                      ),
                      if (m.selected != null)
                        button(
                          Icons.delete_outline,
                          '删除标注',
                          _editable ? m.deleteSelected : null,
                        ),
                      if (m.selected?.tool == ScreenshotTool.text)
                        button(
                          Icons.edit,
                          '修改文字',
                          !_editable
                              ? null
                              : () => _editText(
                                  m.selected,
                                  m.selected!.points.first,
                                ),
                        ),
                      Tooltip(
                        message: '贴图并计入历史',
                        child: FilledButton.icon(
                          onPressed:
                              selected &&
                                  _editable &&
                                  (!_longImage || _longFinishArmed)
                              ? () => _finish(action: _ScreenshotAction.pin)
                              : null,
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFFFCD68B),
                            foregroundColor: const Color(0xFF352506),
                            minimumSize: const Size(0, 32),
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            textStyle: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                          icon: const Icon(Icons.push_pin_rounded, size: 17),
                          label: const Text('贴图'),
                        ),
                      ),
                      button(
                        Icons.save_alt,
                        '另存为并完成',
                        selected &&
                                !_locked &&
                                (!_longImage || _longFinishArmed)
                            ? () => _finish(action: _ScreenshotAction.saveAs)
                            : null,
                      ),
                      button(Icons.close, '取消（Esc）', _close),
                      button(
                        Icons.check,
                        _locked ? '重试完成' : '完成（Enter）',
                        selected && (!_longImage || _longFinishArmed)
                            ? _finish
                            : null,
                        active: true,
                      ),
                    ],
                  ),
                  if (selected && m.tool != ScreenshotTool.select ||
                      m.selected != null)
                    IgnorePointer(
                      ignoring: !_editable,
                      child: Wrap(
                        alignment: WrapAlignment.center,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 5,
                        children: [
                          for (final color in const [
                            Color(0xFFEF4444),
                            Color(0xFFF59E0B),
                            Color(0xFFFDE047),
                            Color(0xFF22C55E),
                            Color(0xFF3B82F6),
                            Color(0xFF8B5CF6),
                            Colors.white,
                            Color(0xFF111827),
                          ])
                            InkWell(
                              onTap: () =>
                                  m.setStyle(style.copyWith(color: color)),
                              child: Container(
                                width: 19,
                                height: 19,
                                decoration: BoxDecoration(
                                  color: color,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: style.color == color
                                        ? Colors.white
                                        : Colors.transparent,
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                          const SizedBox(width: 5),
                          Text(
                            (m.selected?.tool ?? m.tool) ==
                                    ScreenshotTool.mosaic
                                ? '颗粒'
                                : '粗细',
                            style: const TextStyle(fontSize: 11),
                          ),
                          DropdownButton<double>(
                            value: style.width,
                            underline: const SizedBox.shrink(),
                            isDense: true,
                            items:
                                ({
                                      1.0,
                                      2.0,
                                      3.0,
                                      5.0,
                                      8.0,
                                      12.0,
                                      18.0,
                                      24.0,
                                      style.width,
                                    }.toList()..sort())
                                    .map(
                                      (v) => DropdownMenuItem(
                                        value: v,
                                        child: Text(
                                          '${v.toInt()}',
                                          style: const TextStyle(fontSize: 12),
                                        ),
                                      ),
                                    )
                                    .toList(),
                            onChanged: (v) {
                              if (v != null) {
                                m.setStyle(style.copyWith(width: v));
                              }
                            },
                          ),
                          const Text('字号', style: TextStyle(fontSize: 11)),
                          DropdownButton<double>(
                            value: style.fontSize,
                            underline: const SizedBox.shrink(),
                            isDense: true,
                            items:
                                ({
                                      16.0,
                                      20.0,
                                      24.0,
                                      32.0,
                                      40.0,
                                      56.0,
                                      72.0,
                                      style.fontSize,
                                    }.toList()..sort())
                                    .map(
                                      (v) => DropdownMenuItem(
                                        value: v,
                                        child: Text(
                                          '${v.toInt()}',
                                          style: const TextStyle(fontSize: 12),
                                        ),
                                      ),
                                    )
                                    .toList(),
                            onChanged: (v) {
                              if (v != null) {
                                m.setStyle(style.copyWith(fontSize: v));
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            if (_busy)
              const Positioned(
                left: 30,
                right: 30,
                bottom: 1,
                child: LinearProgressIndicator(minHeight: 2),
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _finishArmTimer?.cancel();
    _scrollCapture?.removeListener(_scrollChanged);
    _scrollCapture?.dispose();
    _longVertical.dispose();
    _longHorizontal.dispose();
    _renderTimer?.cancel();
    _model?.removeListener(_changed);
    _model?.dispose();
    _focus.dispose();
    _textFocus.dispose();
    _text.dispose();
    _composite?.dispose();
    _background?.dispose();
    super.dispose();
  }
}

enum _ToolbarPart { tools, dimensions }

Offset _keepToolbarOnScreen(Offset offset, Size screen, Size toolbar) => Offset(
  offset.dx.clamp(8.0, math.max(8.0, screen.width - toolbar.width - 8)),
  offset.dy.clamp(8.0, math.max(8.0, screen.height - toolbar.height - 8)),
);

class _ScreenshotToolbarLayout extends MultiChildLayoutDelegate {
  _ScreenshotToolbarLayout({
    required this.selection,
    required this.fullScreen,
    required this.draggedOffset,
  });

  final Rect? selection;
  final bool fullScreen;
  final Offset? draggedOffset;

  @override
  void performLayout(Size size) {
    // Let the content determine the width; only constrain it to the screen.
    final width = math.max(0.0, size.width - 16);
    final toolbar = layoutChild(
      _ToolbarPart.tools,
      BoxConstraints(
        maxWidth: width,
        maxHeight: math.max(0.0, size.height - 16),
      ),
    );
    final rect = selection;
    final Offset position;
    if (rect == null || fullScreen) {
      position = _keepToolbarOnScreen(
        draggedOffset ?? const Offset(8, 8),
        size,
        toolbar,
      );
    } else {
      // Use the measured height: styles and wrapped buttons change it.
      final double top;
      if (rect.bottom + toolbar.height <= size.height) {
        top = rect.bottom;
      } else if (rect.top >= toolbar.height) {
        top = rect.top - toolbar.height;
      } else {
        // When neither outer edge has room, attach inside the bottom edge.
        top = (rect.bottom - toolbar.height).clamp(
          0.0,
          size.height - toolbar.height,
        );
      }
      position = Offset(rect.left.clamp(0.0, size.width - toolbar.width), top);
    }
    positionChild(_ToolbarPart.tools, position);
    if (hasChild(_ToolbarPart.dimensions)) {
      final label = layoutChild(
        _ToolbarPart.dimensions,
        BoxConstraints.loose(size),
      );
      final left = rect!.left.clamp(0.0, size.width - label.width);
      var top = (rect.top - label.height - 4).clamp(
        0.0,
        size.height - label.height,
      );
      // Keep the size badge clear of the toolbar when attached above selection.
      if ((Offset(left, top) & label).overlaps(position & toolbar)) {
        top =
            (position.dy >= label.height + 4
                    ? position.dy - label.height - 4
                    : position.dy + toolbar.height + 4)
                .clamp(0.0, size.height - label.height);
      }
      positionChild(_ToolbarPart.dimensions, Offset(left, top));
    }
  }

  @override
  bool shouldRelayout(_ScreenshotToolbarLayout oldDelegate) =>
      oldDelegate.selection != selection ||
      oldDelegate.fullScreen != fullScreen ||
      oldDelegate.draggedOffset != draggedOffset;
}

IconData _toolIcon(ScreenshotTool tool) => switch (tool) {
  ScreenshotTool.select => Icons.near_me_outlined,
  ScreenshotTool.rectangle => Icons.crop_square,
  ScreenshotTool.ellipse => Icons.circle_outlined,
  ScreenshotTool.line => Icons.horizontal_rule,
  ScreenshotTool.arrow => Icons.north_east,
  ScreenshotTool.pen => Icons.edit_outlined,
  ScreenshotTool.highlighter => Icons.border_color_outlined,
  ScreenshotTool.text => Icons.title,
  ScreenshotTool.mosaic => Icons.blur_on,
  ScreenshotTool.cover => Icons.rectangle,
  ScreenshotTool.number => Icons.format_list_numbered,
};

class _EditorPainter extends CustomPainter {
  _EditorPainter({
    required this.image,
    required this.model,
    required this.scale,
    required this.candidate,
  });
  final ui.Image image;
  final ScreenshotModel model;
  final double scale;
  final Rect? candidate;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(scale);
    canvas.drawImage(image, Offset.zero, Paint());
    final rect = model.selection ?? candidate;
    final path = Path()..addRect(model.screen);
    if (rect != null) path.addRect(rect);
    path.fillType = PathFillType.evenOdd;
    canvas.drawPath(path, Paint()..color = const Color(0x88000000));
    if (rect != null) {
      canvas.drawRect(
        rect,
        Paint()
          ..color = const Color(0xFF9F7AEA)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1 / scale,
      );
      if (model.selection != null) {
        for (final point in rectangleHandles(rect)) {
          canvas.drawRect(
            Rect.fromCenter(center: point, width: 6 / scale, height: 6 / scale),
            Paint()..color = Colors.white,
          );
        }
      }
    }
    final selected = model.selected;
    if (selected != null && model.tool == ScreenshotTool.select) {
      canvas.drawRect(
        selected.bounds.inflate(2 / scale),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1 / scale
          ..color = const Color(0xFF34D399),
      );
      final handles =
          selected.tool == ScreenshotTool.line ||
              selected.tool == ScreenshotTool.arrow
          ? [selected.points.first, selected.points.last]
          : rectangleHandles(selected.bounds);
      for (final point in handles) {
        canvas.drawCircle(
          point,
          3 / scale,
          Paint()..color = const Color(0xFF34D399),
        );
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _EditorPainter oldDelegate) => true;
}
