import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Serializable state only. No COM pointers cross isolate/apartment boundaries.
class WindowsAutomationFocus {
  const WindowsAutomationFocus(this.path, this.selection);
  final List<String> path;
  final AutomationTextSelection? selection;
}

class AutomationTextSelection {
  const AutomationTextSelection(this.text, this.before, this.selected);
  final String text;
  final String before;
  final String selected;
}

class WindowsAutomationCapture {
  const WindowsAutomationCapture(this.editable, this.focus);
  final bool editable;
  final WindowsAutomationFocus? focus;
}

/// UIA providers run outside Flutter's UI isolate, in a short-lived MTA. Scope
/// all searches to the original top-level window, never the entire desktop.
WindowsAutomationCapture captureAutomationFocus(
  int window,
  int processId, {
  required bool retainSelection,
}) {
  return _withAutomation(const WindowsAutomationCapture(false, null), (scope) {
    if (GetForegroundWindow() != window) {
      return const WindowsAutomationCapture(false, null);
    }
    final element = scope.get(
      scope.automation.getFocusedElement,
      IUIAutomationElement.new,
    );
    if (element == null ||
        element.currentProcessId != processId ||
        element.currentHasKeyboardFocus == 0 ||
        element.currentIsEnabled == 0) {
      return const WindowsAutomationCapture(false, null);
    }
    final value = scope.valuePattern(element);
    final editable = value != null
        ? value.currentIsReadOnly == 0
        : element.currentControlType == UIA_EditControlTypeId;
    if (!editable ||
        !retainSelection ||
        element.currentControlType != UIA_EditControlTypeId) {
      return WindowsAutomationCapture(editable, null);
    }
    final path = scope.path(element, window);
    final selection = scope.captureSelection(element);
    if (path == null || GetForegroundWindow() != window) {
      return const WindowsAutomationCapture(false, null);
    }
    return WindowsAutomationCapture(
      true,
      WindowsAutomationFocus(path, selection),
    );
  });
}

bool restoreAutomationFocus(
  int window,
  int processId,
  WindowsAutomationFocus saved,
  int deadline,
) {
  return _withAutomation(false, (scope) {
    bool allowed() =>
        DateTime.now().millisecondsSinceEpoch < deadline &&
        GetForegroundWindow() == window &&
        using((arena) {
          final pid = arena<Uint32>();
          GetWindowThreadProcessId(window, pid);
          return pid.value == processId;
        });
    if (!allowed()) return false;
    final root = scope.get(
      (out) => scope.automation.elementFromHandle(window, out),
      IUIAutomationElement.new,
    );
    if (root == null) return false;
    final condition = using((arena) {
      final variant = arena<VARIANT>()..ref.vt = VT_I4;
      variant.ref.lVal = UIA_EditControlTypeId;
      return scope.get(
        (out) => scope.automation.createPropertyCondition(
          UIA_ControlTypePropertyId,
          variant.ref,
          out,
        ),
        IUIAutomationCondition.new,
      );
    });
    if (condition == null) return false;
    final elements = scope.get(
      (out) => root.findAll(
        TreeScope_Descendants,
        condition.ptr.ref.lpVtbl.cast(),
        out,
      ),
      IUIAutomationElementArray.new,
    );
    if (elements == null || elements.length > 128) return false;
    IUIAutomationElement? match;
    for (var i = 0; i < elements.length; i++) {
      if (!allowed()) return false;
      final element = scope.get(
        (out) => elements.getElement(i, out),
        IUIAutomationElement.new,
      );
      if (element == null || element.currentProcessId != processId) continue;
      final path = scope.path(element, window);
      if (path != null && _samePath(path, saved.path)) {
        if (match != null) return false; // Never guess between two inputs.
        match = element;
      }
    }
    if (match == null ||
        !allowed() ||
        match.currentIsEnabled == 0 ||
        FAILED(match.setFocus())) {
      return false;
    }
    if (!allowed() || match.currentHasKeyboardFocus == 0) return false;
    final selection = saved.selection;
    if (selection != null &&
        !scope.restoreSelection(match, selection, allowed)) {
      return false;
    }
    return allowed() && match.currentHasKeyboardFocus != 0;
  });
}

bool _samePath(List<String> a, List<String> b) =>
    a.length == b.length &&
    List.generate(a.length, (i) => a[i] == b[i]).every((same) => same);

T _withAutomation<T>(T fallback, T Function(_AutomationScope) action) {
  final initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(initialized)) return fallback;
  final scope = _AutomationScope();
  try {
    scope.automation = scope.own(CUIAutomation.createInstance());
    return action(scope);
  } catch (_) {
    return fallback;
  } finally {
    scope.dispose();
    CoUninitialize();
  }
}

class _AutomationScope {
  late IUIAutomation automation;
  final _objects = <IUnknown>[];

  T own<T extends IUnknown>(T object) {
    _objects.add(object);
    return object;
  }

  T? get<T extends IUnknown>(
    int Function(Pointer<Pointer<COMObject>>) query,
    T Function(Pointer<COMObject>) wrap,
  ) {
    final pointer = calloc<COMObject>();
    if (FAILED(query(pointer.cast())) || pointer.ref.isNull) {
      calloc.free(pointer);
      return null;
    }
    return own(wrap(pointer));
  }

  void dispose() {
    for (final object in _objects.reversed) {
      object.release();
      calloc.free(object.ptr);
    }
  }

  IUIAutomationValuePattern? valuePattern(IUIAutomationElement element) => get(
    (out) => element.getCurrentPattern(UIA_ValuePatternId, out),
    IUIAutomationValuePattern.new,
  );

  IUIAutomationTextPattern? textPattern(IUIAutomationElement element) => get(
    (out) => element.getCurrentPattern(UIA_TextPatternId, out),
    IUIAutomationTextPattern.new,
  );

  List<String>? path(IUIAutomationElement element, int window) {
    final walker = own(IUIAutomationTreeWalker(automation.rawViewWalker));
    final result = <String>[];
    IUIAutomationElement? current = element;
    for (var i = 0; current != null && i < 16; i++) {
      if (current.currentNativeWindowHandle == window) return result;
      result.add(
        '${current.currentControlType}:'
        '${_string(current.currentAutomationId)}:'
        '${_string(current.currentClassName)}',
      );
      final child = current;
      current = get(
        (out) => walker.getParentElement(child.ptr.ref.lpVtbl.cast(), out),
        IUIAutomationElement.new,
      );
    }
    return null;
  }

  AutomationTextSelection? captureSelection(IUIAutomationElement element) {
    final pattern = textPattern(element);
    if (pattern == null) return null;
    final selections = get(
      pattern.getSelection,
      IUIAutomationTextRangeArray.new,
    );
    if (selections == null || selections.length != 1) return null;
    final selected = get(
      (out) => selections.getElement(0, out),
      IUIAutomationTextRange.new,
    );
    final document = own(IUIAutomationTextRange(pattern.documentRange));
    final before = get(document.clone, IUIAutomationTextRange.new);
    if (selected == null ||
        before == null ||
        FAILED(
          before.moveEndpointByRange(
            TextPatternRangeEndpoint_End,
            selected.ptr.ref.lpVtbl.cast(),
            TextPatternRangeEndpoint_Start,
          ),
        )) {
      return null;
    }
    final text = rangeText(document);
    final prefix = rangeText(before);
    final selection = rangeText(selected);
    if (text == null ||
        prefix == null ||
        selection == null ||
        !text.startsWith(prefix + selection)) {
      return null;
    }
    return AutomationTextSelection(text, prefix, selection);
  }

  bool restoreSelection(
    IUIAutomationElement element,
    AutomationTextSelection saved,
    bool Function() allowed,
  ) {
    var pattern = textPattern(element);
    if (pattern == null) return false;
    var document = own(IUIAutomationTextRange(pattern.documentRange));
    if (rangeText(document) != saved.text) {
      // Explorer can discard unsubmitted address text when it loses focus.
      // Restore that draft only for the captured Explorer input, then its range.
      final value = valuePattern(element);
      if (value == null || value.currentIsReadOnly != 0 || !allowed()) {
        return false;
      }
      final restored = using(
        (arena) => SUCCEEDED(
          value.setValue(saved.text.toNativeUtf16(allocator: arena)),
        ),
      );
      if (!restored || !allowed()) return false;
      pattern = textPattern(element);
      if (pattern == null) return false;
      document = own(IUIAutomationTextRange(pattern.documentRange));
      if (rangeText(document) != saved.text) return false;
    }
    // Match actual text ranges instead of treating UTF-16 offsets as UIA
    // Character units (which differ for emoji and combining characters).
    final selection = get(document.clone, IUIAutomationTextRange.new);
    if (selection == null) return false;
    if (saved.before.isNotEmpty) {
      final before = findText(document, saved.before);
      if (before == null ||
          FAILED(
            selection.moveEndpointByRange(
              TextPatternRangeEndpoint_Start,
              before.ptr.ref.lpVtbl.cast(),
              TextPatternRangeEndpoint_End,
            ),
          )) {
        return false;
      }
    }
    if (saved.selected.isNotEmpty) {
      final selected = findText(selection, saved.selected);
      if (selected == null ||
          FAILED(
            selection.moveEndpointByRange(
              TextPatternRangeEndpoint_End,
              selected.ptr.ref.lpVtbl.cast(),
              TextPatternRangeEndpoint_End,
            ),
          )) {
        return false;
      }
    } else if (FAILED(
      selection.moveEndpointByRange(
        TextPatternRangeEndpoint_End,
        selection.ptr.ref.lpVtbl.cast(),
        TextPatternRangeEndpoint_Start,
      ),
    )) {
      return false;
    }
    return allowed() && SUCCEEDED(selection.select());
  }

  IUIAutomationTextRange? findText(IUIAutomationTextRange range, String text) =>
      using(
        (arena) => get(
          (out) => range.findText(
            text.toNativeUtf16(allocator: arena),
            FALSE,
            FALSE,
            out,
          ),
          IUIAutomationTextRange.new,
        ),
      );

  String? rangeText(IUIAutomationTextRange range) => using((arena) {
    final result = arena<Pointer<Utf16>>();
    if (FAILED(range.getText(65537, result))) return null;
    final text = _string(result.value);
    return text.length <= 65536 ? text : null;
  });
}

String _string(Pointer<Utf16> value) {
  if (value == nullptr) return '';
  try {
    return value.toDartString();
  } finally {
    SysFreeString(value);
  }
}
