/// 同步运行状态持久化：设备身份 / 传输开关 / 传输配置 / 变更登记 / 日志。
///
/// - 非敏感状态走 SharedPreferences 单 JSON 键（`sync_state_v2`），字段 ↔
///   JSON 的映射在 `sync_state_codec.dart`（本类只管内存状态与写入时机）；
/// - 敏感项（同步口令、WebDAV 密码）走 [SettingsSecretStore]（生产 =
///   flutter_secure_storage），口令即信任根（见 ADR-0003）；
/// - 变更登记（设置键哈希、脚本墓碑、激活脚本指针）是「变化检测」的基线：
///   settings 写入方分散在多个服务，同步层用「上次登记值 vs 当前值」判定
///   本地修改，避免改造全部写入方。
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
import '../../utils/peer_address.dart';
import '../settings/settings_secret_store.dart';
import 'sync_activity.dart';
import 'sync_book.dart';
import 'sync_state_codec.dart';
import 'sync_stamp.dart';

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
    SharedPreferences? preferences,
    SettingsSecretStore? secrets,
    Random? random,
    String? deviceId,
    int Function()? clock,
  })  : _preferences = preferences,
        _secrets = secrets ?? const SecureSettingsSecretStore(),
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
  static const int lanEndpointRetentionMs = 180 * 24 * 60 * 60 * 1000;

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
    for (final category in SyncCategory.values) category: true,
  };

  /// 启用的传输：两路默认关——装机时不启动监听、不广播、不弹局域网权限，
  /// 用户打开任一开关才算启用同步（开关即总闸，见 [enabled]）。
  final Set<String> _enabledTransports = {};
  WebDavConfig _webdav = const WebDavConfig();

  /// 蜂窝网络下的自动同步策略（默认只同步小类别）。
  SyncCellularPolicy _cellularPolicy = SyncCellularPolicy.auto;

  /// 手动添加的对端地址（局域网发现失败时的兜底）。
  final List<ManualPeer> _manualPeers = [];

  /// 已提示过「首次连通」的设备 id（一次性 UI 提示；见 [markPeerConnectNotified]）。
  final Set<String> _notifiedPeers = {};

  /// 本机局域网快照端点端口（0 = 尚未绑定过）。
  int _lanHttpPort = 0;

  final Map<String, SyncStamp> _settingStamps = {};
  final Map<String, SyncStamp> _scriptTombstones = {};
  final Map<String, SyncStamp> _scriptStamps = {};
  final List<String> _knownScriptIds = [];
  SyncStamp? _activeScriptStamp;
  SyncStamp? _sessionStamp;

  /// 版本戳发号器基线（`sync_state_v2` 的 `stampSeq`）：重启后不倒退。
  SyncVersion _stampBaseline = SyncVersion.zero;

  /// 全库最大戳种子是否已补入（首帧后由 `LibraryRepository.maxVersion` 完成）。
  ///
  /// 首帧前不等这次 DB 打开；写入方在取号前先等这个 Future，保证新戳不会
  /// 低于库内已有记录（ADR-0003 的基线约束）。
  final Completer<void> _stampSeedReady = Completer<void>();

  /// 本机所有同步戳的唯一发号器（见 [SyncStampIssuer]）。
  ///
  /// 基线经 `onAdvanced` 写回本状态并在 [commit] 落盘；初始化时用
  /// `max(持久化基线, 当前时钟, 全库最大戳)` 通过 [SyncStampIssuer.seed] 恢复。
  @override
  late final SyncStampIssuer stampIssuer = SyncStampIssuer(
    clock: _clock,
    deviceId: () => _deviceId,
    onAdvanced: (value) {
      _stampBaseline = SyncVersion(
        physical: value.physical,
        counter: value.counter,
      );
      // 发号器基线也是持久状态的一部分：随轮末 / 用户命令一起提交。
      _markDirty();
    },
  );

  int _lastSyncAt = 0;
  final List<SyncLogEntry> _log = [];

  /// 近 24 小时活动记录（新在前；展示日志之外单独保留，供观测面汇总）。
  final List<SyncActivityEntry> _activity = [];

  /// 每传输最近一次成功接触对端的轮次时间（UI「最后成功于」；0 = 尚未成功过）。
  final Map<String, int> _transportLastSuccess = {};

  /// 各传输最近成功发布的全量快照覆盖位置（kind → seq；-1 = 尚未发布）。
  ///
  /// 日志裁剪不会越过**已发布**的快照覆盖：落后 / 新加入的对端要能 bootstrap。
  /// 读写都只经发布台账（`publish_ledger.dart`，判据唯一处）。
  final Map<String, int> _snapshotPushSeq = {};

  /// 刚被用户从本机移除的设备 id：只压住下一次 `recordRound`，防止正在
  /// 收尾的一轮把已删除的行写回。**不是持久化屏蔽**——设备如果仍在线且
  /// 持有同步口令，下一轮探测会重新发现它。
  final Set<String> _forgottenPeers = {};

  /// 设备名册（deviceId → 最近一次接触的观测值）。
  final Map<String, SyncPeerState> _peers = {};

  /// 已验证的局域网端点（deviceId → 最近一次成功连通的地址 / 端口）。
  ///
  /// 广播 / 组播被 AP 隔离或 iOS entitlement 挡住时，靠这里的单播兜底；
  /// 只在 MAC 验证 + HTTP 解密成功后写入（见 `LanSyncTransport`）。
  final Map<String, LanPeerEndpoint> _lanEndpoints = {};

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
  List<ManualPeer> get manualPeers => List.unmodifiable(_manualPeers);

  /// 蜂窝网络下的自动同步策略。
  @override
  SyncCellularPolicy get cellularPolicy => _cellularPolicy;

  /// 本机局域网快照端点端口（0 = 尚未绑定过；绑定后持久化，对端才能记住）。
  int get lanHttpPort => _lanHttpPort;
  @override
  Map<String, SyncStamp> get settingStamps => _settingStamps;

  @override
  Map<String, SyncStamp> get scriptTombstones => _scriptTombstones;

  /// 脚本 id → 内容哈希 + 版本（本地变化检测；脚本文件本身不带版本）。
  @override
  Map<String, SyncStamp> get scriptStamps => _scriptStamps;

  @override
  List<String> get knownScriptIds => List.unmodifiable(_knownScriptIds);

  @override
  SyncStamp? get activeScriptStamp => _activeScriptStamp;

  @override
  SyncStamp? get sessionStamp => _sessionStamp;
  int get lastSyncAt => _lastSyncAt;
  List<SyncLogEntry> get log => List.unmodifiable(_log);

  /// 近 24 小时活动记录（新在前；上限 [activityLimit]）。
  List<SyncActivityEntry> get activity => List.unmodifiable(_activity);

  /// 名册（按最近接触时间倒序；本机不在其中）。
  @override
  List<SyncPeerState> get peers =>
      List.unmodifiable(trimPeers(_peers.values, peerLimit));

  /// 已验证的局域网端点（不可变；上限 [lanEndpointLimit]）。
  @override
  List<LanPeerEndpoint> get lanEndpoints =>
      List.unmodifiable(_lanEndpoints.values);

  /// 传输最近一次成功接触对端的时间（0 = 尚未成功过）。
  int transportLastSuccessAt(String kind) => _transportLastSuccess[kind] ?? 0;

  /// 传输最近成功发布的全量快照覆盖位置（-1 = 尚未发布）。
  ///
  /// 判据（谁在什么条件下读它、失败时是否前移）在发布台账里；这里只是
  /// `sync_state_v2` 的键值与形状。
  @override
  int snapshotPushSeq(String kind) => _snapshotPushSeq[kind] ?? -1;

  /// 只改内存 + 标脏：发布台账在推送循环里逐载荷记账，由轮末提交统一落盘
  /// （旧实现每次 mark 都写一次整份状态 JSON，多传输 / 多载荷时写放大）。
  @override
  void setSnapshotPushSeq(String kind, int seq) {
    if (_snapshotPushSeq[kind] == seq) return;
    _snapshotPushSeq[kind] = seq;
    _markDirty();
  }

  void _markDirty() {
    _dirty = true;
  }

  @override
  int nowMs() => _clock();

  bool isCategoryEnabled(SyncCategory category) =>
      _categories[category] ?? true;

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
    stampIssuer.seed(dbMax);
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
    stampIssuer.seed(_stampBaseline);
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
  Future<bool> addManualPeer(ManualPeer peer) =>
      _upsertManualPeer(peer, overwriteName: true, persist: true);

  /// 移除手动对端（按地址；仅移除地址簿条目，不影响已发现的对端）。
  Future<void> removeManualPeer(String host) async {
    final index = _manualPeers.indexWhere((entry) => entry.host == host);
    if (index < 0) return;
    _manualPeers.removeAt(index);
    _markDirty();
    await commit();
  }

  /// 从本机列表移除一台设备：名册 + 该设备的地址簿条目 + 首次连通提示。
  ///
  /// **只做本机记录清理，不撤销同步授权**：对方如果仍持有同步口令并在线，
  /// 下一轮探测会重新发现它。真正停止与它同步的唯一方式是更换口令（对
  /// 所有设备生效）。因此这里不写任何屏蔽 / 忽略标记。
  Future<void> removePeer(String deviceId) async {
    if (deviceId.isEmpty) return;
    _peers.remove(deviceId);
    _manualPeers.removeWhere((entry) => entry.deviceId == deviceId);
    _notifiedPeers.remove(deviceId);
    _lanEndpoints.remove(deviceId);
    // 正在收尾的一轮可能带着旧名册快照，压住它一次；下一轮重新发现即恢复。
    _forgottenPeers.add(deviceId);
    _markDirty();
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
    _peers.clear();
    _lanEndpoints.clear();
    _notifiedPeers.clear();
    _transportLastSuccess.clear();
    _forgottenPeers.clear();
    _markDirty();
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
    final index = _manualPeers.indexWhere((entry) => entry.host == fromHost);
    if (index < 0 || toHost.isEmpty || toHost == fromHost) return;
    final moved = _manualPeers.removeAt(index).copyWith(
          host: toHost,
          probePort: probePort,
          name: name,
        );
    final existing = _manualPeers.indexWhere((entry) => entry.host == toHost);
    if (existing >= 0) {
      _manualPeers[existing] = _manualPeers[existing].mergeLearned(
        httpPort: moved.httpPort > 0 ? moved.httpPort : null,
        deviceId: moved.deviceId.isNotEmpty ? moved.deviceId : null,
        name: moved.name.isNotEmpty ? moved.name : null,
      );
    } else {
      // 刚配置的地址排前面：地址簿顺序即探测与展示的优先序。
      _manualPeers.insert(0, moved);
    }
    _markDirty();
    await commit();
  }

  /// 回写首次接触学到的信息（deviceId / 端口 / 名称）。
  ///
  /// 学到的对端名只在条目尚未命名时填入：手动条目优先保留用户命名。
  /// 这是轮内接触的副产物：只改内存 + 标脏，随轮末提交落盘。
  Future<void> learnManualPeer(ManualPeer learned) async {
    await _upsertManualPeer(
      learned,
      overwriteName: false,
      promote: true,
      persist: false,
    );
  }

  /// 该设备是否已提示过「首次连通」（一次性提示，见 [markPeerConnectNotified]）。
  @override
  bool isPeerConnectNotified(String deviceId) =>
      _notifiedPeers.contains(deviceId);

  /// 登记「首次连通」已提示：设备第一次真正交换过数据时只提示一次，
  /// 持久化后重启不重复。
  ///
  /// 只改内存 + 标脏：调用点在引擎轮末（与 `recordRound` 同一次提交），
  /// 不在通知路径上单独写整份状态 JSON。
  @override
  void markPeerConnectNotified(String deviceId) {
    if (deviceId.isEmpty || !_notifiedPeers.add(deviceId)) return;
    _markDirty();
  }

  /// 地址簿写入的唯一入口：按 host 查找合并（重复地址不新增条目）。
  ///
  /// [overwriteName] 是命名策略开关：用户提交同一地址是显式改名，学习路径
  /// 不覆盖已有命名（对端广播的设备名只填空名）。[promote] 把刚更新过的条目
  /// 提到最前（地址簿顺序即探测与展示的优先序；仅学习路径需要）。
  /// 返回 false = 地址已存在。[persist] 区分用户提交（立即落盘）与轮内学习
  /// （随轮末提交），两者共用同一份合并规则。
  Future<bool> _upsertManualPeer(
    ManualPeer peer, {
    required bool overwriteName,
    bool promote = false,
    required bool persist,
  }) async {
    final host = peer.host.trim();
    if (host.isEmpty) return false;
    final index = _manualPeers.indexWhere((entry) => entry.host == host);
    if (index >= 0) {
      final name = peer.name.trim();
      var merged = _manualPeers[index].mergeLearned(
        httpPort: peer.httpPort > 0 ? peer.httpPort : null,
        deviceId: peer.deviceId.isNotEmpty ? peer.deviceId : null,
        // 学习路径才把对端名填进空名；用户提交走下面的显式改名。
        name: !overwriteName && peer.name.isNotEmpty ? peer.name : null,
      );
      if (overwriteName && name.isNotEmpty) {
        merged = merged.copyWith(name: name);
      }
      if (promote) {
        _manualPeers.removeAt(index);
        _manualPeers.insert(0, merged);
      } else {
        _manualPeers[index] = merged;
      }
      _markDirty();
      if (persist) await commit();
      return false;
    }
    _manualPeers.add(peer.copyWith(host: host));
    _markDirty();
    if (persist) await commit();
    return true;
  }

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
    if (!SyncStateCodec.isValidLanEndpoint(endpoint)) return;
    final existing = _lanEndpoints[endpoint.deviceId];
    final next = LanPeerEndpoint(
      deviceId: endpoint.deviceId,
      host: normalizePeerHost(endpoint.host),
      httpPort: endpoint.httpPort,
      // 新观测没带探测端口时保留已有值：来源端口可能因 NAT / 重启变化，
      // 旧的持久化端口仍是有效的单播目标。
      probePort: endpoint.probePort > 0
          ? endpoint.probePort
          : (existing?.probePort ?? 0),
      verifiedAt: endpoint.verifiedAt,
    );
    final identityChanged = existing == null ||
        existing.host != next.host ||
        existing.httpPort != next.httpPort ||
        existing.probePort != next.probePort;
    if (!identityChanged && existing.verifiedAt == next.verifiedAt) return;
    _lanEndpoints[next.deviceId] = next;
    _trimLanEndpoints();
    // 端点身份变化会改变名册淘汰 / 单播目标，仅验证时间前进也要跨重启保留：
    // 都只标脏，等轮末提交（每轮每对端都会回写，绝不能在这里落盘）。
    _markDirty();
  }

  /// 超过 [lanEndpointLimit] 时按 `verifiedAt` 淘汰最旧的端点。
  void _trimLanEndpoints() {
    while (_lanEndpoints.length > lanEndpointLimit) {
      String? oldestId;
      var oldestAt = 1 << 62;
      for (final entry in _lanEndpoints.entries) {
        if (entry.value.verifiedAt < oldestAt) {
          oldestAt = entry.value.verifiedAt;
          oldestId = entry.key;
        }
      }
      if (oldestId == null) return;
      _lanEndpoints.remove(oldestId);
    }
  }

  @override
  void putSettingStamp(String key, SyncStamp stamp) {
    _settingStamps[key] = stamp;
    _markDirty();
  }

  @override
  void putScriptTombstone(String id, SyncStamp stamp) {
    _scriptTombstones[id] = stamp;
    _markDirty();
  }

  @override
  void putScriptStamp(String id, SyncStamp stamp) {
    _scriptStamps[id] = stamp;
    _markDirty();
  }

  @override
  void removeScriptStamp(String id) {
    if (_scriptStamps.remove(id) != null) _markDirty();
  }

  @override
  void removeScriptTombstone(String id) {
    if (_scriptTombstones.remove(id) != null) _markDirty();
  }

  @override
  void setKnownScriptIds(Iterable<String> ids) {
    _knownScriptIds
      ..clear()
      ..addAll(ids);
    _markDirty();
  }

  @override
  void setActiveScriptStamp(SyncStamp? stamp) {
    _activeScriptStamp = stamp;
    _markDirty();
  }

  @override
  void setSessionStamp(SyncStamp? stamp) {
    _sessionStamp = stamp;
    _markDirty();
  }

  /// 记录一轮同步结果：日志条目（变更语义）+ 设备名册。
  ///
  /// 名册由引擎合并后传入（每条都是完整状态），这里只负责内存更新与按最近
  /// 接触时间淘汰，避免长期运行后无界增长；落盘由引擎在轮末提交一次。
  @override
  void recordRound(SyncRoundReport report) {
    _markDirty();
    _lastSyncAt = report.finishedAt;
    _log.insert(
      0,
      SyncLogEntry(
        at: report.finishedAt,
        trigger: report.trigger,
        outcome: report.outcome,
        durationMs: report.durationMs,
        applied: report.applied,
        peersSeen: report.peersSeen,
        failed: report.failedCount,
        bytesIn: report.bytesIn,
        bytesOut: report.bytesOut,
        // 本轮启用的传输（未启用的传输不参与本轮）。
        transports: report.transports
            .where((t) => t.enabled)
            .map((t) => t.kind)
            .toList(),
        error: report.error,
      ),
    );
    while (_log.length > logLimit) {
      _log.removeLast();
    }
    // 活动记录：观测面的「近 24 小时」不受展示保留量截断。
    _activity.insert(
      0,
      SyncActivityEntry(
        at: report.finishedAt,
        bytesIn: report.bytesIn,
        bytesOut: report.bytesOut,
        applied: report.applied,
      ),
    );
    while (_activity.length > activityLimit) {
      _activity.removeLast();
    }
    for (final transport in report.transports) {
      if (transport.enabled && transport.succeeded) {
        _transportLastSuccess[transport.kind] = report.finishedAt;
      }
    }
    // 用户刚移除的设备：压住本轮的在途快照，避免删除动作被收尾中的一轮
    // 立刻写回。只影响这一次落库；下一轮重新发现（设备仍在线）会照常写入。
    final forgotten = Set<String>.of(_forgottenPeers);
    _forgottenPeers.clear();
    for (final peer in report.peers) {
      if (forgotten.contains(peer.deviceId)) continue;
      _peers[peer.deviceId] = peer;
    }
    final recent = trimPeers(_peers.values, peerLimit);
    _peers
      ..clear()
      ..addEntries(recent.map((peer) => MapEntry(peer.deviceId, peer)));
    // 180 天没再验证过的端点随名册一起淘汰：换网 / DHCP 变更后旧地址多半
    // 已失效，留着只会让每轮多试几个连不通的地址。
    final now = report.finishedAt;
    _lanEndpoints.removeWhere(
      (_, endpoint) =>
          endpoint.verifiedAt > 0 &&
          now - endpoint.verifiedAt > lanEndpointRetentionMs,
    );
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
  SyncPersistedState _snapshot() => SyncPersistedState(
        deviceId: _deviceId,
        deviceName: _deviceName,
        categories: _categories,
        transports: _enabledTransports,
        webdav: _webdav,
        cellularPolicy: _cellularPolicy,
        manualPeers: _manualPeers,
        notifiedPeers: _notifiedPeers,
        lanHttpPort: _lanHttpPort,
        stampBaseline: _stampBaseline,
        settingStamps: _settingStamps,
        scriptTombstones: _scriptTombstones,
        scriptStamps: _scriptStamps,
        knownScriptIds: _knownScriptIds,
        activeScriptStamp: _activeScriptStamp,
        sessionStamp: _sessionStamp,
        lastSyncAt: _lastSyncAt,
        transportLastSuccess: _transportLastSuccess,
        snapshotPushSeq: _snapshotPushSeq,
        log: _log,
        activity: _activity,
        peers: _peers.values.toList(),
        lanEndpoints: _lanEndpoints.values.toList(),
      );

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
    _manualPeers
      ..clear()
      ..addAll(state.manualPeers);
    _notifiedPeers
      ..clear()
      ..addAll(state.notifiedPeers);
    _lanHttpPort = state.lanHttpPort;
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
    _activeScriptStamp = state.activeScriptStamp;
    _sessionStamp = state.sessionStamp;
    _lastSyncAt = state.lastSyncAt;
    _transportLastSuccess
      ..clear()
      ..addAll(state.transportLastSuccess);
    _snapshotPushSeq
      ..clear()
      ..addAll(state.snapshotPushSeq);
    _log
      ..clear()
      ..addAll(state.log);
    _activity
      ..clear()
      ..addAll(state.activity);
    _peers
      ..clear()
      ..addEntries(state.peers.map((peer) => MapEntry(peer.deviceId, peer)));
    _lanEndpoints
      ..clear()
      ..addEntries(state.lanEndpoints
          .map((endpoint) => MapEntry(endpoint.deviceId, endpoint)));
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
