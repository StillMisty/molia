/// 曲目时长的统一展示文案（收藏 / 下载 / 搜索结果列表共用）。
///
/// 毫秒 → `m:ss`；未知 / 非法时长返回 null，调用方据此**不占行尾位置**
/// （`TrackRow.trailingText` 传 null 即隐藏），而不是显示 `0:00` 误导用户。
String? durationText(int? milliseconds) {
  if (milliseconds == null || milliseconds <= 0) return null;
  final duration = Duration(milliseconds: milliseconds);
  final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
  return '${duration.inMinutes}:$seconds';
}
