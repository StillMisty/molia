/// 应用更新下载通知 presenter：把「开始下载 / 进度 / 收尾」翻译成系统通知。
///
/// 为什么独立成模块：更新下载与歌曲下载共用同一个 dataSync 前台服务端口，
/// 但渠道与语义不同（固定一条 `app-update` 通知、只有下载这一个任务）；
/// 节流、只收自己起过的通知等通知生命周期细节不应散进 `UpdateProvider`
/// 的状态机。端口可注入，测试不需要 Android。
///
/// 边界：只表达通知。通知是纯附加面（权限未授予 / 通道缺失 / 原生失败一律
/// no-op），下载与安装本身不依赖它。
library;

import 'dart:async';

import '../../data/downloads/download_notifications.dart';
import '../app_branding_service.dart';

/// 应用更新通知 presenter（`UpdateProvider` 持有；每进程一个）。
class UpdateNotificationPresenter {
  /// [title] 默认读用户自定义的应用显示名（[AppBrandingService.titleNotifier]），
  /// 在 [start] 时取值——改名后下一次下载立即生效；测试可注入固定标题。
  UpdateNotificationPresenter({
    required this._notifications,
    String Function()? title,
    int Function()? clock,
  }) : _title = title ?? (() => AppBrandingService.titleNotifier.value),
       _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// 固定通知 id：更新下载整个生命周期只有一条通知。
  static const String notificationId = 'app-update';

  /// 通知进度节流间隔：系统对通知更新有频率限制（前台服务通知尤其），
  /// 进度按「首个分片 / 距上次 ≥500ms / 已到最后一个分片」推送。
  static const int _intervalMs = 500;

  final DownloadNotifications _notifications;
  final String Function() _title;
  final int Function() _clock;

  /// 最近一次推送时间（毫秒）；null 表示还没推过进度。
  int? _sentAt;

  /// 是否已 start 过：stop 只收自己起过的通知。
  bool _started = false;

  /// 当前平台是否支持系统通知（仅 Android）。
  bool get supported => _notifications.supported;

  /// 开始下载：title 取应用显示名，subtitle 显示目标版本，进度从 0 起。
  void start({required String version}) {
    if (!_notifications.supported) return;
    _started = true;
    // 首个进度分片要立即推送：清掉上一轮的节流时间。
    _sentAt = null;
    unawaited(
      _notifications.start(
        id: notificationId,
        title: _title(),
        subtitle: version,
        progress: 0,
        channel: DownloadNotificationChannel.update,
      ),
    );
  }

  /// 进度 → 通知（500ms 节流；100% 立即推送，避免最后停在 99%）。
  ///
  /// [total] ≤ 0 表示服务器没给总大小：max 传 0，通知显示不确定进度条。
  void updateProgress(int received, int total) {
    if (!_started) return;
    final now = _clock();
    final last = _sentAt;
    final complete = total > 0 && received >= total;
    if (last != null && !complete && now - last < _intervalMs) return;
    _sentAt = now;
    unawaited(
      _notifications.update(
        id: notificationId,
        progress: received,
        max: total > 0 ? total : 0,
      ),
    );
  }

  /// 收尾并移除通知；重复调用幂等，未 start 过时不动端口。
  void stop() {
    if (!_started) return;
    _started = false;
    _sentAt = null;
    unawaited(_notifications.stop(notificationId));
  }
}
