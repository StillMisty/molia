/// 按渠道隔离的设备本地搜索历史。
///
/// 隐私边界：只存本机、不登记 `SettingsRegistry`、不参与跨设备同步 / 完整
/// 备份，任何日志都不写查询文本。读取失败、缺失、损坏一律按空列表处理；
/// 存储不可用不影响搜索本身。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 每个渠道最多保留的查询数。
const int kSearchHistoryMaxEntries = 20;

/// 设备本地搜索历史仓库。
class SearchHistoryStore extends ChangeNotifier {
  /// [preferences] 仅测试注入；生产懒加载 `SharedPreferences` 单例。
  SearchHistoryStore({SharedPreferences? preferences})
    : _preferencesOverride = preferences;

  /// 设备本地键前缀（值为 JSON 字符串数组）。
  static const String storagePrefix = 'search_history_v1:';

  final SharedPreferences? _preferencesOverride;
  final Logger _logger = Logger('molia.search_history');

  SharedPreferences? _preferences;
  final Map<String, List<String>> _entries = {};
  bool _ready = false;
  bool _disposed = false;

  bool get isReady => _ready;

  /// 解析偏好并载入所有渠道的历史；重复调用是幂等的。
  Future<void> ready() async {
    if (_ready) return;
    try {
      final prefs = await _resolvePreferences();
      if (prefs == null) return;
      for (final key in prefs.getKeys()) {
        if (!key.startsWith(storagePrefix)) continue;
        final channel = key.substring(storagePrefix.length);
        _entries[channel] = _decode(prefs.getString(key));
      }
      _ready = true;
    } catch (e) {
      // 只记通用失败：历史内容不进入日志。
      _logger.warning('读取搜索历史失败');
      _ready = true;
    }
  }

  /// 某渠道的完整历史（新 → 旧）。未加载 / 无记录返回空列表。
  List<String> entriesFor(String channelKey) {
    final key = _normalizeChannel(channelKey);
    if (key.isEmpty) return const [];
    final entries = _entries[key];
    if (entries == null) return const [];
    return List.unmodifiable(entries);
  }

  /// 记录一次用户确认的查询：trim、去空、忽略大小写去重并移到最前。
  Future<void> record(String channelKey, String query) async {
    final key = _normalizeChannel(channelKey);
    final normalized = query.trim();
    if (key.isEmpty || normalized.isEmpty) return;
    final folded = normalized.toLowerCase();
    final current = List<String>.of(_entries[key] ?? const []);
    current.removeWhere((value) => value.toLowerCase() == folded);
    current.insert(0, normalized);
    if (current.length > kSearchHistoryMaxEntries) {
      current.removeRange(kSearchHistoryMaxEntries, current.length);
    }
    _entries[key] = current;
    _notify();
    await _persist(key, current);
  }

  /// 删除当前渠道的一条历史（大小写不敏感匹配）。
  Future<void> remove(String channelKey, String query) async {
    final key = _normalizeChannel(channelKey);
    final folded = query.trim().toLowerCase();
    if (key.isEmpty || folded.isEmpty) return;
    final current = List<String>.of(_entries[key] ?? const []);
    final before = current.length;
    current.removeWhere((value) => value.toLowerCase() == folded);
    if (current.length == before) return;
    _entries[key] = current;
    _notify();
    await _persist(key, current);
  }

  /// 清空当前渠道的全部历史；其它渠道不受影响。
  Future<void> clear(String channelKey) async {
    final key = _normalizeChannel(channelKey);
    if (key.isEmpty || (_entries[key]?.isEmpty ?? true)) return;
    _entries[key] = const [];
    _notify();
    await _persist(key, const []);
  }

  static String _normalizeChannel(String value) => value.trim();

  List<String> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final result = <String>[];
      final seen = <String>{};
      for (final value in decoded) {
        if (value is! String) continue;
        final normalized = value.trim();
        final folded = normalized.toLowerCase();
        if (normalized.isEmpty || !seen.add(folded)) continue;
        result.add(normalized);
        if (result.length >= kSearchHistoryMaxEntries) break;
      }
      return result;
    } catch (_) {
      // 损坏数据按空历史处理，不阻断搜索。
      return const [];
    }
  }

  Future<void> _persist(String channelKey, List<String> entries) async {
    try {
      final prefs = await _resolvePreferences();
      if (prefs == null) return;
      if (entries.isEmpty) {
        await prefs.remove('$storagePrefix$channelKey');
      } else {
        await prefs.setString('$storagePrefix$channelKey', jsonEncode(entries));
      }
    } catch (e) {
      // 只记通用失败：不写渠道内容之外的任何查询文本。
      _logger.warning('保存搜索历史失败');
    }
  }

  Future<SharedPreferences?> _resolvePreferences() async {
    final override = _preferencesOverride;
    if (override != null) return override;
    try {
      return _preferences ??= await SharedPreferences.getInstance();
    } catch (e) {
      _logger.warning('搜索历史存储不可用');
      return null;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
