/// 批量下载端口的接线：把下载请求结果映射成命令模块自己的形状。
///
/// 为什么单独文件：`collection_io_commands.dart` 只定义端口与编排，不引用
/// 下载请求实现；只有这里认识 `DownloadRequests` / `DownloadBatchStart`，
/// 下载层改名或换类型时不必改命令接口。
library;

import '../domain/models/track.dart';
import '../services/download/download_requests.dart';
import 'collection_io_commands.dart';

/// [CollectionBatchDownloader] 的生产实现：转发下载请求入口。
final class RequestsCollectionBatchDownloader
    implements CollectionBatchDownloader {
  const RequestsCollectionBatchDownloader(this._requests);

  final DownloadRequests _requests;

  @override
  Future<CollectionBatchStart> startBatch(
    List<Track> tracks, {
    void Function(int enqueued)? onEnqueued,
  }) async {
    final result = await _requests.startBatch(tracks, onEnqueued: onEnqueued);
    return CollectionBatchStart(
      enqueued: result.enqueued,
      done: result.done,
      failed: result.failed,
    );
  }
}
