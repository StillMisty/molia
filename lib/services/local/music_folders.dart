/// 音乐文件夹（设备本地配置，不登记设置注册表、不参与同步）。
///
/// 根 locator 因设备而异，不能跨设备同步；每个条目有稳定 id、根 locator、
/// 添加时间、最近扫描时间与摘要。删除配置只停止后续扫描，不删记录、不碰
/// 磁盘 / provider 文件。
///
/// Android 的根是 SAF `content://` 树 URI，桌面是绝对路径；两种形式可以
/// 共存。显示名单独保存，UI 不展示裸 URI。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/files/local_locator.dart';

/// 一次扫描的结果摘要（只用于设置页一行文案，不暴露路径列表）。
class MusicFolderScanSummary {
  const MusicFolderScanSummary({
    this.added = 0,
    this.updated = 0,
    this.skipped = 0,
    this.cancelled = false,
    this.unavailable = false,
    this.accessRevoked = false,
    this.scannedAt = 0,
  });

  final int added;
  final int updated;
  final int skipped;
  final bool cancelled;
  final bool unavailable;

  /// 根不可用是因为 SAF 授权被撤销（提示重新选择文件夹）。
  final bool accessRevoked;
  final int scannedAt;

  Map<String, Object?> toJson() => {
    'added': added,
    'updated': updated,
    'skipped': skipped,
    'cancelled': cancelled,
    'unavailable': unavailable,
    'accessRevoked': accessRevoked,
    'scannedAt': scannedAt,
  };

  static MusicFolderScanSummary? fromJson(Object? raw) {
    if (raw is! Map) return null;
    int value(String key) => (raw[key] as num?)?.toInt() ?? 0;
    return MusicFolderScanSummary(
      added: value('added'),
      updated: value('updated'),
      skipped: value('skipped'),
      cancelled: raw['cancelled'] == true,
      unavailable: raw['unavailable'] == true,
      accessRevoked: raw['accessRevoked'] == true,
      scannedAt: value('scannedAt'),
    );
  }
}

/// 一个音乐文件夹配置。
@immutable
class MusicFolder {
  const MusicFolder({
    required this.id,
    required this.root,
    required this.addedAt,
    this.displayName,
    this.lastScan,
  });

  final String id;

  /// 绝对路径（桌面）或 SAF 树 URI（Android）。
  final String root;

  /// provider 提供的文件夹名（SAF）；桌面为空时 UI 直接展示 [root]。
  final String? displayName;
  final int addedAt;
  final MusicFolderScanSummary? lastScan;

  /// 设置页标题：桌面显示完整路径，SAF 只显示提供方名字。
  String get title => folderDisplayName(root, storedName: displayName);

  MusicFolder copyWith({
    String? displayName,
    MusicFolderScanSummary? lastScan,
  }) => MusicFolder(
    id: id,
    root: root,
    addedAt: addedAt,
    displayName: displayName ?? this.displayName,
    lastScan: lastScan ?? this.lastScan,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'root': root,
    if (displayName != null && displayName!.isNotEmpty) 'name': displayName,
    'addedAt': addedAt,
    if (lastScan != null) 'lastScan': lastScan!.toJson(),
  };

  static MusicFolder? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final root = raw['root'];
    if (id is! String || id.isEmpty || root is! String || root.isEmpty) {
      return null;
    }
    final name = raw['name'];
    return MusicFolder(
      id: id,
      root: root,
      displayName: name is String && name.trim().isNotEmpty
          ? name.trim()
          : null,
      addedAt: (raw['addedAt'] as num?)?.toInt() ?? 0,
      lastScan: MusicFolderScanSummary.fromJson(raw['lastScan']),
    );
  }
}

/// 添加结果（UI 只按这些分支提示）。
enum MusicFolderAddResult { added, duplicate, nested, invalid }

class MusicFoldersStore extends ChangeNotifier {
  MusicFoldersStore({
    Future<SharedPreferences> Function()? preferences,
    DateTime Function()? clock,
  }) : _preferences = preferences ?? SharedPreferences.getInstance,
       _clock = clock ?? DateTime.now;

  static const String prefsKey = 'music_folders_v1';

  final Future<SharedPreferences> Function() _preferences;
  final DateTime Function() _clock;
  final List<MusicFolder> _folders = [];
  int _revision = 0;
  bool _loaded = false;

  List<MusicFolder> get folders => List.unmodifiable(_folders);
  bool get isLoaded => _loaded;
  int get revision => _revision;

  Future<void> load() async {
    try {
      final prefs = await _preferences();
      final raw = prefs.getString(prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          _folders
            ..clear()
            ..addAll([for (final item in decoded) ?MusicFolder.fromJson(item)]);
        }
      }
    } catch (e) {
      // 索引损坏按空配置启动；不阻断启动。
      debugPrint('[Molia] 读取音乐文件夹失败: $e');
    }
    _loaded = true;
    _bump();
  }

  /// 规范化 + 去重 + 拒绝嵌套根（同一个文件不能经两个根重复导入）。
  ///
  /// 路径与 SAF 树 URI 都能添加：URI 不做文件系统规范化，只按完整字符串
  /// 去重（provider 的树 id 才是身份）。
  Future<MusicFolderAddResult> add(
    String locator, {
    String? displayName,
  }) async {
    final raw = locator.trim();
    if (raw.isEmpty) return MusicFolderAddResult.invalid;
    final String root;
    if (isContentLocator(raw)) {
      root = contentTreeUriOf(raw) ?? raw;
    } else {
      final path = raw.startsWith('file://')
          ? (Uri.tryParse(raw)?.toFilePath() ?? '')
          : raw;
      root = p.normalize(path);
      if (!p.isAbsolute(root)) return MusicFolderAddResult.invalid;
    }
    for (final folder in _folders) {
      final existing = folder.root;
      if (_sameLocator(existing, root)) return MusicFolderAddResult.duplicate;
      if (isContentLocator(root) || isContentLocator(existing)) {
        // 树授权彼此独立：嵌套关系由 provider 决定，不在本地猜测。
        continue;
      }
      if (_isInside(root, existing) || _isInside(existing, root)) {
        return MusicFolderAddResult.nested;
      }
    }
    _folders.add(
      MusicFolder(
        id: 'folder-${_clock().microsecondsSinceEpoch}',
        root: root,
        displayName: displayName?.trim().isEmpty ?? true
            ? null
            : displayName!.trim(),
        addedAt: _clock().millisecondsSinceEpoch,
      ),
    );
    await _persist();
    _bump();
    return MusicFolderAddResult.added;
  }

  /// 移除配置：只停止后续扫描，不删记录、不碰磁盘 / provider 文件。
  Future<void> remove(String id) async {
    final removed = _folders.length;
    _folders.removeWhere((folder) => folder.id == id);
    if (_folders.length == removed) return;
    await _persist();
    _bump();
  }

  /// 记录 provider 显示名（扫描时刷新；失败保留旧值）。
  Future<void> setDisplayName(String id, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final index = _folders.indexWhere((folder) => folder.id == id);
    if (index < 0 || _folders[index].displayName == trimmed) return;
    _folders[index] = _folders[index].copyWith(displayName: trimmed);
    await _persist();
    _bump();
  }

  /// 记录一次扫描摘要（设置页只显示一行结果）。
  Future<void> setLastScan(String id, MusicFolderScanSummary summary) async {
    final index = _folders.indexWhere((folder) => folder.id == id);
    if (index < 0) return;
    _folders[index] = _folders[index].copyWith(lastScan: summary);
    await _persist();
    _bump();
  }

  Future<void> _persist() async {
    try {
      final prefs = await _preferences();
      await prefs.setString(
        prefsKey,
        jsonEncode([for (final folder in _folders) folder.toJson()]),
      );
    } catch (e) {
      debugPrint('[Molia] 保存音乐文件夹失败: $e');
    }
  }

  void _bump() {
    _revision++;
    notifyListeners();
  }

  bool _sameLocator(String a, String b) {
    if (isContentLocator(a) || isContentLocator(b)) return a == b;
    return localLocatorKey(a) == localLocatorKey(b);
  }

  bool _isInside(String child, String parent) {
    final childKey = localLocatorKey(child);
    final parentKey = localLocatorKey(parent);
    return childKey.startsWith(
      parentKey.endsWith(p.separator) ? parentKey : '$parentKey${p.separator}',
    );
  }
}
