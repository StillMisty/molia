/// 同步运行状态持久化：设备身份 / 传输开关 / 传输配置 / 变更登记 / 名册 / 日志。
///
/// - 非敏感状态走 SharedPreferences 单 JSON 键（`sync_state_v2`），字段 ↔
///   JSON 的映射在 `sync_state_codec.dart`（本类只管内存状态与写入时机）；
/// - 敏感项（同步口令、WebDAV 密码）走 [SettingsSecretStore]（生产 =
///   flutter_secure_storage），口令即信任根（见 ADR-0003）；
/// - 变更登记（设置键哈希、脚本 / 自定义封面墓碑、激活脚本指针）与发号器
///   由 `sync_stamp_book.dart` 持有：settings 写入方分散在多个服务，同步层用
///   「上次登记值 vs 当前值」判定本地修改，避免改造全部写入方。
/// - 名册 / 地址簿 / 端点与轮次流水各有自己的容器（`sync_roster.dart` /
///   `sync_activity_log.dart`）：这里只拼装持久化快照并决定提交时机。
/// - 持久化只有一个出口 [commit]：所有写入先改内存并标脏，用户命令 / 轮末
///   各自提交一次；轮内逐传输 / 逐对端的记账不落盘（见 `sync_book.dart`）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/models/device_sync.dart';
import '../settings/settings_secret_store.dart';
import 'sync_activity.dart';
import 'sync_activity_log.dart';
import 'sync_book.dart';
import 'sync_roster.dart';
import 'sync_stamp.dart';
import 'sync_stamp_book.dart';
import 'sync_state_codec.dart';

// 登记项是状态与适配器共用的值类型；定义在 sync_stamp.dart，保持旧 import
// 路径可用（大量调用方经本文件拿到 SyncStamp）。
export 'sync_stamp.dart' show SyncStamp;

// 传输配置 / 日志条目与状态快照同属持久化形状；定义在 codec 里，保持旧
// import 路径可用（调用方经本文件拿到 WebDavConfig / SyncLogEntry）。
export 'sync_state_codec.dart' show SyncLogEntry, WebDavConfig;

/// 同步运行状态（内存视图 + SharedPreferences 持久化）。
class SyncStateStore
    implements
        SyncStampLedger,
        SyncRoundState,
        SyncEngineState,
        SyncTransportState,
        SyncSchedulerState,
        SyncBackupState {
  SyncStateStore({
    this._preferences,
    SettingsSecretStore? secrets,
    Random? random,
    String? deviceId,
    int Function()? clock,
  })  : _secrets = secrets ?? const SecureSettingsSecretStore(),
        _random = random ?? Random.secure(),
        _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        _deviceId = deviceId ?? '';

  /// 状态键的断代命名空间（见 ADR-0003 的硬断代）。
  ///
  /// 旧键不读、不删、不迁移：新键缺失即全新安装行为，旧数据当从未存在。
  static const String stateKey = 'sync_state_v2';

  /// 设备身份的独立持久化键（prefs + 安全存储同名）。
  ///
  /// 身份不能只放在 `sync_state_v2` 里：那份 JSON 体积大、写入频繁，损坏时
  /// 若连身份一起丢，对端就会把同一台设备当成新设备（换 IP / 重启后尤其明显）。
  static const String deviceIdKey = 'sync_device_id_v2';

  static const String passphraseSecretKey = 'sync_passphrase_v2';
  static const String webdavPasswordSecretKey = 'sync_webdav_password_v2';

  /// 派生同步状态（journal / 已知版本登记）已清理的持久标记。
  ///
  /// 不能只靠内存 fresh 标志：状态 key 在 [init] 时就已写入，若进程在引擎
  /// 清理前被杀 / 清理失败，下次启动必须还能判定「仍需清理」。只有 journal
  /// 与 known 都 reset 成功后才写 true（见 [markFreshHandled]）。
  static const String derivedResetKey = 'sync_derived_reset_v2';

  /// 日志保留条数（设置页只展示最近几条；上限值定义在 codec，解码共用）。
  static const int logLimit = SyncStateCodec.logLimit;

  /// 活动记录保留条数（近 24 小时汇总用；展示日志的 20 条不足以支撑窗口）。
  static const int activityLimit = SyncStateCodec.activityLimit;

  /// 名册保留设备数（按最近接触时间淘汰；避免长期运行后无界增长）。
  static const int peerLimit = SyncStateCodec.peerLimit;

  /// 已验证局域网端点保留条数（MAC + HTTP 解密成功才写入）。
  static const int lanEndpointLimit = SyncStateCodec.lanEndpointLimit;

  /// 已验证局域网端点的保留期：超过该时长没再验证过随名册淘汰。
  static const int lanEndpointRetentionMs =
      SyncRoster.defaultLanEndpointRetentionMs;

  final SharedPreferences? _preferences;
  final SettingsSecretStore _secrets;
  final Random _random;
  final int Function() _clock;

  final Logger _logger = Logger('molia.sync.state');
  bool _saveFailureLogged = false;
  bool _identityBackupFailureLogged = false;

  /// 有内存变更尚未落盘。UI 命令改完即提交；轮内的登记 / 名册 / 台账只
  /// 标脏，由引擎在 `runRound` 返回后提交一次。
  bool _dirty = false;

  /// 成功写盘的次数（诊断 / 测试：证明一轮只提交一次）。
  int _persistedWrites = 0;

  /// 成功写盘的次数（不包含被合并掉的空提交）。
  @visibleForTesting
  int get persistedWrites => _persistedWrites;

  SharedPreferences? _prefs;
  String _deviceId;
  String _deviceName = '';
  final Map<SyncCategory, bool> _categories = {
    for (final category in SyncCategory.values)
      category: category.defaultEnabled,
  };

  /// 启用的传输：两路默认关——装机时不启动监听、不广播、不弹局域网权限，
  /// 用户打开任一开关才算启用同步（开关即总闸，见 [enabled]）。
  final Set<String> _enabledTransports = {};
  WebDavConfig _webdav = const WebDavConfig();

  /// 蜂窝网络下的自动同步策略（默认只同步小类别）。
  SyncCellularPolicy _cellularPolicy = SyncCellularPolicy.auto;

  /// 对端名册 / 地址簿 / 已验证端点；改动经 [_markDirty] 随下一次提交落盘。
  ///
  /// late 初始化才能把实例方法作为回调传入（构造列表里不能引用 this）。
  late final SyncRoster _roster = SyncRoster(
    onChanged: _markDirty,
    peerLimit: peerLimit,
    lanEndpointLimit: lanEndpointLimit,
    lanEndpointRetentionMs: lanEndpointRetentionMs,
  );

  /// 轮次流水（日志 / 活动 / 传输成功时间 / 快照发布位置）；改动只标脏。
  late final SyncActivityLog _activityLog = SyncActivityLog(
    onChanged: _markDirty,
    logLimit: logLimit,
    activityLimit: activityLimit,
  );

  /// 本机局域网快照端点端口（0 = 尚未绑定过）。
  int _lanHttpPort = 0;

  /// 本机同步戳账本（登记表 + 发号器；改动经 `onChanged` 标脏）。
  ///
  /// 这里只转交 [SyncStampLedger] 成员：登记与取号的先后关系关在账本内，
  /// 状态存储仍负责快照拼装与提交时机。
  late final SyncStampBook _stamps = SyncStampBook(
    clock: _clock,
    deviceId: () => _deviceId,
    onChanged: _markDirty,
  );

  /// 全库最大戳种子是否已补入（首帧后由 `LibraryRepository.maxVersion` 完成）。
  ///
  /// 首帧前不等这次 DB 打开；写入方在取号前先等这个 Future，保证新戳不会
  /// 低于库内已有记录（ADR-0003 的基线约束）。
  final Completer<void> _stampSeedReady = Completer<void>();

  /// 本机所有同步戳的唯一发号器（见 [SyncStampIssuer]）。
  ///
  /// 基线经账本的 `onAdvanced` 写回并在 [commit] 落盘；初始化时用
  /// `max(持久化基线, 当前时钟, 全库最大戳)` 通过 [SyncStampBook.seed] 恢复。
  @override
  SyncStampIssuer get stampIssuer => _stamps.stampIssuer;

  @override
  String get deviceId => _deviceId;

  @override
  String get deviceName => _deviceName;

  /// 同步是否启用 = 至少一路传输开启。
  ///
  /// 没有独立总开关：传输开关就是总闸（两路都关 = 完全停，轮次 / 入站 /
  /// 调度器一并停摆）。派生而非持久化，避免「总开关已开但没有任何通道」的
  /// 僵尸状态。
  @override
  bool get enabled => _enabledTransports.isNotEmpty;
  Map<SyncCategory, bool> get categories => Map.unmodifiable(_categories);

  @override
  Set<String> get enabledTransports => Set.unmodifiable(_enabledTransports);
  WebDavConfig get webdav => _webdav;

  /// 手动对端地址簿（去重后不可变）。
  @override
  List<ManualPeer> get manualPeers => _roster.manualPeers;

  /// 蜂窝网络下的自动同步策略。
  @override
  SyncCellularPolicy get cellularPolicy => _cellularPolicy;

  /// 本机局域网快照端点端口（0 = 尚未绑定过；绑定后持久化，对端才能记住）。
  int get lanHttpPort => _lanHttpPort;

  @override
  Map<String, SyncStamp> get settingStamps => _stamps.settingStamps;

  @override
  Map<String, SyncStamp> get scriptTombstones => _stamps.scriptTombstones;

  @override
  Map<String, SyncStamp> get scriptStamps => _stamps.scriptStamps;

  @override
  List<String> get knownScriptIds => _stamps.knownScriptIds;

  @override
  SyncStamp? get activeScriptStamp => _stamps.activeScriptStamp;

  @override
  SyncStamp? get sessionStamp => _stamps.sessionStamp;

  @override
  Map<String, SyncStamp> get coverStamps => _stamps.coverStamps;

  @override
  Map<String, SyncStamp> get coverTombstones => _stamps.coverTombstones;

  int get lastSyncAt => _activityLog.lastSyncAt;
  List<SyncLogEntry> get log => _activityLog.log;

  /// 近 24 小时活动记录（新在前；上限 [activityLimit]）。
  List<SyncActivityEntry> get activity => _activityLog.activity;

  /// 名册（按最近接触时间倒序；本机不在其中）。
  @override
  List<SyncPeerState> get peers => _roster.peers;

  /// 已验证的局域网端点（不可变；上限 [lanEndpointLimit]）。
  @override
  List<LanPeerEndpoint> get lanEndpoints => _roster.lanEndpoints;

  /// 传输最近一次成功接触对端的时间（0 = 尚未成功过）。
  int transportLastSuccessAt(String kind) =>
      _activityLog.transportLastSuccessAt(kind);

  /// 传输最近成功发布的全量快照覆盖位置（-1 = 尚未发布）。
  ///
  /// 判据（谁在什么条件下读它、失败时是否前移）在发布台账里；这里只是
  /// `sync_state_v2` 的键值与形状。
  @override
  int snapshotPushSeq(String kind) => _activityLog.snapshotPushSeq(kind);

  /// 只改内存 + 标脏：发布台账在推送循环里逐载荷记账，由轮末提交统一落盘
  /// （旧实现每次 mark 都写一次整份状态 JSON，多传输 / 多载荷时写放大）。
  @override
  void setSnapshotPushSeq(String kind, int seq) =>
      _activityLog.setSnapshotPushSeq(kind, seq);

  void _markDirty() {
    _dirty = true;
  }

  @override
  int nowMs() => _stamps.nowMs();

  bool isCategoryEnabled(SyncCategory category) =>
      _categories[category] ?? category.defaultEnabled;

  @override
  Set<SyncCategory> get enabledCategories => {
        for (final entry in _categories.entries)
          if (entry.value) entry.key,
      };

  bool _initialized = false;

  /// 是否需要清空可再生的派生状态。
  ///
  /// 新 key 缺失 / 空 = 全新安装；或持久标记不为 true = 上次清理尚未完成
  /// （进程在 init 与 reset 之间被杀 / reset 失败），下次启动重试。
  /// 旧键不读不迁移，所以不存在需要保留的旧协议状态。
  bool _freshInstall = false;

  /// 是否仍需清空派生状态（见 [derivedResetKey]；仅本进程内的判定结果）。
  @override
  bool get freshInstall => _freshInstall;

  /// 标记「新命名空间的派生状态已清理」（journal / known 都 reset 成功后）。
  ///
  /// 只有持久标记写入成功才清内存标志：写失败 / reset 抛错时保持待清理，
  /// 下次启动继续重试。清理是一次性的：同一进程内多个引擎实例 / 重复 init
  /// 不能反复清空派生状态（否则「登记跨重启保持」会被自己破坏）。
  @override
  Future<void> markFreshHandled() async {
    final prefs = _prefs ??= await SharedPreferences.getInstance();
    if (!await prefs.setBool(derivedResetKey, true)) {
      throw StateError('同步派生状态清理标记写入失败');
    }
    _freshInstall = false;
  }

  /// 设备 id 的 prefs 键已写、安全存储备份还没写（首装 / 身份迁移）。
  ///
  /// 首帧前只写小体积 prefs（设备 id 立即可用）；Keystore 备份放到首帧后，
  /// 避免首装冷启动在主线程等一次安全存储写入。
  bool _deviceIdBackupPending = false;

  /// 备份尚未完成的持久标记：进程在首帧后备份前被杀时，下次启动继续补写，
  /// 避免「prefs 有 id 就以为备份已完成」而永久丢掉安全存储副本。
  ///
  /// 同样按命名空间断代：旧标记不读。
  static const String _deviceIdBackupPendingKey =
      'sync_device_id_backup_pending_v2';

  /// 写入方等待「全库最大戳」种子完成（首帧后的 DB 查询）。
  Future<void> get stampSeedReady => _stampSeedReady.future;

  /// 首帧后由组合根调用：吸收全库最大戳并放行写入。
  void seedStampBaseline(SyncVersion dbMax) {
    _stamps.seed(dbMax);
    if (!_stampSeedReady.isCompleted) _stampSeedReady.complete();
  }

  /// 读取全库最大戳失败时也要放行写入：沿用持久化基线 / 当前时钟，
  /// 不能让资料库写入永久挂起（失败已由调用方记录）。
  void markStampSeedFailed() {
    if (!_stampSeedReady.isCompleted) _stampSeedReady.complete();
  }

  @override
  Future<void> init() async {
    if (_initialized) return;
    _prefs = _preferences ?? await SharedPreferences.getInstance();
    final raw = _prefs!.getString(stateKey);
    _freshInstall =
        raw == null || raw.isEmpty || _prefs!.getBool(derivedResetKey) != true;
    var stateCorrupt = false;
    if (raw != null && raw.isNotEmpty) {
      try {
        final state = SyncStateCodec.decode(jsonDecode(raw));
        if (state == null) {
          // 解析成功但不是对象：只能是写坏 / 被改过的载荷，按损坏处理
          // （状态只会由本类按对象写出）。
          stateCorrupt = true;
        } else {
          _applyState(state);
        }
      } catch (e) {
        // 损坏状态按默认处理，但**设备身份不能跟着重生成**：先尝试独立键
        // 与安全存储备份，只有全部缺失时才生成新 id（否则对端会多出一台
        // 同名的“新设备”）。
        stateCorrupt = true;
        _logger.warning('同步状态解析失败（设备身份将从独立备份恢复）', e);
      }
    }

    final stateId = _deviceId.trim();
    var identity = stateId;
    if (identity.isEmpty) {
      identity = (_prefs!.getString(deviceIdKey) ?? '').trim();
    }
    if (identity.isEmpty) {
      identity = await _readDeviceIdBackup();
    }
    if (identity.isEmpty) {
      identity = _generateDeviceId();
      _logger.warning('未找到既有同步设备身份，已生成新的设备 id（对端会视为一台新设备）');
    }
    _deviceId = identity;
    // 独立身份键先落盘（小体积），再写大状态 JSON：后者损坏时仍能恢复身份。
    await _persistDeviceIdToPrefs();

    var dirty =
        stateCorrupt || raw == null || raw.isEmpty || stateId != identity;
    if (_deviceName.isEmpty) {
      _deviceName = _defaultDeviceName();
      dirty = true;
    }
    if (dirty) {
      _markDirty();
      await commit();
    }
    // 发号器基线 = max(持久化基线, 当前时钟)：重启（含时钟回拨）不倒退。
    // 「全库最大戳」由组合根在仓库就绪后经 seed() 补入（见 LibraryRepository
    // .maxVersion）。
    _stamps.seed(_stamps.stampBaseline);
    _initialized = true;
  }

  /// 把身份写进独立 prefs 键（首帧前；只在缺失 / 不一致时写）。
  ///
  /// 正常启动 prefs 已一致：不碰安全存储，也不触发任何后续备份。
  Future<void> _persistDeviceIdToPrefs() async {
    final current = (_prefs!.getString(deviceIdKey) ?? '').trim();
    if (current == _deviceId) {
      // 上次进程可能没走到首帧后的备份：持久标记还在就继续补写。
      _deviceIdBackupPending =
          _prefs!.getBool(_deviceIdBackupPendingKey) ?? false;
      return;
    }
    _deviceIdBackupPending = true;
    try {
      await _prefs!.setString(deviceIdKey, _deviceId);
      await _prefs!.setBool(_deviceIdBackupPendingKey, true);
    } catch (e) {
      _logIdentityBackupFailure('写入', e);
    }
  }

  /// 把设备 id 备份到安全存储（首帧后调用；正常启动是空操作）。
  ///
  /// 首装 / 身份变化时 Keystore 写入可能上百毫秒，放在首帧后避免推后首帧。
  /// 读取仍留在 [init]：身份缺失时要靠备份恢复既有身份，不能安全后移。
  Future<void> backupDeviceId() async {
    if (!_deviceIdBackupPending) return;
    _deviceIdBackupPending = false;
    var backedUp = false;
    if (await _readDeviceIdBackup() == _deviceId) {
      backedUp = true;
    } else {
      try {
        await _secrets.write(deviceIdKey, _deviceId);
        backedUp = true;
      } catch (e) {
        _logIdentityBackupFailure('写入', e);
      }
    }
    if (!backedUp) {
      // 写失败保留内存标记：同进程再次调用还能重试；prefs 标记也留着，
      // 下次启动继续补写。
      _deviceIdBackupPending = true;
      return;
    }
    try {
      await _prefs!.setBool(_deviceIdBackupPendingKey, false);
    } catch (_) {
      // 清标记失败只影响下次启动多读一次安全存储，不影响正确性。
    }
  }

  Future<String> _readDeviceIdBackup() async {
    try {
      return (await _secrets.read(deviceIdKey) ?? '').trim();
    } catch (e) {
      _logIdentityBackupFailure('读取', e);
      return '';
    }
  }

  void _logIdentityBackupFailure(String action, Object error) {
    if (_identityBackupFailureLogged) return;
    _identityBackupFailureLogged = true;
    _logger.warning('设备身份备份$action失败（仅影响状态损坏后的恢复）', error);
  }

  @override
  Future<String?> readPassphrase() => _secrets.read(passphraseSecretKey);

  Future<void> writePassphrase(String passphrase) =>
      _secrets.write(passphraseSecretKey, passphrase);

  Future<String?> readWebdavPassword() =>
      _secrets.read(webdavPasswordSecretKey);

  Future<void> writeWebdavPassword(String password) =>
      _secrets.write(webdavPasswordSecretKey, password);

  // 用户命令：改完立即提交（设置页的开关 / 名称 / 配置必须扛住进程被杀）。

  Future<void> setCategory(SyncCategory category, bool value) async {
    _categories[category] = value;
    _markDirty();
    await commit();
  }

  Future<void> setTransportEnabled(String kind, bool value) async {
    if (value) {
      _enabledTransports.add(kind);
    } else {
      _enabledTransports.remove(kind);
    }
    _markDirty();
    await commit();
  }

  Future<void> setDeviceName(String value) async {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return;
    _deviceName = trimmed;
    _markDirty();
    await commit();
  }

  Future<void> setWebdavConfig(WebDavConfig config) async {
    _webdav = config;
    _markDirty();
    await commit();
  }

  Future<void> setCellularPolicy(SyncCellularPolicy value) async {
    if (_cellularPolicy == value) return;
    _cellularPolicy = value;
    _markDirty();
    await commit();
  }

  /// 添加手动对端（同一 host 覆盖：地址簿以地址为身份，学到的信息合并保留）。
  ///
  /// 返回 false 表示该地址已存在（本次按用户输入更新名称与端口）。
  Future<bool> addManualPeer(ManualPeer peer) async {
    // 空 host 不入簿也不落盘（与旧行为一致）；同址合并仍提交一次。
    if (peer.host.trim().isEmpty) return false;
    final added = _roster.addManualPeer(peer);
    await commit();
    return added;
  }

  /// 移除手动对端（按地址；仅移除地址簿条目，不影响已发现的对端）。
  Future<void> removeManualPeer(String host) async {
    if (!_roster.removeManualPeer(host)) return;
    await commit();
  }

  /// 从本机列表移除一台设备：名册 + 该设备的地址簿条目 + 首次连通提示。
  ///
  /// **只做本机记录清理，不撤销同步授权**：对方如果仍持有同步口令并在线，
  /// 下一轮探测会重新发现它。真正停止与它同步的唯一方式是更换口令（对
  /// 所有设备生效）。因此这里不写任何屏蔽 / 忽略标记（单轮抑制在名册内）。
  Future<void> removePeer(String deviceId) async {
    if (deviceId.isEmpty) return;
    _roster.removePeer(deviceId);
    await commit();
  }

  /// 清空本机对**旧同步组**的全部观测（换口令时调用）。
  ///
  /// 名册、已验证局域网端点、首次连通提示、传输成功时间与「刚移除」暂存都
  /// 只描述旧组；口令即信任根，换口令后这些设备已不再被授权。留着会让
  /// `SyncControlPlane.hasEstablishedGroup` 继续声称「已有组」，把新设备误判
  /// 成邀请方 / 冲突，旧端点也仍会被当作可信的单播目标。手动地址簿
  /// （host / 端口）是用户配置而非组观察，保留。
  Future<void> resetGroupState() async {
    _roster.resetGroupObservations();
    _activityLog.resetGroupObservations();
    await commit();
  }

  /// 更新某条手动地址的 host / 探测端口 / 命名（设备详情里的「更新地址」）。
  ///
  /// 身份（deviceId）与已学到的端点端口保留：改的是「设备在哪」，不是「是谁」。
  /// 目标地址已有条目时并入该条目并移除旧条目（同一地址不重复入簿）。
  Future<void> moveManualPeer(
    String fromHost, {
    required String toHost,
    int? probePort,
    String? name,
  }) async {
    if (!_roster.moveManualPeer(
      fromHost,
      toHost: toHost,
      probePort: probePort,
      name: name,
    )) {
      return;
    }
    await commit();
  }

  /// 回写首次接触学到的信息（deviceId / 端口 / 名称）。
  ///
  /// 学到的对端名只在条目尚未命名时填入：手动条目优先保留用户命名。
  /// 这是轮内接触的副产物：只改内存 + 标脏，随轮末提交落盘。
  Future<void> learnManualPeer(ManualPeer learned) async {
    _roster.learnManualPeer(learned);
  }

  /// 该设备是否已提示过「首次连通」（一次性提示，见 [markPeerConnectNotified]）。
  @override
  bool isPeerConnectNotified(String deviceId) =>
      _roster.isPeerConnectNotified(deviceId);

  /// 登记「首次连通」已提示：设备第一次真正交换过数据时只提示一次，
  /// 持久化后重启不重复。
  ///
  /// 只改内存 + 标脏：调用点在引擎轮末（与 `recordRound` 同一次提交），
  /// 不在通知路径上单独写整份状态 JSON。
  @override
  void markPeerConnectNotified(String deviceId) =>
      _roster.markPeerConnectNotified(deviceId);

  /// 端口只在绑定成功时写一次（生命周期事件，不是轮内逐对端记账）：立即
  /// 提交，避免对端学到的端口在进程被杀后丢失。
  Future<void> setLanHttpPort(int port) async {
    if (port <= 0 || port == _lanHttpPort) return;
    _lanHttpPort = port;
    _markDirty();
    await commit();
  }

  /// 记住一个已验证的局域网端点（MAC 验证 + HTTP 解密成功后回写）。
  ///
  /// 只更新内存 + 标脏：每轮每对端成功都会回写一次，这里若自己落盘会让
  /// 多对端一轮写多次大状态 JSON。持久化由引擎轮末的 [commit] 统一完成。
  Future<void> rememberLanEndpoint(LanPeerEndpoint endpoint) async {
    _roster.rememberLanEndpoint(endpoint);
  }

  // 登记写入只在账本内改内存并标脏；适配器仍经本类的 SyncStampLedger 面
  // 写入，落盘时机仍由本类的 commit() 统一决定。

  @override
  void putSettingStamp(String key, SyncStamp stamp) =>
      _stamps.putSettingStamp(key, stamp);

  @override
  void putScriptTombstone(String id, SyncStamp stamp) =>
      _stamps.putScriptTombstone(id, stamp);

  @override
  void putScriptStamp(String id, SyncStamp stamp) =>
      _stamps.putScriptStamp(id, stamp);

  @override
  void removeScriptStamp(String id) => _stamps.removeScriptStamp(id);

  @override
  void removeScriptTombstone(String id) => _stamps.removeScriptTombstone(id);

  @override
  void setKnownScriptIds(Iterable<String> ids) =>
      _stamps.setKnownScriptIds(ids);

  @override
  void setActiveScriptStamp(SyncStamp? stamp) =>
      _stamps.setActiveScriptStamp(stamp);

  @override
  void setSessionStamp(SyncStamp? stamp) => _stamps.setSessionStamp(stamp);

  @override
  void putCoverStamp(String key, SyncStamp stamp) =>
      _stamps.putCoverStamp(key, stamp);

  @override
  void removeCoverStamp(String key) => _stamps.removeCoverStamp(key);

  @override
  void putCoverTombstone(String key, SyncStamp stamp) =>
      _stamps.putCoverTombstone(key, stamp);

  @override
  void removeCoverTombstone(String key) => _stamps.removeCoverTombstone(key);

  /// 记录一轮同步结果：日志条目（变更语义）+ 设备名册。
  ///
  /// 日志 / 活动 / 传输成功时间与名册各归其模块；两边都只改内存 + 标脏，
  /// 落盘由引擎在轮末提交一次。
  @override
  void recordRound(SyncRoundReport report) {
    _activityLog.recordRound(report);
    _roster.recordRound(report);
  }

  /// 持久化的唯一出口：把当前内存状态写入 `sync_state_v2`。
  ///
  /// 没有脏标记时是空操作（连续 UI 命令 / 空轮次不会重复写同一份 JSON）。
  /// 写失败保留脏标记，下一次提交还会重试；内存状态仍可用。
  @override
  Future<void> commit() async {
    if (!_dirty) return;
    _dirty = false;
    try {
      final prefs = _prefs ??= await SharedPreferences.getInstance();
      if (!await prefs.setString(
          stateKey, jsonEncode(SyncStateCodec.encode(_snapshot())))) {
        throw StateError('同步状态写入被平台拒绝（setString 返回 false）');
      }
      _persistedWrites++;
    } catch (e) {
      _dirty = true;
      // 持久化失败只影响下次启动的恢复；本轮内存状态仍可用。首次失败记一条
      // warning：反复静默会让「状态损坏 → 设备身份变化」难以定位。
      if (!_saveFailureLogged) {
        _saveFailureLogged = true;
        _logger.warning('同步状态持久化失败（下次启动可能恢复旧状态）', e);
      }
    }
  }

  /// 当前内存状态的持久化快照（不可变；JSON 形状由 `SyncStateCodec` 维护）。
  SyncPersistedState _snapshot() {
    final roster = _roster.snapshot();
    final activityLog = _activityLog.snapshot();
    final stamps = _stamps.snapshot();
    return SyncPersistedState(
      deviceId: _deviceId,
      deviceName: _deviceName,
      categories: _categories,
      transports: _enabledTransports,
      webdav: _webdav,
      cellularPolicy: _cellularPolicy,
      manualPeers: roster.manualPeers,
      notifiedPeers: roster.notifiedPeers,
      lanHttpPort: _lanHttpPort,
      stampBaseline: stamps.stampBaseline,
      settingStamps: stamps.settingStamps,
      scriptTombstones: stamps.scriptTombstones,
      scriptStamps: stamps.scriptStamps,
      knownScriptIds: stamps.knownScriptIds,
      activeScriptStamp: stamps.activeScriptStamp,
      sessionStamp: stamps.sessionStamp,
      coverStamps: stamps.coverStamps,
      coverTombstones: stamps.coverTombstones,
      lastSyncAt: activityLog.lastSyncAt,
      transportLastSuccess: activityLog.transportLastSuccess,
      snapshotPushSeq: activityLog.snapshotPushSeq,
      log: activityLog.log,
      activity: activityLog.activity,
      peers: roster.peers,
      lanEndpoints: roster.lanEndpoints,
    );
  }

  /// 把解码出的快照写回内存（整体替换：状态 JSON 是完整视图，不是增量）。
  void _applyState(SyncPersistedState state) {
    _deviceId = state.deviceId;
    _deviceName = state.deviceName;
    _categories
      ..clear()
      ..addAll(state.categories);
    _enabledTransports
      ..clear()
      ..addAll(state.transports);
    _webdav = state.webdav;
    _cellularPolicy = state.cellularPolicy;
    _lanHttpPort = state.lanHttpPort;
    _stamps.applyState(
      SyncStampBookState(
        stampBaseline: state.stampBaseline,
        settingStamps: state.settingStamps,
        scriptTombstones: state.scriptTombstones,
        scriptStamps: state.scriptStamps,
        knownScriptIds: state.knownScriptIds,
        activeScriptStamp: state.activeScriptStamp,
        sessionStamp: state.sessionStamp,
        coverStamps: state.coverStamps,
        coverTombstones: state.coverTombstones,
      ),
    );
    _roster.applySnapshot(
      SyncRosterSnapshot(
        manualPeers: state.manualPeers,
        notifiedPeers: state.notifiedPeers,
        peers: state.peers,
        lanEndpoints: state.lanEndpoints,
      ),
    );
    _activityLog.applySnapshot(
      SyncActivityLogSnapshot(
        lastSyncAt: state.lastSyncAt,
        transportLastSuccess: state.transportLastSuccess,
        snapshotPushSeq: state.snapshotPushSeq,
        log: state.log,
        activity: state.activity,
      ),
    );
  }

  String _generateDeviceId() {
    const hex = '0123456789abcdef';
    final buffer = StringBuffer();
    for (var i = 0; i < 32; i++) {
      buffer.write(hex[_random.nextInt(hex.length)]);
    }
    return buffer.toString();
  }

  String _defaultDeviceName() {
    final platform = defaultTargetPlatform.name;
    final short = _deviceId.length >= 4 ? _deviceId.substring(0, 4) : _deviceId;
    return '$platform-$short';
  }
}
