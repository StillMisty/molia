/// 跨页面请求：让收藏页切换到某个智能列表（设备本地，不落库）。
///
/// 下载维护等页面只表达「打开文件不见」的意图；收藏页消费后清空请求，
/// 不新增导航目的地，也不持有收藏页的会话状态。
library;

import 'package:flutter/foundation.dart';

import 'snapshot_source.dart';

/// 请求对象快照：当前是否有待消费的智能列表。
@immutable
class LibraryCollectionRequestState {
  const LibraryCollectionRequestState({required this.pendingSmartListId});

  final String? pendingSmartListId;
}

class LibraryCollectionRequest
    implements SnapshotSource<LibraryCollectionRequestState> {
  String? _pendingSmartListId;

  /// 变更信号（替代 `ChangeNotifier.notifyListeners` 的订阅面）。
  final SnapshotSignal _changes = SnapshotSignal();

  String? get pendingSmartListId => _pendingSmartListId;

  @override
  LibraryCollectionRequestState get state =>
      LibraryCollectionRequestState(pendingSmartListId: _pendingSmartListId);

  @override
  Listenable get changes => _changes;

  void requestSmartList(String id) {
    if (_pendingSmartListId == id) return;
    _pendingSmartListId = id;
    _changes.notify();
  }

  /// 收藏页消费请求；返回被请求的智能列表 id。
  String? take() {
    final id = _pendingSmartListId;
    _pendingSmartListId = null;
    return id;
  }
}
