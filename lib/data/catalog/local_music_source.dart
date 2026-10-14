/// `local` 音源：播放本地下载副本（`downloads/` 持久文件）。
///
/// 曲目 payload 约定（见 `lib/domain/models/download.dart`）：
/// `path` 为音频文件绝对路径；本地曲目的 `sourceKey = 'local'`，
/// `songId = '{原音源key}:{原曲目id}'`。
///
/// 能力位只有 `resolveUrl = true`：
/// - 搜索 / 收藏 / 集合等能力全 false，不出现在搜索 / 发现 / 渠道列表
///   （`SourceRegistryImpl.descriptors` 不包含本地源）；
/// - 歌词 / 封面走下载时写入的离线文件（组合根读 `payload.lyricPath` /
///   `coverPath`），不经过本音源；
/// - 文件缺失归一化为可读 [SourceFailure]（notFound），供 UI 提示重下。
library;

import '../../domain/models/catalog.dart';
import '../../domain/models/comment.dart';
import '../../domain/models/failure.dart';
import '../../domain/models/source.dart';
import '../../domain/models/track.dart';
import '../../domain/ports/music_source.dart';
import 'local_file_probe.dart';

class LocalMusicSource implements MusicSource {
  /// [fileExists] 仅测试注入（默认走平台文件探测）。
  LocalMusicSource({Future<bool> Function(String path)? fileExists})
      : _fileExists = fileExists ?? localFileExists;

  /// 本地音源 key（与 `kLocalSourceKey` 同值；数据层不反向依赖领域模型）。
  static const String sourceKey = 'local';

  static const String _displayName = 'Local';

  final Future<bool> Function(String path) _fileExists;

  @override
  String get key => sourceKey;

  @override
  String get displayName => _displayName;

  /// 本地副本只提供取链：搜索 / 歌词 / 封面 / 集合全部不支持。
  @override
  SourceCapabilities get capabilities =>
      const SourceCapabilities(resolveUrl: true);

  @override
  Future<void> init() async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<SearchResult<Track>> search(
    SearchQuery query, {
    CancelToken? cancel,
  }) {
    return Future.error(const SourceFailure(
      kind: FailureKind.unsupported,
      message: '本地音源不支持搜索',
    ));
  }

  /// 读 payload 里的文件路径回 `Uri.file(...)`；文件缺失归一化为 notFound。
  @override
  Future<PlayableStream> resolve(
    Track track, {
    AudioQuality? preferredQuality,
  }) async {
    final path = track.payload['path'];
    if (path is! String || path.trim().isEmpty) {
      throw const SourceFailure(
        kind: FailureKind.notFound,
        message: '本地文件记录缺少路径',
        l10nKey: 'downloadFileMissing',
      );
    }
    if (!await _fileExists(path)) {
      throw SourceFailure(
        kind: FailureKind.notFound,
        message: '本地文件不存在: $path',
        l10nKey: 'downloadFileMissing',
      );
    }
    return PlayableStream(Uri.file(path));
  }

  @override
  Future<LyricsDoc?> lyrics(Track track) async => null;

  /// 本地副本没有评论能力（与 `capabilities.comment = false` 一致）。
  @override
  Future<CommentPage> comments(
    Track track, {
    required CommentKind kind,
    int page = 1,
    int limit = kCommentPageSize,
  }) {
    return Future.error(const SourceFailure(
      kind: FailureKind.unsupported,
      message: '本地音源不支持评论',
    ));
  }

  @override
  Future<Artwork?> artwork(Track track) async => null;

  @override
  Future<CollectionPage> collection(
    CollectionRef ref, {
    int page = 1,
    int limit = 50,
  }) {
    return Future.error(const SourceFailure(
      kind: FailureKind.unsupported,
      message: '本地音源不支持集合浏览',
    ));
  }

  /// 只认自己的曲目（`local` 键）。
  @override
  Track? adopt(Track track) =>
      track.id.sourceKey == sourceKey ? track : null;
}
