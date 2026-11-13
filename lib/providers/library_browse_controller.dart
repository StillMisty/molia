/// 浏览索引缓存：输入 revision 变化后防抖 150ms 重建，旧快照保持可见。
///
/// 构建只做纯计算（分组 / 去重 / 重复聚类）；读取输入由注入的 loader 完成，
/// 页面 build 不触发查询。revision 是「是否需要重算」的唯一信号。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/models/library_browse.dart';

/// 一次浏览快照（不可变）。
class LibraryBrowseSnapshot {
  const LibraryBrowseSnapshot({
    required this.index,
    required this.duplicateGroups,
    required this.versionCounts,
  });

  final LibraryBrowseIndex index;
  final List<DuplicateGroup> duplicateGroups;

  /// 代表行 key → 版本数（只有多版本才出现）。
  final Map<String, int> versionCounts;
}

class LibraryBrowseController extends ChangeNotifier {
  LibraryBrowseController({
    required this.loader,
    this.debounce = const Duration(milliseconds: 150),
  });

  final Future<BrowseSource> Function() loader;
  final Duration debounce;

  LibraryBrowseSnapshot? _snapshot;
  Timer? _timer;
  int? _scheduledRevision;
  int _token = 0;
  bool _loading = false;
  bool _disposed = false;

  LibraryBrowseSnapshot? get snapshot => _snapshot;
  bool get loading => _loading;

  /// 输入变了才安排一次重建；相同 revision 直接返回。
  void schedule({required int revision}) {
    if (_scheduledRevision == revision) return;
    _scheduledRevision = revision;
    _timer?.cancel();
    _timer = Timer(debounce, () => unawaited(rebuild()));
  }

  /// 立即重建（测试 / 显式刷新）；旧快照在完成前保持可见。
  Future<void> rebuild() async {
    final token = ++_token;
    _loading = true;
    _notify();
    try {
      final source = await loader();
      if (token != _token) return;
      final index = buildBrowseIndex(source);
      final groups = groupDuplicates(index.tracks);
      _snapshot = LibraryBrowseSnapshot(
        index: index,
        duplicateGroups: groups,
        versionCounts: duplicateVersionCounts(groups),
      );
    } finally {
      if (token == _token) {
        _loading = false;
        _notify();
      }
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _token++;
    super.dispose();
  }
}
