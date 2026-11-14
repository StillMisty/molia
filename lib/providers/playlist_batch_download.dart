/// 列表多选 / 全部下载的资格过滤与提交流程（页面只消费结果）。
library;

import '../domain/models/library.dart';
import '../domain/models/track.dart';
import '../services/download/download_requests.dart';

class PlaylistBatchDownloadAction {
  const PlaylistBatchDownloadAction();

  /// 选中行里现在就能下载的列表行（本地 / 已下载 / 进行中跳过）。
  static List<PlaylistTrack> downloadableRows(
    Iterable<PlaylistTrack> rows, {
    required Track Function(PlaylistTrack row) toTrack,
    required DownloadIntentStatus Function(Track track) statusOf,
  }) => [
    for (final row in rows)
      if (statusOf(toTrack(row)) == DownloadIntentStatus.ready) row,
  ];

  /// 省流确认一次 → 批量入口一次 → 成功才回调 [onSucceeded]。
  ///
  /// 返回 null = 没有候选或用户取消；抛错 = 批量入口失败（调用方提示）。
  Future<DownloadBatchStart?> run({
    required List<Track> tracks,
    required Future<bool> Function() confirm,
    required Future<DownloadBatchStart> Function(
      List<Track> tracks, {
      void Function(int enqueued)? onEnqueued,
    })
    startBatch,
    void Function(int enqueued)? onEnqueued,
    void Function()? onSucceeded,
  }) async {
    if (tracks.isEmpty) return null;
    if (!await confirm()) return null;
    final result = await startBatch(tracks, onEnqueued: onEnqueued);
    onSucceeded?.call();
    return result;
  }
}
