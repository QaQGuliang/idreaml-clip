enum ArrowStyle {
  single('单向箭头'),
  filled('实心箭头'),
  outlined('空心箭头'),
  doubleHeaded('双向箭头'),
  dashed('虚线箭头'),
  elbow('折线箭头');

  const ArrowStyle(this.label);
  final String label;

  static ArrowStyle? tryParse(Object? value) {
    for (final style in values) {
      if (value == style.name) return style;
    }
    return null;
  }
}
