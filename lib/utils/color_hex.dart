/// 颜色十六进制文案的统一格式（大写、`#` 前缀）。
///
/// 任意取色无需色名：设置页与歌词颜色行共用同一格式；
/// [withAlpha] 为 true 时保留 alpha 通道（`#AARRGGBB`），否则输出 `#RRGGBB`
/// （与取色器弹层内部的显示格式一致）。
String colorHexLabel(int argb, {bool withAlpha = false}) {
  final digits = withAlpha ? 8 : 6;
  final value = withAlpha ? argb : (argb & 0xFFFFFF);
  return '#${value.toRadixString(16).padLeft(digits, '0').toUpperCase()}';
}
