import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/data/catalog/comments_service.dart';
import 'package:molia/domain/models/comment.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/domain/models/source.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/song_comments_page.dart';
import 'package:molia/providers/comments_provider.dart';
import 'package:molia/widgets/comment_list_view.dart';
import 'package:provider/provider.dart';

import 'support/fake_music_source.dart';

/// 评论页：tab 切换（带计数）/ 分页 / 刷新 / 空态 / 错误态 / 评论行字段。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const supportedCaps = SourceCapabilities(search: true, comment: true);
  const unsupportedCaps = SourceCapabilities(search: true);

  final track = Track(
    id: const TrackId('wy', '186016'),
    title: '晴天',
    artists: const [Artist(name: '周杰伦')],
    origin: TrackOrigin.builtin,
  );

  late FakeMusicSource source;
  late CommentsProvider provider;

  /// 评论行固定字段（时间用相对时间便于断言 l10n 文案）。
  Comment commentOf(String id, {String text = '正文', Comment? quoted}) =>
      Comment(
        id: id,
        text: text,
        createdAt: DateTime.now().subtract(const Duration(hours: 2)),
        location: '广东',
        authorName: '听友$id',
        likedCount: 7,
        quoted: quoted,
      );

  CommentPage pageOf(CommentKind kind, int page, {int total = 45}) =>
      CommentPage.fromPage(
        kind: kind,
        items: [
          for (var i = 0; i < 20; i++)
            commentOf(
              '${kind.name}-$page-$i',
              text: '${kind.name} 第 $page 页第 $i 条',
            ),
        ],
        page: page,
        limit: CommentsProvider.pageSize,
        total: total,
      );

  void build({
    SourceCapabilities caps = supportedCaps,
    Future<CommentPage> Function(CommentKind kind, int page, int limit)?
        onComments,
  }) {
    source = FakeMusicSource('wy', capabilities: caps)
      ..onComments =
          onComments ?? (kind, page, limit) async => pageOf(kind, page);
    final registry = FakeSourceRegistry({'wy': source});
    provider = CommentsProvider(
      service: CommentsService(registry: registry),
      registry: registry,
    );
  }

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<CommentsProvider>.value(
        value: provider,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: SongCommentsPage(track: track),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('热门 tab 首屏：计数 + 评论行字段（昵称/时间/IP/点赞/引用）', (tester) async {
    final quoted = Comment(id: 'q', text: '被引用的原评论', authorName: '甲');
    build(
      onComments: (kind, page, limit) async => CommentPage.fromPage(
        kind: kind,
        items: [
          commentOf('a', text: '第一条评论', quoted: quoted),
        ],
        page: page,
        limit: CommentsProvider.pageSize,
        total: 12,
      ),
    );
    await pumpPage(tester);

    expect(find.text('热门 (12)'), findsOneWidget);
    expect(find.text('最新'), findsOneWidget, reason: '未加载的 tab 不带计数');
    expect(find.text('第一条评论'), findsOneWidget);
    expect(find.text('听友a'), findsOneWidget);
    expect(find.text('2 小时前'), findsOneWidget);
    expect(find.text('IP 属地：广东'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
    expect(find.text('甲：被引用的原评论', findRichText: true), findsOneWidget);
    expect(find.text('没有更多评论了'), findsOneWidget, reason: '单页即到底');
  });

  testWidgets('tab 切换：最新评论懒加载并带计数', (tester) async {
    build();
    await pumpPage(tester);

    expect(find.text('热门 (45)'), findsOneWidget);
    expect(source.commentCalls, 1);

    await tester.tap(find.text('最新'));
    await tester.pumpAndSettle();

    expect(source.commentCalls, 2, reason: '切到最新才发起请求');
    expect(find.text('最新 (45)'), findsOneWidget);
    expect(find.textContaining('latest 第 1 页'), findsWidgets);
  });

  testWidgets('分页：触底自动加载下一页', (tester) async {
    build();
    await pumpPage(tester);

    expect(find.textContaining('hot 第 1 页'), findsWidgets);

    await tester.fling(find.byType(ListView), const Offset(0, -4000), 4000);
    await tester.pumpAndSettle();

    // 触底自动取下一页（甩动惯性可能连取多页，断言「已追加」而非固定页号）。
    final state = provider.stateOf(CommentKind.hot);
    expect(state.page, greaterThanOrEqualTo(2));
    expect(state.items.length, greaterThan(20));
    expect(state.items[20].id, 'hot-2-0', reason: '第 2 页按序追加');
    expect(find.byType(CommentRow), findsWidgets);
  });

  testWidgets('刷新按钮：重新取数（绕过缓存）', (tester) async {
    build();
    await pumpPage(tester);
    expect(source.commentCalls, 1);

    await tester.tap(find.byIcon(Icons.refresh_rounded));
    await tester.pumpAndSettle();

    expect(source.commentCalls, 2);
    expect(find.textContaining('hot 第 1 页'), findsWidgets);
  });

  testWidgets('错误态：展示 l10n 文案（不展示原始异常）+ 重试恢复', (tester) async {
    var shouldFail = true;
    build(onComments: (kind, page, limit) async {
      if (shouldFail) {
        throw const SourceFailure(
          kind: FailureKind.network,
          message: 'SocketException: boom',
        );
      }
      return pageOf(kind, page);
    });
    await pumpPage(tester);

    expect(find.text('评论加载失败'), findsOneWidget);
    expect(find.textContaining('SocketException'), findsNothing);

    shouldFail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(find.text('评论加载失败'), findsNothing);
    expect(find.textContaining('hot 第 1 页'), findsWidgets);
  });

  testWidgets('空态：无评论时展示提示', (tester) async {
    build(
      onComments: (kind, page, limit) async => CommentPage.fromPage(
        kind: kind,
        items: const [],
        page: page,
        limit: CommentsProvider.pageSize,
        total: 0,
      ),
    );
    await pumpPage(tester);

    expect(find.text('还没有评论'), findsOneWidget);
    expect(find.text('没有更多评论了'), findsNothing);
  });

  testWidgets('渠道不支持评论：空态提示且不发请求', (tester) async {
    build(caps: unsupportedCaps);
    await pumpPage(tester);

    expect(find.text('当前渠道不支持评论'), findsOneWidget);
    expect(source.commentCalls, 0);
  });

  testWidgets('加载更多失败：保留已加载项 + 底部重试', (tester) async {
    var failPage2 = true;
    build(onComments: (kind, page, limit) async {
      if (page == 2 && failPage2) {
        throw const SourceFailure(kind: FailureKind.timeout, message: 'timeout');
      }
      return pageOf(kind, page);
    });
    await pumpPage(tester);

    await tester.fling(find.byType(ListView), const Offset(0, -4000), 4000);
    await tester.pumpAndSettle();

    expect(find.text('加载更多评论失败'), findsOneWidget);
    expect(
      find.textContaining('hot 第 1 页'),
      findsWidgets,
      reason: '保留已加载项',
    );

    failPage2 = false;
    await tester.tap(find.byKey(const Key('commentsLoadMoreRetry')));
    await tester.pumpAndSettle();

    expect(find.text('加载更多评论失败'), findsNothing);
    expect(provider.stateOf(CommentKind.hot).page, 2);
    expect(provider.stateOf(CommentKind.hot).items.length, 40);
  });

  testWidgets('时间文案：1 分钟内 / 小时前 / 日期', (tester) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('zh'));
    final now = DateTime.now();
    expect(commentTimeLabel(l10n, now), '刚刚');
    expect(
      commentTimeLabel(l10n, now.subtract(const Duration(minutes: 5))),
      '5 分钟前',
    );
    expect(
      commentTimeLabel(l10n, now.subtract(const Duration(hours: 3))),
      '3 小时前',
    );
    expect(
      commentTimeLabel(l10n, DateTime(2024, 1, 2, 3, 4)),
      '2024-01-02',
    );
  });
}
