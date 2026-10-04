import 'dart:convert';

class WorkspaceLayout {
  const WorkspaceLayout({this.sidebarWidth = 226, this.historyFraction = .65});

  static const minSidebarWidth = 72.0;
  static const maxSidebarWidth = 320.0;
  static const compactSidebarWidth = 176.0;
  static const minHistoryWidth = 300.0;
  static const minDetailWidth = 280.0;

  final double sidebarWidth;
  final double historyFraction;

  WorkspaceLayout copyWith({double? sidebarWidth, double? historyFraction}) =>
      WorkspaceLayout(
        sidebarWidth: _bounded(
          sidebarWidth,
          this.sidebarWidth,
          minSidebarWidth,
          maxSidebarWidth,
        ),
        historyFraction: _bounded(historyFraction, this.historyFraction, 0, 1),
      );

  String encode() => jsonEncode({
    'sidebarWidth': sidebarWidth,
    'historyFraction': historyFraction,
  });

  static WorkspaceLayout decode(String? value) {
    const fallback = WorkspaceLayout();
    if (value == null) return fallback;
    try {
      final json = jsonDecode(value);
      if (json is! Map) return fallback;
      return fallback.copyWith(
        sidebarWidth: (json['sidebarWidth'] as num?)?.toDouble(),
        historyFraction: (json['historyFraction'] as num?)?.toDouble(),
      );
    } on FormatException {
      return fallback;
    } on TypeError {
      return fallback;
    }
  }

  static double _bounded(
    double? value,
    double fallback,
    double min,
    double max,
  ) => value == null || !value.isFinite ? fallback : value.clamp(min, max);
}
