/// 本地曲目标题编辑：标签文件 + 一处数据库事务，失败有明确回退。
///
/// 语义：
/// - 先写文件标签（只改标题），成功后再提交数据库；数据库失败不回滚已经
///   写入的文件，提示重试即可（重试幂等）；
/// - 格式不支持 / 写入失败 / 文件不见：返回 [LocalTitleEditStatus.appOnlyRequired]，
///   UI 让用户选「只在 Molia 中修改」，不展示技术原因；
/// - 会话写入先等会话层排空（正常保存先完成），再在同一事务里更新会话
///   JSON，避免旧标题被在途写入盖回去。
library;

import '../../data/downloads/audio_title_editor.dart';
import '../../data/downloads/download_storage.dart';
import '../../data/local_title_store.dart';
import '../../domain/models/download.dart';
import '../download/download_records.dart';

enum LocalTitleEditStatus {
  written,

  /// 需要用户选择「只在 Molia 中修改」（文件不动）。
  appOnlyRequired,

  /// 数据库提交失败；文件可能已经改了，重试幂等。
  failed,

  invalidTitle,
}

class LocalMetadataService {
  LocalMetadataService({
    required this.storage,
    required this.store,
    required this.records,
    this.awaitSessionWrites,
    this.onCommitted,
  });

  final DownloadStorage storage;
  final LocalTitleStore store;
  final DownloadRecords records;

  /// 会话写队列排空（组合根在播放栈建好后接线：`sessionStore.pendingWrite`）。
  Future<void> Function()? awaitSessionWrites;
  void Function(DownloadedTrack record)? onCommitted;

  /// 编辑本地曲目标题；[appOnly] 表示用户已选择「只在 Molia 中修改」。
  Future<LocalTitleEditStatus> editTitle(
    DownloadedTrack record,
    String rawTitle, {
    bool appOnly = false,
  }) async {
    final title = normalizeTitleText(rawTitle);
    if (title == null) return LocalTitleEditStatus.invalidTitle;

    if (!appOnly) {
      final path = record.filePath;
      if (path == null || path.isEmpty || !record.hasAudio) {
        return LocalTitleEditStatus.appOnlyRequired;
      }
      final outcome = await rewriteAudioTitle(
        storage: storage,
        filePath: path,
        title: title,
      );
      if (outcome != TagWriteOutcome.written) {
        return LocalTitleEditStatus.appOnlyRequired;
      }
    }

    try {
      await awaitSessionWrites?.call();
      await store.applyLocalTitle(
        songId: record.localSongId,
        downloadSourceKey: record.originSourceKey,
        downloadSongId: record.originSongId,
        title: title,
      );
      final updated = record.copyWith(title: title);
      records.put(updated);
      onCommitted?.call(updated);
      return LocalTitleEditStatus.written;
    } catch (_) {
      return LocalTitleEditStatus.failed;
    }
  }
}
