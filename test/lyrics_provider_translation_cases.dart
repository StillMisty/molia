import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/providers/lyrics_provider.dart';
import 'package:molia/services/lyrics_service.dart';

import 'support/lyrics_test_support.dart';

/// 双语管道：翻译/罗马音按时间戳对齐到主行；手动选择清空扩展行。
void main() {
  Track track() => Track(
    id: TrackId('fake', '1'),
    title: '歌名',
    artists: const [Artist(name: '歌手')],
    origin: TrackOrigin.lx,
    payload: const {'id': '1'},
  );

  test('翻译/罗马音按时间戳对齐，缺失位置补空串', () async {
    final provider = buildLyricsProvider(
      _FakeLyricsService(
        const LyricsResult(
          lyric: '[00:01.00]第一行\n[00:05.00]第二行\n[00:10.00]第三行',
          translation: '[00:01.00]译一\n[00:05.00]译二',
          roma: '[00:05.00]roma2',
          provider: 'fake',
        ),
      ),
    );
    await provider.load(track());
    expect(provider.currentState.status, LyricsStatus.ready);
    expect(provider.currentState.lines.map((line) => line.text), [
      '第一行',
      '第二行',
      '第三行',
    ]);
    expect(provider.currentState.translations, ['译一', '译二', '']);
    expect(provider.currentState.romas, ['', 'roma2', '']);
  });

  test('同一时间戳多条翻译合并；无翻译时为空列表', () async {
    final merged = buildLyricsProvider(
      _FakeLyricsService(
        const LyricsResult(
          lyric: '[00:01.00]A',
          translation: '[00:01.00]译甲\n[00:01.00]译乙',
          provider: 'fake',
        ),
      ),
    );
    await merged.load(track());
    expect(merged.currentState.translations, ['译甲 译乙']);

    final none = buildLyricsProvider(
      _FakeLyricsService(
        const LyricsResult(lyric: '[00:01.00]A', provider: 'fake'),
      ),
    );
    await none.load(track());
    expect(none.currentState.translations, isEmpty);
    expect(none.currentState.romas, isEmpty);
  });

  test('未同步歌词的伪时间戳同样可对齐扩展行', () async {
    final provider = buildLyricsProvider(
      _FakeLyricsService(
        const LyricsResult(
          lyric: 'hello\nworld',
          translation: '你好\n世界',
          provider: 'fake',
        ),
      ),
    );
    await provider.load(track());
    expect(provider.currentState.isSynced, isFalse);
    expect(provider.currentState.translations, ['你好', '世界']);
  });

  test('手动选择歌词清空扩展行', () async {
    final provider = buildLyricsProvider(
      _FakeLyricsService(
        const LyricsResult(
          lyric: '[00:01.00]A',
          translation: '[00:01.00]译',
          provider: 'fake',
        ),
      ),
    );
    await provider.load(track());
    expect(provider.currentState.translations, ['译']);

    await provider.saveManual(
      trackId: 'fake:1',
      lyric: '[00:03.00]手动',
      providerName: 'qq',
    );
    expect(provider.currentState.providerName, 'qq');
    expect(provider.currentState.translations, isEmpty);
  });
}

class _FakeLyricsService extends LyricsService {
  _FakeLyricsService(this.result) : super(providers: const []);

  final LyricsResult? result;

  @override
  Future<LyricsResult?> getLyrics(
    String songName,
    String artistName,
    String trackId, {
    Track? track,
    bool ignoreCache = false,
  }) async => result;
}
