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
import '../settings/settings_secret_store.dart';

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

/// 记录级时间戳登记项（设置键哈希 / 脚本墓碑 / 激活脚本指针共用）。
class SyncStamp {
  /// 值哈希（设置键用；脚本指针不需要，为空串）。
  final String hash;
  final int updatedAt;
  final String updatedBy;

  const SyncStamp({
    this.hash = '',
    required this.updatedAt,
    this.updatedBy = '',
  });

  Map<String, dynamic> toJson() => {
        if (hash.isNotEmpty) 'h': hash,
        't': updatedAt,
        if (updatedBy.isNotEmpty) 'd': updatedBy,
      };

  static SyncStamp? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final t = raw['t'];
    if (t is! num) return null;
    return SyncStamp(
      hash: raw['h'] is String ? raw['h'] as String : '',
      updatedAt: t.toInt(),
      updatedBy: raw['d'] is String ? raw['d'] as String : '',
    );
  }
}

/// 同步日志条目（设置页展示最近若干条；不含口令/密钥内容）。
class SyncLogEntry {
  final int at;
  final bool ok;
  final bool manual;
  final int pulled;
  final int applied;
  final int skipped;
  final String? error;

  const SyncLogEntry({
    required this.at,
    required this.ok,
    this.manual = false,
    this.pulled = 0,
    this.applied = 0,
    this.skipped = 0,
    this.error,
  });

  Map<String, dynamic> toJson() => {
        'at': at,
        'ok': ok,
        if (manual) 'manual': true,
        'pulled': pulled,
        'applied': applied,
        'skipped': skipped,
        if (error != null && error!.isNotEmpty) 'error': error,
      };

  static SyncLogEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final at = raw['at'];
    if (at is! num) return null;
    return SyncLogEntry(
      at: at.toInt(),
      ok: raw['ok'] != false,
      manual: raw['manual'] == true,
      pulled: raw['pulled'] is num ? (raw['pulled'] as num).toInt() : 0,
      applied: raw['applied'] is num ? (raw['applied'] as num).toInt() : 0,
      skipped: raw['skipped'] is num ? (raw['skipped'] as num).toInt() : 0,
      error: raw['error'] is String ? raw['error'] as String : null,
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
  final Set<String> _enabledTransports = {'lan'};
  WebDavConfig _webdav = const WebDavConfig();

  final Map<String, SyncStamp> _settingStamps = {};
  final Map<String, SyncStamp> _scriptTombstones = {};
  final List<String> _knownScriptIds = [];
  SyncStamp? _activeScriptStamp;
  SyncStamp? _sessionStamp;

  int _lastSyncAt = 0;
  bool _lastSyncOk = true;
  String? _lastSyncError;
  final List<SyncLogEntry> _log = [];

  String get deviceId => _deviceId;
  String get deviceName => _deviceName;
  bool get enabled => _enabled;
  Map<SyncCategory, bool> get categories => Map.unmodifiable(_categories);
  Set<String> get enabledTransports => Set.unmodifiable(_enabledTransports);
  WebDavConfig get webdav => _webdav;
  Map<String, SyncStamp> get settingStamps => _settingStamps;
  Map<String, SyncStamp> get scriptTombstones => _scriptTombstones;
  List<String> get knownScriptIds => List.unmodifiable(_knownScriptIds);
  SyncStamp? get activeScriptStamp => _activeScriptStamp;
  SyncStamp? get sessionStamp => _sessionStamp;
  int get lastSyncAt => _lastSyncAt;
  bool get lastSyncOk => _lastSyncOk;
  String? get lastSyncError => _lastSyncError;
  List<SyncLogEntry> get log => List.unmodifiable(_log);

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

  void putSettingStamp(String key, SyncStamp stamp) {
    _settingStamps[key] = stamp;
  }

  void putScriptTombstone(String id, SyncStamp stamp) {
    _scriptTombstones[id] = stamp;
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

  void recordSyncResult({
    required bool ok,
    required bool manual,
    required int pulled,
    required int applied,
    required int skipped,
    String? error,
  }) {
    _lastSyncAt = nowMs();
    _lastSyncOk = ok;
    _lastSyncError = error;
    _log.insert(
      0,
      SyncLogEntry(
        at: _lastSyncAt,
        ok: ok,
        manual: manual,
        pulled: pulled,
        applied: applied,
        skipped: skipped,
        error: error,
      ),
    );
    while (_log.length > logLimit) {
      _log.removeLast();
    }
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
        'v': 1,
        'deviceId': _deviceId,
        'deviceName': _deviceName,
        'enabled': _enabled,
        'categories': {
          for (final entry in _categories.entries) entry.key.name: entry.value,
        },
        'transports': _enabledTransports.toList(),
        'webdav': _webdav.toJson(),
        'settings': {
          for (final entry in _settingStamps.entries)
            entry.key: entry.value.toJson(),
        },
        'scriptTombstones': {
          for (final entry in _scriptTombstones.entries)
            entry.key: entry.value.toJson(),
        },
        'knownScripts': _knownScriptIds,
        if (_activeScriptStamp != null)
          'activeScript': _activeScriptStamp!.toJson(),
        if (_sessionStamp != null) 'sessionStamp': _sessionStamp!.toJson(),
        'lastSyncAt': _lastSyncAt,
        'lastSyncOk': _lastSyncOk,
        if (_lastSyncError != null) 'lastSyncError': _lastSyncError,
        'log': [for (final entry in _log) entry.toJson()],
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
    _knownScriptIds
      ..clear()
      ..addAll((json['knownScripts'] as List?)?.whereType<String>() ?? const []);
    _activeScriptStamp = SyncStamp.fromJson(json['activeScript']);
    _sessionStamp = SyncStamp.fromJson(json['sessionStamp']);

    _lastSyncAt = json['lastSyncAt'] is num
        ? (json['lastSyncAt'] as num).toInt()
        : 0;
    _lastSyncOk = json['lastSyncOk'] != false;
    _lastSyncError =
        json['lastSyncError'] is String ? json['lastSyncError'] as String : null;
    _log.clear();
    final log = json['log'];
    if (log is List) {
      for (final item in log) {
        final entry = SyncLogEntry.fromJson(item);
        if (entry != null && _log.length < logLimit) _log.add(entry);
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
