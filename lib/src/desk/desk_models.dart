import 'dart:convert';

/// Styles are always opaque. Nullable entry values inherit the module defaults.
bool validDeskTextColor(Object? value) =>
    value == null ||
    (value is int && value >= 0xff000000 && value <= 0xffffffff);

bool validDeskFontFamily(Object? value) =>
    value == null ||
    (value is String &&
        value.length <= 100 &&
        !value.contains(RegExp(r'[\x00-\x1f]')));

bool validDeskFontSize(Object? value) =>
    value == null ||
    (value is num && value.isFinite && value >= 10 && value <= 32);

enum DeskKind {
  note('便签'),
  todo('待办');

  const DeskKind(this.label);
  final String label;
}

/// Multi-value register: causal successors replace ancestors; concurrent
/// versions survive until an explicit user resolution observes both clocks.
class DeskEntry {
  const DeskEntry({
    required this.id,
    required this.revision,
    required this.kind,
    required this.body,
    this.title = '',
    this.done = false,
    this.deleted = false,
    this.fontFamily,
    this.fontSize,
    this.textColor,
    required this.created,
    required this.updated,
    required this.clock,
  });
  final String id, revision, title, body;
  final DeskKind kind;
  final bool done, deleted;
  final String? fontFamily;
  final double? fontSize;
  final int? textColor;
  final int created, updated;
  final Map<String, int> clock;

  bool supersedes(DeskEntry other) =>
      other.clock.entries.every((e) => (clock[e.key] ?? 0) >= e.value) &&
      clock.entries.any((e) => e.value > (other.clock[e.key] ?? 0));

  Map<String, Object?> toJson() => {
    'id': id,
    'revision': revision,
    'kind': kind.name,
    'title': title,
    'body': body,
    'done': done,
    'deleted': deleted,
    if (fontFamily != null) 'fontFamily': fontFamily,
    if (fontSize != null) 'fontSize': fontSize,
    if (textColor != null) 'textColor': textColor,
    'created': created,
    'updated': updated,
    'clock': clock,
  };

  factory DeskEntry.fromJson(Map<String, dynamic> m) {
    if (!validDeskFontFamily(m['fontFamily']) ||
        !validDeskFontSize(m['fontSize']) ||
        !validDeskTextColor(m['textColor'])) {
      throw const FormatException('便签/待办文字样式无效');
    }
    final kind = DeskKind.values.byName(m['kind'] as String);
    final clock = Map<String, int>.from(m['clock'] as Map);
    final entry = DeskEntry(
      id: m['id'] as String,
      revision: m['revision'] as String,
      kind: kind,
      title: m['title'] as String,
      body: m['body'] as String,
      done: m['done'] as bool,
      deleted: m['deleted'] as bool,
      fontFamily: (m['fontFamily'] as String?)?.trim().isEmpty == true
          ? null
          : (m['fontFamily'] as String?)?.trim(),
      fontSize: (m['fontSize'] as num?)?.toDouble(),
      textColor: m['textColor'] as int?,
      created: m['created'] as int,
      updated: m['updated'] as int,
      clock: Map.unmodifiable(clock),
    );
    if (entry.id.isEmpty ||
        entry.id.length > 128 ||
        entry.revision.isEmpty ||
        entry.revision.length > 128 ||
        entry.title.length > 200 ||
        entry.body.length > 20000 ||
        clock.isEmpty ||
        clock.length > 256 ||
        clock.entries.any(
          (e) => e.key.isEmpty || e.key.length > 128 || e.value <= 0,
        )) {
      throw const FormatException('便签/待办同步数据无效');
    }
    return entry;
  }

  static List<DeskEntry> heads(Iterable<DeskEntry> entries) {
    final values = entries.toList();
    return values
        .where(
          (a) => !values.any(
            (b) => a.id == b.id && a.kind == b.kind && b.supersedes(a),
          ),
        )
        .toList();
  }
}

class DeskSettings {
  const DeskSettings({
    this.enabled = false,
    this.sync = false,
    this.monitor = '',
    this.x = -1,
    this.y = -1,
    this.width = 320,
    this.height = 0,
    this.color = 0xFFFFFFFF,
    this.color2 = 0xFFD8D0F8,
    this.gradient = 'none',
    this.transparent = true,
    this.opacity = 0.24,
    this.fontFamily = '',
    this.fontSize = 12,
    this.textColor,
  });
  final bool enabled, sync, transparent;
  final String monitor, gradient;
  final double x, y, width, height, opacity;
  final int color, color2;
  final String fontFamily;
  final double fontSize;
  final int? textColor;
  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'sync': sync,
    'monitor': monitor,
    'x': x,
    'y': y,
    'width': width,
    'height': height,
    'color': color,
    'color2': color2,
    'gradient': gradient,
    'transparent': transparent,
    'opacity': opacity,
    'fontFamily': fontFamily,
    'fontSize': fontSize,
    'textColor': textColor,
  };
  factory DeskSettings.fromJson(Map<String, dynamic> m) => DeskSettings(
    enabled: m['enabled'] == true,
    sync: m['sync'] == true,
    monitor: m['monitor'] as String? ?? '',
    x: (m['x'] as num?)?.toDouble() ?? -1,
    y: (m['y'] as num?)?.toDouble() ?? -1,
    width: ((m['width'] as num?)?.toDouble() ?? 320).clamp(180, 4000),
    height: ((m['height'] as num?)?.toDouble() ?? 0).clamp(0, 8000),
    color: m['color'] as int? ?? 0xFFFFFFFF,
    color2: m['color2'] as int? ?? 0xFFD8D0F8,
    gradient: m['gradient'] as String? ?? 'none',
    transparent: m['transparent'] != false,
    opacity: ((m['opacity'] as num?)?.toDouble() ?? 0.24).clamp(0, 1),
    fontFamily: validDeskFontFamily(m['fontFamily'])
        ? (m['fontFamily'] as String? ?? '').trim()
        : '',
    fontSize: validDeskFontSize(m['fontSize'])
        ? (m['fontSize'] as num?)?.toDouble() ?? 12
        : 12,
    textColor: validDeskTextColor(m['textColor'])
        ? m['textColor'] as int?
        : null,
  );
  DeskSettings change(Map<String, Object?> changes) =>
      DeskSettings.fromJson({...toJson(), ...changes});
  static DeskSettings decode(String? value) => value == null
      ? const DeskSettings()
      : DeskSettings.fromJson(jsonDecode(value));
}
