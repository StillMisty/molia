/// DownloadNotifications 的 Pigeon **channel 模式**适配器（issue #82）。
///
/// 只做平台守卫与失败静默；生成绑定见同目录
/// `download_notifications.g.dart`。手写适配器刻意不与生成物同名
/// （source_gen 会删除同名 `.g.dart`）。
///
/// 旧 `top.stillmisty.molia/download_notifications` 通道保留为 fallback：本层
/// 只负责 Pigeon transport，fallback 组合在
/// `lib/data/downloads/download_notifications_io.dart` 完成（平台层不得反向
/// 依赖 data 层，ADR-0038）。非 Android 不调用生成 API，一律 no-op。
///
/// 渠道用 wire 字符串（`downloads` / `update`）而不是 data 层的 enum：平台层
/// 不能 import `download_notifications_types.dart`，映射由 data 层完成。
library;

import 'dart:io' show Platform;

import 'download_notifications.g.dart';

/// 生成 host API 的最小接口：便于单测注入假 host，也隔离生成类的构造细节。
abstract interface class DownloadNotificationsHostApi {
  Future<void> start(StartRequest request);

  Future<void> update(UpdateRequest request);

  Future<void> stop(String id);
}

/// 把生成的 [DownloadNotificationsApi] 投影成
/// [DownloadNotificationsHostApi]。
class GeneratedDownloadNotificationsHostApi
    implements DownloadNotificationsHostApi {
  GeneratedDownloadNotificationsHostApi({DownloadNotificationsApi? api})
    : _api = api ?? DownloadNotificationsApi();

  final DownloadNotificationsApi _api;

  @override
  Future<void> start(StartRequest request) => _api.start(request);

  @override
  Future<void> update(UpdateRequest request) => _api.update(request);

  @override
  Future<void> stop(String id) => _api.stop(id);
}

/// Pigeon transport 的窄接口，供 fallback 组合与单测注入。
abstract interface class DownloadNotificationsTransport {
  /// 当前平台是否支持系统下载 / 更新通知（仅 Android）。
  bool get supported;

  /// Pigeon transport 是否仍可用；首次异常后置 false，后续调用直接走 fallback。
  bool get transportAvailable;

  Future<void> start({
    required String id,
    required String title,
    String subtitle,
    int? index,
    int? total,
    int? progress,
    int? max,
    String channel,
  });

  Future<void> update({
    required String id,
    String? title,
    String? subtitle,
    int? index,
    int? total,
    int? progress,
    int? max,
  });

  Future<void> stop(String id);
}

/// Pigeon 优先的通知实现：Android 调生成 API，其余平台与异常一律静默降级。
///
/// 与旧通道语义保持一致：空 id 不触碰 transport（原生也会忽略），通知失败
/// 只吞掉异常并永久标记 transport 不可用，不影响下载链路。
class PigeonDownloadNotificationsAdapter
    implements DownloadNotificationsTransport {
  PigeonDownloadNotificationsAdapter({
    DownloadNotificationsHostApi? api,
    bool? isAndroid,
  }) : _api = api ?? GeneratedDownloadNotificationsHostApi(),
       _isAndroid = isAndroid ?? Platform.isAndroid;

  final DownloadNotificationsHostApi _api;
  final bool _isAndroid;

  /// 首次调用异常即视为 Pigeon transport 缺失（旧版原生未注册 / 引擎未就绪），
  /// 后续调用不再重复抛异常。
  bool _unavailable = false;

  @override
  bool get supported => _isAndroid;

  @override
  bool get transportAvailable => _isAndroid && !_unavailable;

  @override
  Future<void> start({
    required String id,
    required String title,
    String subtitle = '',
    int? index,
    int? total,
    int? progress,
    int? max,
    String channel = 'downloads',
  }) async {
    if (!transportAvailable || id.isEmpty) return;
    try {
      await _api.start(
        StartRequest(
          id: id,
          title: title,
          subtitle: subtitle,
          index: index,
          total: total,
          progress: progress,
          max: max,
          channel: channel,
        ),
      );
    } catch (_) {
      _unavailable = true;
    }
  }

  @override
  Future<void> update({
    required String id,
    String? title,
    String? subtitle,
    int? index,
    int? total,
    int? progress,
    int? max,
  }) async {
    if (!transportAvailable || id.isEmpty) return;
    try {
      await _api.update(
        UpdateRequest(
          id: id,
          title: title,
          subtitle: subtitle,
          index: index,
          total: total,
          progress: progress,
          max: max,
        ),
      );
    } catch (_) {
      _unavailable = true;
    }
  }

  @override
  Future<void> stop(String id) async {
    if (!transportAvailable || id.isEmpty) return;
    try {
      await _api.stop(id);
    } catch (_) {
      _unavailable = true;
    }
  }
}
