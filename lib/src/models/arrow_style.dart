enum ArrowStyle {
  single('单向'),
  filled('实心'),
  outlined('空心'),
  doubleHeaded('双向'),
  dashed('虚线'),
  elbow('折线');

  const ArrowStyle(this.label);
  final String label;

  static ArrowStyle? tryParse(Object? value) {
    for (final style in values) {
      if (value == style.name) return style;
    }
    return null;
  }
}
