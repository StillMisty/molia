import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/catalog_service.dart';
import 'package:molia/data/molia_database.dart';
import 'package:molia/data/play_statistics_repository.dart';
import 'package:molia/domain/models/ai_dj.dart';
import 'package:molia/domain/models/catalog.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/library.dart';
import 'package:molia/domain/models/source.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/domain/ports/music_source.dart';
import 'package:molia/domain/ports/source_registry.dart';
import 'package:molia/services/ai/ai_prompt_text.dart';
import 'package:molia/services/ai/ai_recommendation_service.dart';
import 'package:molia/services/ai/llm_client.dart';
import 'package:molia/services/ai/taste_profile_builder.dart';

import '../support/fake_library_repository.dart';
import '../support/memory_database.dart';
import '../support/sync_test_support.dart';

/// 假 LLM：直接返回预置文本（不触碰网络）。
class _FakeLlm extends LlmClient {
  _FakeLlm(this.response);

  String response;
  Object? error;
  String? lastUserPrompt;
  String? lastSystemPrompt;
  bool? lastJsonMode;
  int calls = 0;

  @override
  Future<String> complete({
    required LlmConfig config,
    required String systemPrompt,
    required String userPrompt,
    double temperature = 0.8,
    int maxTokens = 4096,
    bool jsonMode = false,
  }) async {
    calls++;
    lastUserPrompt = userPrompt;
    lastSystemPrompt = systemPrompt;
    lastJsonMode = jsonMode;
    final failure = error;
    if (failure != null) throw failure;
    return response;
  }
}

/// 假音源：search 返回固定结果（其余成员不会被调用）。
class _FakeSource implements MusicSource {
  _FakeSource(
    this.key,
    this.results, {
    String? displayName,
    this.searchGate,
  }) : displayName = displayName ?? key;

  @override
  final String key;

  @override
  final String displayName;

  final List<Track> results;

  /// 测试用闸门：非空时 search 等待其完成后再返回（模拟慢音源）。
  final Completer<void>? searchGate;

  String? artworkUrl;
  int artworkCalls = 0;
  int searchCalls = 0;

  @override
  Future<Artwork?> artwork(Track track) async {
    artworkCalls++;
    final url = artworkUrl;
    return url == null ? null : Artwork(uri: Uri.parse(url));
  }

  @override
  SourceCapabilities get capabilities => const SourceCapabilities(search: true);

  @override
  Future<SearchResult<Track>> search(SearchQuery query,
      {CancelToken? cancel}) async {
    searchCalls++;
    final gate = searchGate;
    if (gate != null) await gate.future;
    return SearchResult(items: results);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRegistry implements SourceRegistry {
  _FakeRegistry(List<({MusicSource source, int order, bool enabled})> entries)
      : _entries = entries;

  final List<({MusicSource source, int order, bool enabled})> _entries;

  @override
  List<SourceDescriptor> get descriptors => [
        for (final entry in _entries)
          SourceDescriptor(
            key: entry.source.key,
            displayName: entry.source.displayName,
            kind: SourceKind.builtin,
            capabilities: entry.source.capabilities,
            enabled: entry.enabled,
            order: entry.order,
          ),
      ];

  @override
  MusicSource? byKey(String key) {
    for (final entry in _entries) {
      if (entry.source.key == key) return entry.source;
    }
    return null;
  }

  @override
  Set<String> get enabledChannelKeys => {
        for (final entry in _entries)
          if (entry.enabled) entry.source.key,
      };

  @override
  MusicSource? forTrack(Track track) => byKey(track.id.sourceKey);

  @override
  Future<void> refresh() async {}

  @override
  Future<void> setOrder(List<String> keys) async {}

  @override
  Stream<void> get changes => const Stream.empty();
}

Track _track(
  String id,
  String title,
  String artist, {
  String source = 'wy',
  Map<String, dynamic> raw = const {},
}) =>
    Track(
      id: TrackId(source, id),
      title: title,
      artists: [Artist(name: artist)],
      duration: const Duration(minutes: 4),
      origin: TrackOrigin.builtin,
      payload: raw,
    );

/// 提示词里是否存在某个数据段（避免把 [要求] 里引用的段名误判成数据）。
bool _hasSection(String prompt, String label) =>
    prompt.split('\n').any((line) => line.startsWith('$label '));

/// 轮询等待条件成立（真实计时器场景用；超时直接失败，避免挂住测试）。
Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(reason ?? '等待条件超时');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MoliaDatabase db;
  late PlayStatisticsRepository statistics;
  late FakeLibraryRepository library;
  late _FakeLlm llm;
  late AiRecommendationService service;

  const config = LlmConfig(
    baseUrl: 'https://api.example.com/v1',
    apiKey: 'sk-test',
    model: 'm',
  );

  Future<void> insertPlayed(
    String title,
    String artist, {
    int startedAt = 1000,
  }) async {
    await insertPlayEvent(
      db,
      songId: '$title-$artist',
      title: title,
      artist: artist,
      durationMs: 200000,
      raw: const {},
      startedAt: startedAt,
      endedAt: startedAt + 200000,
      listenedMs: 150000,
      maxPositionMs: 190000,
      endReason: 'completed',
    );
  }

  AiRecommendationService buildService(
    List<_FakeSource> sources, {
    Map<String, ({int order, bool enabled})> config = const {},
    int resolveConcurrency = 3,
    Duration resolveHedgeDelay = const Duration(milliseconds: 250),
    AiPromptLanguage Function()? promptLanguage,
  }) {
    final registry = _FakeRegistry([
      for (final source in sources)
        (
          source: source,
          order: config[source.key]?.order ?? 0,
          enabled: config[source.key]?.enabled ?? true,
        ),
    ]);
    return AiRecommendationService(
      llm: llm,
      catalog: CatalogService(registry: registry),
      registry: registry,
      profileBuilder: TasteProfileBuilder(
        repository: statistics,
        libraryStore: library,
      ),
      resolveConcurrency: resolveConcurrency,
      resolveHedgeDelay: resolveHedgeDelay,
      promptLanguage: promptLanguage,
    );
  }

  Future<void> addFavorite(String title, String artist) async {
    await library.toggleFavorite(
      sourceKey: 'wy',
      songId: 'fav-$title',
      title: title,
      artist: artist,
      raw: const {'songmid': 'secret-raw'},
    );
  }

  Future<void> createPlaylist(
      String name, List<(String, String)> tracks) async {
    final id = await library.createPlaylist(name);
    for (final (title, artist) in tracks) {
      await library.addTrackToPlaylist(
        id,
        PlaylistTrack(
          playlistId: id,
          sourceKey: 'wy',
          songId: 'pl-$name-$title',
          title: title,
          artist: artist,
          raw: const {'songmid': 'secret-raw'},
          addedAt: 1,
        ),
      );
    }
  }

  setUp(() async {
    db = openMemoryDatabase();
    statistics = PlayStatisticsRepository(
      databaseProvider: () => db,
      statisticsSync: testStatisticsSyncStore(() => db),
    );
    library = FakeLibraryRepository();
    llm = _FakeLlm('{}');
    service = buildService(const []);
  });

  tearDown(() async {
    await statistics.dispose();
    await library.dispose();
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
      expect(batch.items.single.sourceName, 'wy');
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
      expect(llm.lastUserPrompt, contains('[本批排除]'));
      expect(llm.lastUserPrompt, contains('已在该列表'));
    });

    test('summarizeUpstream 统计发送范围（含收藏 / 歌单）', () async {
      await insertPlayed('晴天', '周杰伦');
      await addFavorite('收藏歌', '收藏人');
      await createPlaylist('通勤', [('歌单一', '歌手一'), ('歌单二', '歌手二')]);

      final summary = await service.summarizeUpstream(
        preferences: const AiPreferences(
          sections: {
            ...kAiDefaultUpstreamSections,
            AiUpstreamSection.favorites,
            AiUpstreamSection.playlists,
          },
        ),
      );

      expect(summary.recentEvents, 1);
      expect(summary.favorites, 1);
      expect(summary.playlists, 2);
    });
  });

  group('发送范围与提示词', () {
    test('默认不发送收藏 / 歌单；开启后只发歌名、歌手与歌单名', () async {
      await addFavorite('收藏歌', '收藏人');
      await createPlaylist('通勤', [('歌单一', '歌手一')]);
      llm.response = jsonEncode({
        'songs': [
          {'title': '新歌', 'artist': '新人'},
        ],
      });

      final previewDefault = await service.buildPromptPreview(
        count: 20,
      );
      expect(_hasSection(previewDefault.userPrompt, '[收藏]'), isFalse);
      expect(_hasSection(previewDefault.userPrompt, '[歌单]'), isFalse);
      expect(previewDefault.userPrompt, isNot(contains('收藏歌')));

      const preferences = AiPreferences(
        sections: {
          ...kAiDefaultUpstreamSections,
          AiUpstreamSection.favorites,
          AiUpstreamSection.playlists,
        },
      );
      await service.buildPromptPreview(
        count: 20,
        preferences: preferences,
      );

      final prompt = llm.lastUserPrompt;
      expect(prompt, isNull, reason: '预览不触发 LLM 调用');
      final preview = await service.buildPromptPreview(
        count: 20,
        preferences: preferences,
      );
      expect(_hasSection(preview.userPrompt, '[收藏]'), isTrue);
      expect(preview.userPrompt, contains('收藏歌'));
      expect(preview.userPrompt, contains('收藏人'));
      expect(_hasSection(preview.userPrompt, '[歌单]'), isTrue);
      expect(preview.userPrompt, contains('通勤'));
      expect(preview.userPrompt, contains('歌单一'));
      expect(preview.userPrompt, isNot(contains('secret-raw')));
      expect(preview.userPrompt, isNot(contains('cover')));
    });

    test('关闭提交范围后对应字段从 prompt 消失；全部关闭仍可仅按偏好生成', () async {
      const preferences = AiPreferences(
        styles: ['pop'],
        scenes: ['commute'],
        languages: ['mandarin'],
        era: kAiEra2010s,
        exploration: kAiExplorationSurprise,
        extraPrompt: '女声优先',
        sections: {},
      );

      final prompt = await service.buildPromptPreview(
        count: 30,
        preferences: preferences,
      );

      for (final label in [
        '[摘要]',
        '[常听歌手]',
        '[常听歌曲]',
        '[常听时段]',
        '[收听来源]',
        '[最近播放]',
        '[已听过]',
        '[收藏]',
        '[歌单]',
      ]) {
        expect(
          _hasSection(prompt.userPrompt, label),
          isFalse,
          reason: '关闭的范围不应发送 $label 数据段',
        );
      }
      expect(prompt.userPrompt, contains('流行'));
      expect(prompt.userPrompt, contains('通勤'));
      expect(prompt.userPrompt, contains('华语'));
      expect(prompt.userPrompt, contains('2010s'));
      expect(prompt.userPrompt, contains('惊喜'));
      expect(prompt.userPrompt, contains('女声优先'));
      expect(prompt.userPrompt, contains('请推荐 30 首'));
      expect(prompt.userPrompt, contains('[偏好]'));
    });

    test('只推荐没听过的关闭、排除清单开启：仍发送已听清单但不本地强制过滤', () async {
      await insertPlayed('旧歌', '老歌手');
      llm.response = jsonEncode({
        'songs': [
          {'title': '旧歌', 'artist': '老歌手'},
        ],
      });
      service = buildService([
        _FakeSource('wy', [_track('a', '旧歌', '老歌手')]),
      ]);
      final preferences = AiPreferences.defaults.copyWith(
        onlyUnheard: false,
      );
      final preview = await service.buildPromptPreview(
        count: 20,
        preferences: preferences,
      );
      final batch = await service.generate(
        config: config,
        count: 20,
        preferences: preferences,
      );

      expect(_hasSection(preview.userPrompt, '[已听过]'), isTrue);
      expect(preview.userPrompt, contains('旧歌 - 老歌手'));
      expect(batch.items, hasLength(1), reason: '关闭后不本地强制排除');
    });

    test('只推荐没听过的开启、排除清单关闭：本地过滤生效但不发送清单', () async {
      await insertPlayed('晴天', '周杰伦');
      llm.response = jsonEncode({
        'songs': [
          {'title': '晴天', 'artist': '周杰伦'},
        ],
      });
      service = buildService([
        _FakeSource('wy', [_track('a', '晴天', '周杰伦')]),
      ]);
      final preferences = AiPreferences.defaults.copyWith(
        sections: {
          for (final section in AiPreferences.defaults.sections)
            if (section != AiUpstreamSection.listenedExclusions) section,
        },
      );

      final preview = await service.buildPromptPreview(
        count: 20,
        preferences: preferences,
      );
      final batch = await service.generate(
        config: config,
        count: 20,
        preferences: preferences,
      );

      expect(_hasSection(preview.userPrompt, '[已听过]'), isFalse);
      expect(batch.items, isEmpty, reason: '本地仍排除已听曲目');
    });

    test('收藏歌曲进入本地排除集合（即使只勾选收藏）', () async {
      await addFavorite('晴天', '周杰伦');
      llm.response = jsonEncode({
        'songs': [
          {'title': '晴天', 'artist': '周杰伦'},
        ],
      });
      service = buildService([
        _FakeSource('wy', [_track('a', '晴天', '周杰伦')]),
      ]);

      final batch = await service.generate(
        config: config,
        count: 20,
        preferences: const AiPreferences(
          sections: {AiUpstreamSection.favorites},
        ),
      );

      expect(batch.items, isEmpty);
      expect(batch.unresolved, isEmpty);
    });

    test('预览与实际请求共用同一份 userPrompt', () async {
      await insertPlayed('旧歌', '老歌手');
      const preferences = AiPreferences(styles: ['jazz'], batchSize: 30);
      llm.response = jsonEncode({
        'songs': [
          {'title': '新歌', 'artist': '新人'},
        ],
      });
      service = buildService([
        _FakeSource('wy', [_track('a', '新歌', '新人')]),
      ]);
      const skipped = ['跳过歌 - 某'];
      const liked = ['收藏歌 - 某'];
      const excluded = ['已有 - 某'];

      final preview = await service.buildPromptPreview(
        count: preferences.batchSize,
        preferences: preferences,
        skippedLabels: skipped,
        likedLabels: liked,
        excludeLabels: excluded,
      );
      final batch = await service.generate(
        config: config,
        count: preferences.batchSize,
        preferences: preferences,
        skippedLabels: skipped,
        likedLabels: liked,
        excludeLabels: excluded,
      );

      expect(llm.lastUserPrompt, preview.userPrompt);
      expect(batch.prompt, preview);
      expect(batch.rawResponse, llm.response);
    });

    test('种子进入反馈段落', () async {
      final prompt = await service.buildPromptPreview(
        count: 20,
        preferences: const AiPreferences(seeds: ['晴天 - 周杰伦']),
      );
      expect(prompt.userPrompt, contains('多来点这种'));
      expect(prompt.userPrompt, contains('晴天 - 周杰伦'));
    });

    test('最近播放只发 50 条；已听清单只发 100 但本地仍排除全部', () async {
      for (var i = 0; i < 150; i++) {
        await insertPlayed('旧歌$i', '歌手$i', startedAt: 1000 + i);
      }

      final preview = await service.buildPromptPreview(count: 10);
      String lineOf(String label) => preview.userPrompt.split('\n').firstWhere(
            (line) => line.startsWith('$label '),
            orElse: () => '',
          );
      final recentLine = lineOf('[最近播放]');
      final heardLine = lineOf('[已听过]');
      expect(RegExp(' - ').allMatches(recentLine).length, 50);
      expect(RegExp(' - ').allMatches(heardLine).length, 100);
      expect(preview.userPrompt, contains('旧歌149 - 歌手149'));
      expect(preview.userPrompt, isNot(contains('旧歌0 - 歌手0')));

      final summary = await service.summarizeUpstream();
      expect(summary.exclusions, 100);

      llm.response = jsonEncode({
        'songs': [
          {'title': '旧歌0', 'artist': '歌手0'},
        ],
      });
      service = buildService([
        _FakeSource('wy', [_track('a', '旧歌0', '歌手0')]),
      ]);
      final batch = await service.generate(config: config, count: 10);
      expect(batch.items, isEmpty, reason: '本地 500 键仍排除旧歌0');
    });

    test('提示词跟随应用语言：英文模式切换整段文案', () async {
      service = buildService(
        [_FakeSource('wy', const [])],
        promptLanguage: () => AiPromptLanguage.en,
      );
      final prompt = await service.buildPromptPreview(
        count: 7,
        preferences: const AiPreferences(
          styles: ['pop'],
          onlyUnheard: false,
        ),
      );

      expect(prompt.systemPrompt, contains('music recommendation assistant'));
      expect(prompt.userPrompt, contains('[Preferences]'));
      expect(prompt.userPrompt, contains('styles pop'));
      expect(prompt.userPrompt, contains('repeats allowed'));
      expect(prompt.userPrompt, contains('[Requirements]'));
      expect(prompt.userPrompt, contains('[Output JSON]'));
      expect(prompt.userPrompt, contains('max 60 characters'));
      expect(prompt.userPrompt, contains('Recommend 7 songs.'));
      expect(prompt.userPrompt, isNot(contains('[偏好]')));
      expect(prompt.userPrompt, isNot(contains('请推荐')));
    });

    test('system 极简；user 末尾保留 JSON 样例与要求', () async {
      final prompt = await service.buildPromptPreview(count: 10);

      expect(
        prompt.systemPrompt,
        '你是音乐推荐助手。根据用户提供的听歌数据，推荐其可能喜欢的歌曲。',
      );
      expect(prompt.userPrompt, contains('[要求]'));
      expect(prompt.userPrompt, contains('[输出 JSON]'));
      expect(prompt.userPrompt, contains('{"songs"'));
      expect(prompt.userPrompt, isNot(contains('Markdown')));
    });

    test('可用渠道写入要求行，减少本地搜不到的推荐', () async {
      service = buildService([
        _FakeSource('wy', const [], displayName: '网易云音乐'),
        _FakeSource('tx', const [], displayName: 'QQ音乐'),
      ]);

      final prompt = await service.buildPromptPreview(count: 10);

      expect(prompt.userPrompt, contains('可用渠道：网易云音乐/QQ音乐'));
    });

    test('额外排除键在本地兜底过滤（即使模型返回同一首）', () async {
      llm.response = jsonEncode({
        'songs': [
          {'title': '晴天', 'artist': '周杰伦'},
          {'title': '新歌', 'artist': '新人'},
        ],
      });
      service = buildService([
        _FakeSource('wy', [
          _track('a', '晴天', '周杰伦'),
          _track('b', '新歌', '新人'),
        ]),
      ]);

      final batch = await service.generate(
        config: config,
        count: 10,
        excludeLabels: const ['晴天 - 周杰伦'],
        excludeKeys: const ['晴天|周杰伦'],
      );

      expect(batch.items.map((item) => item.track.title), ['新歌']);
      expect(batch.unresolved, isEmpty);
    });
  });

  group('找歌渠道', () {
    test('按音源页顺序遍历全部可搜索渠道，首个命中即停止', () async {
      final s1 = _FakeSource('s1', [_track('a', '歌', '手', source: 's1')]);
      final s2 = _FakeSource('s2', const []);
      final s3 = _FakeSource('s3', [_track('a', '歌', '手', source: 's3')]);
      final s4 = _FakeSource('s4', const []);
      service = buildService(
        [s1, s2, s3, s4],
        config: {
          's1': (order: 4, enabled: true),
          's2': (order: 1, enabled: true),
          's3': (order: 3, enabled: true),
          's4': (order: 2, enabled: true),
        },
      );
      llm.response = jsonEncode({
        'songs': [
          {'title': '歌', 'artist': '手'},
        ],
      });

      final batch = await service.generate(config: config, count: 10);

      expect(batch.items.single.track.id.sourceKey, 's3');
      expect(s2.searchCalls, 1);
      expect(s4.searchCalls, 1);
      expect(s3.searchCalls, 1);
      expect(s1.searchCalls, 0, reason: '命中后不再尝试后续渠道');
    });

    test('前 3 个渠道都没有结果时继续尝试后续渠道（不限制数量）', () async {
      final s1 = _FakeSource('s1', const []);
      final s2 = _FakeSource('s2', const []);
      final s3 = _FakeSource('s3', const []);
      final s4 = _FakeSource('s4', [_track('a', '歌', '手', source: 's4')]);
      service = buildService(
        [s1, s2, s3, s4],
        config: {
          's1': (order: 1, enabled: true),
          's2': (order: 2, enabled: true),
          's3': (order: 3, enabled: true),
          's4': (order: 4, enabled: true),
        },
      );
      llm.response = jsonEncode({
        'songs': [
          {'title': '歌', 'artist': '手'},
        ],
      });

      final batch = await service.generate(config: config, count: 10);

      expect(batch.items.single.track.id.sourceKey, 's4');
      expect(s1.searchCalls, 1);
      expect(s2.searchCalls, 1);
      expect(s3.searchCalls, 1);
      expect(s4.searchCalls, 1);
    });

    test('先序源立即命中：不启动后序源（对冲计时器不改变原有行为）', () async {
      final s1 = _FakeSource('s1', [_track('a', '歌', '手', source: 's1')]);
      final s2 = _FakeSource('s2', [_track('a', '歌', '手', source: 's2')]);
      service = buildService(
        [s1, s2],
        resolveHedgeDelay: const Duration(milliseconds: 50),
      );
      llm.response = jsonEncode({
        'songs': [
          {'title': '歌', 'artist': '手'},
        ],
      });

      final batch = await service.generate(config: config, count: 10);

      expect(batch.items.single.track.id.sourceKey, 's1');
      expect(s1.searchCalls, 1);
      expect(s2.searchCalls, 0, reason: '先序命中后不再启动后续渠道');
    });

    test('慢源对冲：后序源先返回也不抢先序源最终命中', () async {
      final slowGate = Completer<void>();
      final slow = _FakeSource(
        's1',
        [_track('a', '歌', '手', source: 's1')],
        searchGate: slowGate,
      );
      final fast = _FakeSource('s2', [_track('a', '歌', '手', source: 's2')]);
      service = buildService(
        [slow, fast],
        resolveHedgeDelay: const Duration(milliseconds: 100),
      );
      llm.response = jsonEncode({
        'songs': [
          {'title': '歌', 'artist': '手'},
        ],
      });

      final pending = service.generate(config: config, count: 10);
      await _waitUntil(() => slow.searchCalls == 1);
      expect(fast.searchCalls, 0, reason: '对冲延时未到，不提前启动后序源');
      await _waitUntil(
        () => fast.searchCalls == 1,
        reason: '先序源超过对冲延时未返回，应启动后序源',
      );

      slowGate.complete();
      final batch = await pending;

      expect(
        batch.items.single.track.id.sourceKey,
        's1',
        reason: '后序源先返回也只算候选；先序源最终命中必须优先',
      );
    });

    test('后序源命中需等先序源确认未命中后才采用', () async {
      final slowGate = Completer<void>();
      final slow = _FakeSource('s1', const [], searchGate: slowGate);
      final fast = _FakeSource('s2', [_track('a', '歌', '手', source: 's2')]);
      final later = _FakeSource('s3', [_track('a', '歌', '手', source: 's3')]);
      service = buildService(
        [slow, fast, later],
        resolveHedgeDelay: const Duration(milliseconds: 20),
      );
      llm.response = jsonEncode({
        'songs': [
          {'title': '歌', 'artist': '手'},
        ],
      });

      var done = false;
      final pending =
          service.generate(config: config, count: 10).whenComplete(() {
        done = true;
      });
      await _waitUntil(() => fast.searchCalls == 1);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(done, isFalse, reason: '先序源仍在途，后序命中不能提前返回');

      slowGate.complete();
      final batch = await pending;

      expect(
        batch.items.single.track.id.sourceKey,
        's2',
        reason: '先序源最终无命中后，采用后序源命中',
      );
      expect(later.searchCalls, 0, reason: '已有候选命中，不再浪费后续请求');
    });

    test('停用渠道不参与解析', () async {
      final s1 = _FakeSource('s1', [_track('a', '歌', '手', source: 's1')]);
      final s2 = _FakeSource('s2', [_track('a', '歌', '手', source: 's2')]);
      service = buildService(
        [s1, s2],
        config: {
          's1': (order: 1, enabled: false),
          's2': (order: 2, enabled: true),
        },
      );
      llm.response = jsonEncode({
        'songs': [
          {'title': '歌', 'artist': '手'},
        ],
      });

      final batch = await service.generate(config: config, count: 10);

      expect(batch.items.single.track.id.sourceKey, 's2');
      expect(s1.searchCalls, 0);
      expect(s2.searchCalls, 1);
    });
  });

  group('进度 / 取消 / 未解析重试', () {
    test('进度阶段依次 profile → model → resolving，done 单调递增', () async {
      final progresses = <AiDjProgress>[];
      llm.response = jsonEncode({
        'songs': [
          {'title': '歌一', 'artist': '手'},
          {'title': '歌二', 'artist': '手'},
        ],
      });
      service = buildService(
        [
          _FakeSource('wy', [
            _track('a', '歌一', '手'),
            _track('b', '歌二', '手'),
          ]),
        ],
        resolveConcurrency: 1,
      );

      await service.generate(
        config: config,
        count: 2,
        onProgress: progresses.add,
      );

      expect(
        progresses.map((progress) => progress.phase).toSet(),
        {AiDjPhase.profile, AiDjPhase.model, AiDjPhase.resolving},
      );
      expect(progresses.first.phase, AiDjPhase.profile);
      expect(progresses[1].phase, AiDjPhase.model);
      final resolving = [
        for (final progress in progresses)
          if (progress.phase == AiDjPhase.resolving) progress,
      ];
      expect(resolving.first.done, 0);
      expect(resolving.map((progress) => progress.done).toList(), [0, 1, 2]);
      expect(resolving.every((progress) => progress.total == 2), isTrue);
      expect(resolving.first.fraction, 0);
      expect(resolving.last.fraction, 1);
      expect(progresses[1].fraction, isNull);
    });

    test('取消令牌：抛 cancelled，不返回批次', () async {
      final token = AiGenerationCancelToken();
      llm.response = jsonEncode({
        'songs': [
          {'title': '歌', 'artist': '手'},
        ],
      });
      service = buildService([
        _FakeSource('wy', [_track('a', '歌', '手')]),
      ]);

      await expectLater(
        service.generate(
          config: config,
          count: 1,
          cancelToken: token,
          onProgress: (progress) {
            if (progress.phase == AiDjPhase.model) token.cancel();
          },
        ),
        throwsA(isA<SourceFailure>()
            .having((failure) => failure.kind, 'kind', FailureKind.cancelled)),
      );
      expect(llm.calls, 1, reason: '取消后不再继续解析');
    });

    test('未解析重试只重新搜索，不调用 LLM', () async {
      llm.response = jsonEncode({
        'songs': [
          {'title': '找不到', 'artist': '无人'},
        ],
      });
      service = buildService([_FakeSource('wy', const [])]);
      final first = await service.generate(config: config, count: 1);
      expect(first.unresolved, hasLength(1));
      expect(llm.calls, 1);

      service = buildService([
        _FakeSource('wy', [_track('a', '找不到', '无人')]),
      ]);
      final retried = await service.resolveUnresolved(batch: first);

      expect(retried.unresolved, isEmpty);
      expect(retried.items.single.track.id.id, 'a');
      expect(retried.id, first.id);
      expect(llm.calls, 1, reason: '重试不重新调 LLM');
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

    test('兼容 recommendations / data 包装与嵌套 items', () {
      final recommendations = AiRecommendationService.parseRecommendations(
        '{"recommendations":[{"title":"A","artist":"B"}]}',
      );
      expect(recommendations.single.title, 'A');

      final nested = AiRecommendationService.parseRecommendations(
        '{"data":{"items":[{"title":"C","artist":"D"}]}}',
      );
      expect(nested.single.title, 'C');
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
