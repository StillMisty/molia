import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/mapping/track_mapper.dart';
import 'package:molia/domain/models/catalog.dart';
import 'package:molia/domain/models/comment.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/library.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/source.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/models/play_mode.dart';
import 'package:molia/sources/builtin/builtin_transport.dart';
import 'package:molia/sources/lx/lx_engine_types.dart';
import 'package:molia/sources/source_track.dart';

Track _track({
  String id = '1',
  String title = 'Title',
  String artist = 'Artist',
  Map<String, Object?> payload = const {'id': '1'},
}) {
  return Track(
    id: TrackId('fake', id),
    title: title,
    artists: [Artist(name: artist)],
    album: 'Album',
    duration: const Duration(seconds: 30),
    origin: TrackOrigin.lx,
    payload: payload,
  );
}

void main() {
  group('LibraryChange → 同步类别', () {
    test('历史 / 列表 / 曲目 / 收藏 / 导入各自映射到受影响的类别', () {
      expect(LibraryChange.history().syncCategories, {SyncCategory.history});
      expect(
        LibraryChange.playlists().syncCategories,
        {SyncCategory.playlists},
      );
      expect(
        LibraryChange.playlistTracks(7).syncCategories,
        {SyncCategory.playlists, SyncCategory.playlistTracks},
      );
      expect(
        LibraryChange.favorites().syncCategories,
        {SyncCategory.playlists, SyncCategory.playlistTracks},
      );
      expect(
        LibraryChange.import().syncCategories,
        {
          SyncCategory.history,
          SyncCategory.playlists,
          SyncCategory.playlistTracks,
        },
      );
    });
  });

  group('Track / TrackId', () {
    test('TrackId.uri 与旧 SourceTrack.id 约定一致', () {
      expect(const TrackId('kw', 'abc123').uri, 'kw:abc123');
    });

    test('相等性与 hashCode（payload 参与深比较）', () {
      final a = _track(payload: const {
        'id': '1',
        'nested': {
          'x': [1, 2],
        },
      });
      final b = _track(payload: const {
        'id': '1',
        'nested': {
          'x': [1, 2],
        },
      });
      expect(a, b);
      expect(a.hashCode, b.hashCode);

      final c = _track(payload: const {'id': '2'});
      expect(a, isNot(c));
    });

    test('artistLabel：`, ` 连接、过滤空名、全空为空串（唯一展示 / 持久化词表）', () {
      const multi = Track(
        id: TrackId('kw', '1'),
        title: 'Title',
        artists: [
          Artist(name: 'A'),
          Artist(name: ''),
          Artist(name: 'B'),
        ],
        origin: TrackOrigin.builtin,
      );
      expect(multi.artistLabel, 'A, B');

      const none = Track(
        id: TrackId('kw', '2'),
        title: 'Title',
        artists: [Artist(name: '')],
        origin: TrackOrigin.builtin,
      );
      expect(none.artistLabel, '');
      expect(
        const Track(
          id: TrackId('kw', '3'),
          title: 'Title',
          origin: TrackOrigin.builtin,
        ).artistLabel,
        '',
      );
    });

    test('primaryArtistName：首个有效歌手名，全空为空串', () {
      const multi = Track(
        id: TrackId('kw', '1'),
        title: 'Title',
        artists: [Artist(name: ''), Artist(name: 'B')],
        origin: TrackOrigin.builtin,
      );
      expect(multi.primaryArtistName, 'B');
      expect(
        const Track(
          id: TrackId('kw', '2'),
          title: 'Title',
          artists: [Artist(name: '')],
          origin: TrackOrigin.builtin,
        ).primaryArtistName,
        '',
      );
    });

    test('copyWith 替换封面且原对象不变', () {
      final original = _track();
      final updated = original.copyWith(
        artwork: Artwork(uri: Uri.parse('https://img.example/a.jpg')),
      );
      expect(updated.artwork, isNotNull);
      expect(updated.title, original.title);
      expect(updated.id, original.id);
      expect(original.artwork, isNull);
    });

    test('Artwork fallbacks 按值比较', () {
      final a = Artwork(
        uri: Uri.parse('https://x/a.jpg'),
        fallbacks: [Uri.parse('https://x/a-small.jpg')],
      );
      final b = Artwork(
        uri: Uri.parse('https://x/a.jpg'),
        fallbacks: [Uri.parse('https://x/a-small.jpg')],
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('SourceFailure.from 归一化', () {
    test('TimeoutException → timeout / retryable', () {
      final failure = SourceFailure.from(TimeoutException('超时'));
      expect(failure.kind, FailureKind.timeout);
      expect(failure.retryable, isTrue);
    });

    test('LxEngineException → scriptError', () {
      final failure = SourceFailure.from(const LxEngineException('脚本挂了'));
      expect(failure.kind, FailureKind.scriptError);
    });

    test('SocketException → network', () {
      final failure = SourceFailure.from(SocketException('Connection refused'));
      expect(failure.kind, FailureKind.network);
      expect(failure.retryable, isTrue);
    });

    test('字符串形态（LocalPlaybackService.lastError）也能归一化', () {
      expect(
        SourceFailure.from('LxEngineException: 音源当前不可用').kind,
        FailureKind.scriptError,
      );
      expect(
        SourceFailure.from('SocketException: Connection refused (OS Error)')
            .kind,
        FailureKind.network,
      );
      expect(
        SourceFailure.from('TimeoutException after 0:00:20.000000').kind,
        FailureKind.timeout,
      );
      expect(
        SourceFailure.from('某个未知错误').kind,
        FailureKind.unknown,
      );
    });

    test('内置传输失败按类型名归一化为 network（可重试）', () {
      final failure = SourceFailure.from(
        BuiltinHttpException('连接失败', attempts: 3),
      );
      expect(failure.kind, FailureKind.network);
      expect(failure.retryable, isTrue);
    });

    test('幂等：传入 SourceFailure 原样返回', () {
      const failure = SourceFailure(kind: FailureKind.playback, message: 'x');
      expect(identical(SourceFailure.from(failure), failure), isTrue);
    });

    test('相等性', () {
      const a = SourceFailure(kind: FailureKind.network, message: 'm');
      const b = SourceFailure(kind: FailureKind.network, message: 'm');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a,
          isNot(const SourceFailure(kind: FailureKind.timeout, message: 'm')));
    });
  });

  group('Track mapper 往返', () {
    test('SourceTrack → Track → SourceTrack → Track 保真（raw 原样）', () {
      final source = SourceTrack(
        sourceKey: 'kw',
        origin: 'builtin',
        title: 'Hello',
        artist: 'Tester',
        album: 'Album',
        coverUrl: 'https://img.example/a.jpg',
        duration: const Duration(seconds: 30),
        qualities: const [
          SourceQuality(type: '320k', size: '8MB', hash: 'h1'),
        ],
        raw: {
          'songmid': 'mid-1',
          'id': '1',
          'nested': {'a': 1},
        },
      );

      final track = trackFromSourceTrack(source);
      expect(track.id, const TrackId('kw', 'mid-1'));
      expect(track.origin, TrackOrigin.builtin);
      expect(track.artwork?.uri.toString(), 'https://img.example/a.jpg');
      expect(track.qualities.single.hash, 'h1');
      expect(identical(track.payload, source.raw), isTrue,
          reason: 'payload 必须原样透传');

      final back = sourceTrackFromTrack(track);
      expect(back.sourceKey, source.sourceKey);
      expect(back.origin, source.origin);
      expect(back.title, source.title);
      expect(back.artist, source.artist);
      expect(back.album, source.album);
      expect(back.coverUrl, source.coverUrl);
      expect(back.duration, source.duration);
      expect(back.qualities.single.type, '320k');
      expect(back.qualities.single.size, '8MB');
      expect(back.qualities.single.hash, 'h1');
      expect(identical(back.raw, source.raw), isTrue, reason: 'raw 必须原样回传');

      final track2 = trackFromSourceTrack(back);
      expect(track2, track);
      expect(identical(track2.payload, source.raw), isTrue);
    });

    test('any-listen origin 映射保持 any_listen', () {
      final source = SourceTrack(
        sourceKey: 'any_listen',
        origin: 'any_listen',
        title: 't',
        artist: 'a',
        album: '',
        raw: const {'id': '9'},
      );
      final track = trackFromSourceTrack(source);
      expect(track.origin, TrackOrigin.anyListen);
      final back = sourceTrackFromTrack(track);
      expect(back.origin, 'any_listen');
      expect(back.sourceKey, 'any_listen');
    });

    test('空封面 → artwork null；无 songmid 时 id 回退 title-artist', () {
      final source = SourceTrack(
        sourceKey: 'lx',
        origin: 'lx',
        title: 'T',
        artist: 'A',
        album: '',
        coverUrl: '',
        raw: const {},
      );
      final track = trackFromSourceTrack(source);
      expect(track.artwork, isNull);
      expect(track.id.uri, 'lx:T-A');
      expect(sourceTrackFromTrack(track).coverUrl, isNull);
    });
  });

  test('平台页面地址在映射层派生：bili bvid / av aid，UI 不读 payload', () {
    final bili = trackFromSourceTrack(const SourceTrack(
      sourceKey: 'bili',
      origin: 'builtin',
      title: '晴天',
      artist: '周杰伦',
      album: '',
      raw: {'bvid': 'BV1xx', 'aid': 9},
    ));
    expect(bili.platformPageUrl, 'https://www.bilibili.com/video/BV1xx');

    final fallback = trackFromSourceTrack(const SourceTrack(
      sourceKey: 'bili',
      origin: 'builtin',
      title: '晴天',
      artist: '周杰伦',
      album: '',
      raw: {'aid': 9},
    ));
    expect(fallback.platformPageUrl, 'https://www.bilibili.com/video/av9');
  });

  group('Playback / Catalog / Source 模型', () {
    test('BackendSnapshot：position 参与后端快照相等性', () {
      final track = _track();
      final a = BackendSnapshot(
        current: track,
        queue: [track],
        currentIndex: 0,
        isPlaying: true,
      );
      final b = BackendSnapshot(
        current: track,
        queue: [track],
        currentIndex: 0,
        isPlaying: true,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);

      final moved = BackendSnapshot(
        current: track,
        queue: [track],
        currentIndex: 0,
        isPlaying: true,
        position: const Duration(seconds: 1),
      );
      expect(a, isNot(moved));
    });

    test('PlaybackSnapshot：不含 position，值比较稳定', () {
      final track = _track();
      final a = PlaybackSnapshot(
        current: track,
        queue: [track],
        currentIndex: 0,
        isPlaying: true,
        mode: PlayMode.shuffle,
      );
      final b = PlaybackSnapshot(
        current: track,
        queue: [track],
        currentIndex: 0,
        isPlaying: true,
        mode: PlayMode.shuffle,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(PlaybackSnapshot.empty));
    });

    test('SearchQuery / SearchResult 相等性', () {
      expect(
        const SearchQuery(keyword: 'hello', page: 2, limit: 30),
        const SearchQuery(keyword: 'hello', page: 2, limit: 30),
      );
      const a = SearchResult<int>(items: [1, 2], hasMore: true, total: 5);
      const b = SearchResult<int>(items: [1, 2], hasMore: true, total: 5);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(SearchResult.empty<int>().items, isEmpty);
    });

    test('SourceDescriptor / SourceCapabilities 相等性', () {
      const caps = SourceCapabilities(search: true, resolveUrl: true);
      expect(
        const SourceDescriptor(
          key: 'kw',
          displayName: '酷我',
          kind: SourceKind.builtin,
          capabilities: caps,
          order: 1,
        ),
        const SourceDescriptor(
          key: 'kw',
          displayName: '酷我',
          kind: SourceKind.builtin,
          capabilities: caps,
          order: 1,
        ),
      );
    });

    test('SourceCapabilities.comment 参与相等性', () {
      expect(
        const SourceCapabilities(search: true, comment: true),
        const SourceCapabilities(search: true, comment: true),
      );
      expect(
        const SourceCapabilities(search: true, comment: true),
        isNot(const SourceCapabilities(search: true)),
      );
    });

    test('Comment / CommentPage 相等性（含引用与楼中楼）', () {
      const quoted = Comment(id: 'q', text: '被引用');
      const a = Comment(
        id: '1',
        text: '正文',
        authorName: 'A',
        likedCount: 2,
        quoted: quoted,
        replies: [quoted],
      );
      const b = Comment(
        id: '1',
        text: '正文',
        authorName: 'A',
        likedCount: 2,
        quoted: quoted,
        replies: [quoted],
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a.hasReplies, isTrue);
      expect(a, isNot(const Comment(id: '1', text: '正文')));

      final page = CommentPage.fromPage(
        kind: CommentKind.hot,
        items: const [a],
        page: 1,
        limit: 20,
        total: 40,
      );
      final same = CommentPage.fromPage(
        kind: CommentKind.hot,
        items: const [b],
        page: 1,
        limit: 20,
        total: 40,
      );
      expect(page, same);
      expect(page.hasMore, isTrue);
      expect(
        page,
        isNot(CommentPage.fromPage(
          kind: CommentKind.latest,
          items: const [a],
          page: 1,
          limit: 20,
          total: 40,
        )),
        reason: '类型参与相等性',
      );
    });
  });
}
