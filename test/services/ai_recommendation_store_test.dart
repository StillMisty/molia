import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/ai_dj.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/services/ai/ai_recommendation_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 待播批次持久化：往返、损坏降级、清空。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late AiRecommendationStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    store = AiRecommendationStore(preferences: prefs);
  });

  AiDjBatch batch() => AiDjBatch(
        items: [
          ResolvedRecommendation(
            source: const AiRecommendation(
              title: '夜航',
              artist: '林晚舟',
              reason: '你常听这个风格',
            ),
            track: Track(
              id: const TrackId('wy', '42'),
              title: '夜航',
              artists: const [Artist(name: '林晚舟')],
              album: '专辑',
              duration: const Duration(seconds: 240),
              origin: TrackOrigin.builtin,
              payload: const {'songmid': '42', 'qualitys': []},
            ),
          ),
        ],
        unresolved: const [AiRecommendation(title: '找不到的歌', artist: 'X')],
        generatedAt: DateTime.fromMillisecondsSinceEpoch(1000000),
      );

  test('保存 / 读取往返：曲目元数据、raw、未解析项与时间戳', () async {
    await store.save(batch());

    final stored = await store.load();

    expect(stored, isNotNull);
    expect(stored!.items, hasLength(1));
    final item = stored.items.single;
    expect(item.sourceKey, 'wy');
    expect(item.songId, '42');
    expect(item.title, '夜航');
    expect(item.artist, '林晚舟');
    expect(item.reason, '你常听这个风格');
    expect(item.durationMs, 240000);
    expect(item.raw['songmid'], '42');
    expect(stored.unresolved.single.title, '找不到的歌');
    expect(stored.generatedAt.millisecondsSinceEpoch, 1000000);
  });

  test('损坏数据降级为无缓存', () async {
    await prefs.setString(AiRecommendationStore.storageKey, 'not-json{{{');
    expect(await store.load(), isNull);

    await prefs.setString(AiRecommendationStore.storageKey, '{"items":[]}');
    expect(await store.load(), isNull);
  });

  test('clear 后无缓存', () async {
    await store.save(batch());
    expect(await store.load(), isNotNull);

    await store.clear();

    expect(await store.load(), isNull);
  });
}
