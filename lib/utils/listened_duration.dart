/// 收听时长的显示口径（统计页 / 年度报告 / 统计导出提示共用）。
///
/// 秒 / 分钟 / 小时·分三档；不负责数据聚合，只把毫秒转成用户可读文案。
library;

import '../l10n/app_localizations.dart';

String formatListenedDuration(AppLocalizations l10n, int listenedMs) {
  final totalSeconds = listenedMs ~/ 1000;
  if (totalSeconds < 60) return l10n.statsDurationSeconds(totalSeconds);
  final minutes = totalSeconds ~/ 60;
  if (minutes < 60) return l10n.statsDurationMinutes(minutes);
  return l10n.statsDurationHours(minutes ~/ 60, minutes % 60);
}
