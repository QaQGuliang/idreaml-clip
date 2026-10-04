import 'dart:convert';

import 'json_document.dart';

enum JsonTreeToken { object, array, string, number, boolean, nil }

class JsonTreeLine {
  JsonTreeLine({
    required this.index,
    required this.depth,
    required this.token,
    required this.text,
    required this.comma,
    this.name,
    this.count = 0,
    this.closing = false,
  });

  final int index;
  final int depth;
  final JsonTreeToken token;
  final String text;
  final bool comma;
  final String? name;
  final int count;
  final bool closing;
  int? end;
  bool get container =>
      token == JsonTreeToken.object || token == JsonTreeToken.array;
  bool get canFold => container && !closing;
  String get prefix => name == null ? '' : '${jsonEncode(name)}: ';
}

List<JsonTreeLine> jsonTreeLines(JsonDocument document) {
  final lines = <JsonTreeLine>[];
  // An explicit stack also handles deeply nested clipboard JSON.
  final pending =
      <
        ({
          Object? value,
          String? name,
          int depth,
          bool comma,
          JsonTreeLine? close,
        })
      >[
        (
          value: document.value,
          name: null,
          depth: 0,
          comma: false,
          close: null,
        ),
      ];
  while (pending.isNotEmpty) {
    final task = pending.removeLast();
    if (task.close case final opening?) {
      opening.end = lines.length;
      lines.add(
        JsonTreeLine(
          index: lines.length,
          depth: opening.depth,
          token: opening.token,
          text: opening.token == JsonTreeToken.object ? '}' : ']',
          comma: opening.comma,
          closing: true,
        ),
      );
      continue;
    }
    final value = task.value;
    final children = value is Map<String, dynamic>
        ? value.entries.map((entry) => (entry.key, entry.value)).toList()
        : value is List
        ? value.map((entry) => (null, entry)).toList()
        : null;
    final token = value is Map
        ? JsonTreeToken.object
        : value is List
        ? JsonTreeToken.array
        : value is String
        ? JsonTreeToken.string
        : value is num
        ? JsonTreeToken.number
        : value is bool
        ? JsonTreeToken.boolean
        : JsonTreeToken.nil;
    final line = JsonTreeLine(
      index: lines.length,
      depth: task.depth,
      token: token,
      name: task.name,
      comma: task.comma,
      count: children?.length ?? 0,
      text: children == null
          ? jsonEncode(value)
          : value is Map
          ? '{'
          : '[',
    );
    lines.add(line);
    if (children == null) continue;
    pending.add((value: null, name: null, depth: 0, comma: false, close: line));
    for (var i = children.length - 1; i >= 0; i--) {
      pending.add((
        value: children[i].$2,
        name: children[i].$1,
        depth: task.depth + 1,
        comma: i < children.length - 1,
        close: null,
      ));
    }
  }
  return lines;
}

List<JsonTreeLine> visibleJsonLines(
  List<JsonTreeLine> lines,
  Set<int> collapsed,
) {
  final visible = <JsonTreeLine>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    visible.add(line);
    if (line.canFold && collapsed.contains(line.index)) i = line.end!;
  }
  return visible;
}
