/// 跨页面请求：让收藏页切换到某个智能列表（设备本地，不落库）。
///
/// 下载维护等页面只表达「打开文件不见」的意图；收藏页消费后清空请求，
/// 不新增导航目的地，也不持有收藏页的会话状态。
library;

import 'package:flutter/foundation.dart';

class LibraryCollectionRequest extends ChangeNotifier {
  String? _pendingSmartListId;

  String? get pendingSmartListId => _pendingSmartListId;

  void requestSmartList(String id) {
    if (_pendingSmartListId == id) return;
    _pendingSmartListId = id;
    notifyListeners();
  }

  /// 收藏页消费请求；返回被请求的智能列表 id。
  String? take() {
    final id = _pendingSmartListId;
    _pendingSmartListId = null;
    return id;
  }
}
