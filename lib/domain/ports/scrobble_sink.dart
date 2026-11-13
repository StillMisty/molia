/// 听歌同步协议适配器的最小接口。
///
/// 适配器只负责「把一条事件发出去并报告结论」，不读写设置、不重试、不排队；
/// 重试 / 退避 / 授权状态由 `ScrobbleService` 与 outbox 统一负责。
library;

import '../models/scrobble.dart';

abstract interface class ScrobbleSink {
  ScrobbleTarget get target;

  /// 发送「正在播放」提示（best-effort，不进 outbox）。
  Future<ScrobbleDelivery> sendNowPlaying(ScrobbleListen listen);

  /// 发送一条计入历史的 scrobble。
  Future<ScrobbleDelivery> sendScrobble(ScrobbleListen listen);
}

/// 支持口令验证的服务（ListenBrainz）。
abstract interface class ScrobbleCredentialSink {
  Future<ScrobbleCredentialCheck> validateCredential(String credential);
}
