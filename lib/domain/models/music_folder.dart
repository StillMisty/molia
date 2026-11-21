/// 音乐文件夹配置的纯领域模型。
///
/// 持久化形状由 `data/settings/device_settings_keys.dart` 的 JSON 数组键声明；
/// 根 locator 的规范化 / 去重 / 显示名规则留在
/// `services/local/music_folders.dart`（依赖 `data/files/local_locator.dart`，
/// 领域层保持纯 Dart）。
library;

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
