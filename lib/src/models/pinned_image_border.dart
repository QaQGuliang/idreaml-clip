import 'dart:ui';

enum PinnedImageBorder {
  none('无边框', null),
  light('浅色边框', Color(0xFFFFFFFF)),
  dark('深色边框', Color(0xFF292630)),
  amber('琥珀色边框', Color(0xFFE8A52C));

  const PinnedImageBorder(this.label, this.color);

  final String label;
  final Color? color;

  static PinnedImageBorder? tryParse(String? name) => values.asNameMap()[name];
}
