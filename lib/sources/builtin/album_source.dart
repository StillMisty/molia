/// 内置平台专辑获取的调度入口（五平台：kw / kg / tx / wy / mg）。
///
/// 与评论同构：专辑没有「脚本回传」需求（LX 的专辑只在内置实现），解析直接
/// 产出领域模型 `Album`（曲目为领域 `Track`，payload 经 track_mapper 原样
/// 透传），不再经 sources → data 的额外映射层。
///
/// 平台矩阵与各平台实现集中在 [BuiltinPlatforms]；本文件只保留参数校验与
/// 「不支持」的失败语义（抛 [SourceFailure]）。
///
/// 端点均已在开发环境抓到真实响应（test/fixtures/albums/），仍需真机复验。
library;

import '../../domain/models/album.dart';
import '../../domain/models/failure.dart';
import 'builtin_platforms.dart';

class BuiltinAlbums {
  BuiltinAlbums._();

  static bool isSupported(String sourceKey) =>
      BuiltinPlatforms.albumFor(sourceKey) != null;

  /// 取一页专辑；[albumId] 为平台内专辑 id（wy 数字 id / tx albumMid / kg/kw/mg albumId）。
  ///
  /// 声明为 `async`：校验失败（不支持）也走 Future 错误通道，
  /// 调用方用统一的 `try/await` 即可，不会出现同步抛错。
  static Future<Album> fetch(
    String sourceKey,
    String albumId, {
    int page = 1,
    int limit = kAlbumPageSize,
  }) async {
    if (albumId.trim().isEmpty) {
      throw SourceFailure(
        kind: FailureKind.unknown,
        message: '缺少专辑 id',
        retryable: true,
      );
    }
    final adapter = BuiltinPlatforms.albumFor(sourceKey);
    if (adapter == null) {
      throw SourceFailure(
        kind: FailureKind.unsupported,
        message: '内置平台不支持专辑: $sourceKey',
      );
    }
    return adapter(albumId, page: page, limit: limit);
  }
}
