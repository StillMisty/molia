/// 本地曲库写入门闸：扫描导入 / 手动导入 / 缺文件探测共用一条串行队列。
///
/// 为什么需要：两条路径都会读「同路径已有记录」再写库；并发时一条可能看不到
/// 另一条刚建的记录（同一路径两条记录），探测也可能把扫描刚写下的「存在」
/// 覆盖成「缺失」。串行后每次「读判断 → 写」都在同一顺序里完成。
library;

import 'dart:async';

class LocalWriteGate {
  Future<void> _tail = Future<void>.value();

  /// 排队执行 [action]；前一个任务完成（成功或失败）后才开始下一个。
  Future<T> run<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }
}
