import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/sync/sync_engine.dart';
import '../data/sync/sync_passphrase.dart';
import '../data/sync/sync_state_store.dart';
import '../domain/models/device_sync.dart';

/// 跨设备同步的 UI 门面：引擎状态 + 口令管理 + 手动同步 + 变更去抖触发。
///
/// 口令即信任根：显示/复制/重置都在这里管理；UI 不直接接触引擎。
class SyncProvider extends ChangeNotifier {
  SyncProvider({required SyncEngine engine}) : _engine = engine {
    _engine.addListener(notifyListeners);
  }

  final SyncEngine _engine;

  String? _passphrase;
  bool _busy = false;
  Timer? _debounce;

  SyncEngine get engine => _engine;

  bool get enabled => _engine.state.enabled;
  bool get syncing => _busy || _engine.syncing;
  String get deviceId => _engine.state.deviceId;
  String get deviceName => _engine.state.deviceName;
  Map<SyncCategory, bool> get categories => _engine.state.categories;
  Set<String> get enabledTransports => _engine.state.enabledTransports;
  WebDavConfig get webdav => _engine.state.webdav;
  int get lastSyncAt => _engine.state.lastSyncAt;
  bool get lastSyncOk => _engine.state.lastSyncOk;
  String? get lastSyncError => _engine.state.lastSyncError;
  List<SyncLogEntry> get log => _engine.state.log;
  SyncReport get lastReport => _engine.lastReport;

  /// 完整同步口令（显示与复制用；调用方负责提示妥善保管）。
  String? get passphrase => _passphrase;

  /// 打码口令（设置行副标题用；保留首组便于用户核对自己输入的是哪台）。
  String get maskedPassphrase {
    final value = _passphrase;
    if (value == null || value.isEmpty) return '';
    final chars = value.split('');
    for (var i = 0; i < chars.length; i++) {
      if (chars[i] == '-') continue;
      if (i < 4) continue;
      chars[i] = '*';
    }
    return chars.join();
  }

  Future<void> init() async {
    await _engine.init();
    _passphrase = await _engine.readPassphrase();
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    if (value) await _engine.ensurePassphrase();
    await _engine.setEnabled(value);
    _passphrase = await _engine.readPassphrase();
    notifyListeners();
  }

  Future<void> setCategory(SyncCategory category, bool value) =>
      _engine.setCategory(category, value);

  Future<void> setTransportEnabled(String kind, bool value) =>
      _engine.setTransportEnabled(kind, value);

  Future<void> setDeviceName(String value) => _engine.setDeviceName(value);

  Future<void> setWebdavConfig(WebDavConfig config) =>
      _engine.setWebdavConfig(config);

  Future<void> setWebdavPassword(String password) async {
    await _engine.state.writeWebdavPassword(password);
    notifyListeners();
  }

  Future<String?> readWebdavPassword() => _engine.state.readWebdavPassword();

  /// 输入已有口令加入同步（归一化后保存；无效输入抛 [ArgumentError]）。
  Future<void> joinWithPassphrase(String raw) async {
    final normalized = SyncPassphrase.normalize(raw);
    if (normalized.length < 16) {
      throw ArgumentError('口令过短');
    }
    await _engine.setPassphrase(normalized);
    _passphrase = normalized;
    notifyListeners();
  }

  /// 重置口令：所有设备需重新输入新口令。
  Future<String> resetPassphrase() async {
    final generated = await _engine.resetPassphrase();
    _passphrase = generated;
    notifyListeners();
    return generated;
  }

  Future<SyncReport> syncNow({bool manual = false}) async {
    if (_busy) return _engine.lastReport;
    _busy = true;
    notifyListeners();
    try {
      return await _engine.syncNow(manual: manual);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 数据变更后的去抖触发（资料库/统计变更等高频事件共用）。
  void scheduleSync({Duration delay = const Duration(seconds: 20)}) {
    if (!enabled) return;
    _debounce?.cancel();
    _debounce = Timer(delay, () => unawaited(syncNow()));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _engine.removeListener(notifyListeners);
    super.dispose();
  }
}
