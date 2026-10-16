/// 同步运行状态持久化：设备身份 / 开关 / 传输配置 / 变更登记 / 日志。
///
/// - 非敏感状态走 SharedPreferences 单 JSON 键（`sync_state_v1`）；
/// - 敏感项（同步口令、WebDAV 密码）走 [SettingsSecretStore]（生产 =
///   flutter_secure_storage），口令即信任根（见 ADR-0003）；
/// - 变更登记（设置键哈希、脚本墓碑、激活脚本指针）是「变化检测」的基线：
///   settings 写入方分散在多个服务，同步层用「上次登记值 vs 当前值」判定
///   本地修改，避免改造全部写入方。
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/models/device_sync.dart';
import '../../domain/ports/sync_transport.dart';
import '../settings/settings_secret_store.dart';
import 'sync_activity.dart';
import 'sync_stamp.dart';

/// WebDAV 传输配置（密码单独走安全存储，不在此结构内）。
class WebDavConfig {
  final String baseUrl;
  final String username;

  /// 远端目录名（相对 baseUrl，默认 `molia-sync`）。
  final String remoteDir;

  const WebDavConfig({
    this.baseUrl = '',
    this.username = '',
    this.remoteDir = 'molia-sync',
  });

  bool get isConfigured => baseUrl.trim().isNotEmpty;

  WebDavConfig copyWith({String? baseUrl, String? username, String? remoteDir}) =>
      WebDavConfig(
        baseUrl: baseUrl ?? this.baseUrl,
        username: username ?? this.username,
        remoteDir: remoteDir ?? this.remoteDir,
      );

  Map<String, dynamic> toJson() => {
        'baseUrl': baseUrl,
        'username': username,
        'remoteDir': remoteDir,
      };

  static WebDavConfig fromJson(Object? raw) {
    if (raw is! Map) return const WebDavConfig();
    return WebDavConfig(
      baseUrl: raw['baseUrl'] is String ? raw['baseUrl'] as String : '',
      username: raw['username'] is String ? raw['username'] as String : '',
      remoteDir: raw['remoteDir'] is String && (raw['remoteDir'] as String).trim().isNotEmpty
          ? (raw['remoteDir'] as String).trim()
          : 'molia-sync',
    );
  }
}

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

/// 同步日志条目（设置页展示与诊断导出用；不含口令/密钥内容）。
///
/// 语义是**本轮变更量**：`applied` 是本轮真正落地的记录数，与库大小无关。
class SyncLogEntry {
  const SyncLogEntry({
    required this.at,
    required this.trigger,
    required this.outcome,
    this.durationMs = 0,
    this.applied = 0,
    this.peersSeen = 0,
    this.failed = 0,
    this.bytesIn = 0,
    this.bytesOut = 0,
    this.transports = const [],
    this.error,
  });

  final int at;

  /// 触发原因（用户能看出「为什么现在同步」）。
  final SyncTrigger trigger;

  final SyncOutcome outcome;
  final int durationMs;

  /// 本轮落地的记录数（变更量）。
  final int applied;

  /// 本轮接触到的对端数（0 = 未发现对端）。
  final int peersSeen;

  /// 失败计数（拉取 + 推送）。
  final int failed;

  final int bytesIn;
  final int bytesOut;

  /// 本轮启用的传输标识。
  final List<String> transports;

  /// 失败原因（类型化；技术细节在 [SyncIssue.detail]，UI 不展示原文）。
  final SyncIssue? error;

  Map<String, dynamic> toJson() => {
        'at': at,
        'trigger': trigger.name,
        'outcome': outcome.name,
        if (durationMs > 0) 'durationMs': durationMs,
        if (applied > 0) 'applied': applied,
        if (peersSeen > 0) 'peersSeen': peersSeen,
        if (failed > 0) 'failed': failed,
        if (bytesIn > 0) 'bytesIn': bytesIn,
        if (bytesOut > 0) 'bytesOut': bytesOut,
        if (transports.isNotEmpty) 'transports': transports,
        if (error != null) 'error': error!.toJson(),
      };

  static SyncLogEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final at = raw['at'];
    if (at is! num) return null;
    return SyncLogEntry(
      at: at.toInt(),
      trigger: SyncTrigger.parse(raw['trigger'] as String?),
      outcome: SyncOutcome.parse(raw['outcome'] as String?),
      durationMs: (raw['durationMs'] as num?)?.toInt() ?? 0,
      applied: (raw['applied'] as num?)?.toInt() ?? 0,
      peersSeen: (raw['peersSeen'] as num?)?.toInt() ?? 0,
      failed: (raw['failed'] as num?)?.toInt() ?? 0,
      bytesIn: (raw['bytesIn'] as num?)?.toInt() ?? 0,
      bytesOut: (raw['bytesOut'] as num?)?.toInt() ?? 0,
      transports:
          (raw['transports'] as List?)?.whereType<String>().toList() ?? const [],
      error: SyncIssue.fromJson(raw['error']),
    );
  }
}

/// 同步运行状态（内存视图 + SharedPreferences 持久化）。
class SyncStateStore {
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

  static const String stateKey = 'sync_state_v1';
  static const String passphraseSecretKey = 'sync_passphrase_v1';
  static const String webdavPasswordSecretKey = 'sync_webdav_password_v1';

  /// 日志保留条数（设置页只展示最近几条）。
  static const int logLimit = 20;

  /// 活动记录保留条数（近 24 小时汇总用；展示日志的 20 条不足以支撑窗口）。
  static const int activityLimit = 240;

  /// 名册保留设备数（按最近接触时间淘汰；避免长期运行后无界增长）。
  static const int peerLimit = 20;

  final SharedPreferences? _preferences;
  final SettingsSecretStore _secrets;
  final Random _random;
  final int Function() _clock;

  SharedPreferences? _prefs;
  String _deviceId;
  String _deviceName = '';
  bool _enabled = false;
  final Map<SyncCategory, bool> _categories = {
    for (final category in SyncCategory.values) category: true,
  };
  final Set<String> _enabledTransports = {SyncTransportKind.lan};
  WebDavConfig _webdav = const WebDavConfig();

  /// 蜂窝网络下的自动同步策略（默认只同步小类别）。
  SyncCellularPolicy _cellularPolicy = SyncCellularPolicy.auto;

  /// 手动添加的对端地址（局域网发现失败时的兜底）。
  final List<ManualPeer> _manualPeers = [];

  /// 本机局域网快照端点端口（0 = 尚未绑定过）。
  int _lanHttpPort = 0;

  final Map<String, SyncStamp> _settingStamps = {};
  final Map<String, SyncStamp> _scriptTombstones = {};
  final Map<String, SyncStamp> _scriptStamps = {};
  final List<String> _knownScriptIds = [];
  SyncStamp? _activeScriptStamp;
  SyncStamp? _sessionStamp;

  /// 版本戳发号器基线（`sync_state_v1` 的 `stampSeq`）：重启后不倒退。
  SyncVersion _stampBaseline = SyncVersion.zero;

  /// 本机所有同步戳的唯一发号器（见 [SyncStampIssuer]）。
  ///
  /// 基线经 `onAdvanced` 写回本状态并在 [save] 落盘；初始化时用
  /// `max(持久化基线, 当前时钟, 全库最大戳)` 通过 [SyncStampIssuer.seed] 恢复。
  late final SyncStampIssuer stampIssuer = SyncStampIssuer(
    clock: _clock,
    deviceId: () => _deviceId,
    onAdvanced: (value) => _stampBaseline = SyncVersion(
      physical: value.physical,
      counter: value.counter,
    ),
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
  final Map<String, int> _snapshotPushSeq = {};

  /// 设备名册（deviceId → 最近一次接触的观测值）。
  final Map<String, SyncPeerState> _peers = {};

  String get deviceId => _deviceId;
  String get deviceName => _deviceName;
  bool get enabled => _enabled;
  Map<SyncCategory, bool> get categories => Map.unmodifiable(_categories);
  Set<String> get enabledTransports => Set.unmodifiable(_enabledTransports);
  WebDavConfig get webdav => _webdav;

  /// 手动对端地址簿（去重后不可变）。
  List<ManualPeer> get manualPeers => List.unmodifiable(_manualPeers);

  /// 蜂窝网络下的自动同步策略。
  SyncCellularPolicy get cellularPolicy => _cellularPolicy;

  /// 本机局域网快照端点端口（0 = 尚未绑定过；绑定后持久化，对端才能记住）。
  int get lanHttpPort => _lanHttpPort;
  Map<String, SyncStamp> get settingStamps => _settingStamps;
  Map<String, SyncStamp> get scriptTombstones => _scriptTombstones;

  /// 脚本 id → 内容哈希 + 版本（本地变化检测；脚本文件本身不带版本）。
  Map<String, SyncStamp> get scriptStamps => _scriptStamps;
  List<String> get knownScriptIds => List.unmodifiable(_knownScriptIds);
  SyncStamp? get activeScriptStamp => _activeScriptStamp;
  SyncStamp? get sessionStamp => _sessionStamp;
  int get lastSyncAt => _lastSyncAt;
  List<SyncLogEntry> get log => List.unmodifiable(_log);

  /// 近 24 小时活动记录（新在前；上限 [activityLimit]）。
  List<SyncActivityEntry> get activity => List.unmodifiable(_activity);

  /// 名册（按最近接触时间倒序；本机不在其中）。
  List<SyncPeerState> get peers =>
      List.unmodifiable(trimPeers(_peers.values, peerLimit));

  /// 传输最近一次成功接触对端的时间（0 = 尚未成功过）。
  int transportLastSuccessAt(String kind) => _transportLastSuccess[kind] ?? 0;

  /// 传输最近成功发布的全量快照覆盖位置（-1 = 尚未发布）。
  int snapshotPushSeq(String kind) => _snapshotPushSeq[kind] ?? -1;

  Future<void> setSnapshotPushSeq(String kind, int seq) async {
    if (_snapshotPushSeq[kind] == seq) return;
    _snapshotPushSeq[kind] = seq;
    await save();
  }

  int nowMs() => _clock();

  bool isCategoryEnabled(SyncCategory category) => _categories[category] ?? true;

  Set<SyncCategory> get enabledCategories => {
        for (final entry in _categories.entries)
          if (entry.value) entry.key,
      };

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _prefs = _preferences ?? await SharedPreferences.getInstance();
    final raw = _prefs!.getString(stateKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final json = jsonDecode(raw);
        if (json is Map) _applyJson(json.cast<String, dynamic>());
      } catch (_) {
        // 损坏状态按默认处理；deviceId 重新生成（旧口令仍可用，仅设备身份变化）。
      }
    }
    if (_deviceId.isEmpty) {
      _deviceId = _generateDeviceId();
      await save();
    }
    if (_deviceName.isEmpty) {
      _deviceName = _defaultDeviceName();
      await save();
    }
    // 发号器基线 = max(持久化基线, 当前时钟)：重启（含时钟回拨）不倒退。
    // 「全库最大戳」由组合根在仓库就绪后经 seed() 补入（见 LibraryRepository
    // .maxVersion）。
    stampIssuer.seed(_stampBaseline);
    _initialized = true;
  }

  Future<String?> readPassphrase() =>
      _secrets.read(passphraseSecretKey);

  Future<void> writePassphrase(String passphrase) =>
      _secrets.write(passphraseSecretKey, passphrase);

  Future<String?> readWebdavPassword() =>
      _secrets.read(webdavPasswordSecretKey);

  Future<void> writeWebdavPassword(String password) =>
      _secrets.write(webdavPasswordSecretKey, password);

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    await save();
  }

  Future<void> setCategory(SyncCategory category, bool value) async {
    _categories[category] = value;
    await save();
  }

  Future<void> setTransportEnabled(String kind, bool value) async {
    if (value) {
      _enabledTransports.add(kind);
    } else {
      _enabledTransports.remove(kind);
    }
    await save();
  }

  Future<void> setDeviceName(String value) async {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return;
    _deviceName = trimmed;
    await save();
  }

  Future<void> setWebdavConfig(WebDavConfig config) async {
    _webdav = config;
    await save();
  }

  Future<void> setCellularPolicy(SyncCellularPolicy value) async {
    if (_cellularPolicy == value) return;
    _cellularPolicy = value;
    await save();
  }

  /// 添加手动对端（同一 host 覆盖：地址簿以地址为身份，学到的信息合并保留）。
  ///
  /// 返回 false 表示该地址已存在（本次按用户输入更新名称与端口）。
  Future<bool> addManualPeer(ManualPeer peer) =>
      _upsertManualPeer(peer, overwriteName: true);

  /// 移除手动对端（按地址；仅移除地址簿条目，不影响已发现的对端）。
  Future<void> removeManualPeer(String host) async {
    _manualPeers.removeWhere((entry) => entry.host == host);
    await save();
  }

  /// 回写首次接触学到的信息（deviceId / 端口 / 名称）。
  ///
  /// 学到的对端名只在条目尚未命名时填入：手动条目优先保留用户命名。
  Future<void> learnManualPeer(ManualPeer learned) async {
    await _upsertManualPeer(learned, overwriteName: false);
  }

  /// 地址簿写入的唯一入口：按 host 查找合并（重复地址不新增条目）。
  ///
  /// [overwriteName] 是命名策略开关：用户提交同一地址是显式改名，学习路径
  /// 不覆盖已有命名（对端广播的设备名只填空名）。返回 false = 地址已存在。
  Future<bool> _upsertManualPeer(
    ManualPeer peer, {
    required bool overwriteName,
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
      _manualPeers[index] = merged;
      await save();
      return false;
    }
    _manualPeers.add(peer.copyWith(host: host));
    await save();
    return true;
  }

  Future<void> setLanHttpPort(int port) async {
    if (port <= 0 || port == _lanHttpPort) return;
    _lanHttpPort = port;
    await save();
  }

  void putSettingStamp(String key, SyncStamp stamp) {
    _settingStamps[key] = stamp;
  }

  void putScriptTombstone(String id, SyncStamp stamp) {
    _scriptTombstones[id] = stamp;
  }

  void putScriptStamp(String id, SyncStamp stamp) {
    _scriptStamps[id] = stamp;
  }

  void removeScriptStamp(String id) {
    _scriptStamps.remove(id);
  }

  void removeScriptTombstone(String id) {
    _scriptTombstones.remove(id);
  }

  void setKnownScriptIds(Iterable<String> ids) {
    _knownScriptIds
      ..clear()
      ..addAll(ids);
  }

  void setActiveScriptStamp(SyncStamp? stamp) {
    _activeScriptStamp = stamp;
  }

  void setSessionStamp(SyncStamp? stamp) {
    _sessionStamp = stamp;
  }

  /// 记录一轮同步结果：日志条目（变更语义）+ 设备名册。
  ///
  /// 名册由引擎合并后传入（每条都是完整状态），这里只负责落库与按最近接触
  /// 时间淘汰，避免长期运行后无界增长。
  void recordRound(SyncRoundReport report) {
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
    for (final peer in report.peers) {
      _peers[peer.deviceId] = peer;
    }
    final recent = trimPeers(_peers.values, peerLimit);
    _peers
      ..clear()
      ..addEntries(recent.map((peer) => MapEntry(peer.deviceId, peer)));
  }

  Future<void> save() async {
    try {
      final prefs = _prefs ??= await SharedPreferences.getInstance();
      await prefs.setString(stateKey, jsonEncode(_toJson()));
    } catch (_) {
      // 持久化失败只影响下次启动的恢复；本轮内存状态仍可用。
    }
  }

  Map<String, dynamic> _toJson() => {
        'v': 2,
        'deviceId': _deviceId,
        'deviceName': _deviceName,
        'enabled': _enabled,
        'categories': {
          for (final entry in _categories.entries) entry.key.name: entry.value,
        },
        'transports': _enabledTransports.toList(),
        'webdav': _webdav.toJson(),
        'cellularPolicy': _cellularPolicy.name,
        if (_manualPeers.isNotEmpty)
          'manualPeers': [for (final peer in _manualPeers) peer.toJson()],
        if (_lanHttpPort > 0) 'lanHttpPort': _lanHttpPort,
        'stampSeq': _stampBaseline.toJson(),
        'settings': {
          for (final entry in _settingStamps.entries)
            entry.key: entry.value.toJson(),
        },
        'scriptTombstones': {
          for (final entry in _scriptTombstones.entries)
            entry.key: entry.value.toJson(),
        },
        'scriptStamps': {
          for (final entry in _scriptStamps.entries)
            entry.key: entry.value.toJson(),
        },
        'knownScripts': _knownScriptIds,
        if (_activeScriptStamp != null)
          'activeScript': _activeScriptStamp!.toJson(),
        if (_sessionStamp != null) 'sessionStamp': _sessionStamp!.toJson(),
        'lastSyncAt': _lastSyncAt,
        if (_transportLastSuccess.isNotEmpty)
          'transportLastSuccess': _transportLastSuccess,
        if (_snapshotPushSeq.isNotEmpty) 'snapshotPush': _snapshotPushSeq,
        'log': [for (final entry in _log) entry.toJson()],
        'activity': [for (final entry in _activity) entry.toJson()],
        'peers': [for (final peer in _peers.values) peer.toJson()],
      };

  void _applyJson(Map<String, dynamic> json) {
    _deviceId = json['deviceId'] is String ? json['deviceId'] as String : '';
    _deviceName = json['deviceName'] is String ? json['deviceName'] as String : '';
    _enabled = json['enabled'] == true;

    final categories = json['categories'];
    if (categories is Map) {
      for (final category in SyncCategory.values) {
        final value = categories[category.name];
        if (value is bool) _categories[category] = value;
      }
    }
    final transports = json['transports'];
    if (transports is List) {
      _enabledTransports
        ..clear()
        ..addAll(transports.whereType<String>());
    }
    _webdav = WebDavConfig.fromJson(json['webdav']);
    _cellularPolicy = SyncCellularPolicy.parse(json['cellularPolicy'] as String?);

    _manualPeers.clear();
    final manualPeers = json['manualPeers'];
    if (manualPeers is List) {
      for (final item in manualPeers) {
        final peer = ManualPeer.fromJson(item);
        if (peer != null) _manualPeers.add(peer);
      }
    }
    _lanHttpPort = (json['lanHttpPort'] as num?)?.toInt() ?? 0;

    final stampSeq = json['stampSeq'];
    if (stampSeq is Map) {
      final baseline = SyncVersion.fromJson(stampSeq) ??
          // 兼容早期 `{'p','c'}` 形状（当前写 SyncVersion.toJson）。
          (stampSeq['p'] is num
              ? SyncVersion(
                  physical: (stampSeq['p'] as num).toInt(),
                  counter: (stampSeq['c'] as num?)?.toInt() ?? 0,
                )
              : null);
      if (baseline != null) _stampBaseline = baseline;
    }

    _settingStamps.clear();
    final settings = json['settings'];
    if (settings is Map) {
      for (final entry in settings.entries) {
        final stamp = SyncStamp.fromJson(entry.value);
        if (stamp != null) _settingStamps[entry.key.toString()] = stamp;
      }
    }
    _scriptTombstones.clear();
    final tombstones = json['scriptTombstones'];
    if (tombstones is Map) {
      for (final entry in tombstones.entries) {
        final stamp = SyncStamp.fromJson(entry.value);
        if (stamp != null) _scriptTombstones[entry.key.toString()] = stamp;
      }
    }
    _scriptStamps.clear();
    final scriptStamps = json['scriptStamps'];
    if (scriptStamps is Map) {
      for (final entry in scriptStamps.entries) {
        final stamp = SyncStamp.fromJson(entry.value);
        if (stamp != null) _scriptStamps[entry.key.toString()] = stamp;
      }
    }
    _knownScriptIds
      ..clear()
      ..addAll((json['knownScripts'] as List?)?.whereType<String>() ?? const []);
    _activeScriptStamp = SyncStamp.fromJson(json['activeScript']);
    _sessionStamp = SyncStamp.fromJson(json['sessionStamp']);

    _lastSyncAt = json['lastSyncAt'] is num
        ? (json['lastSyncAt'] as num).toInt()
        : 0;
    _transportLastSuccess.clear();
    final transportLastSuccess = json['transportLastSuccess'];
    if (transportLastSuccess is Map) {
      for (final entry in transportLastSuccess.entries) {
        final at = entry.value;
        if (at is num) _transportLastSuccess[entry.key.toString()] = at.toInt();
      }
    }
    _snapshotPushSeq.clear();
    final snapshotPush = json['snapshotPush'];
    if (snapshotPush is Map) {
      for (final entry in snapshotPush.entries) {
        final seq = entry.value;
        if (seq is num) _snapshotPushSeq[entry.key.toString()] = seq.toInt();
      }
    }
    _log.clear();
    final log = json['log'];
    if (log is List) {
      for (final item in log) {
        final entry = SyncLogEntry.fromJson(item);
        if (entry != null && _log.length < logLimit) _log.add(entry);
      }
    }
    _activity.clear();
    final activity = json['activity'];
    if (activity is List) {
      for (final item in activity) {
        final entry = SyncActivityEntry.fromJson(item);
        if (entry != null && _activity.length < activityLimit) {
          _activity.add(entry);
        }
      }
    }
    _peers.clear();
    final peers = json['peers'];
    if (peers is List) {
      for (final item in peers) {
        final peer = SyncPeerState.fromJson(item);
        if (peer != null && _peers.length < peerLimit) _peers[peer.deviceId] = peer;
      }
    }
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
    final platform = kIsWeb ? 'Web' : defaultTargetPlatform.name;
    final short = _deviceId.length >= 4 ? _deviceId.substring(0, 4) : _deviceId;
    return '$platform-$short';
  }
}
