/// 同步版本登记册：设置 / 脚本 / 自定义封面的变化检测登记与唯一发号器。
///
/// 为什么单独一层：这些表都是「本机写出的戳 + 内容哈希」的账本，取号、登记
/// 与发号器基线必须一起更新（下一次提交要同时带上新戳与抬高后的基线）。
/// 收进这里后，`SyncStateStore` 只负责拼装持久化快照与决定提交时机；适配器
/// 仍经 [SyncStampLedger] 看到同一组方法，落盘形状仍由
/// `sync_state_codec.dart` 定义（本模块不认 JSON 键名）。
library;

import '../../domain/models/device_sync.dart';
import 'sync_book.dart';
import 'sync_stamp.dart';

/// 登记册类字段的持久化切片（对应 `SyncPersistedState` 的同名字段）。
///
/// 构造时复制集合：调用方可以把切片交给异步编码，之后的本地写入不会改到
/// 正在落盘的内容。
class SyncStampBookState {
  SyncStampBookState({
    this.stampBaseline = SyncVersion.zero,
    Map<String, SyncStamp> settingStamps = const {},
    Map<String, SyncStamp> scriptTombstones = const {},
    Map<String, SyncStamp> scriptStamps = const {},
    List<String> knownScriptIds = const [],
    this.activeScriptStamp,
    this.sessionStamp,
    Map<String, SyncStamp> coverStamps = const {},
    Map<String, SyncStamp> coverTombstones = const {},
  }) : settingStamps = Map.unmodifiable(settingStamps),
       scriptTombstones = Map.unmodifiable(scriptTombstones),
       scriptStamps = Map.unmodifiable(scriptStamps),
       knownScriptIds = List.unmodifiable(knownScriptIds),
       coverStamps = Map.unmodifiable(coverStamps),
       coverTombstones = Map.unmodifiable(coverTombstones);

  /// 版本戳发号器基线（JSON 键 `stampSeq`）；重启后不倒退。
  final SyncVersion stampBaseline;

  /// 设置键 → 登记哈希 + 版本。
  final Map<String, SyncStamp> settingStamps;

  /// 脚本 id → 删除墓碑。
  final Map<String, SyncStamp> scriptTombstones;

  /// 脚本 id → 内容哈希 + 版本（本地变化检测）。
  final Map<String, SyncStamp> scriptStamps;

  /// 上一轮收集到的脚本 id（本地删除检测的基线）。
  final List<String> knownScriptIds;

  /// 激活脚本指针的登记。
  final SyncStamp? activeScriptStamp;

  /// 上次播放会话的登记。
  final SyncStamp? sessionStamp;

  /// 自定义封面键 → 内容哈希 + 版本（本地变化检测）。
  final Map<String, SyncStamp> coverStamps;

  /// 自定义封面键 → 删除墓碑。
  final Map<String, SyncStamp> coverTombstones;
}

/// 本机同步戳账本（内存状态；不做持久化）。
class SyncStampBook implements SyncStampLedger {
  SyncStampBook({
    required this._clock,
    required this._deviceId,
    required this._onChanged,
  });

  final int Function() _clock;
  final String Function() _deviceId;

  /// 有内存变更（由状态存储标脏；轮内不改磁盘）。
  final void Function() _onChanged;

  final Map<String, SyncStamp> _settingStamps = {};
  final Map<String, SyncStamp> _scriptTombstones = {};
  final Map<String, SyncStamp> _scriptStamps = {};
  final List<String> _knownScriptIds = [];
  final Map<String, SyncStamp> _coverStamps = {};
  final Map<String, SyncStamp> _coverTombstones = {};
  SyncStamp? _activeScriptStamp;
  SyncStamp? _sessionStamp;

  SyncVersion _stampBaseline = SyncVersion.zero;

  /// 本机所有同步戳的唯一发号器。
  ///
  /// 基线经 `onAdvanced` 写回本账本并标脏；初始化时用
  /// `max(持久化基线, 当前时钟, 全库最大戳)` 通过 [SyncStampIssuer.seed] 恢复。
  @override
  late final SyncStampIssuer stampIssuer = SyncStampIssuer(
    clock: _clock,
    deviceId: _deviceId,
    onAdvanced: (value) {
      // 设备 id 不进持久化基线：记录级版本才需要它（见 SyncStampIssuer）。
      _stampBaseline = SyncVersion(
        physical: value.physical,
        counter: value.counter,
      );
      _onChanged();
    },
  );

  /// 发号器最近一次发布的基线（只随发号器前进更新）。
  SyncVersion get stampBaseline => _stampBaseline;

  @override
  int nowMs() => _clock();

  @override
  Map<String, SyncStamp> get settingStamps => _settingStamps;

  @override
  Map<String, SyncStamp> get scriptTombstones => _scriptTombstones;

  @override
  Map<String, SyncStamp> get scriptStamps => _scriptStamps;

  @override
  List<String> get knownScriptIds => List.unmodifiable(_knownScriptIds);

  @override
  SyncStamp? get activeScriptStamp => _activeScriptStamp;

  @override
  SyncStamp? get sessionStamp => _sessionStamp;

  @override
  Map<String, SyncStamp> get coverStamps => _coverStamps;

  @override
  Map<String, SyncStamp> get coverTombstones => _coverTombstones;

  @override
  void putSettingStamp(String key, SyncStamp stamp) {
    _settingStamps[key] = stamp;
    _onChanged();
  }

  @override
  void putScriptTombstone(String id, SyncStamp stamp) {
    _scriptTombstones[id] = stamp;
    _onChanged();
  }

  @override
  void putScriptStamp(String id, SyncStamp stamp) {
    _scriptStamps[id] = stamp;
    _onChanged();
  }

  @override
  void removeScriptStamp(String id) {
    if (_scriptStamps.remove(id) != null) _onChanged();
  }

  @override
  void removeScriptTombstone(String id) {
    if (_scriptTombstones.remove(id) != null) _onChanged();
  }

  @override
  void setKnownScriptIds(Iterable<String> ids) {
    _knownScriptIds
      ..clear()
      ..addAll(ids);
    _onChanged();
  }

  @override
  void setActiveScriptStamp(SyncStamp? stamp) {
    _activeScriptStamp = stamp;
    _onChanged();
  }

  @override
  void setSessionStamp(SyncStamp? stamp) {
    _sessionStamp = stamp;
    _onChanged();
  }

  @override
  void putCoverStamp(String key, SyncStamp stamp) {
    _coverStamps[key] = stamp;
    _onChanged();
  }

  @override
  void removeCoverStamp(String key) {
    if (_coverStamps.remove(key) != null) _onChanged();
  }

  @override
  void putCoverTombstone(String key, SyncStamp stamp) {
    _coverTombstones[key] = stamp;
    _onChanged();
  }

  @override
  void removeCoverTombstone(String key) {
    if (_coverTombstones.remove(key) != null) _onChanged();
  }

  /// 恢复 / 补入发号器基线（持久化残留、全库最大戳、导入备份最大戳）。
  void seed(SyncVersion known) => stampIssuer.seed(known);

  /// 当前内存状态的持久化切片（不可变；字段由 `sync_state_codec.dart` 编码）。
  SyncStampBookState snapshot() => SyncStampBookState(
    stampBaseline: _stampBaseline,
    settingStamps: _settingStamps,
    scriptTombstones: _scriptTombstones,
    scriptStamps: _scriptStamps,
    knownScriptIds: _knownScriptIds,
    activeScriptStamp: _activeScriptStamp,
    sessionStamp: _sessionStamp,
    coverStamps: _coverStamps,
    coverTombstones: _coverTombstones,
  );

  /// 把解码出的切片写回内存（整体替换：状态 JSON 是完整视图，不是增量）。
  ///
  /// 不标脏：这是启动恢复，不是本地变更。
  void applyState(SyncStampBookState state) {
    _stampBaseline = state.stampBaseline;
    _settingStamps
      ..clear()
      ..addAll(state.settingStamps);
    _scriptTombstones
      ..clear()
      ..addAll(state.scriptTombstones);
    _scriptStamps
      ..clear()
      ..addAll(state.scriptStamps);
    _knownScriptIds
      ..clear()
      ..addAll(state.knownScriptIds);
    _coverStamps
      ..clear()
      ..addAll(state.coverStamps);
    _coverTombstones
      ..clear()
      ..addAll(state.coverTombstones);
    _activeScriptStamp = state.activeScriptStamp;
    _sessionStamp = state.sessionStamp;
  }
}
