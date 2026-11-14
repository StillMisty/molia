/// 下载记录写入的唯一入口：内存记录表 + drift 仓库 + 崩溃恢复提交日志。
///
/// 为什么单独一层：一条记录要在三处保持一致——drift 行、UI 读取的内存表、
/// 以及「文件已 rename、记录未落库」窗口里的提交日志 marker。顺序一旦由调用
/// 方各写，新增一个写入点就可能漏掉步骤或 marker；收口后调用方只表达意图
/// （保存 / 删除 / 待恢复），顺序由这里保证。
///
/// 本类不是 [ChangeNotifier]：可监听的读模型是 [records]，页面直接订阅它。
library;

import '../../data/downloads/downloads_repository.dart';
import '../../domain/models/download.dart';
import 'download_journal.dart';
import 'download_records.dart';

/// 下载记录存储（由 `DownloadService` 持有并调用）。
class DownloadRecordStore {
  DownloadRecordStore({
    required this._repository,
    required this._journal,
    DownloadRecords? records,
  }) : _records = records ?? DownloadRecords();

  final DownloadsRepository _repository;
  final DownloadJournal _journal;
  final DownloadRecords _records;

  /// 内存记录表 / 可监听读模型（UI 只订阅它）。
  DownloadRecords get records => _records;

  /// 按路径查导入记录（内存表缺失时回退数据库，避免生成第二个身份）。
  Future<DownloadedTrack?> findImportedByPath(String path) =>
      _repository.findByFilePath(path);

  /// 启动时把 drift 全表灌进内存表。
  Future<void> load() async {
    _records.replaceAll(await _repository.listAll());
  }

  /// 保存一条记录（落库 → 更新内存 → 可选清 marker）。
  ///
  /// 先写仓库再更新内存：UI 永远不会先看到一条实际没落库的记录。[clearJournal]
  /// 用于「marker 只在文件已就位、记录未落库的窗口存在」的完成路径。
  Future<void> save(DownloadedTrack record, {bool clearJournal = false}) async {
    await _repository.insert(record);
    records.put(record);
    if (clearJournal) await _journal.remove(record.key);
  }

  /// 重定位：库行路径 / 大小 / 修改时间 + 清缺失，再换内存记录。
  Future<void> relocate(
    DownloadedTrack record, {
    required String path,
    required int sizeBytes,
    required int? mtimeMs,
  }) async {
    await _repository.relocate(
      originSourceKey: record.originSourceKey,
      originSongId: record.originSongId,
      filePath: path,
      sizeBytes: sizeBytes,
      mtimeMs: mtimeMs,
    );
    records.put(
      record.copyWith(
        filePath: path,
        sizeBytes: sizeBytes,
        mtimeMs: mtimeMs,
        clearMissingAt: true,
      ),
    );
  }

  /// 标记文件缺失（只写 missingAt，保留旧 mtime 与记录）。
  Future<void> markMissing(
    DownloadedTrack record, {
    required int missingAt,
  }) async {
    await _repository.setFileProbe(
      originSourceKey: record.originSourceKey,
      originSongId: record.originSongId,
      mtimeMs: record.mtimeMs,
      missing: true,
      missingAt: missingAt,
    );
    records.put(record.copyWith(missingAt: missingAt));
  }

  /// 删除一条记录（库行 → 内存 → marker）。
  ///
  /// 删除意味着「这首已经不在本地」：顺手清掉可能残留的 marker，避免下次
  /// 启动把一条已删除的下载又恢复回来。清 marker 失败不影响删除结果。
  Future<void> deleteRecord(DownloadedTrack record) async {
    await _repository.delete(record.originSourceKey, record.originSongId);
    records.remove(record.key);
    await _journal.remove(record.key);
  }

  /// 在音频 rename 前写一条 pending marker。
  ///
  /// 返回 false 表示这次提交没有崩溃保护，调用方必须在 rename 前中止。
  Future<bool> markPending(DownloadedTrack record) => _journal.write(record);

  /// 读取全部有效 pending marker（启动恢复用）。
  Future<List<({String markerPath, DownloadedTrack record})>> pending() =>
      _journal.readAll();

  /// 删除读取时拿到的 marker（已有记录 / 文件不存在等只清理场景）。
  Future<void> removePending(String markerPath) =>
      _journal.removePath(markerPath);

  /// 按记录键丢弃 marker（下载失败 / 取消时只持有键）。
  ///
  /// 与 [removePending] 的差别只是入参形态：marker 路径由 journal 约定，
  /// 调用方不必知道 `<md5(key)>.json` 的细节。
  Future<void> removePendingByKey(String key) => _journal.remove(key);
}
