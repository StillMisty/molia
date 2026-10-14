import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/catalog/comments_service.dart';
import 'package:molia/domain/models/comment.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/source.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/providers/comments_provider.dart';

import 'support/fake_music_source.dart';

/// 评论会话：热门 / 最新懒加载、分页、去重、错误与能力位。
void main() {
  const supportedCaps = SourceCapabilities(search: true, comment: true);
  const unsupportedCaps = SourceCapabilities(search: true);

  final track = Track(
    id: const TrackId('wy', '186016'),
    title: '晴天',
    origin: TrackOrigin.builtin,
  );

  Comment commentOf(String id) => Comment(id: id, text: '评论 $id');

  /// 每页 20 条、总数 45（第 3 页为末页）。
  CommentPage pageOf(CommentKind kind, int page, {int total = 45}) =>
      CommentPage.fromPage(
        kind: kind,
        items: [for (var i = 0; i < 20; i++) commentOf('${kind.name}-$page-$i')],
        page: page,
        limit: CommentsProvider.pageSize,
        total: total,
      );

  late FakeMusicSource source;
  late FakeSourceRegistry registry;
  late CommentsProvider provider;

  CommentsProvider build({
    SourceCapabilities caps = supportedCaps,
    Future<CommentPage> Function(CommentKind kind, int page, int limit)?
        onComments,
  }) {
    source = FakeMusicSource('wy', capabilities: caps)
      ..onComments = onComments ?? (kind, page, limit) async => pageOf(kind, page);
    registry = FakeSourceRegistry({'wy': source});
    provider = CommentsProvider(
      service: CommentsService(registry: registry),
      registry: registry,
    );
    return provider;
  }

  tearDown(() => provider.dispose());

  test('open：加载热门首屏（含总数 / hasMore），最新 tab 懒加载', () async {
    build();
    await provider.open(track);

    final hot = provider.stateOf(CommentKind.hot);
    expect(hot.items, hasLength(20));
    expect(hot.total, 45);
    expect(hot.page, 1);
    expect(hot.hasMore, isTrue);
    expect(hot.isLoading, isFalse);
    expect(source.commentCalls, 1, reason: '只加载默认 tab');
    expect(provider.kind, CommentKind.hot);
    expect(provider.stateOf(CommentKind.latest).page, 0);

    await provider.selectKind(CommentKind.latest);
    expect(source.commentCalls, 2);
    expect(provider.stateOf(CommentKind.latest).items, hasLength(20));
    expect(provider.stateOf(CommentKind.latest).total, 45);

    // 再切回已加载过的 tab：不重复请求。
    await provider.selectKind(CommentKind.hot);
    expect(source.commentCalls, 2);
  });

  test('loadMore：追加下一页、跨页去重、末页后 hasMore=false', () async {
    build();
    await provider.open(track);
    await provider.loadMore();

    final state = provider.stateOf(CommentKind.hot);
    expect(state.page, 2);
    expect(state.items, hasLength(40));
    expect(state.hasMore, isTrue, reason: '40 < 45');

    // 平台分页边界重复返回：按 id 去重。
    await provider.loadMore();
    expect(provider.stateOf(CommentKind.hot).page, 3);
    expect(provider.stateOf(CommentKind.hot).hasMore, isFalse);

    // 已到底：不再请求。
    final calls = source.commentCalls;
    await provider.loadMore();
    expect(source.commentCalls, calls);
  });

  test('重复页去重（平台忽略 page 时不会无限追加）', () async {
    build(onComments: (kind, page, limit) async => pageOf(kind, 1));
    await provider.open(track);
    await provider.loadMore();
    expect(provider.stateOf(CommentKind.hot).items, hasLength(20));
    expect(provider.stateOf(CommentKind.hot).page, 2);
  });

  test('首屏失败：错误态（failure 归一化）+ retry 恢复', () async {
    var shouldFail = true;
    build(onComments: (kind, page, limit) async {
      if (shouldFail) {
        throw const SourceFailure(
          kind: FailureKind.network,
          message: 'network down',
        );
      }
      return pageOf(kind, page);
    });

    await provider.open(track);
    final failed = provider.stateOf(CommentKind.hot);
    expect(failed.failed, isTrue);
    expect(failed.failure?.kind, FailureKind.network);
    expect(failed.items, isEmpty);
    expect(failed.page, 0);

    shouldFail = false;
    await provider.retry();
    final recovered = provider.stateOf(CommentKind.hot);
    expect(recovered.failed, isFalse);
    expect(recovered.items, hasLength(20));
    expect(recovered.page, 1);
  });

  test('加载更多失败：保留已加载项 + loadMoreFailed，重试可恢复', () async {
    var failPage2 = true;
    build(onComments: (kind, page, limit) async {
      if (page == 2 && failPage2) {
        throw const SourceFailure(kind: FailureKind.timeout, message: 'timeout');
      }
      return pageOf(kind, page);
    });

    await provider.open(track);
    await provider.loadMore();
    final state = provider.stateOf(CommentKind.hot);
    expect(state.loadMoreFailed, isTrue);
    expect(state.items, hasLength(20), reason: '保留已加载项');
    expect(state.page, 1);
    expect(state.hasMore, isTrue);

    failPage2 = false;
    await provider.loadMore();
    expect(provider.stateOf(CommentKind.hot).loadMoreFailed, isFalse);
    expect(provider.stateOf(CommentKind.hot).items, hasLength(40));
  });

  test('refresh：清缓存重新取数并替换列表', () async {
    build();
    await provider.open(track);
    expect(source.commentCalls, 1);

    await provider.refresh();
    expect(source.commentCalls, 2, reason: '刷新绕过缓存');
    expect(provider.stateOf(CommentKind.hot).items, hasLength(20));
  });

  test('渠道无评论能力：supports=false，open 不发请求', () async {
    build(caps: unsupportedCaps);
    expect(provider.supports(track), isFalse);
    await provider.open(track);
    expect(source.commentCalls, 0);
    expect(provider.isSupported, isFalse);
    expect(provider.stateOf(CommentKind.hot).page, 0);
    expect(provider.stateOf(CommentKind.hot).failed, isFalse);
  });

  test('close：清空会话与状态', () async {
    build();
    await provider.open(track);
    provider.close();
    expect(provider.track, isNull);
    expect(provider.isSupported, isFalse);
    expect(provider.stateOf(CommentKind.hot).items, isEmpty);
    expect(provider.stateOf(CommentKind.hot).page, 0);
  });
}
