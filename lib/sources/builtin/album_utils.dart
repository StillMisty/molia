/// 内置平台专辑解析的共享工具（五平台 album 实现共用）。
///
/// 失败语义（与内置评论一致）：
/// - 传输失败（含重试耗尽）由 `BuiltinHttpException` 上抛，边界归一化为
///   `SourceFailure(kind: network)`；
/// - 平台业务拒绝 / 缺少取专辑所需字段 → [albumPlatformFailure]
///   （kind: unknown、retryable: true）。
library;

import '../../domain/models/failure.dart';

/// 平台业务拒绝 / 缺少字段的统一失败（可重试：多为平台抖动或字段缺失）。
SourceFailure albumPlatformFailure(String platform, String reason) =>
    SourceFailure(
      kind: FailureKind.unknown,
      message: '$platform: $reason',
      retryable: true,
    );

/// 是否还有下一页：平台返回总数时按页码算；无总数（或总数为 0）视为结束。
bool albumHasMore({required int page, required int limit, int? total}) =>
    total != null && total > 0 && page * limit < total;

/// 发行年份归一化：兼容毫秒时间戳（wy `publishTime`）、
/// `yyyy-MM-dd[ HH:mm:ss]` 文本（tx/kg/mg）与裸年份。
int? albumYearOf(Object? value) {
  if (value == null) return null;
  if (value is num) {
    final number = value.toInt();
    if (number <= 0) return null;
    // 毫秒时间戳（10 位秒级时间戳在此语义下不出现，直接按年份拒绝）。
    if (number > 100000000000) {
      return DateTime.fromMillisecondsSinceEpoch(number).year;
    }
    return (number >= 1000 && number <= 9999) ? number : null;
  }
  final match = RegExp(r'(\d{4})').firstMatch(value.toString());
  if (match == null) return null;
  final year = int.tryParse(match.group(1)!);
  return (year != null && year >= 1000 && year <= 9999) ? year : null;
}
