import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/comments_service.dart';
import 'package:molia/domain/models/comment.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/source.dart';
import 'package:molia/domain/models/track.dart';

import 'support/fake_music_source.dart';

/// 评论服务：缓存（single-flight / TTL / 失效）+ 错误归一化。
void main() {
  const caps = SourceCapabilities(search: true, comment: true);

  Track trackOf(String id) => Track(
        id: TrackId('wy', id),
        title: '晴天',
        origin: TrackOrigin.builtin,
      );

  Comment commentOf(String id) => Comment(id: id, text: '评论 $id');

  CommentPage pageOf(
    CommentKind kind,
    int page, {
    int limit = 20,
    int total = 45,
    int count = 20,
  }) =>
      CommentPage.fromPage(
        kind: kind,
        items: [for (var i = 0; i < count; i++) commentOf('$page-$i')],
        page: page,
        limit: limit,
        total: total,
      );

  late FakeMusicSource source;
  late CommentsService service;
  late List<({CommentKind kind, int page})> calls;

  setUp(() {
    calls = [];
    source = FakeMusicSource('wy', capabilities: caps)
      ..onComments = (kind, page, limit) async {
        calls.add((kind: kind, page: page));
        return pageOf(kind, page);
      };
    service = CommentsService(registry: FakeSourceRegistry({'wy': source}));
  });

  test('同 key 命中缓存（single-flight）；不同页 / 类型各自取数', () async {
    final track = trackOf('186016');

    final first = await service.fetch(track, kind: CommentKind.hot);
    final second = await service.fetch(track, kind: CommentKind.hot);
    expect(source.commentCalls, 1, reason: '同 key 命中缓存');
    expect(second.items, first.items);

    await service.fetch(track, kind: CommentKind.hot, page: 2);
    await service.fetch(track, kind: CommentKind.latest);
    await service.fetch(trackOf('other'), kind: CommentKind.hot);
    expect(
      calls,
      [
        (kind: CommentKind.hot, page: 1),
        (kind: CommentKind.hot, page: 2),
        (kind: CommentKind.latest, page: 1),
        (kind: CommentKind.hot, page: 1),
      ],
    );
  });

  test('并发同 key 只发一次请求（single-flight）', () async {
    final track = trackOf('186016');
    await Future.wait([
      service.fetch(track, kind: CommentKind.hot),
      service.fetch(track, kind: CommentKind.hot),
      service.fetch(track, kind: CommentKind.hot),
    ]);
    expect(source.commentCalls, 1);
  });

  test('invalidateTrack 清该曲目全部页；其他曲目不受影响', () async {
    final track = trackOf('186016');
    final other = trackOf('other');
    await service.fetch(track, kind: CommentKind.hot);
    await service.fetch(track, kind: CommentKind.hot, page: 2);
    await service.fetch(other, kind: CommentKind.hot);
    expect(service.countForTrack(track), 2);

    service.invalidateTrack(track);
    expect(service.countForTrack(track), 0);
    expect(service.countForTrack(other), 1);

    await service.fetch(track, kind: CommentKind.hot);
    expect(source.commentCalls, 4, reason: '失效后重新取数');
  });

  test('失败不缓存：下一次调用重新取数', () async {
    var shouldFail = true;
    source.onComments = (kind, page, limit) async {
      if (shouldFail) {
        throw const SourceFailure(
          kind: FailureKind.network,
          message: 'boom',
        );
      }
      return pageOf(kind, page);
    };
    final track = trackOf('186016');

    await expectLater(
      service.fetch(track, kind: CommentKind.hot),
      throwsA(isA<SourceFailure>()),
    );
    shouldFail = false;
    final page = await service.fetch(track, kind: CommentKind.hot);
    expect(page.items, isNotEmpty);
    expect(source.commentCalls, 2);
  });

  test('任意异常归一化为 SourceFailure', () async {
    source.onComments = (kind, page, limit) async => throw StateError('boom');
    await expectLater(
      service.fetch(trackOf('1'), kind: CommentKind.latest),
      throwsA(
        isA<SourceFailure>().having((f) => f.kind, 'kind', FailureKind.unknown),
      ),
    );
  });

  test('无评论能力：适配器抛 unsupported（不静默返回空页）', () async {
    final plain = FakeMusicSource('kw', capabilities: caps);
    final service = CommentsService(
      registry: FakeSourceRegistry({'kw': plain}),
    );
    await expectLater(
      service.fetch(
        Track(id: const TrackId('kw', '1'), title: 'x', origin: TrackOrigin.builtin),
        kind: CommentKind.hot,
      ),
      throwsA(
        isA<SourceFailure>()
            .having((f) => f.kind, 'kind', FailureKind.unsupported),
      ),
    );
  });

  test('未知音源：StateError（编程错误，不归一化）', () async {
    await expectLater(
      service.fetch(
        Track(
          id: const TrackId('nope', '1'),
          title: 'x',
          origin: TrackOrigin.builtin,
        ),
        kind: CommentKind.hot,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('cacheKey 含平台 / 曲目 / 类型 / 页', () {
    expect(
      CommentsService.cacheKey(
        trackOf('186016'),
        kind: CommentKind.hot,
        page: 2,
      ),
      'comments:wy:186016:hot:2:20',
    );
    expect(
      CommentsService.trackCacheKeyPrefix(trackOf('186016')),
      'comments:wy:186016:',
    );
  });
}
