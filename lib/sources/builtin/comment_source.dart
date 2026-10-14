/// 内置平台评论获取的调度入口（五平台：kw / kg / tx / wy / mg）。
///
/// 移植自 lx-music-mobile `{wy,tx,kg,kw,mg}/comment.js`：热门 + 最新两类、
/// 按页取数，统一产出领域模型 [CommentPage]。
///
/// 与搜索/歌词的差异：评论没有「脚本回传」需求（LX 的 comment 只在内置实现），
/// 因此解析直接产出领域模型，不再经 sources → data 的映射层。
library;

import '../../domain/models/comment.dart';
import '../../domain/models/failure.dart';
import 'comment_utils.dart';
import 'kg_comment.dart';
import 'kw_comment.dart';
import 'mg_comment.dart';
import 'tx_comment.dart';
import 'wy_comment.dart';

class BuiltinComments {
  BuiltinComments._();

  /// 具备内置评论能力的平台（与 `BuiltinSearch.platforms` 一致）。
  static const Set<String> supportedKeys = {'kw', 'kg', 'tx', 'wy', 'mg'};

  static bool isSupported(String sourceKey) => supportedKeys.contains(sourceKey);

  /// 取一页评论；[raw] 为 `SourceTrack.raw`（平台字段原样，禁改写）。
  ///
  /// 声明为 `async`：校验失败（缺字段 / 不支持）也走 Future 错误通道，
  /// 调用方用统一的 `try/await` 即可，不会出现同步抛错。
  static Future<CommentPage> fetch(
    String sourceKey,
    Map<String, dynamic> raw, {
    required CommentKind kind,
    int page = 1,
    int limit = kCommentPageSize,
  }) async {
    switch (sourceKey) {
      case 'wy':
        return WyComment.fetch(
          _requiredId(sourceKey, raw, const ['songmid', 'id']),
          kind: kind,
          page: page,
          limit: limit,
        );
      case 'tx':
        return TxComment.fetch(
          _requiredId(sourceKey, raw, const ['songId']),
          kind: kind,
          page: page,
          limit: limit,
        );
      case 'kg':
        return KgComment.fetch(
          _requiredId(sourceKey, raw, const ['hash']),
          kind: kind,
          page: page,
          limit: limit,
        );
      case 'kw':
        return KwComment.fetch(
          _requiredId(sourceKey, raw, const ['songmid']),
          kind: kind,
          page: page,
          limit: limit,
        );
      case 'mg':
        return MgComment.fetch(
          _requiredId(sourceKey, raw, const ['songmid', 'copyrightId']),
          kind: kind,
          page: page,
          limit: limit,
        );
      default:
        throw SourceFailure(
          kind: FailureKind.unsupported,
          message: '内置平台不支持评论: $sourceKey',
        );
    }
  }

  /// 取评论所需的平台 ID：按候选键依次取第一个非空值。
  static String _requiredId(
    String platform,
    Map<String, dynamic> raw,
    List<String> keys,
  ) {
    for (final key in keys) {
      final value = raw[key]?.toString();
      if (value != null && value.isNotEmpty) return value;
    }
    throw commentPlatformFailure(platform, '缺少取评论所需字段 ${keys.join('/')}');
  }
}
