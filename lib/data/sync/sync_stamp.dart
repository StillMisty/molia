/// HLC-lite 版本戳发号器（唯一发号器，见 ADR-0003 v2 §2）。
///
/// 为什么用 HLC-lite 而不是裸墙上时钟：裸墙上时钟有三条一致性放大路径——
/// 超前时钟永久赢、时钟回拨自伤（新写入小于已同步记录会被静默无视）、同毫秒
/// 竞争丢后写。HLC-lite 的做法是**吸收**：版本物理分量取
/// `max(本地时钟, 已观测最大值)`，同毫秒（或回拨）时 `counter++`，因此
/// - 任何设备观测过超前戳后，它的下一次写入严格大于该超前戳（全组不再被压）；
/// - 时钟回拨后仍严格递增（不会自伤）；
/// - 同毫秒不撞车（`counter` 递增）。
///
/// 发号器每进程一个（经 `SyncStampBook` 持有），基线持久化在
/// `sync_state_v2`：重启后从 `max(持久化基线, 当前时钟, 全库最大戳)` 继续，
/// 不倒退。
library;

import 'package:logging/logging.dart';

import '../../domain/models/device_sync.dart';

/// 记录级版本登记项（设置键哈希 / 脚本指针 / 会话 / 脚本墓碑共用）。
///
/// [version] 是发号器给的版本三元组；[hash] 是内容指纹（设置键 / 脚本 /
/// 会话用，判定本地是否变化），不需要时为空串。
class SyncStamp {
  /// 值哈希（设置键用；脚本指针不需要，为空串）。
  final String hash;
  final SyncVersion version;

  const SyncStamp({this.hash = '', this.version = SyncVersion.zero});

  Map<String, dynamic> toJson() => {
        if (hash.isNotEmpty) 'h': hash,
        'v': version.toJson(),
      };

  static SyncStamp? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final version = SyncVersion.fromJson(raw['v']);
    if (version == null) return null;
    return SyncStamp(
      hash: raw['h'] is String ? raw['h'] as String : '',
      version: version,
    );
  }
}

/// 版本戳发号器：本机所有同步戳的唯一来源。
///
/// 线程/调用约定：纯同步 API（不 await），调用方在自己的事务/写入路径里
/// 同步取号；`onAdvanced` 回调把新基线写回持久化状态（内存更新同步完成，
/// 磁盘落盘由状态存储的 `commit()` 提交点承担）。
class SyncStampIssuer {
  SyncStampIssuer({
    required this._clock,
    required this._deviceId,
    this._onAdvanced,
    Logger? logger,
  })  : _logger = logger ?? Logger('molia.sync');

  final int Function() _clock;
  final String Function() _deviceId;
  final void Function(SyncVersion value)? _onAdvanced;
  final Logger _logger;

  int _physical = 0;
  int _counter = 0;

  /// 当前基线（`deviceId` 不在基线里：它由调用方按记录补上）。
  SyncVersion get baseline =>
      SyncVersion(physical: _physical, counter: _counter);

  /// 本机设备 id（发号器与写路径共用同一来源）。
  String get deviceId => _deviceId();

  /// 取号：严格单调。物理分量 = `max(本地时钟, 基线)`；同值（同毫秒 / 回拨）
  /// 时 `counter++`，前进时归零。
  SyncVersion next() {
    final now = _clock();
    if (now > _physical) {
      _physical = now;
      _counter = 0;
    } else {
      _counter += 1;
    }
    return _publish();
  }

  /// 初始化 / 恢复基线：吸收外部已知的最大值（持久化残留、全库最大戳、
  /// 已导入备份最大戳）。不产生警告——这是启动种子而不是运行期观测。
  void seed(SyncVersion known) {
    final now = _clock();
    if (now > _physical) {
      _physical = now;
      _counter = 0;
    }
    _advance(known, warnAhead: false);
  }

  /// 观测一个远端版本：吸收超前的最大值。
  ///
  /// 超前（物理分量大于本机时钟）意味着对端时钟快：吸收后本机下一次写入
  /// 必然赢过它，同时记 warning 供用户自查（名册另有 `clockSkewMs`）。
  void observe(SyncVersion remote) {
    _advance(remote, warnAhead: remote.physical > _clock());
  }

  /// 吸收 `(physical, counter)` 中更大的值；严格大于才前进。
  void _advance(SyncVersion value, {required bool warnAhead}) {
    final advanced = value.physical > _physical ||
        (value.physical == _physical && value.counter > _counter);
    if (!advanced) return;
    if (warnAhead) {
      _logger.warning(
        '吸收超前版本戳：对端物理时间比本机快 '
        '${value.physical - _clock()} ms（来源 ${value.deviceId.isEmpty ? '未知' : value.deviceId}）',
      );
    }
    _physical = value.physical;
    _counter = value.counter;
    _publish();
  }

  SyncVersion _publish() {
    final value = SyncVersion(
      physical: _physical,
      counter: _counter,
      deviceId: _deviceId(),
    );
    _onAdvanced?.call(value);
    return value;
  }
}
