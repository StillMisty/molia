/// 内置平台评论解析的共享工具（五平台 comment 实现共用）。
///
/// 失败语义（与内置搜索一致）：
/// - 传输失败（含重试耗尽）由 `BuiltinHttpException` 上抛，边界归一化为
///   `SourceFailure(kind: network)`；
/// - 平台业务拒绝 / 缺少取评论所需字段 → [commentPlatformFailure]
///   （kind: unknown、retryable: true）。
library;

import '../../domain/models/failure.dart';

/// 平台业务拒绝 / 缺少字段的统一失败（可重试：多为平台抖动或字段缺失）。
SourceFailure commentPlatformFailure(String platform, String reason) =>
    SourceFailure(
      kind: FailureKind.unknown,
      message: '$platform: $reason',
      retryable: true,
    );

/// 非空文本（平台常返回 null / 空串占位）。
String? commentTextOf(Object? value) {
  final text = value?.toString();
  return (text == null || text.isEmpty) ? null : text;
}

/// 整数（平台混用 int / 数字字符串）。
int? commentIntOf(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

/// 秒级时间戳 → 本地时间（毫秒时间戳按位数自动识别）。
DateTime? commentTimeFromEpoch(Object? value) {
  final raw = commentIntOf(value);
  if (raw == null || raw <= 0) return null;
  final millis = raw > 100000000000 ? raw : raw * 1000;
  return DateTime.fromMillisecondsSinceEpoch(millis);
}

/// 文本时间（`yyyy-MM-dd HH:mm(:ss)`）→ 本地时间。
DateTime? commentTimeFromText(Object? value) {
  final text = commentTextOf(value);
  if (text == null) return null;
  return DateTime.tryParse(text.replaceFirst(' ', 'T'));
}

/// 游标分页会话存储：按「曲目 → 页码」保存平台游标。
///
/// 网易云最新评论（weapi `cursor`）与咪咕最新评论（`commentId`）都是
/// 「上一页的最后位置」语义：取第 N 页时读 key N（第 N-1 页写入），
/// 第一页无游标（平台从最新一条开始）。超出 [maxSessions] 时丢弃最早的曲目
/// （简化的 LRU），只保留最近两页的游标避免按曲目无限增长。
class CommentCursorStore {
  CommentCursorStore({this.maxSessions = 32});

  /// 同时保留游标的曲目数上限。
  final int maxSessions;

  final Map<String, Map<int, String>> _cursors = {};

  /// 取第 [page] 页所需游标（不存在时为 null）。
  String? read(String trackKey, int page) => _cursors[trackKey]?[page];

  /// 写入第 [page] 页所需游标（由第 `page - 1` 页的响应提供）。
  void write(String trackKey, int page, String cursor) {
    if (cursor.isEmpty) return;
    if (_cursors.length >= maxSessions && !_cursors.containsKey(trackKey)) {
      _cursors.remove(_cursors.keys.first);
    }
    final pages = _cursors.putIfAbsent(trackKey, () => <int, String>{});
    pages[page] = cursor;
    pages.removeWhere((nextPage, _) => nextPage <= page - 2);
  }

  void clear() => _cursors.clear();
}
