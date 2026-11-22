/// 生产健康检查探针：把正常音源搜索 / 取链路径适配成诊断探针。
///
/// 直接走 [SourceRegistry] 的音源适配器，绕过目录缓存与“最近失败”记录；
/// 不启动脚本、不改渠道偏好、不碰播放队列。固定低开销查询、第 1 页、1 条。
library;

import 'dart:async';
import 'dart:io';

import '../../domain/models/catalog.dart';
import '../../domain/models/failure.dart';
import '../../domain/models/track.dart';
import '../../domain/ports/music_source.dart';
import '../../domain/ports/source_registry.dart';
import '../../services/diagnostics/source_health_checker.dart';
import '../../sources/source_track.dart' show pickQualityFor;

class CatalogSourceHealthProbe implements SourceHealthProbe {
  CatalogSourceHealthProbe({
    required this._registry,
    this._preferredQuality,
    this.keyword = 'love',
    this._clientFactory,
  });

  final SourceRegistry _registry;

  /// 与正常播放同源的偏好音质（组合根注入省流压低后的值）。
  final String Function()? _preferredQuality;
  final String keyword;

  /// 首字节探测的 HTTP 客户端工厂（测试注入；生产每次新建并在探测后关闭）。
  final HttpClient Function()? _clientFactory;

  @override
  List<SourceHealthTarget> get targets => [
    for (final descriptor in _registry.descriptors)
      if (descriptor.enabled && descriptor.capabilities.search)
        SourceHealthTarget(
          key: descriptor.key,
          displayName: descriptor.displayName,
          canResolve: descriptor.capabilities.resolveUrl,
        ),
  ];

  @override
  Future<Track?> search(SourceHealthTarget target) async {
    // 直接走音源适配器：不经过 CatalogService 的搜索缓存，也不把健康检查
    // 失败写进“最近问题”（结果只在本轮健康检查里）。
    final source = _requireSource(target);
    final result = await source.search(
      SearchQuery(keyword: keyword, page: 1, limit: 1),
    );
    return result.items.isEmpty ? null : result.items.first;
  }

  @override
  Future<PlayableStream> resolve(SourceHealthTarget target, Track track) async {
    // 与正常播放一致：偏好音质（组合根已叠加省流上限）先按曲目可用档位
    // 收敛，再把同一档位交给取链，避免健康检查绕过省流或绕过回退规则。
    final preferred = _preferredQuality?.call();
    final quality = preferred == null || preferred.isEmpty
        ? null
        : AudioQuality(
            type: pickQualityFor(
              track.qualities.map((quality) => quality.type),
              preferred,
            ),
          );
    return _requireSource(target).resolve(track, preferredQuality: quality);
  }

  /// 有界首字节探测：只带取链结果给出的请求头（B 站直链需要 Referer / UA），
  /// 并在设置前过滤掉账号类敏感头；绝不附加账号 Cookie。
  ///
  /// 这里刻意不使用播放 / 缓存链路：探测结果不落盘、不进目录缓存，也不改变
  /// 任何播放状态。
  @override
  Future<void> stream(PlayableStream stream) async {
    final client = (_clientFactory ?? HttpClient.new)()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(stream.uri);
      for (final entry in sanitizeStreamHeaders(stream.headers).entries) {
        request.headers.set(entry.key, entry.value);
      }
      // Range 最后设置：无论音源给了什么头，探测都只请求 1 字节。
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1');
      final response = await request.close();
      final failure = streamHttpFailure(response.statusCode);
      if (failure != null) {
        // 不下载错误响应正文：直接抛类型化失败，由 finally 强制断开。
        throw failure;
      }
      final iterator = StreamIterator<List<int>>(response);
      try {
        // 只确认 body 真的能流动；空 body（如 204）不算失败。
        await iterator.moveNext().timeout(const Duration(seconds: 8));
      } finally {
        await iterator.cancel();
      }
    } finally {
      // 无论成功 / 超时 / 抛错都强制关闭，不在后台留下悬挂连接。
      client.close(force: true);
    }
  }

  MusicSource _requireSource(SourceHealthTarget target) {
    final source = _registry.byKey(target.key);
    if (source == null) {
      throw StateError('Unknown source: ${target.key}');
    }
    return source;
  }
}

/// 诊断流探测永不发送的账号 / 凭证请求头（比较时统一转小写）。
const Set<String> kSensitiveStreamHeaderNames = {
  'cookie',
  'set-cookie',
  'authorization',
  'proxy-authorization',
  'x-api-key',
  'api-key',
  'x-auth-token',
  'x-access-token',
};

/// 过滤播放直链请求头：保留 Referer / User-Agent 等播放必需头，去掉任何
/// 可能携带账号凭据的头。大小写不敏感。
Map<String, String> sanitizeStreamHeaders(Map<String, String> headers) {
  final sanitized = <String, String>{};
  for (final entry in headers.entries) {
    if (kSensitiveStreamHeaderNames.contains(entry.key.toLowerCase())) {
      continue;
    }
    sanitized[entry.key] = entry.value;
  }
  return sanitized;
}

/// HTTP 状态 → 类型化失败；`null` 表示可接受（2xx）。
///
/// 单独的纯函数便于单测：错误 message 只写状态码，不带签名 URL / 请求头 /
/// 响应正文，最终进入页面的只有 [HealthFailure]。
SourceFailure? streamHttpFailure(int statusCode) {
  if (statusCode >= 200 && statusCode < 300) return null;
  if (statusCode == 401 || statusCode == 403) {
    return SourceFailure(
      kind: FailureKind.unauthorized,
      message: 'stream probe HTTP $statusCode',
      retryable: false,
    );
  }
  if (statusCode == 404) {
    return SourceFailure(
      kind: FailureKind.notFound,
      message: 'stream probe HTTP $statusCode',
      retryable: false,
    );
  }
  if (statusCode == 429) {
    return SourceFailure(
      kind: FailureKind.rateLimited,
      message: 'stream probe HTTP $statusCode',
      retryable: true,
    );
  }
  if (statusCode >= 500) {
    return SourceFailure(
      kind: FailureKind.network,
      message: 'stream probe HTTP $statusCode',
      retryable: true,
    );
  }
  // 其余 3xx / 4xx：地址或请求本身有问题，原样重试没有意义。
  return SourceFailure(
    kind: FailureKind.unknown,
    message: 'stream probe HTTP $statusCode',
  );
}
