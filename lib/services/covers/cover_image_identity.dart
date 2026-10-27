import 'dart:convert';
import 'dart:io';

import '../../managers/artwork_cache.dart';
import '../../utils/local_image_provider.dart';

/// 封面内容的本地身份：URL + 文件大小 + 修改时间。
///
/// seed 只由像素决定，但同一个封面 URL 的缓存文件可能被重新下载 / 替换。
/// 把文件元数据并入缓存键，旧 seed 自然失效，不需要额外的失效广播或版本号。
class CoverImageIdentity {
  const CoverImageIdentity({
    required this.url,
    required this.sizeBytes,
    required this.modifiedMs,
  });

  /// 封面原始地址（网络 URL 或 `file://`）。
  final String url;

  /// 本地文件大小；内容变化时通常随之变化。
  final int sizeBytes;

  /// 本地文件修改时间（毫秒）；与 [sizeBytes] 一起判断内容是否已换。
  final int modifiedMs;

  /// 取色 seed 的持久化键。
  ///
  /// 用 JSON 数组编码而不是 `url|size|mtime`：URL 本身可以含分隔符，JSON 的
  /// 引号 / 转义让三元组无歧义，避免两个不同封面拼出同一个 key。
  String get cacheKey => jsonEncode([url, sizeBytes, modifiedMs]);

  /// 解析 [url] 当前指向的本地文件身份；拿不到文件元数据返回 null。
  ///
  /// 只 `stat()` 取元数据，不读图片字节：启动命中 seed 时整条路径不应再碰
  /// 封面内容。`file://`（下载封面 / 自定义封面）直接看本地文件；网络封面
  /// 看共享封面缓存里的文件。
  static Future<CoverImageIdentity?> resolve(String url) async {
    if (url.isEmpty) return null;
    try {
      if (localFileImageProvider(url) != null) {
        final stat = await File.fromUri(Uri.parse(url)).stat();
        if (stat.type != FileSystemEntityType.file) return null;
        return CoverImageIdentity(
          url: url,
          sizeBytes: stat.size,
          modifiedMs: stat.modified.millisecondsSinceEpoch,
        );
      }
      final cached = await ArtworkCache.instance.cachedFileInfo(url);
      if (cached == null) return null;
      return CoverImageIdentity(
        url: url,
        sizeBytes: cached.sizeBytes,
        modifiedMs: cached.modifiedMs,
      );
    } catch (_) {
      // 文件消失 / URI 异常 / 缓存未就绪：按「没有身份」处理，不读也不写
      // seed；调用方继续走原来的取色链路。
      return null;
    }
  }
}
