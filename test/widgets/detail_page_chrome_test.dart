import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/widgets/app_network_image.dart';
import 'package:molia/widgets/cover_viewer.dart';
import 'package:molia/widgets/detail_page/detail_cover_header.dart';
import 'package:molia/widgets/detail_page/detail_page_chrome.dart';
import 'package:molia/widgets/track_artwork.dart';

import '../support/cover_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const track = Track(
    id: TrackId('wy', '1'),
    title: '晴天',
    artists: [Artist(name: '周杰伦')],
    origin: TrackOrigin.builtin,
  );

  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(400, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      withCoverStore(
        M3EMaterialApp(
          data: M3EThemeData.fromMaterial(ThemeData()),
          theme: ThemeData(),
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: Scaffold(body: child),
        ),
      ),
    );
  }

  testWidgets('曲目条：标题 / 歌手副标题 / 默认与覆盖内边距', (tester) async {
    await pump(tester, const DetailPageTrackHeader(track: track));

    expect(find.text('晴天'), findsOneWidget);
    expect(find.text('周杰伦'), findsOneWidget);
    expect(find.byType(TrackArtwork), findsOneWidget);
    // 手机档详情页页边距 16：封面左缘贴页边距，标题在封面 + 12 之后。
    expect(tester.getTopLeft(find.byType(TrackArtwork)).dx, 16);
    expect(tester.getTopLeft(find.text('晴天')).dx, 16 + 40 + 12);
    expect(
      tester
          .widget<Padding>(
            find
                .descendant(
                  of: find.byType(DetailPageTrackHeader),
                  matching: find.byType(Padding),
                )
                .first,
          )
          .padding,
      const EdgeInsets.fromLTRB(16, 12, 16, 8),
    );

    await pump(
      tester,
      const DetailPageTrackHeader(
        track: track,
        subtitle: '周杰伦 · 网易云音乐',
        padding: EdgeInsets.fromLTRB(7, 3, 5, 9),
      ),
    );

    expect(find.text('周杰伦 · 网易云音乐'), findsOneWidget);
    expect(tester.getTopLeft(find.text('晴天')).dx, 7 + 40 + 12);
    expect(
      tester
          .widget<Padding>(
            find
                .descendant(
                  of: find.byType(DetailPageTrackHeader),
                  matching: find.byType(Padding),
                )
                .first,
          )
          .padding,
      const EdgeInsets.fromLTRB(7, 3, 5, 9),
    );
  });

  testWidgets('曲目条：没有歌手时不渲染空白副标题', (tester) async {
    await pump(
      tester,
      const DetailPageTrackHeader(
        track: Track(
          id: TrackId('wy', '2'),
          title: '无歌手曲目',
          origin: TrackOrigin.builtin,
        ),
      ),
    );

    expect(find.text('无歌手曲目'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(DetailPageTrackHeader),
        matching: find.byType(Text),
      ),
      findsOneWidget,
      reason: '空 artistLabel 不应留下第二条空白文本',
    );
  });

  testWidgets('头部：封面 / 标题 / 副标题 / 简介 / 行动纵向排列', (tester) async {
    await pump(
      tester,
      DetailPageHeroHeader(
        artwork: const SizedBox(key: Key('heroArtwork'), width: 96, height: 96),
        title: '叶惠美',
        subtitle: '周杰伦 · 2003 · 11 首',
        description: '这是一段专辑简介，用来确认简介位于标题行下方。',
        action: M3EButton.filled(onPressed: () {}, child: const Text('播放全部')),
      ),
    );

    final artwork = find.byKey(const Key('heroArtwork'));
    final description = find.text('这是一段专辑简介，用来确认简介位于标题行下方。');
    final action = find.text('播放全部');
    expect(artwork, findsOneWidget);
    expect(find.text('叶惠美'), findsOneWidget);
    expect(find.text('周杰伦 · 2003 · 11 首'), findsOneWidget);
    expect(description, findsOneWidget);
    expect(action, findsOneWidget);
    expect(
      tester.getTopLeft(description).dy,
      greaterThan(tester.getBottomLeft(artwork).dy),
      reason: '简介在封面行下方整宽排列',
    );
    expect(
      tester.getTopLeft(action).dy,
      greaterThan(tester.getBottomLeft(description).dy),
      reason: '行动在简介之后',
    );
    expect(tester.widget<Text>(description).maxLines, 3);
  });

  testWidgets('tab 栏：选中项与切换回调', (tester) async {
    int? selected;
    await pump(
      tester,
      DetailPageTabBar(
        tabs: const [
          M3ETab(icon: Icon(Icons.local_fire_department_rounded), label: '热门'),
          M3ETab(icon: Icon(Icons.schedule_rounded), label: '最新'),
        ],
        selectedIndex: 0,
        onTabSelected: (index) => selected = index,
      ),
    );

    expect(tester.widget<M3ETabs>(find.byType(M3ETabs)).selectedIndex, 0);
    expect(tester.getTopLeft(find.byType(M3ETabs)).dx, 16);

    await tester.tap(find.text('最新'));
    await tester.pumpAndSettle();
    expect(selected, 1);
  });

  testWidgets('加载态：指示器与可选说明', (tester) async {
    await pump(tester, const DetailPageLoading(label: '正在加载'));

    expect(find.byType(M3ELoadingIndicator), findsOneWidget);
    expect(find.text('正在加载'), findsOneWidget);
  });

  testWidgets('空态：图标 / 文案 / 下一步提示与行动', (tester) async {
    await pump(
      tester,
      DetailPageEmpty(
        icon: Icons.forum_rounded,
        message: '还没有内容',
        hint: '换个来源试试',
        action: M3EButton.filled(onPressed: () {}, child: const Text('刷新')),
      ),
    );

    expect(find.byIcon(Icons.forum_rounded), findsOneWidget);
    expect(find.text('还没有内容'), findsOneWidget);
    expect(find.text('换个来源试试'), findsOneWidget);
    expect(find.text('刷新'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('换个来源试试')).dy,
      greaterThan(tester.getBottomLeft(find.text('还没有内容')).dy),
    );
  });

  testWidgets('失败态：文案 / 提示 / 重试回调', (tester) async {
    var retries = 0;
    await pump(
      tester,
      DetailPageFailure(
        message: '加载失败',
        hint: '请稍后再试',
        retryLabel: '重试',
        onRetry: () => retries++,
      ),
    );

    expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
    expect(find.text('加载失败'), findsOneWidget);
    expect(find.text('请稍后再试'), findsOneWidget);

    await tester.tap(find.widgetWithText(M3EButton, '重试'));
    await tester.pump();
    expect(retries, 1);
  });

  testWidgets('详情页封面头：方形 / 圆形裁切与无封面占位', (tester) async {
    Finder inHeader(Finder matching) =>
        find.descendant(of: find.byType(DetailCoverHeader), matching: matching);

    // 方形无封面：占位图标可见，但不挂可点层（key 不存在）。
    await pump(
      tester,
      const DetailCoverHeader(
        coverUrl: null,
        shape: DetailCoverShape.square,
        fallbackIcon: Icons.album_rounded,
        coverKey: Key('albumHeaderCover'),
        title: '专辑名',
        subtitle: '歌手 · 2026 · 8 首',
      ),
    );
    expect(find.byIcon(Icons.album_rounded), findsOneWidget);
    expect(find.byKey(const Key('albumHeaderCover')), findsNothing);
    expect(inHeader(find.byType(ClipRRect)), findsOneWidget);
    expect(inHeader(find.byType(ClipOval)), findsNothing);

    // 方形有封面：方形裁切 + 可点层。
    await pump(
      tester,
      const DetailCoverHeader(
        coverUrl: 'file:///tmp/album-cover.jpg',
        shape: DetailCoverShape.square,
        fallbackIcon: Icons.album_rounded,
        coverKey: Key('albumHeaderCover'),
        title: '专辑名',
        subtitle: '歌手 · 2026 · 8 首',
      ),
    );
    expect(find.byKey(const Key('albumHeaderCover')), findsOneWidget);
    expect(inHeader(find.byType(ClipRRect)), findsOneWidget);
    expect(inHeader(find.byType(ClipOval)), findsNothing);
    expect(
      tester
          .widget<AppNetworkImage>(inHeader(find.byType(AppNetworkImage)))
          .memCacheWidth,
      96,
      reason: '按 96dp 容器解码，不把原图整张留在内存',
    );

    // 圆形无封面：ClipOval + 歌手占位图，可点层同样不出现。
    await pump(
      tester,
      const DetailCoverHeader(
        coverUrl: '',
        shape: DetailCoverShape.circle,
        fallbackIcon: Icons.person_rounded,
        coverKey: Key('artistHeaderAvatar'),
        title: '歌手名',
        subtitle: '8 首歌曲',
      ),
    );
    expect(find.byIcon(Icons.person_rounded), findsOneWidget);
    expect(find.byKey(const Key('artistHeaderAvatar')), findsNothing);
    expect(inHeader(find.byType(ClipOval)), findsOneWidget);
    expect(inHeader(find.byType(ClipRRect)), findsNothing);
  });

  testWidgets('详情页封面头：点击封面打开查看器并带上副标题 / 保存基名', (tester) async {
    await pump(
      tester,
      const DetailCoverHeader(
        coverUrl: 'file:///tmp/artist-avatar.jpg',
        shape: DetailCoverShape.circle,
        fallbackIcon: Icons.person_rounded,
        coverKey: Key('artistHeaderAvatar'),
        title: '歌手名',
        subtitle: '8 首歌曲',
        viewerSubtitle: '平台歌手名',
        viewerFileNameBase: '歌手名 - 现场',
      ),
    );

    await tester.tap(find.byKey(const Key('artistHeaderAvatar')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('coverViewerPage')), findsOneWidget);
    final viewer = tester.widget<CoverViewerPage>(find.byType(CoverViewerPage));
    expect(viewer.title, '封面');
    expect(viewer.subtitle, '平台歌手名');
    expect(viewer.fileNameBase, '歌手名 - 现场');
  });

  testWidgets('播放全部分裂按钮：主操作 / 随机播放 / 可选加入列表', (tester) async {
    var plays = 0;
    var shuffles = 0;
    var additions = 0;

    await pump(
      tester,
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DetailPlayAllSplitButton(
            key: const Key('albumPlayAll'),
            onPlay: () => plays++,
            onShuffle: () => shuffles++,
            onAddToLibrary: () => additions++,
          ),
        ],
      ),
    );

    await tester.tap(find.byKey(const Key('albumPlayAll')));
    await tester.pump();
    expect(plays, 1);

    Future<void> openMenu() async {
      final rect = tester.getRect(find.byKey(const Key('albumPlayAll')));
      await tester.tapAt(Offset(rect.right - 16, rect.center.dy));
      await tester.pumpAndSettle();
    }

    await openMenu();
    expect(find.text('随机播放全部'), findsOneWidget);
    expect(find.text('加入列表'), findsOneWidget);
    await tester.tap(find.text('随机播放全部'));
    await tester.pumpAndSettle();
    expect(shuffles, 1);

    await openMenu();
    await tester.tap(find.text('加入列表'));
    await tester.pumpAndSettle();
    expect(additions, 1);

    // 不传 onAddToLibrary：尾部菜单只留随机播放（发现详情的导入在 AppBar）。
    await pump(
      tester,
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DetailPlayAllSplitButton(
            key: const Key('discoverTracksPlayAll'),
            onPlay: () {},
            onShuffle: () {},
          ),
        ],
      ),
    );
    final rect = tester.getRect(find.byKey(const Key('discoverTracksPlayAll')));
    await tester.tapAt(Offset(rect.right - 16, rect.center.dy));
    await tester.pumpAndSettle();
    expect(find.text('随机播放全部'), findsOneWidget);
    expect(find.text('加入列表'), findsNothing);
  });
}
