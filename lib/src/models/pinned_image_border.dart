import 'dart:ui';

enum PinnedImageBorder {
  none('无边框', null),
  light('浅色', Color(0xFFF5F5F5)),
  dark('深色', Color(0xFF303030)),
  amber('琥珀色', Color(0xFFFCD68B));

  const PinnedImageBorder(this.label, this.color);

  final String label;
  final Color? color;

  static PinnedImageBorder? tryParse(String? name) => values.asNameMap()[name];
}
