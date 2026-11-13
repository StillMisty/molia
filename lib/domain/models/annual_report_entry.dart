/// 年度报告入口的纯模型：可用年份、默认年份与 12–1 月强调。
///
/// 数据来自统计页已有的全量日历 rollup（不额外查询）；时钟只决定「现在是
/// 哪个月」，因此可以脱离 widget 测试。
library;

import 'play_statistics.dart';

/// 统计页里的年度报告入口状态。
class AnnualReportEntry {
  const AnnualReportEntry({
    required this.years,
    required this.featuredYear,
    required this.prominent,
  });

  /// 没有可用年份时入口完全不出现。
  static const AnnualReportEntry hidden = AnnualReportEntry(
    years: [],
    featuredYear: 0,
    prominent: false,
  );

  /// 有数据的年份，新 → 旧。
  final List<int> years;

  /// 打开报告时的默认年份。
  final int featuredYear;

  /// 12 月 / 1 月用高强调（填充卡片 + tonal 行动），其余月份低调。
  final bool prominent;

  bool get isVisible => years.isNotEmpty;

  /// 从全量按日 rollup 推导入口。
  ///
  /// - 1 月：上一年有数据则推上一年，否则推最新一年；
  /// - 12 月：当年有数据则推当年，否则推最新一年；
  /// - 其它月份：最新一年。
  static AnnualReportEntry fromDaily(
    List<DayListened> daily, {
    required DateTime now,
  }) {
    final years = <int>{};
    for (final day in daily) {
      if (day.listenedMs > 0 || day.playCount > 0) years.add(day.day.year);
    }
    if (years.isEmpty) return hidden;
    final sorted = years.toList()..sort((a, b) => b.compareTo(a));
    final newest = sorted.first;
    int featured;
    if (now.month == 1) {
      featured = sorted.contains(now.year - 1) ? now.year - 1 : newest;
    } else if (now.month == 12) {
      featured = sorted.contains(now.year) ? now.year : newest;
    } else {
      featured = newest;
    }
    return AnnualReportEntry(
      years: List.unmodifiable(sorted),
      featuredYear: featured,
      prominent: now.month == 12 || now.month == 1,
    );
  }
}
