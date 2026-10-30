/// 下载记录的唯一持有者：记录表、排序列表缓存、就绪 / 能力位与 revision。
///
/// 为什么单独一层：收藏页、单曲本地数据门面与分享弹层只需要「有哪些下载 /
/// 某个原曲键有没有记录 / 记录是否就绪」，不应该被迫依赖整个下载服务。
/// 记录变化是低频事件（下载完成 / 删除 / 导入 / 启动加载）；下载进度只属于
/// `DownloadTask`，永远不会经过本模块，因此监听记录不会跟着进度 tick 重建。
library;

import 'package:flutter/foundation.dart';

import '../../domain/models/download.dart';
import '../../domain/models/track.dart';

/// 下载记录的只读视图 + 下载服务专用的写入面。
///
/// 读取方（页面 / 门面）只使用 [supported]、[initialized]、[revision]、
/// [downloads]、[recordFor] 与 [recordForTrack]；写入方法只由
/// `DownloadService` 调用——记录必须与 drift 持久化、下载提交日志保持同一
/// 写入顺序，页面不得自行改表。
class DownloadRecords extends ChangeNotifier {
  DownloadRecords({
    Iterable<DownloadedTrack> records = const <DownloadedTrack>[],
    bool initialized = false,
    bool supported = false,
  }) : _records = {for (final record in records) record.key: record} {
    _initialized = initialized;
    _supported = supported;
  }

  /// 记录表（键 = 原音源曲目键 `sourceKey:songId`）。
  final Map<String, DownloadedTrack> _records;

  /// 排序列表缓存：记录变更时失效，避免每次读取都复制 + 排序。
  List<DownloadedTrack>? _downloadsCache;

  late bool _initialized;
  late bool _supported;
  int _revision = 0;
  bool _disposed = false;

  /// 下载目录是否可用（无文件系统 / 目录解析失败时为 false，UI 隐藏下载
  /// 入口）。
  bool get supported => _supported;

  /// 记录是否已加载（启动时 `DownloadService.init` 一次）。
  bool get initialized => _initialized;

  /// 记录 / 初始化 / 能力位变化计数：读取方只把它当作「是否需要重算」的
  /// 失效信号，不参与展示。
  int get revision => _revision;

  /// 全部下载（下载时间倒序；缓存不可变列表，记录变更时失效）。
  List<DownloadedTrack> get downloads {
    final cached = _downloadsCache;
    if (cached != null) return cached;
    final list = List<DownloadedTrack>.of(_records.values)
      ..sort((a, b) {
        final byTime = b.downloadedAt.compareTo(a.downloadedAt);
        return byTime != 0 ? byTime : b.key.compareTo(a.key);
      });
    return _downloadsCache = List<DownloadedTrack>.unmodifiable(list);
  }

  /// 按原音源曲目键查询下载记录。
  DownloadedTrack? recordFor(String sourceKey, String songId) =>
      _records['$sourceKey:$songId'];

  /// 当前曲目的下载记录：本地曲目按自身 id 反查，在线曲目按原音源键。
  DownloadedTrack? recordForTrack(Track track) {
    if (track.id.sourceKey == kLocalSourceKey) return _records[track.id.id];
    return _records['${track.id.sourceKey}:${track.id.id}'];
  }

  // 以下写入面只由 `DownloadService` 调用（见类文档）。

  /// 替换整表记录（启动加载 / 测试夹具）。
  void replaceAll(Iterable<DownloadedTrack> records) {
    final next = {for (final record in records) record.key: record};
    if (_sameRecords(next)) return;
    _records
      ..clear()
      ..addAll(next);
    _invalidate();
    _bump();
  }

  /// 写入一条记录（下载完成 / 分项落库 / 恢复 / 导入）。
  void put(DownloadedTrack record) {
    if (identical(_records[record.key], record)) return;
    _records[record.key] = record;
    _invalidate();
    _bump();
  }

  /// 移除一条记录（删除下载）。
  void remove(String key) {
    if (_records.remove(key) == null) return;
    _invalidate();
    _bump();
  }

  /// 标记记录已加载（只从 false → true 算变化）。
  void markInitialized() {
    if (_initialized) return;
    _initialized = true;
    _bump();
  }

  /// 设置下载目录能力位（只有值变化才算一次能力变化）。
  void setSupported(bool value) {
    if (_supported == value) return;
    _supported = value;
    _bump();
  }

  bool _sameRecords(Map<String, DownloadedTrack> next) {
    if (next.length != _records.length) return false;
    for (final entry in next.entries) {
      if (!identical(_records[entry.key], entry.value)) return false;
    }
    return true;
  }

  void _invalidate() => _downloadsCache = null;

  /// revision 与通知同源：任何真实变化只递增 / 通知一次。
  void _bump() {
    _revision++;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    // 运行中的 service 可能在记录模块销毁后晚到一次写入：忽略通知，避免
    // ChangeNotifier 的 dispose 后通知断言。
    _disposed = true;
    super.dispose();
  }
}
