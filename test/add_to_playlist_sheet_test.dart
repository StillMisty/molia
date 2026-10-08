import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/library.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/widgets/add_to_playlist_sheet.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

/// 「加入列表」弹层（收藏页 / 发现页共用）：
/// 内置收藏 / 播放历史 / 自建列表 / 就地新建与返回结果类型。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AddToPlaylistSelection? picked;
  late String? createdName;

  Future<void> pumpHost(
    WidgetTester tester, {
    List<PlaylistInfo> playlists = const [],
    int newId = 42,
    bool includeFavorites = true,
    bool includeHistory = true,
  }) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    picked = null;
    createdName = null;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: const [Locale('zh')],
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: M3EButton.filled(
                onPressed: () async {
                  picked = await showAddToPlaylistSheet(
                    context,
                    playlists: playlists,
                    includeFavorites: includeFavorites,
                    includeHistory: includeHistory,
                    onCreate: (name) async {
                      createdName = name;
                      return newId;
                    },
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('选择已有列表：点击行返回列表目标', (tester) async {
    await pumpHost(
      tester,
      playlists: const [
        PlaylistInfo(id: 1, name: 'love', createdAt: 0, trackCount: 3),
      ],
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('加入列表'), findsOneWidget);
    expect(find.text('我的收藏'), findsOneWidget);
    expect(find.text('播放历史'), findsOneWidget);
    expect(find.text('新建列表'), findsOneWidget);
    expect(find.text('love'), findsOneWidget);
    expect(find.text('3 首'), findsOneWidget);

    await tester.tap(find.text('love'));
    await tester.pumpAndSettle();
    expect(picked?.kind, AddToPlaylistTargetKind.playlist);
    expect(picked?.playlistId, 1);
  });

  testWidgets('内置目标：我的收藏 / 播放历史', (tester) async {
    await pumpHost(tester);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('我的收藏'));
    await tester.pumpAndSettle();
    expect(picked?.kind, AddToPlaylistTargetKind.favorites);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('播放历史'));
    await tester.pumpAndSettle();
    expect(picked?.kind, AddToPlaylistTargetKind.history);
  });

  testWidgets('去重：已身处收藏合集时隐藏我的收藏入口', (tester) async {
    await pumpHost(tester, includeFavorites: false);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('我的收藏'), findsNothing);
    expect(find.text('播放历史'), findsOneWidget);
  });

  testWidgets('就地新建：命名对话框校验并返回新列表目标', (tester) async {
    await pumpHost(tester);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('新建列表'));
    await tester.pumpAndSettle();

    // 空名称：停留并提示。
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(find.text('请输入列表名称'), findsOneWidget);
    expect(picked, isNull);

    await tester.enterText(find.byType(M3ETextField), '路上听');
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    expect(createdName, '路上听');
    expect(picked?.kind, AddToPlaylistTargetKind.playlist);
    expect(picked?.playlistId, 42);
  });
}
