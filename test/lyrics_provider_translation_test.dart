import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/providers/lyrics_provider.dart';
import 'package:molia/services/lyrics_service.dart';

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
    final provider = LyricsProvider(
      service: _FakeLyricsService(
        const LyricsResult(
          lyric: '[00:01.00]第一行\n[00:05.00]第二行\n[00:10.00]第三行',
          translation: '[00:01.00]译一\n[00:05.00]译二',
          roma: '[00:05.00]roma2',
          provider: 'fake',
        ),
      ),
    );
    await provider.load(track());
    expect(provider.state.status, LyricsStatus.ready);
    expect(provider.state.lines.map((line) => line.text),
        ['第一行', '第二行', '第三行']);
    expect(provider.state.translations, ['译一', '译二', '']);
    expect(provider.state.romas, ['', 'roma2', '']);
  });

  test('同一时间戳多条翻译合并；无翻译时为空列表', () async {
    final merged = LyricsProvider(
      service: _FakeLyricsService(
        const LyricsResult(
          lyric: '[00:01.00]A',
          translation: '[00:01.00]译甲\n[00:01.00]译乙',
          provider: 'fake',
        ),
      ),
    );
    await merged.load(track());
    expect(merged.state.translations, ['译甲 译乙']);

    final none = LyricsProvider(
      service: _FakeLyricsService(
        const LyricsResult(lyric: '[00:01.00]A', provider: 'fake'),
      ),
    );
    await none.load(track());
    expect(none.state.translations, isEmpty);
    expect(none.state.romas, isEmpty);
  });

  test('未同步歌词的伪时间戳同样可对齐扩展行', () async {
    final provider = LyricsProvider(
      service: _FakeLyricsService(
        const LyricsResult(
          lyric: 'hello\nworld',
          translation: '你好\n世界',
          provider: 'fake',
        ),
      ),
    );
    await provider.load(track());
    expect(provider.state.isSynced, isFalse);
    expect(provider.state.translations, ['你好', '世界']);
  });

  test('手动选择歌词清空扩展行', () async {
    final provider = LyricsProvider(
      service: _FakeLyricsService(
        const LyricsResult(
          lyric: '[00:01.00]A',
          translation: '[00:01.00]译',
          provider: 'fake',
        ),
      ),
    );
    await provider.load(track());
    expect(provider.state.translations, ['译']);

    await provider.saveManual(
      trackId: 'fake:1',
      lyric: '[00:03.00]手动',
      providerName: 'qq',
    );
    expect(provider.state.providerName, 'qq');
    expect(provider.state.translations, isEmpty);
  });
}

class _FakeLyricsService extends LyricsService {
  _FakeLyricsService(this.result);

  final LyricsResult? result;

  @override
  Future<LyricsResult?> getLyrics(
    String songName,
    String artistName,
    String trackId,
  ) async =>
      result;
}
