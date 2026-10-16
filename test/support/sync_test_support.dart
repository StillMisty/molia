import 'dart:async';

import 'package:molia/data/settings/settings_secret_store.dart';
import 'package:molia/data/sync/sync_stamp.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/ports/sync_transport.dart';

/// 测试用发号器（固定/可注入时钟 + 设备 id）：给不关心同步语义的仓库测试用。
SyncStampIssuer testStampIssuer({
  int Function()? clock,
  String deviceId = '',
}) =>
    SyncStampIssuer(
      clock: clock ?? () => DateTime.now().millisecondsSinceEpoch,
      deviceId: () => deviceId,
    );

/// 测试用内存密钥存储（替代 flutter_secure_storage）。
class MemorySyncSecretStore implements SettingsSecretStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

/// 测试用内存传输：可注入远端快照、失败计数与不可用原因，并记录推送内容。
///
/// 默认把「可用快照数」当作本轮探测到的对端数（有快照 = 见过一个对端），
/// 需要构造「探测到对端但没拿到数据」时用 [peersSeenOverride]。
class FakeSyncTransport implements SyncTransport {
  FakeSyncTransport({this.kind = 'lan', this.unavailableReason});

  @override
  final String kind;

  @override
  String? unavailableReason;

  @override
  String? unavailableDetail;

  bool _running = false;
  final List<SyncEnvelope> available = [];
  final List<SyncEnvelope> pushed = [];
  final StreamController<SyncEnvelope> _incoming =
      StreamController<SyncEnvelope>.broadcast();

  /// 覆盖 pull 报告的探测对端数（null = 用 [available] 长度）。
  int? peersSeenOverride;

  /// pull / push 报告的失败数（用于构造部分失败与全失败）。
  int pullFailures = 0;
  int pushFailures = 0;

  /// pull 报告的原因（不伴随失败计数：验证传输级错误不被吞）。
  SyncIssue? pullError;

  /// push 失败时报告的对端 id（走名册失败路径）。
  List<String> pushFailedIds = const [];

  /// pull 前执行的钩子（模拟传输侧学到手动对端身份等）。
  Future<void> Function()? onPull;

  /// pull 抛异常（模拟传输层崩溃）。
  bool throwOnPull = false;

  @override
  bool get isRunning => _running;

  @override
  Future<void> start() async {
    _running = true;
  }

  @override
  Future<void> stop() async {
    _running = false;
  }

  @override
  Future<SyncPullResult> pull() async {
    await onPull?.call();
    if (throwOnPull) throw StateError('拉取失败（测试注入）');
    return SyncPullResult(
      envelopes: List.of(available),
      peersSeen: peersSeenOverride ?? available.length,
      failedPeers: pullFailures,
      error: pullError ??
          (pullFailures > 0
              ? const SyncIssue(
                  code: SyncIssueCode.pullFailed, detail: '拉取失败（测试注入）')
              : null),
    );
  }

  @override
  Future<SyncPushResult> push(SyncEnvelope envelope) async {
    pushed.add(envelope);
    if (pushFailures > 0) {
      return SyncPushResult(
        failedPeers: pushFailures,
        failedIds: pushFailedIds,
        error: const SyncIssue(
            code: SyncIssueCode.pushFailed, detail: '推送失败（测试注入）'),
      );
    }
    return const SyncPushResult(succeededPeers: 1);
  }

  @override
  Stream<SyncEnvelope> get incoming => _incoming.stream;

  /// 模拟对端主动推送。
  void emitIncoming(SyncEnvelope envelope) => _incoming.add(envelope);
}
