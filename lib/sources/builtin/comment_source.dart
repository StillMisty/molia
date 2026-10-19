/// 内置平台评论获取的调度入口（五平台：kw / kg / tx / wy / mg）。
///
/// 移植自 lx-music-mobile `{wy,tx,kg,kw,mg}/comment.js`：热门 + 最新两类、
/// 按页取数，统一产出领域模型 [CommentPage]。
///
/// 与搜索/歌词的差异：评论没有「脚本回传」需求（LX 的 comment 只在内置实现），
/// 因此解析直接产出领域模型，不再经 sources → data 的映射层。
///
/// 平台矩阵、评论 ID 字段与各平台实现集中在 [BuiltinPlatforms]；本文件只做
/// raw 字段解析与「不支持」的失败语义（抛 [SourceFailure]）。
library;

import '../../domain/models/comment.dart';
import '../../domain/models/failure.dart';
import 'builtin_platforms.dart';
import 'comment_utils.dart';

class BuiltinComments {
  BuiltinComments._();

  static bool isSupported(String sourceKey) =>
      BuiltinPlatforms.commentsFor(sourceKey) != null;

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
    final adapter = BuiltinPlatforms.commentsFor(sourceKey);
    if (adapter == null) {
      throw SourceFailure(
        kind: FailureKind.unsupported,
        message: '内置平台不支持评论: $sourceKey',
      );
    }
    return adapter.fetch(
      _requiredId(sourceKey, raw, adapter.rawIdKeys),
      kind: kind,
      page: page,
      limit: limit,
    );
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
