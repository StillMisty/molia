import 'package:molia/domain/models/catalog.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/source.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/domain/ports/music_source.dart';
import 'package:molia/domain/ports/source_registry.dart';

/// 内存音源（provider / widget 测试用）：可配置结果 / 失败 / 自定义回调，
/// 记录查询关键词。
class FakeMusicSource implements MusicSource {
  FakeMusicSource(this.key, {List<Track>? items}) : items = items ?? const [];

  @override
  final String key;

  List<Track> items;
  bool fail = false;
  int searchCalls = 0;
  SearchQuery? lastQuery;
  Future<SearchResult<Track>> Function(SearchQuery query)? onSearch;

  @override
  String get displayName => key;

  @override
  SourceCapabilities get capabilities =>
      const SourceCapabilities(search: true, pagination: true);

  @override
  Future<void> init() async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<SearchResult<Track>> search(
    SearchQuery query, {
    CancelToken? cancel,
  }) async {
    searchCalls++;
    lastQuery = query;
    final custom = onSearch;
    if (custom != null) return custom(query);
    if (fail) {
      throw const SourceFailure(
        kind: FailureKind.network,
        message: 'fake search failure',
      );
    }
    return SearchResult(items: items);
  }

  @override
  Future<PlayableStream> resolve(
    Track track, {
    AudioQuality? preferredQuality,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<LyricsDoc?> lyrics(Track track) async => null;

  @override
  Future<Artwork?> artwork(Track track) async => null;

  @override
  Future<CollectionPage> collection(
    CollectionRef ref, {
    int page = 1,
    int limit = 50,
  }) {
    throw UnimplementedError();
  }

  @override
  Track? adopt(Track track) => null;
}

/// 内存音源注册表：描述符按 map 插入顺序排列，能力取自各假音源。
class FakeSourceRegistry implements SourceRegistry {
  FakeSourceRegistry(this._sources);

  final Map<String, FakeMusicSource> _sources;

  @override
  List<SourceDescriptor> get descriptors => [
        for (var index = 0; index < _sources.length; index++)
          SourceDescriptor(
            key: _sources.keys.elementAt(index),
            displayName: _sources.values.elementAt(index).displayName,
            kind: SourceKind.builtin,
            capabilities: _sources.values.elementAt(index).capabilities,
            order: index,
          ),
      ];

  @override
  MusicSource? byKey(String key) => _sources[key];

  @override
  MusicSource? forTrack(Track track) => byKey(track.id.sourceKey);

  @override
  Future<void> refresh() async {}

  @override
  Future<void> setOrder(List<String> keys) async {}

  @override
  Stream<void> get changes => const Stream.empty();
}
