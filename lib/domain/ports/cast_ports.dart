/// 投屏端口：发现 / 传输 / 本地播放命令面。
///
/// 控制器只依赖这三个接口；生产实现（SSDP、AVTransport、播放 provider）
/// 与测试假件都从这里接入，避免控制器 import provider 或平台代码。
library;

import '../models/cast.dart';

abstract interface class CastDiscovery {
  /// 按需发现（不后台扫描）；无设备返回空列表。
  Future<List<CastDevice>> discover();

  Future<void> stop();
}

abstract interface class CastTransport {
  Future<void> connect(CastDevice device);

  Future<void> play(CastMedia media);

  Future<void> pause();

  Future<void> resume();

  Future<void> seek(Duration position);

  Future<CastRemoteState> poll();

  Future<void> stop();
}

/// 本地播放命令面：投屏开始只允许暂停本地，**没有**恢复本地播放的方法。
abstract interface class CastPlaybackPort {
  Future<void> pauseForCast();

  /// 队列下一首（按现有队列快照）；没有下一首返回 null。
  Future<CastCandidate?> nextMedia();
}
