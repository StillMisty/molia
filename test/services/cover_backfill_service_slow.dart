import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/services/covers/cover_backfill_service.dart';

/// 封面补取：本渠道原生 → 本渠道名字搜索 → 跨渠道严格匹配。
void main() {
  Track track({
    String sourceKey = 'tx',
    String id = '1',
    String title = '晴天',
    String artist = '周杰伦',
    Duration? duration = const Duration(seconds: 269),
  }) => Track(
    id: TrackId(sourceKey, id),
    title: title,
    artists: [Artist(name: artist)],
    duration: duration,
    origin: TrackOrigin.builtin,
    payload: {'songmid': id},
  );

  Track candidate({
    String sourceKey = 'tx',
    required String id,
    String title = '晴天',
    String artist = '周杰伦',
    Duration? duration = const Duration(seconds: 269),
    String cover = 'https://img.example/cover.jpg',
  }) => Track(
    id: TrackId(sourceKey, id),
    title: title,
    artists: [Artist(name: artist)],
    duration: duration,
    artwork: Artwork(uri: Uri.parse(cover)),
    origin: TrackOrigin.builtin,
    payload: {'songmid': id},
  );

  test('原生取图命中：不发起跨渠道搜索', () async {
    final calls = <String>[];
    final service = CoverBackfillService(
      nativeLoader: (_) async => 'https://img.example/native.jpg',
      searchChannel: (key, keyword) async {
        calls.add(key);
        return const [];
      },
      isChannelEnabled: (_) => true,
    );

    expect(await service.fetch(track()), 'https://img.example/native.jpg');
    expect(calls, isEmpty);
  });

  test('原生失败：本渠道名字搜索优先（其它渠道更快也让位）', () async {
    final calls = <String>[];
    final service = CoverBackfillService(
      nativeLoader: (_) async => null,
      searchChannel: (key, keyword) async {
        calls.add(key);
        if (key == 'tx') {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return [candidate(sourceKey: 'tx', id: 'tx1', cover: 'tx-cover')];
        }
        return [candidate(sourceKey: key, id: '$key-1', cover: '$key-cover')];
      },
      isChannelEnabled: (_) => true,
      sameSourceTimeout: const Duration(milliseconds: 100),
    );

    expect(await service.fetch(track()), 'tx-cover');
    expect(calls, containsAll(['tx', 'wy']));
  });

  test('本渠道无结果：其它音乐平台严格匹配兜底', () async {
    final service = CoverBackfillService(
      nativeLoader: (_) async => null,
      searchChannel: (key, keyword) async {
        if (key == 'wy') {
          return [candidate(sourceKey: 'wy', id: 'wy1', cover: 'wy-cover')];
        }
        return const [];
      },
      isChannelEnabled: (key) => key == 'tx' || key == 'wy',
      sameSourceTimeout: const Duration(milliseconds: 20),
    );

    expect(await service.fetch(track()), 'wy-cover');
  });

  test('严格匹配：单条候选是别的歌也不采用', () async {
    final service = CoverBackfillService(
      nativeLoader: (_) async => null,
      searchChannel: (key, keyword) async => [
        candidate(
          sourceKey: 'tx',
          id: 'other',
          title: '完全不同的歌',
          artist: '别人',
          duration: const Duration(seconds: 10),
        ),
      ],
      isChannelEnabled: (key) => key == 'tx',
      sameSourceTimeout: const Duration(milliseconds: 20),
    );

    expect(await service.fetch(track()), isNull);
  });

  test('渠道停用：不发起该渠道搜索', () async {
    final calls = <String>[];
    final service = CoverBackfillService(
      nativeLoader: (_) async => null,
      searchChannel: (key, keyword) async {
        calls.add(key);
        return [candidate(sourceKey: key, id: '$key-1')];
      },
      isChannelEnabled: (_) => false,
    );

    expect(await service.fetch(track()), isNull);
    expect(calls, isEmpty);
  });

  test('本地曲目：只走原生，不跨渠道触网', () async {
    final calls = <String>[];
    final service = CoverBackfillService(
      nativeLoader: (_) async => null,
      searchChannel: (key, keyword) async {
        calls.add(key);
        return [candidate(sourceKey: key, id: '$key-1')];
      },
      isChannelEnabled: (_) => true,
    );

    expect(await service.fetch(track(sourceKey: 'local')), isNull);
    expect(calls, isEmpty);
  });

  test('allowCrossChannel=false：只走原生', () async {
    final calls = <String>[];
    final service = CoverBackfillService(
      nativeLoader: (_) async => null,
      searchChannel: (key, keyword) async {
        calls.add(key);
        return [candidate(sourceKey: key, id: '$key-1')];
      },
      isChannelEnabled: (_) => true,
    );

    expect(await service.fetch(track(), allowCrossChannel: false), isNull);
    expect(calls, isEmpty);
  });

  test('正结果缓存：同曲目第二次不再搜索', () async {
    var searches = 0;
    final service = CoverBackfillService(
      nativeLoader: (_) async => null,
      searchChannel: (key, keyword) async {
        searches++;
        return [candidate(sourceKey: key, id: '$key-1', cover: '$key-cover')];
      },
      isChannelEnabled: (key) => key == 'tx',
      sameSourceTimeout: const Duration(milliseconds: 20),
    );

    final target = track();
    expect(await service.fetch(target), 'tx-cover');
    expect(await service.fetch(target), 'tx-cover');
    expect(searches, 1);
  });

  test('keywordOf：使用调用方给的搜索关键词', () async {
    String? seen;
    final service = CoverBackfillService(
      nativeLoader: (_) async => null,
      searchChannel: (key, keyword) async {
        seen = keyword;
        return [candidate(sourceKey: key, id: '$key-1')];
      },
      isChannelEnabled: (key) => key == 'tx',
      keywordOf: (track) => 'custom keyword',
      sameSourceTimeout: const Duration(milliseconds: 20),
    );

    await service.fetch(track());
    expect(seen, 'custom keyword');
  });
}
