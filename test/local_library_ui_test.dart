import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';

import 'package:provider/provider.dart';

import 'package:molia/domain/models/download.dart';
import 'package:molia/domain/models/library_browse.dart';
import 'package:molia/domain/models/smart_lists.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/downloads_manage_page.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/download/download_records.dart';
import 'package:molia/providers/collection_mode.dart';
import 'package:molia/providers/library_collections.dart';
import 'package:molia/widgets/collection_mode_switch.dart';
import 'package:molia/widgets/collection_picker.dart';
import 'package:molia/widgets/library_browse_view.dart';

import 'support/cover_test_support.dart';
import 'support/fakes.dart';

Widget host(Widget child) => M3EMaterialApp(
  data: M3EThemeData.fromMaterial(ThemeData.light()),
  theme: ThemeData.light(),
  locale: const Locale('zh'),
  localizationsDelegates: const [
    AppLocalizations.delegate,
    ...GlobalMaterialLocalizations.delegates,
  ],
  supportedLocales: const [Locale('zh')],
  home: Scaffold(body: child),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('模式开关：歌曲 / 专辑 / 歌手，默认歌曲，可切换', (tester) async {
    var mode = CollectionMode.songs;
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (context, setState) => CollectionModeSwitch(
            mode: mode,
            onChanged: (next) => setState(() => mode = next),
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('favoritesModeSwitch')), findsOneWidget);
    expect(find.text('歌曲'), findsOneWidget);
    expect(find.text('专辑'), findsOneWidget);
    expect(find.text('歌手'), findsOneWidget);

    await tester.tap(find.text('专辑'));
    await tester.pumpAndSettle();
    expect(mode, CollectionMode.albums);
  });

  testWidgets('合集弹层：智能列表独立分组，点选返回虚拟哨兵', (tester) async {
    CollectionPickerOutcome? outcome;
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              outcome = await showCollectionPicker(
                context,
                title: '切换合集',
                entries: [
                  const CollectionPickerEntry(
                    key: LibraryCollections.favoritesOrderKey,
                    id: LibraryCollections.favoritesSentinel,
                    name: '我的收藏',
                    icon: Icons.favorite_rounded,
                    trackCount: 2,
                    selected: true,
                  ),
                  const CollectionPickerEntry(
                    key: 'smart:header',
                    id: LibraryCollections.unset,
                    name: '智能列表',
                    icon: Icons.auto_awesome_rounded,
                    trackCount: 0,
                    selected: false,
                    isHeader: true,
                  ),
                  CollectionPickerEntry(
                    key: SmartListIds.missingFiles,
                    id: LibraryCollections.smartSentinelFor(
                      SmartListIds.missingFiles,
                    ),
                    name: '文件不见',
                    icon: Icons.report_gmailerrorred_rounded,
                    trackCount: 1,
                    selected: false,
                    isSmart: true,
                  ),
                ],
                onOrderChanged: (_) {},
                onCreate: (_) async => 1,
                onDelete: (_) async => throw UnimplementedError(),
                onRename: (_, _) async => throw UnimplementedError(),
              );
            },
            child: const Text('打开'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('智能列表'), findsOneWidget);
    expect(find.text('文件不见'), findsOneWidget);
    await tester.tap(find.text('文件不见'));
    await tester.pumpAndSettle();
    expect(
      outcome!.selectedId,
      LibraryCollections.smartSentinelFor(SmartListIds.missingFiles),
    );
  });

  testWidgets('下载维护：缺文件只显示数量 + 检查入口', (tester) async {
    final records = DownloadRecords(
      initialized: true,
      supported: true,
      records: const [
        DownloadedTrack(
          originSourceKey: 'wy',
          originSongId: '1',
          title: 'Missing',
          filePath: '/downloads/missing.mp3',
          sizeBytes: 1,
          downloadedAt: 1,
          missingAt: 9,
        ),
        DownloadedTrack(
          originSourceKey: 'wy',
          originSongId: '2',
          title: 'Present',
          filePath: '/downloads/present.mp3',
          sizeBytes: 1,
          downloadedAt: 2,
        ),
      ],
    );
    final playback = buildTestPlaybackProvider();
    addTearDown(playback.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
          ChangeNotifierProvider<DownloadRecords>.value(value: records),
        ],
        child: host(const DownloadsManagePage()),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('downloadsMissingFilesItem')), findsOneWidget);
    expect(find.text('1 个文件不见'), findsOneWidget);
    expect(find.text('检查文件'), findsOneWidget);
  });

  group('专辑 / 歌手浏览', () {
    BrowseTrack track(
      String id, {
      String title = 'Song',
      int duration = 200000,
    }) => BrowseTrack(
      sourceKey: 'wy',
      songId: id,
      title: title,
      artist: 'Artist',
      album: 'Album A',
      durationMs: duration,
    );

    Widget browse({
      required List<LibraryBrowseGroup> groups,
      bool twoPane = false,
      String signature = 'songs||added',
    }) => host(
      withCoverStore(
        LibraryBrowseView(
          groups: groups,
          modeName: 'albums',
          query: '',
          emptyTitle: '还没有专辑',
          emptyBody: '收藏、列表和本地歌曲会出现在这里',
          searchEmpty: '没有匹配',
          selectHint: '选择一个专辑',
          resetSignature: signature,
          twoPane: twoPane,
          isFavorite: (_) => false,
          onPlay: (_, _, {shuffle = false}) async {},
          onPlayTrack: (_) async {},
          onAdd: (_) async {},
          onToggleFavorite: (_) async {},
        ),
      ),
    );

    testWidgets('分组列表进入详情；重复版本展开后再次签名变化收起', (tester) async {
      final groups = [
        LibraryBrowseGroup(
          key: 'a',
          title: 'Album A',
          subtitle: 'Artist',
          tracks: [track('1'), track('2', duration: 201000)],
        ),
        const LibraryBrowseGroup(
          key: 'b',
          title: 'Album B',
          subtitle: 'Artist B',
          tracks: [],
        ),
      ];
      await tester.pumpWidget(browse(groups: groups));
      expect(find.text('Album A'), findsOneWidget);
      expect(find.text('Album B'), findsOneWidget);
      await tester.tap(find.text('Album A'));
      await tester.pumpAndSettle();
      expect(find.text('2 个版本'), findsOneWidget);
      expect(find.text('Song'), findsOneWidget, reason: '代表行只出现一次');
      await tester.tap(find.text('2 个版本'));
      await tester.pumpAndSettle();
      expect(find.text('Song'), findsNWidgets(2));

      // 模式 / 搜索 / 排序签名变化：展开态重置。
      await tester.pumpWidget(
        browse(groups: groups, signature: 'albums|q|title'),
      );
      await tester.pumpAndSettle();
      expect(find.text('2 个版本'), findsOneWidget);
      expect(find.text('Song'), findsOneWidget);
    });

    testWidgets('展开宽度：左分组列表保留，右栏显示详情', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        browse(
          twoPane: true,
          groups: [
            LibraryBrowseGroup(
              key: 'a',
              title: 'Album A',
              subtitle: 'Artist',
              tracks: [track('1')],
            ),
          ],
        ),
      );
      await tester.tap(find.text('Album A'));
      await tester.pumpAndSettle();
      expect(find.text('Album A'), findsNWidgets(2), reason: '左分组 + 右详情标题');
      expect(find.text('Song'), findsOneWidget);
      expect(find.text('选择一个专辑'), findsNothing);
    });
  });
}
