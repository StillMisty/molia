import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/data/database_helper.dart';
import 'package:molia/data/play_statistics_repository.dart';
import 'package:molia/domain/models/ai_dj.dart';
import 'package:molia/domain/models/catalog.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/source.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/domain/ports/music_source.dart';
import 'package:molia/domain/ports/source_registry.dart';
import 'package:molia/services/ai/ai_recommendation_service.dart';
import 'package:molia/services/ai/llm_client.dart';
import 'package:molia/services/ai/taste_profile_builder.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 假 LLM：直接返回预置文本（不触碰网络）。
class _FakeLlm extends LlmClient {
  _FakeLlm(this.response);

  String response;
  Object? error;
  String? lastUserPrompt;
  bool? lastJsonMode;

  @override
  Future<String> complete({
    required LlmConfig config,
    required String systemPrompt,
    required String userPrompt,
    double temperature = 0.8,
    int maxTokens = 4096,
    bool jsonMode = false,
  }) async {
    lastUserPrompt = userPrompt;
    lastJsonMode = jsonMode;
    final failure = error;
    if (failure != null) throw failure;
    return response;
  }
}

/// 假音源：search 返回固定结果（其余成员不会被调用）。
class _FakeSource implements MusicSource {
  _FakeSource(this.key, this.results);

  @override
  final String key;

  final List<Track> results;

  /// 封面补取：非空时 `artwork()` 返回它（统计调用次数）。
  String? artworkUrl;
  int artworkCalls = 0;

  @override
  String get displayName => key;

  @override
  Future<Artwork?> artwork(Track track) async {
    artworkCalls++;
    final url = artworkUrl;
    return url == null ? null : Artwork(uri: Uri.parse(url));
  }

  @override
  SourceCapabilities get capabilities => const SourceCapabilities(search: true);

  @override
  Future<SearchResult<Track>> search(SearchQuery query, {CancelToken? cancel}) async =>
      SearchResult(items: results);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRegistry implements SourceRegistry {
  _FakeRegistry(this._sources);

  final Map<String, MusicSource> _sources;

  @override
  List<SourceDescriptor> get descriptors => [
        for (final entry in _sources.entries)
          SourceDescriptor(
            key: entry.key,
            displayName: entry.key,
            kind: SourceKind.builtin,
            capabilities: entry.value.capabilities,
            enabled: true,
          ),
      ];

  @override
  MusicSource? byKey(String key) => _sources[key];

  @override
  MusicSource? forTrack(Track track) => _sources[track.id.sourceKey];

  @override
  Future<void> refresh() async {}

  @override
  Future<void> setOrder(List<String> keys) async {}

  @override
  Stream<void> get changes => const Stream.empty();
}

Track _track(String id, String title, String artist) => Track(
      id: TrackId('wy', id),
      title: title,
      artists: [Artist(name: artist)],
      duration: const Duration(minutes: 4),
      origin: TrackOrigin.builtin,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database db;
  late PlayStatisticsRepository statistics;
  late _FakeLlm llm;
  late AiRecommendationService service;

  const config = LlmConfig(
    baseUrl: 'https://api.example.com/v1',
    apiKey: 'sk-test',
    model: 'm',
  );

  Future<void> insertPlayed(String title, String artist) async {
    await db.insert('play_events', {
      'sourceKey': 'wy',
      'songId': '$title-$artist',
      'title': title,
      'artist': artist,
      'durationMs': 200000,
      'raw': '{}',
      'startedAt': 1000,
      'endedAt': 200000,
      'listenedMs': 150000,
      'maxPositionMs': 190000,
      'endReason': 'completed',
    });
  }

  AiRecommendationService buildService(List<MusicSource> sources) {
    final registry = _FakeRegistry({
      for (final source in sources) source.key: source,
    });
    return AiRecommendationService(
      llm: llm,
      catalog: CatalogService(registry: registry),
      registry: registry,
      profileBuilder: TasteProfileBuilder(repository: statistics),
    );
  }

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: DatabaseHelper.dbVersion,
        onCreate: (database, version) => DatabaseHelper.createSchema(database),
      ),
    );
    statistics = PlayStatisticsRepository(databaseProvider: () async => db);
    llm = _FakeLlm('{}');
    service = buildService(const []);
  });

  tearDown(() async {
    await statistics.dispose();
    await db.close();
  });

  group('生成链路', () {
    test('解析并匹配可播放曲目；未命中进入 unresolved', () async {
      llm.response = jsonEncode({
        'songs': [
          {'title': '晴天', 'artist': '周杰伦', 'reason': '经典'},
          {'title': '不存在的歌', 'artist': '无人', 'reason': 'x'},
        ],
      });
      service = buildService([
        _FakeSource('wy', [
          _track('a', '晴天', '周杰伦'),
          _track('b', '夜曲', '周杰伦'),
        ]),
      ]);

      final batch = await service.generate(config: config, count: 20);

      expect(batch.items, hasLength(1));
      expect(batch.items.single.track.title, '晴天');
      expect(batch.items.single.track.id.id, 'a');
      expect(batch.items.single.source.reason, '经典');
      expect(batch.unresolved.single.title, '不存在的歌');
    });

    test('已听排除清单命中 → 不再推荐', () async {
      await insertPlayed('晴天', '周杰伦');
      llm.response = jsonEncode({
        'songs': [
          {'title': '晴天', 'artist': '周杰伦', 'reason': '经典'},
        ],
      });
      service = buildService([
        _FakeSource('wy', [_track('a', '晴天', '周杰伦')]),
      ]);

      final batch = await service.generate(config: config, count: 20);

      expect(batch.items, isEmpty);
      expect(batch.unresolved, isEmpty);
    });

    test('批内规范化去重（括号后缀视为同一首）', () async {
      llm.response = jsonEncode({
        'songs': [
          {'title': '晴天', 'artist': '周杰伦', 'reason': 'a'},
          {'title': '晴天 (Live)', 'artist': '周杰伦', 'reason': 'b'},
        ],
      });
      service = buildService([
        _FakeSource('wy', [_track('a', '晴天', '周杰伦')]),
      ]);

      final batch = await service.generate(config: config, count: 20);

      expect(batch.items, hasLength(1));
      expect(batch.items.single.source.reason, 'a', reason: '保留首个');
    });

    test('模型返回不可解析 → SourceFailure(aiDjBadResponse)', () async {
      llm.response = '抱歉，我无法完成这个请求。';

      await expectLater(
        service.generate(config: config, count: 20),
        throwsA(isA<SourceFailure>()
            .having((f) => f.l10nKey, 'l10nKey', 'aiDjBadResponse')),
      );
    });

    test('LLM 失败原样上抛（SourceFailure）', () async {
      llm.error = const SourceFailure(
        kind: FailureKind.rateLimited,
        message: '限流',
      );

      await expectLater(
        service.generate(config: config, count: 20),
        throwsA(isA<SourceFailure>()
            .having((f) => f.kind, 'kind', FailureKind.rateLimited)),
      );
    });

    test('命中但无封面 → 经音源 artwork() 补取', () async {
      llm.response = jsonEncode({
        'songs': [
          {'title': '晴天', 'artist': '周杰伦', 'reason': 'x'},
        ],
      });
      final source = _FakeSource('wy', [_track('a', '晴天', '周杰伦')])
        ..artworkUrl = 'https://img.example/cover.jpg';
      service = buildService([source]);

      final batch = await service.generate(config: config, count: 20);

      expect(source.artworkCalls, 1);
      expect(
        batch.items.single.track.artwork?.uri.toString(),
        'https://img.example/cover.jpg',
      );
    });

    test('请求带 JSON 模式；额外排除清单进入提示词', () async {
      llm.response = jsonEncode({
        'songs': [
          {'title': '歌', 'artist': '手'},
        ],
      });

      await service.generate(
        config: config,
        count: 1,
        excludeLabels: const ['已在该列表 - 某'],
      );

      expect(llm.lastJsonMode, isTrue);
      expect(llm.lastUserPrompt, contains('这些不要再推荐'));
      expect(llm.lastUserPrompt, contains('已在该列表'));
    });

    test('summarizeUpstream 只统计条数', () async {
      await insertPlayed('晴天', '周杰伦');

      final summary = await service.summarizeUpstream();

      expect(summary.recentEvents, 1);
      expect(summary.exclusions, 1);
    });

    test('提示词包含画像、排除清单与本轮反馈', () async {
      await insertPlayed('旧歌', '老歌手');
      llm.response = jsonEncode({
        'songs': [
          {'title': '新歌', 'artist': '新人', 'reason': 'x'},
        ],
      });
      service = buildService([
        _FakeSource('wy', [_track('a', '新歌', '新人')]),
      ]);

      await service.generate(
        config: config,
        count: 20,
        skippedLabels: const ['跳过歌 - 某'],
        likedLabels: const ['收藏歌 - 某'],
      );

      final prompt = llm.lastUserPrompt!;
      expect(prompt, contains('"alreadyListened"'));
      expect(prompt, contains('旧歌 - 老歌手'));
      expect(prompt, contains('请推荐 20 首'));
      expect(prompt, contains('跳过歌'));
      expect(prompt, contains('收藏歌'));
    });
  });

  group('parseRecommendations 容错解析', () {
    test('JSON 前后夹带文字 / 代码块也能解析', () {
      final parsed = AiRecommendationService.parseRecommendations(
        '好的，这是推荐：\n```json\n{"songs":[{"title":"A","artist":"B"}]}\n```',
      );
      expect(parsed.single.title, 'A');
      expect(parsed.single.artist, 'B');
    });

    test('裸数组与字符串条目', () {
      final parsed = AiRecommendationService.parseRecommendations(
        '[{"song":"歌名","singer":"歌手"}, "另一首"]',
      );
      expect(parsed.map((r) => r.title), ['歌名', '另一首']);
      expect(parsed.first.artist, '歌手');
      expect(parsed.first.reason, '');
    });

    test('去重空标题、截断上限', () {
      final parsed = AiRecommendationService.parseRecommendations(
        '{"songs":[{"title":""},{"title":"a"},{"title":"b"},{"title":"c"}]}',
        limit: 2,
      );
      expect(parsed.map((r) => r.title), ['a', 'b']);
    });
  });

  group('pickBestMatch 打分', () {
    test('标题精确 + 艺人互含 → 命中', () {
      final match = AiRecommendationService.pickBestMatch(
        const AiRecommendation(title: '晴天', artist: '周杰伦'),
        [_track('a', '晴天', '周杰伦 (Jay Chou)')],
      );
      expect(match?.id.id, 'a');
    });

    test('标题精确、艺人不同 → 仍命中（0.6 阈值）', () {
      final match = AiRecommendationService.pickBestMatch(
        const AiRecommendation(title: '晴天', artist: '别人'),
        [_track('a', '晴天', '周杰伦')],
      );
      expect(match?.id.id, 'a');
    });

    test('仅标题部分包含 → 不命中', () {
      final match = AiRecommendationService.pickBestMatch(
        const AiRecommendation(title: '晴天', artist: ''),
        [_track('a', '晴天霹雳', '未知')],
      );
      expect(match, isNull);
    });

    test('标题为空 → null', () {
      expect(
        AiRecommendationService.pickBestMatch(
          const AiRecommendation(title: '  '),
          [_track('a', '晴天', '周杰伦')],
        ),
        isNull,
      );
    });
  });
}
