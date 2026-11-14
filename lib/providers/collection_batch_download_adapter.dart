/// 批量下载端口的接线：把下载意图结果映射成命令模块自己的形状。
///
/// 为什么单独文件：`collection_io_commands.dart` 只定义端口与编排，不引用
/// 下载意图实现；只有这里认识 `DownloadLauncher` / `DownloadBatchStart`，
/// 下载请求模块改名或换类型时不必改命令接口。
library;

import '../domain/models/track.dart';
import '../services/download/download_intent.dart';
import 'collection_io_commands.dart';

/// [CollectionBatchDownloader] 的生产实现：转发下载意图入口。
final class LauncherCollectionBatchDownloader
    implements CollectionBatchDownloader {
  const LauncherCollectionBatchDownloader(this._launcher);

  final DownloadLauncher _launcher;

  @override
  Future<CollectionBatchStart> startBatch(
    List<Track> tracks, {
    void Function(int enqueued)? onEnqueued,
  }) async {
    final result = await _launcher.startBatch(tracks, onEnqueued: onEnqueued);
    return CollectionBatchStart(
      enqueued: result.enqueued,
      done: result.done,
      failed: result.failed,
    );
  }
}
