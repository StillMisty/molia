/// 音乐文件夹（设备本地配置，不登记设置注册表、不参与同步）。
///
/// 根 locator 因设备而异，不能跨设备同步；每个条目有稳定 id、根 locator、
/// 添加时间、最近扫描时间与摘要。删除配置只停止后续扫描，不删记录、不碰
/// 磁盘 / provider 文件。
///
/// Android 的根是 SAF `content://` 树 URI，桌面是绝对路径；两种形式可以
/// 共存。显示名单独保存，UI 不展示裸 URI。
library;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../data/files/local_locator.dart';
import '../../data/settings/device_settings.dart';
import '../../data/settings/device_settings_keys.dart';
import '../../domain/models/music_folder.dart';

export '../../domain/models/music_folder.dart';

/// 设置页标题：桌面显示完整路径，SAF 只显示提供方名字。
extension MusicFolderTitle on MusicFolder {
  String get title => folderDisplayName(root, storedName: displayName);
}

/// 添加结果（UI 只按这些分支提示）。
///
/// [invalid] 是位置本身不合法；[unreadable] 是位置合法但当前读不到
/// （SAF 授权拒绝 / provider 无法枚举），UI 文案与「重新选择」引导不同。
enum MusicFolderAddResult { added, duplicate, nested, invalid, unreadable }

class MusicFoldersStore extends ChangeNotifier {
  /// [settings] / [clock] 仅测试注入；生产构造自己的设备本地入口。
  MusicFoldersStore({DeviceSettings? settings, DateTime Function()? clock})
    : _settings = settings ?? DeviceSettings(),
      _clock = clock ?? DateTime.now;

  static const String prefsKey = kMusicFoldersKeyName;

  final DeviceSettings _settings;
  final DateTime Function() _clock;
  final List<MusicFolder> _folders = [];
  int _revision = 0;
  bool _loaded = false;

  List<MusicFolder> get folders => List.unmodifiable(_folders);
  bool get isLoaded => _loaded;
  int get revision => _revision;

  Future<void> load() async {
    final stored = await _settings.readJsonList(kMusicFoldersKey);
    if (stored != null) {
      _folders
        ..clear()
        ..addAll(stored);
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

  Future<void> _persist() =>
      _settings.writeJsonList(kMusicFoldersKey, _folders);

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
