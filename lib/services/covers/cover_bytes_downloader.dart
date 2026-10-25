/// 封面字节直连下载：统一请求头 + 8MB 上限 + 缓存回填。
///
/// 下载链路（`DownloadService`）与「保存原图」共用；不走
/// `flutter_cache_manager` 的缩略图路径——那条路径会把原 URL 缓存键覆盖成
/// 缩小图，拿缓存当原图会保存成缩略图。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import '../../data/http/app_dio.dart';
import '../../managers/artwork_cache.dart';

/// 封面大小上限：超过按无封面处理（避免异常大图占用磁盘）。
const int defaultCoverMaxBytes = 8 * 1024 * 1024;

final Logger _logger = Logger('molia.cover_bytes_downloader');

/// 按原 URL 下载封面字节；失败 / 超限返回 null。
///
/// [cache] 非空时把下载结果回填封面缓存（后续展示 / 再次保存直接命中）。
Future<Uint8List?> downloadCoverBytes(
  Dio dio,
  String url, {
  ArtworkCache? cache,
  int maxBytes = defaultCoverMaxBytes,
}) async {
  if (url.isEmpty) return null;
  try {
    final response = await dio
        .get<ResponseBody>(
          url,
          options: Options(
            responseType: ResponseType.stream,
            // 与封面显示同一套请求头（浏览器 UA + 平台 Referer）。
            headers: ArtworkCache.headersFor(url),
          ),
        )
        .timeout(const Duration(seconds: 30));
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) return null;
    final builder = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in streamBody(response).stream) {
      total += chunk.length;
      if (total > maxBytes) return null;
      builder.add(chunk);
    }
    if (total == 0) return null;
    final bytes = builder.takeBytes();
    // 回填封面缓存：后续展示 / 再次下载直接命中。
    unawaited(cache?.putBytes(url, bytes));
    return bytes;
  } catch (e) {
    _logger.warning('封面原图下载失败: $e');
    return null;
  }
}
