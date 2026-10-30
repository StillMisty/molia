/// 下载管理面的窄接口：管理页 / 本地数据页 / 分享弹层只依赖命令，不依赖
/// 具体服务实现。
///
/// 队列 / 提交日志 / 文件放置 / 记录装配仍只有 `DownloadService` 一份实现；
/// 本接口只把页面真正用到的命令收口，便于 widget 测试替换为小假件。记录读取
/// 不在这里：只读消费方直接依赖 `DownloadRecords`。
library;

import 'package:flutter/foundation.dart';

import '../../domain/models/download.dart';
import '../../domain/models/track.dart';
import 'download_queue.dart';

/// 下载命令面（由 `DownloadService` 实现）。
///
/// 继承 [ChangeNotifier] 只为让能力位 / 就绪状态可被页面监听；下载进度属于
/// 任务自身（[DownloadTask]），任务结构变化走 [taskChanges]。
abstract class DownloadManager extends ChangeNotifier {
  /// 下载目录是否可用（无文件系统 / 目录解析失败时为 false）。
  bool get supported;

  /// 是否支持发布公共 Downloads 副本（仅 Android）。
  bool get publisherSupported;

  /// 是否支持系统下载通知（仅 Android）。
  bool get notificationsSupported;

  /// 下载记录是否已加载（依赖记录的命令会自行等待 [ready]）。
  bool get initialized;

  /// 记录加载完成的信号。
  Future<void> get ready;

  /// 加载已有下载记录并探测存储可用性（幂等）。
  Future<void> init();

  /// 当前解析出的下载根目录（不可用返回 null）。
  Future<String?> rootPath();

  /// 任务结构变化（增删 / 状态切换）。
  Listenable get taskChanges;

  /// 按状态分组的音频任务（运行 / 等待 / 失败）。
  DownloadTaskGroups get taskGroups;

  /// 当前曲目的音频任务（排队 / 运行 / 失败）；无任务返回 null。
  DownloadTask? taskForTrack(Track track);

  /// 重试失败任务。
  Future<void> retryTask(DownloadTask task);

  /// 从失败区移除任务（不重试）。
  void dismissTask(DownloadTask task);

  /// 取消当前曲目的下载（排队或运行中）。
  void cancelTrack(Track track);

  /// 下载音频（可同时带离线歌词 / 封面）。
  Future<void> download(
    Track track, {
    String? quality,
    bool includeLyrics = true,
    bool includeCover = true,
  });

  /// 单独下载歌词。
  Future<void> downloadLyrics(Track track);

  /// 单独下载封面。
  Future<void> downloadCover(Track track);

  /// 批量下载候选（跳过本地 / 已下载 / 进行中）。
  List<({int index, Track track})> batchCandidates(Iterable<Track> tracks);

  /// 批量下载：先全部入队，再等待结果。
  Future<(int, int)> downloadBatch(
    Iterable<Track> tracks, {
    void Function(int enqueued)? onEnqueued,
  });

  /// 删除下载记录及其文件（本地导入只移除记录）。
  Future<void> delete(DownloadedTrack record);

  /// 导入本地音频文件（就地引用）。
  Future<(int, int)> importLocalFiles(Iterable<String> paths);

  /// 把已有音频补发布到公共 Downloads。
  Future<(int, int)> publishMissingPublicCopies();

  /// 清扫崩溃遗留的半成品（`*.part`）。
  Future<int> cleanupIncompleteDownloads();

  /// 无记录引用的孤儿文件。
  Future<List<String>> orphanFiles();

  /// 删除孤儿文件。
  Future<int> deleteOrphanFiles({Iterable<String>? paths});

  /// 缺省下载音质：偏好音质 × 曲目可用音质。
  String defaultQualityFor(Track track);

  /// 播放取链优先命中本地副本（下载记录 → 完整缓存）。
  Future<Uri?> localUriFor(Track track, {String? quality});
}
