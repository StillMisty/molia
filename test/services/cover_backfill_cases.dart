import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/services/covers/cover_backfill_service.dart';

/// 封面补取：结果缓存释放（托盘隐藏 / 系统低内存）的幂等性。
void main() {
  Track track() => const Track(
    id: TrackId('wy', '1'),
    title: '测试歌曲',
    artists: [Artist(name: '歌手')],
    origin: TrackOrigin.builtin,
  );

  test('clearCache：清空后重新补取，重复调用安全', () async {
    var calls = 0;
    final service = CoverBackfillService(
      nativeLoader: (track) async {
        calls++;
        return 'https://cover.example/$calls.jpg';
      },
      searchChannel: (channelKey, keyword) async => const [],
      isChannelEnabled: (_) => false,
      keywordOf: (track) => track.title,
    );
    final song = track();

    expect(
      await service.fetch(song, allowCrossChannel: false),
      'https://cover.example/1.jpg',
    );
    expect(
      await service.fetch(song, allowCrossChannel: false),
      'https://cover.example/1.jpg',
      reason: '正结果命中缓存',
    );
    expect(calls, 1);

    service
      ..clearCache()
      ..clearCache();
    expect(
      await service.fetch(song, allowCrossChannel: false),
      'https://cover.example/2.jpg',
      reason: '清空后重新补取',
    );
    expect(calls, 2);
  });
}
