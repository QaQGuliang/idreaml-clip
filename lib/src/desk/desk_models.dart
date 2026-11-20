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

/// 标题上限在模型、仓库与提示文案中保持一致。
const int deskTitleMaxLength = 120;
const int deskBodyMaxLength = 20000;

/// 已发布版本允许 200 字标题；读取历史/远端数据时保持兼容，
/// 避免收紧上限后旧数据无法加载。
const int deskTitleLegacyMaxLength = 200;

/// 提前提醒最多支持 7 天。
const int deskRemindBeforeMinutesMax = 7 * 24 * 60;

/// [DateTime] 可表示的毫秒时间戳范围上限，超出后无法再转换为本地时间。
const int _maxDeskTimestamp = 8640000000000000;

/// 时间戳统一为 epoch 毫秒且必须为正整数，可选字段缺省为 null。
bool validDeskTimestamp(Object? value) =>
    value == null || (value is int && value > 0 && value <= _maxDeskTimestamp);

/// 待办时间与提醒的公共校验，模型与仓库共用同一套规则。
///
/// - [startAt]/[endAt]/[remindAt] 为 epoch 毫秒且必须为正；
/// - 同时存在开始与结束时间时要求结束时间不早于开始时间；
/// - 绝对提醒 [remindAt] 与相对开始时间的提前提醒 [remindBeforeMinutes]
///   互斥，且提前提醒必须已有开始时间，范围 1–10080 分钟。
void validateDeskSchedule({
  int? startAt,
  int? endAt,
  int? remindAt,
  int? remindBeforeMinutes,
}) {
  if (!validDeskTimestamp(startAt) ||
      !validDeskTimestamp(endAt) ||
      !validDeskTimestamp(remindAt)) {
    throw const FormatException('时间设置无效：时间须为有效的毫秒时间戳');
  }
  if (startAt != null && endAt != null && endAt < startAt) {
    throw const FormatException('时间设置无效：结束时间不能早于开始时间');
  }
  if (remindAt != null && remindBeforeMinutes != null) {
    throw const FormatException('时间设置无效：绝对提醒与提前提醒只能设置一种');
  }
  if (remindBeforeMinutes != null) {
    if (startAt == null) {
      throw const FormatException('时间设置无效：提前提醒需要先设置开始时间');
    }
    if (remindBeforeMinutes < 1 ||
        remindBeforeMinutes > deskRemindBeforeMinutesMax) {
      throw const FormatException('时间设置无效：提前提醒须为 1–10080 分钟');
    }
  }
}

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
    this.startAt,
    this.endAt,
    this.remindAt,
    this.remindBeforeMinutes,
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

  /// 待办的开始时间，epoch 毫秒；null 表示未安排。
  final int? startAt;

  /// 待办的结束时间，epoch 毫秒；存在 [startAt] 时不早于开始时间。
  final int? endAt;

  /// 绝对提醒时间，epoch 毫秒；与 [remindBeforeMinutes] 互斥。
  final int? remindAt;

  /// 相对 [startAt] 的提前提醒分钟数，范围 1–10080；必须有 [startAt]。
  final int? remindBeforeMinutes;
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
    if (startAt != null) 'startAt': startAt,
    if (endAt != null) 'endAt': endAt,
    if (remindAt != null) 'remindAt': remindAt,
    if (remindBeforeMinutes != null) 'remindBeforeMinutes': remindBeforeMinutes,
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
    final startAt = _deskTimestamp(m['startAt']);
    final endAt = _deskTimestamp(m['endAt']);
    final remindAt = _deskTimestamp(m['remindAt']);
    final remindBeforeMinutes = _deskInt(m['remindBeforeMinutes']);
    validateDeskSchedule(
      startAt: startAt,
      endAt: endAt,
      remindAt: remindAt,
      remindBeforeMinutes: remindBeforeMinutes,
    );
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
      startAt: startAt,
      endAt: endAt,
      remindAt: remindAt,
      remindBeforeMinutes: remindBeforeMinutes,
      created: m['created'] as int,
      updated: m['updated'] as int,
      clock: Map.unmodifiable(clock),
    );
    if (entry.id.isEmpty ||
        entry.id.length > 128 ||
        entry.revision.isEmpty ||
        entry.revision.length > 128 ||
        entry.title.length > deskTitleLegacyMaxLength ||
        entry.body.length > deskBodyMaxLength ||
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

int? _deskTimestamp(Object? value) {
  if (value == null) return null;
  if (value is! int) {
    throw const FormatException('时间设置无效：时间须为有效的毫秒时间戳');
  }
  return value;
}

int? _deskInt(Object? value) {
  if (value == null) return null;
  if (value is! int) {
    throw const FormatException('时间设置无效：提前提醒须为 1–10080 分钟');
  }
  return value;
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
