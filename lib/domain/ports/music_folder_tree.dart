/// 音乐文件夹树枚举端口：扫描器只依赖这个接口，不感知 `dart:io` / SAF。
///
/// 桌面实现走 `dart:io`（保留深度上限、符号链接环检测、隐藏文件跳过与
/// 确定性排序）；Android 的 SAF 实现走应用内 Kotlin bridge，`locator` 是
/// `content://` 文档 URI，桌面是绝对路径。
///
/// 枚举按目录流式产出：文件条目不整树读入内存，调用方可以随时取消订阅。
library;

/// 树中的一个文件或目录。
class FolderTreeEntry {
  const FolderTreeEntry({
    required this.locator,
    required this.canonicalLocator,
    required this.displayName,
    required this.relativePath,
    required this.isDirectory,
    this.sizeBytes = 0,
    this.mtimeMs = 0,
  });

  /// 存库 / 播放使用的地址：桌面绝对路径，SAF 子文档 `content://` URI。
  final String locator;

  /// 去重用的真实地址：桌面解析符号链接后的路径，SAF 与 [locator] 相同。
  final String canonicalLocator;

  /// 用户可见名称（不含路径）——扩展名判定也用它，避免解析 URI 字符串。
  final String displayName;

  /// 相对根目录的路径，用 `/` 分隔（SAF 与桌面统一）。
  final String relativePath;

  final bool isDirectory;
  final int sizeBytes;
  final int mtimeMs;
}

/// 枚举时跳过的子树原因（数量进扫描摘要，不暴露路径）。
enum FolderTreeSkipReason { hidden, depthExceeded, symlinkCycle, unreadable }

sealed class FolderTreeEvent {
  const FolderTreeEvent();
}

final class FolderTreeEntryFound extends FolderTreeEvent {
  const FolderTreeEntryFound(this.entry);

  final FolderTreeEntry entry;
}

final class FolderTreeSkipped extends FolderTreeEvent {
  const FolderTreeSkipped(this.reason);

  final FolderTreeSkipReason reason;
}

/// 根目录无法枚举（不存在 / 权限被撤销 / provider 离线）。
class FolderTreeUnavailable implements Exception {
  const FolderTreeUnavailable({required this.permissionDenied, this.cause});

  /// `true` 表示授权被撤销 / 被系统拒绝；UI 据此提示重新选择文件夹，
  /// 而不是把整库记录标成缺失。
  final bool permissionDenied;
  final Object? cause;

  @override
  String toString() =>
      'FolderTreeUnavailable(permissionDenied: $permissionDenied)';
}

/// 音乐文件夹树端口。
abstract interface class MusicFolderTree {
  /// 根目录显示名（provider 提供；无法读取时返回 null）。
  ///
  /// 桌面返回目录名；SAF 返回文档提供方的 `DISPLAY_NAME`。UI 只展示它，
  /// 绝不展示裸 `content://`。
  Future<String?> displayName(String root);

  /// 单文件 / 目录 stat；不存在或不可读返回 null。
  Future<FolderTreeEntry?> stat(String locator, {String relativePath = ''});

  /// 规范化 locator（桌面解析符号链接；SAF 原样返回）；失败抛异常。
  Future<String> canonicalLocator(String locator);

  /// 流式枚举 [root] 下全部条目（含目录），按目录排序保证顺序确定。
  Stream<FolderTreeEvent> walk(
    String root, {
    int maxDepth = 32,
    bool Function()? isCancelled,
  });
}
