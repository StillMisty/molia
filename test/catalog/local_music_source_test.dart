import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/local_music_source.dart';
import 'package:molia/data/catalog/local_path_resolver.dart';
import 'package:molia/domain/models/catalog.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/domain/ports/music_source.dart';

/// `local` 音源：能力位、payload 路径取链、文件缺失归一化。
void main() {
  Track makeTrack(Map<String, Object?> payload) => Track(
    id: const TrackId('local', 'kw:1'),
    title: '本地歌曲',
    origin: TrackOrigin.localFile,
    payload: payload,
  );

  test('能力位只有 resolveUrl（搜索/歌词/封面/集合全 false）', () {
    final source = LocalMusicSource();
    expect(source.key, 'local');
    expect(source.capabilities.resolveUrl, isTrue);
    expect(source.capabilities.search, isFalse);
    expect(source.capabilities.pagination, isFalse);
    expect(source.capabilities.lyrics, isFalse);
    expect(source.capabilities.artwork, isFalse);
    expect(source.capabilities.collection, isFalse);
    expect(source.capabilities.favorite, isFalse);
  });

  test('resolve 读 payload.path 回 Uri.file', () async {
    final source = LocalMusicSource(fileExists: (path) async => true);
    final stream = await source.resolve(makeTrack({'path': '/data/a.mp3'}));
    expect(stream.uri, Uri.file('/data/a.mp3'));
    expect(stream.headers, isEmpty);
  });

  test('文件缺失 → notFound + 可读 l10nKey', () async {
    final source = LocalMusicSource(fileExists: (path) async => false);
    await expectLater(
      source.resolve(makeTrack({'path': '/data/missing.mp3'})),
      throwsA(
        predicate(
          (e) =>
              e is SourceFailure &&
              e.kind == FailureKind.notFound &&
              e.l10nKey == 'downloadFileMissing',
        ),
      ),
    );
  });

  test('payload 缺少路径 → notFound', () async {
    final source = LocalMusicSource(fileExists: (path) async => true);
    await expectLater(
      source.resolve(makeTrack(const {})),
      throwsA(
        predicate((e) => e is SourceFailure && e.kind == FailureKind.notFound),
      ),
    );
  });

  test('search / collection 抛 unsupported；lyrics / artwork 返回 null', () async {
    final source = LocalMusicSource();
    await expectLater(
      source.search(const SearchQuery(keyword: 'x')),
      throwsA(
        predicate(
          (e) => e is SourceFailure && e.kind == FailureKind.unsupported,
        ),
      ),
    );
    await expectLater(
      source.collection(const CollectionRef(type: 'album', id: '1')),
      throwsA(
        predicate(
          (e) => e is SourceFailure && e.kind == FailureKind.unsupported,
        ),
      ),
    );
    expect(await source.lyrics(makeTrack(const {})), isNull);
    expect(await source.artwork(makeTrack(const {})), isNull);
  });

  test('adopt 只认 local 曲目', () {
    final source = LocalMusicSource();
    final local = makeTrack(const {});
    expect(source.adopt(local), same(local));
    expect(
      source.adopt(
        Track(
          id: const TrackId('kw', '1'),
          title: 't',
          origin: TrackOrigin.builtin,
        ),
      ),
      isNull,
    );
  });

  test('稳定身份经注入端口解析当前路径，payload 旧路径只作回退', () async {
    final resolver = LocalPathResolver();
    resolver.attach((track) async => '/new/location/song.mp3');
    final probed = <String>[];
    final source = LocalMusicSource(
      fileExists: (path) async {
        probed.add(path);
        return true;
      },
      pathResolver: resolver,
    );

    final stream = await source.resolve(
      makeTrack({'path': '/old/location/song.mp3'}),
    );
    expect(stream.uri, Uri.file('/new/location/song.mp3'));
    expect(probed, ['/new/location/song.mp3']);

    // 没有记录（重定位前 / 记录已删）时回退 payload 路径。
    resolver.attach((track) async => null);
    await source.resolve(makeTrack({'path': '/old/location/song.mp3'}));
    expect(probed.last, '/old/location/song.mp3');
  });
}
