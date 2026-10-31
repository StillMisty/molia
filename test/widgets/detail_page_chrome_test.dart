import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/widgets/detail_page/detail_page_chrome.dart';
import 'package:molia/widgets/track_artwork.dart';

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
}
