/// 下载任务产物写入器：输出登记与歌词 / 封面边车的唯一写入路径。
///
/// 为什么独立成模块：同一套 sidecar 约定（`lyrics/` 下的 `.lrc` + `.t.lrc`
/// 翻译、`covers/`）被音频下载与独立的歌词 / 封面下载共用。三条 runner 各写一份
/// 「先登记期望路径、再写、失败归一」时，改边车命名或孤儿保护策略必然漏一处；
/// 这里把登记与写入绑成一条路径，runner 只保留自己的基名来源与失败语义
/// （音频 best-effort；独立分项写失败即 typed failure）。
///
/// 依赖全部经端口注入（活跃输出 / 文件布局 / 记录读写 / 标签补写），写入器
/// 不持有下载服务，可脱离完整下载链路构造与测试。
library;

import 'dart:async';
import 'dart:typed_data';

import '../../data/downloads/download_storage.dart';
import '../../domain/models/download.dart';
import '../../domain/models/failure.dart';
import '../../domain/models/track.dart';
import 'download_file_layout.dart';

/// 下载时取词结果（主歌词 + 可选翻译；罗马音/逐字不落盘）。
class DownloadLyrics {
  const DownloadLyrics({required this.lyric, this.translation});

  final String lyric;
  final String? translation;
}

/// 运行中任务的活跃输出登记端口：落库前这些路径不能被孤儿清理删掉。
abstract interface class DownloadOutputRegistry {
  /// 登记一条即将产生 / 已产生的输出路径（必须在写文件前调用）。
  void add(String path);

  /// 撤销若干路径的登记（任务收尾时只传本任务登记过的路径）。
  void removeAll(Iterable<String> paths);
}

/// 活跃输出集合：`DownloadService` 的唯一实例，孤儿判定读取同一份路径。
class DownloadActiveOutputs implements DownloadOutputRegistry {
  final Set<String> _paths = <String>{};

  /// 当前受保护的路径快照。
  Set<String> get paths => Set<String>.unmodifiable(_paths);

  @override
  void add(String path) => _paths.add(path);

  @override
  void removeAll(Iterable<String> paths) => _paths.removeAll(paths);
}

/// 产物写入需要的下载记录端口：查询既有记录 + 分项 upsert。
abstract interface class DownloadArtifactRecords {
  /// 当前曲目的下载记录（分项基名跟随既有音频 / 另一分项）。
  DownloadedTrack? recordForTrack(Track track);

  /// 分项写成功后的记录更新（实现方保留既有音频与另一分项）。
  Future<void> upsertPart(Track track, {String? lyricPath, String? coverPath});
}

/// 独立分项落库后的标签补写（只对已有音频生效；best-effort）。
typedef DownloadTagEmbedder = Future<void> Function(Track track);

/// 已解析的封面：写边车与标签嵌入共用同一份字节。
class DownloadResolvedCover {
  const DownloadResolvedCover({
    required this.bytes,
    required this.url,
    required this.mimeType,
  });

  final Uint8List bytes;
  final String? url;
  final String mimeType;
}

/// 单个下载任务的产物写入器（由 `DownloadService` 按任务构造）。
class DownloadTaskArtifacts {
  DownloadTaskArtifacts({
    required this._outputs,
    required this._layout,
    required this._records,
    required this._embedTags,
  });

  final DownloadOutputRegistry _outputs;
  final DownloadFileLayout _layout;
  final DownloadArtifactRecords _records;
  final DownloadTagEmbedder _embedTags;

  /// 本任务登记过的路径：收尾只撤销自己加的保护，不影响其它任务。
  final Set<String> _registered = <String>{};

  /// 登记预计 / 已产生的输出路径：落库前孤儿扫描必须避开它们。
  ///
  /// 必须在写文件前登记，而不是写完再登记：写入过程中与失败回滚前路径都可能
  /// 短暂存在，孤儿清理不能在这个窗口里删掉任务产物。
  void register(String? path) {
    if (path == null || path.isEmpty) return;
    _registered.add(path);
    _outputs.add(path);
  }

  /// 写歌词主文件 + 翻译边车；两条期望路径都先登记（翻译边车也是任务产物）。
  ///
  /// 返回值与 [DownloadFileLayout.writeLyrics] 一致：失败回滚后为 null，
  /// 由调用方决定「音频 best-effort」还是「独立分项报错」。
  Future<String?> writeLyrics({
    required String root,
    required String base,
    required DownloadLyrics lyrics,
  }) {
    final expected = DownloadFileLayout.lyricsPath(root, base);
    register(expected);
    register(translationLyricPathOf(expected));
    return _layout.writeLyrics(
      root,
      base,
      lyric: lyrics.lyric,
      translation: lyrics.translation,
    );
  }

  /// 写封面文件；扩展名由封面 URL 推断，期望路径先登记再写。
  Future<String?> writeCover({
    required String root,
    required String base,
    required DownloadResolvedCover cover,
  }) {
    final coverUrl = cover.url ?? '';
    register(
      DownloadFileLayout.coverPath(
        root,
        base,
        coverUrl,
        mimeType: cover.mimeType,
      ),
    );
    return _layout.writeCover(
      root: root,
      base: base,
      coverUrl: coverUrl,
      bytes: cover.bytes,
      mimeType: cover.mimeType,
    );
  }

  /// 独立歌词任务骨架：基名 → 写边车 → 分项落库 → 补标签。
  ///
  /// 基名跟随已有音频（sidecar 同基名约定）或复用已有歌词路径；没有音频时
  /// 在 `lyrics/` 内查重。写失败抛 `downloadFailed`（独立分项不吞错）。
  Future<void> saveLyricsPart(
    Track track, {
    required String root,
    required DownloadLyrics lyrics,
  }) async {
    final existing = _records.recordForTrack(track);
    final base = await _layout.partBaseName(
      root: root,
      track: track,
      audioPath: existing?.filePath,
      existingPath: existing?.lyricPath,
      subdir: downloadsLyricsDirName,
      extension: 'lrc',
    );
    final path = await writeLyrics(root: root, base: base, lyrics: lyrics);
    if (path == null) {
      throw const SourceFailure(
        kind: FailureKind.unknown,
        message: '歌词写入失败',
        l10nKey: 'downloadFailed',
      );
    }
    await _records.upsertPart(track, lyricPath: path);
    unawaited(_embedTags(track));
  }

  /// 独立封面任务骨架：基名 → 写边车 → 分项落库 → 补标签。
  Future<void> saveCoverPart(
    Track track, {
    required String root,
    required DownloadResolvedCover cover,
  }) async {
    final existing = _records.recordForTrack(track);
    final coverUrl = cover.url ?? '';
    final base = await _layout.partBaseName(
      root: root,
      track: track,
      audioPath: existing?.filePath,
      existingPath: existing?.coverPath,
      subdir: downloadsCoversDirName,
      extension: DownloadFileLayout.coverExtension(coverUrl),
    );
    final path = await writeCover(root: root, base: base, cover: cover);
    if (path == null) {
      throw const SourceFailure(
        kind: FailureKind.unknown,
        message: '封面写入失败',
        l10nKey: 'downloadFailed',
      );
    }
    await _records.upsertPart(track, coverPath: path);
    unawaited(_embedTags(track));
  }

  /// 任务收尾（成功 / 失败 / 取消）撤销本任务的孤儿保护。
  void close() => _outputs.removeAll(_registered);
}
