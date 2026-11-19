/// DownloadsPublisher 的 Pigeon **channel 模式**适配器（issue #80）。
///
/// 只做平台守卫、参数校验与失败静默；生成绑定见同目录
/// `downloads_publisher.g.dart`。手写适配器刻意不与生成物同名
/// （source_gen 会删除同名 `.g.dart`）。
///
/// 旧 `top.stillmisty.molia/downloads` 通道保留为 fallback：本层只负责 Pigeon
/// transport，fallback 组合在 `lib/data/downloads/downloads_publisher_io.dart`
/// 完成（平台层不得反向依赖 data 层，ADR-0038）。非 Android 不调用生成 API，
/// 一律返回 null / false。
library;

import 'dart:io' show Platform;

import 'downloads_publisher.g.dart';

/// 生成 host API 的最小接口：便于单测注入假 host，也隔离生成类的构造细节。
abstract interface class DownloadsPublisherHostApi {
  Future<String?> publicRoot();

  Future<String?> publish(
    String sourcePath,
    String displayName,
    String mimeType,
    String relativeDir,
  );

  Future<bool> remove(String uri);
}

/// 把生成的 [DownloadsPublisherApi] 投影成 [DownloadsPublisherHostApi]。
class GeneratedDownloadsPublisherHostApi implements DownloadsPublisherHostApi {
  GeneratedDownloadsPublisherHostApi({DownloadsPublisherApi? api})
    : _api = api ?? DownloadsPublisherApi();

  final DownloadsPublisherApi _api;

  @override
  Future<String?> publicRoot() => _api.publicRoot();

  @override
  Future<String?> publish(
    String sourcePath,
    String displayName,
    String mimeType,
    String relativeDir,
  ) => _api.publish(sourcePath, displayName, mimeType, relativeDir);

  @override
  Future<bool> remove(String uri) => _api.remove(uri);
}

/// Pigeon transport 的窄接口，供 fallback 组合与单测注入。
abstract interface class DownloadsPublisherTransport {
  /// 当前平台是否支持公共目录发布（仅 Android）。
  bool get supported;

  /// Pigeon transport 是否仍可用；首次异常后置 false，后续调用直接走 fallback。
  bool get transportAvailable;

  Future<String?> publicRoot();

  Future<String?> publish({
    required String sourcePath,
    required String displayName,
    required String mimeType,
    String relativeDir = '',
  });

  Future<bool> remove(String uri);
}

/// Pigeon 优先的发布器：Android 调生成 API，其余平台与异常一律静默降级。
///
/// 与旧通道语义保持一致：空 `sourcePath` / `displayName` 返回 null，空 uri
/// 返回 false（原生侧同样校验）；参数校验失败不触碰 transport。
class PigeonDownloadsPublisherAdapter implements DownloadsPublisherTransport {
  PigeonDownloadsPublisherAdapter({
    DownloadsPublisherHostApi? api,
    bool? isAndroid,
  }) : _api = api ?? GeneratedDownloadsPublisherHostApi(),
       _isAndroid = isAndroid ?? Platform.isAndroid;

  final DownloadsPublisherHostApi _api;
  final bool _isAndroid;

  /// 首次调用异常即视为 Pigeon transport 缺失（旧版原生未注册 / 引擎未就绪），
  /// 后续调用不再重复抛异常。
  bool _unavailable = false;

  @override
  bool get supported => _isAndroid;

  @override
  bool get transportAvailable => _isAndroid && !_unavailable;

  @override
  Future<String?> publicRoot() async {
    if (!transportAvailable) return null;
    try {
      return await _api.publicRoot();
    } catch (_) {
      _unavailable = true;
      return null;
    }
  }

  @override
  Future<String?> publish({
    required String sourcePath,
    required String displayName,
    required String mimeType,
    String relativeDir = '',
  }) async {
    if (!transportAvailable) return null;
    if (sourcePath.isEmpty || displayName.isEmpty) return null;
    try {
      return await _api.publish(sourcePath, displayName, mimeType, relativeDir);
    } catch (_) {
      _unavailable = true;
      return null;
    }
  }

  @override
  Future<bool> remove(String uri) async {
    if (!transportAvailable) return false;
    if (uri.isEmpty) return false;
    try {
      return await _api.remove(uri);
    } catch (_) {
      _unavailable = true;
      return false;
    }
  }
}
