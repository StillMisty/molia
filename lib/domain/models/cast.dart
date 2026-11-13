/// 投屏领域模型：来源资格、会话状态与投屏条目。
///
/// 投屏是**新的播放目标**，不是本地播放的假进度：本地 `PlaybackSnapshot`
/// 仍然只描述本机播放器；远端状态由 `CastSessionController` 单独持有。
library;

import 'track.dart' show TrackOrigin;
import '../ports/music_source.dart' show PlayableStream;

/// 投屏被拒绝的类型化原因（UI 只把它翻成一句「这个来源不能稳定投屏」）。
enum CastRejectionReason {
  /// 平台链接需要请求头（B 站 Referer / UA 等），投屏设备无法携带。
  headersRequired,

  /// 链接剩余有效期太短，渲染器还没起播就过期。
  shortLived,

  /// 链接不是 http(s)，无法交给渲染器。
  unsupportedScheme,

  /// 本地 / 下载曲目缺少可读文件。
  missingLocalFile,
}

/// 一次来源判定：合格时带可交给渲染器的 URI。
class CastEligibility {
  const CastEligibility.eligible(this.uri) : reason = null;

  const CastEligibility.rejected(CastRejectionReason this.reason) : uri = null;

  final Uri? uri;
  final CastRejectionReason? reason;

  bool get isEligible => uri != null;
}

/// 候选来源：本地文件优先，其次匿名平台链接。
class CastSource {
  const CastSource({
    required this.origin,
    this.localFileUri,
    this.stream,
    this.downloaded = false,
  });

  final TrackOrigin origin;

  /// 本地 / 下载曲目的文件 URI（由本地媒体服务转成局域网地址）。
  final Uri? localFileUri;

  /// 平台解析出的播放链接（含请求头与有效期）。
  final PlayableStream? stream;

  /// 是否已有完整下载副本（下载副本即使 origin 不是 localFile 也可投）。
  final bool downloaded;
}

/// 纯策略：决定「这个来源能不能投」。
///
/// 规则（规格）：
/// - 本地 / 下载曲目永远合格（由本地媒体服务提供 URL）；
/// - 匿名平台链接要求无请求头、且没有已知过期或剩余 >= 10 分钟；
/// - B 站等带请求头的链接按策略拒绝，不靠渲染器失败兜底。
abstract final class CastSourcePolicy {
  /// 交给渲染器的最短剩余有效期：渲染器启动慢，低于这个值等于必然失败。
  static const Duration minRemainingLifetime = Duration(minutes: 10);

  static CastEligibility evaluate(CastSource source, {DateTime? now}) {
    if (source.downloaded || source.origin == TrackOrigin.localFile) {
      final file = source.localFileUri;
      return file == null
          ? const CastEligibility.rejected(CastRejectionReason.missingLocalFile)
          : CastEligibility.eligible(file);
    }
    final stream = source.stream;
    if (stream == null) {
      return const CastEligibility.rejected(CastRejectionReason.shortLived);
    }
    if (stream.headers.isNotEmpty) {
      return const CastEligibility.rejected(
        CastRejectionReason.headersRequired,
      );
    }
    final scheme = stream.uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      return const CastEligibility.rejected(
        CastRejectionReason.unsupportedScheme,
      );
    }
    final expiresIn = stream.expiresIn;
    if (expiresIn != null && expiresIn < minRemainingLifetime) {
      return const CastEligibility.rejected(CastRejectionReason.shortLived);
    }
    return CastEligibility.eligible(stream.uri);
  }
}

/// 投屏条目（远端播放的最小信息；不携带本地 payload / headers）。
class CastMedia {
  const CastMedia({
    required this.title,
    required this.uri,
    this.artist,
    this.duration,
    this.queueIndex,
  });

  final String title;
  final String? artist;
  final Uri uri;
  final Duration? duration;

  /// 队列下标（原生 browse tree / 下一首定位用；非队列来源为 null）。
  final int? queueIndex;
}

/// 队列下一首的候选：媒体地址 + 原始来源（控制器重新做资格判定）。
class CastCandidate {
  const CastCandidate({required this.media, required this.source});

  final CastMedia media;
  final CastSource source;
}

/// 发现到的渲染器。
class CastDevice {
  const CastDevice({required this.id, required this.name, this.address});

  final String id;
  final String name;
  final String? address;
}

/// 远端播放状态（只读展示；不写回本地 PlaybackSnapshot）。
class CastRemoteState {
  const CastRemoteState({
    this.position = Duration.zero,
    this.isPlaying = false,
    this.duration,
  });

  final Duration position;
  final bool isPlaying;
  final Duration? duration;
}

/// 会话状态机。
enum CastSessionState { idle, discovering, connecting, connected, error }
