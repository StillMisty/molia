// flutter_cache_manager 是 cached_network_image 的传递依赖；测试需要直接构造
// 失败 CacheManager 验证重试。
// ignore: depend_on_referenced_packages
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/domain/models/comment.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/managers/artwork_cache.dart';
import 'package:molia/services/cache_service.dart';
import 'package:molia/widgets/comment_avatar.dart';
import 'package:molia/widgets/comment_list_view.dart';

import '../support/memory_cache_storage.dart';

/// 永远失败的 CacheManager：统计次数，验证 CommentAvatar 只自动重试一次。
class _CountingFailingManager extends CacheManager {
  _CountingFailingManager()
      : super(Config(
          'comment_avatar_retry_test',
          repo: NonStoringObjectProvider(),
          fileSystem: MemoryCacheSystem(),
          fileService: HttpFileService(),
        ));

  int calls = 0;

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) async* {
    calls += 1;
    throw Exception('offline');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget host(Widget child, {double width = 360}) => MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: const [Locale('zh')],
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: SingleChildScrollView(child: child),
            ),
          ),
        ),
      );

  Comment comment(
    String id, {
    String text = '正文',
    List<Comment> replies = const [],
  }) =>
      Comment(
        id: id,
        text: text,
        authorName: '用户$id',
        replies: replies,
      );

  final longText = List.filled(6, '很长的回复正文，用来验证窄屏下不会横向溢出。').join();

  /// 父评论 + 3 条一级回复 + 1 条二级回复：覆盖最常出现的楼中楼形状。
  Comment floor() => comment(
        'root',
        text: '父评论正文',
        replies: [
          comment(
            'reply-1',
            text: '一级回复 0 $longText',
            replies: [comment('reply-1-1', text: '二级回复 $longText')],
          ),
          comment('reply-2', text: '一级回复 1 $longText'),
          comment('reply-3', text: '一级回复 2 $longText'),
        ],
      );

  for (final width in const [360.0, 320.0]) {
    testWidgets('楼中楼窄屏布局：回复在主行下方，缩进不挤占正文（$width）', (tester) async {
      await tester.pumpWidget(host(CommentRow(comment: floor()), width: width));

      expect(tester.takeException(), isNull);
      expect(find.text('父评论正文'), findsOneWidget);
      expect(find.textContaining('一级回复 0'), findsOneWidget);
      expect(find.textContaining('二级回复'), findsOneWidget);

      final parentX = tester.getTopLeft(find.text('父评论正文')).dx;
      final replyX = tester.getTopLeft(find.textContaining('一级回复 0')).dx;
      final nestedX = tester.getTopLeft(find.textContaining('二级回复')).dx;

      // 旧实现把回复塞进父评论内容列并叠加缩进，一级回复正文会从 ~152px 开始。
      expect(parentX, lessThan(80));
      expect(replyX, lessThan(110), reason: '一级回复不应被父评论头像列挤到右侧');
      expect(nestedX, lessThan(130), reason: '二级回复只再缩进 20px');
    });
  }

  testWidgets('空头像显示人像占位，不显示品牌标志', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: CommentAvatar(url: null, size: 36)),
        ),
      ),
    );

    expect(find.byIcon(Icons.person_rounded), findsOneWidget);
    expect(find.byType(CommentAvatar), findsOneWidget);
  });

  testWidgets('头像加载失败自动重试一次，之后稳定回退人像', (tester) async {
    final manager = _CountingFailingManager();
    final cache = ArtworkCache(
      cacheService: CacheService(storage: MemoryCacheStorage()),
      managerOverride: manager,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: CommentAvatar(
              url: 'https://p1.music.126.net/avatar.jpg',
              size: 36,
              artworkCache: cache,
            ),
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final firstCalls = manager.calls;
    expect(firstCalls, greaterThan(0));

    // 700ms 后自动重试一次。
    await tester.pump(const Duration(milliseconds: 800));
    expect(manager.calls, greaterThan(firstCalls));

    final retriedCalls = manager.calls;
    await tester.pump(const Duration(seconds: 2));
    expect(manager.calls, retriedCalls, reason: '最多只重试一次');
    expect(find.byIcon(Icons.person_rounded), findsWidgets);
  });
}
