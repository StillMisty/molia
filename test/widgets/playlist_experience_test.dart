import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'package:molia/domain/models/library.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/library_collections.dart';
import 'package:molia/providers/library_outcome.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/playlist/playlist_import_service.dart';
import 'package:molia/widgets/collection_picker.dart';
import 'package:molia/widgets/playlist_sheets.dart';
import 'package:molia/widgets/queue.dart';

import '../support/fakes.dart';

Widget host(Widget child, {PlaybackProvider? playback}) {
  final app = M3EMaterialApp(
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
  if (playback == null) return app;
  return ChangeNotifierProvider<PlaybackProvider>.value(
    value: playback,
    child: app,
  );
}

PlaylistInfo playlist(int id, String name, {String folder = ''}) =>
    PlaylistInfo(
      id: id,
      name: name,
      createdAt: id,
      folder: folder,
      syncId: 's$id',
      trackCount: id,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('详情弹层：保存名称 / 描述 / 分组；收藏隐藏分组', (tester) async {
    String? savedName;
    String? savedDescription;
    String? savedFolder;
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () {
              showPlaylistDetailsSheet(
                context,
                playlist: playlist(1, '旧名'),
                existingNames: const ['别的列表'],
                onSave: (name, description, folder) async {
                  savedName = name;
                  savedDescription = description;
                  savedFolder = folder;
                  return true;
                },
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('playlistDetailsFolder')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('playlistDetailsName')), '新名');
    await tester.enterText(
      find.byKey(const Key('playlistDetailsDescription')),
      '说明',
    );
    await tester.enterText(
      find.byKey(const Key('playlistDetailsFolder')),
      'Work',
    );
    await tester.tap(find.byKey(const Key('playlistDetailsSave')));
    await tester.pumpAndSettle();
    expect(savedName, '新名');
    expect(savedDescription, '说明');
    expect(savedFolder, 'Work');
  });

  testWidgets('导出弹层：Molia 选项只在自身可用时出现', (tester) async {
    PlaylistExportFormat? picked;
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              picked = await showPlaylistExportSheet(
                context,
                moliaAvailable: true,
              );
            },
            child: const Text('export'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('export'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('playlistExportM3u8')), findsOneWidget);
    expect(find.byKey(const Key('playlistExportMolia')), findsOneWidget);
    await tester.tap(find.byKey(const Key('playlistExportMolia')));
    await tester.pumpAndSettle();
    expect(picked, PlaylistExportFormat.molia);

    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showPlaylistExportSheet(context, moliaAvailable: false),
            child: const Text('export2'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('export2'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('playlistExportM3u8')), findsOneWidget);
    expect(find.byKey(const Key('playlistExportMolia')), findsNothing);
  });

  testWidgets('导入复核：列出未解析原因，确认只返回布尔', (tester) async {
    bool? confirmed;
    final plan = PlaylistImportPlan(
      name: 'Trip',
      resolved: [
        PlaylistTrack(
          playlistId: 0,
          sourceKey: 'wy',
          songId: '1',
          title: 'A',
          addedAt: 1,
        ),
      ],
      issues: const [
        PlaylistImportIssue(
          displayName: 'missing.mp3',
          reason: PlaylistImportIssueReason.localUnavailable,
        ),
      ],
      totalEntries: 2,
    );
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              confirmed = await showPlaylistImportReviewSheet(
                context,
                plan: plan,
              );
            },
            child: const Text('review'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('review'));
    await tester.pumpAndSettle();
    expect(find.text('missing.mp3'), findsOneWidget);
    expect(find.text('文件不在本机或无法读取'), findsOneWidget);
    expect(find.text('未识别的 1 首会被跳过'), findsOneWidget);
    await tester.tap(find.byKey(const Key('playlistImportConfirm')));
    await tester.pumpAndSettle();
    expect(confirmed, isTrue);
  });

  testWidgets('合集弹层：分组标题可收起，组内列表隐藏且无拖动把手', (tester) async {
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showCollectionPicker(
              context,
              title: '切换合集',
              entries: [
                const CollectionPickerEntry(
                  key: LibraryCollections.favoritesOrderKey,
                  id: LibraryCollections.favoritesSentinel,
                  name: '我的收藏',
                  icon: Icons.favorite_rounded,
                  trackCount: 1,
                  selected: true,
                ),
                const CollectionPickerEntry(
                  key: 'folder:Work',
                  id: LibraryCollections.unset,
                  name: 'Work',
                  icon: Icons.folder_rounded,
                  trackCount: 0,
                  selected: false,
                  folder: 'Work',
                  isFolderHeader: true,
                ),
                CollectionPickerEntry(
                  key: 'playlist:2',
                  id: 2,
                  name: '通勤',
                  icon: Icons.queue_music_rounded,
                  trackCount: 3,
                  selected: false,
                  playlistId: 2,
                  folder: 'Work',
                ),
              ],
              onOrderChanged: (_) {},
              onCreate: (_) async => 1,
              onDelete: (_) async => const LibraryMutationOutcome.applied(),
              onRename: (_, _) async => const LibraryMutationOutcome.applied(),
            ),
            child: const Text('picker'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('picker'));
    await tester.pumpAndSettle();
    expect(find.text('Work'), findsOneWidget);
    expect(find.text('通勤'), findsOneWidget);
    expect(find.byIcon(Icons.drag_handle_rounded), findsNothing);
    await tester.tap(find.text('Work'));
    await tester.pumpAndSettle();
    expect(find.text('通勤'), findsNothing);
    expect(find.text('我的收藏'), findsOneWidget);
  });

  testWidgets('队列：空队列不出现溢出，有队列才出现', (tester) async {
    final facade = FakePlaybackFacade();
    final playback = buildTestPlaybackProvider(facade: facade);
    final controller = ScrollController();
    addTearDown(() {
      controller.dispose();
      playback.dispose();
    });
    await tester.pumpWidget(
      host(QueueDisplay(controller: controller), playback: playback),
    );
    await tester.pump();
    expect(find.byKey(const Key('queueOverflow')), findsNothing);

    final track = Track(
      id: const TrackId('wy', '1'),
      title: 'Song',
      origin: TrackOrigin.builtin,
    );
    facade.emit(
      PlaybackSnapshot(current: track, queue: [track], currentIndex: 0),
    );
    await tester.pump();
    expect(find.byKey(const Key('queueOverflow')), findsOneWidget);
  });
}
