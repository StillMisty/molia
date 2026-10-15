/// 内置平台「按歌词搜歌」的执行骨架（唯一实现）。
///
/// 与搜索共用同一份请求 / 重试 / 业务码校验策略（`BuiltinCall` +
/// `sendBuiltinCall`，见 `builtin_search_runner.dart`）；差别只在结果形态与
/// 失败语义：
/// - 搜索：失败 → `SourceSearchResult.failed`（安静空结果）；
/// - 歌词检索：失败 → 抛 [SourceFailure]（UI 直接错误态）。
///
/// kw（伪 JSON 需要容错解析）与 wy（ids → `v3/song/detail` 二次补全规范 raw）
/// 有各自的请求流程，不走本 runner（见对应文件注释）。
library;

import '../../domain/models/failure.dart';
import 'crypto_utils.dart';
import 'builtin_search_runner.dart';
import 'lyric_hit.dart';

/// 一次歌词检索的变体面：请求 + 响应判定 + 命中解析（骨架在 [BuiltinCall]）。
class BuiltinLyricSearchCall extends BuiltinCall {
  BuiltinLyricSearchCall({
    required super.platform,
    super.method,
    required super.url,
    super.headers,
    super.body,
    super.form,
    super.retries,
    super.retryIf,
    required super.isInvalid,
    required this.parseHits,
    this.totalOf,
  });

  /// 响应 → 命中项；返回 null 表示响应合法但没有结果页（按「平台返回空」）。
  final List<SourceLyricHit>? Function(dynamic response) parseHits;

  /// 响应 → 结果总数（平台不返回时为 null，此时按「本页取满」近似 hasMore）。
  final int? Function(dynamic response)? totalOf;
}

/// 执行一次歌词检索：异常与业务拒绝抛 [SourceFailure]，「平台返回空」保持正常。
Future<LyricSearchPage> runBuiltinLyricSearch(
  BuiltinLyricSearchCall call, {
  required int page,
  required int limit,
}) async {
  final result = await sendBuiltinCall(call);
  final SourceFailure? failure = result.failure;
  if (failure != null) throw failure;

  final hits = call.parseHits(result.response);
  if (hits == null) return LyricSearchPage.empty;
  final total = call.totalOf?.call(result.response);
  return LyricSearchPage(
    hits: hits,
    total: total,
    hasMore:
        total != null && total > 0 ? page * limit < total : hits.length >= limit,
  );
}

/// 命中片段归一化：解码实体、把换行 / 多空格压成单空格；空串视为无片段。
String? normalizeLyricSnippet(String? text) {
  final decoded = decodeName(text).replaceAll(RegExp(r'\s+'), ' ').trim();
  return decoded.isEmpty ? null : decoded;
}
