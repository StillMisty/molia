import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/domain/models/library.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/library_collections.dart';
import 'package:molia/providers/library_outcome.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/covers/custom_cover_store.dart';
import 'package:molia/services/library/playlist_folder_prefs.dart';
import 'package:molia/services/playlist/playlist_import_service.dart';
import 'package:molia/services/poster/playlist_poster_layout.dart';
import 'package:molia/theme/poster_palette.dart';
import 'package:molia/widgets/collection_picker.dart';
import 'package:molia/widgets/playlist_cover.dart';
import 'package:molia/widgets/playlist_folder_dialog.dart';
import 'package:molia/widgets/playlist_header_overflow.dart';
import 'package:molia/widgets/playlist_sheets.dart';
import 'package:molia/widgets/queue.dart';

import '../support/fake_library_repository.dart';
import '../support/fakes.dart';

Widget host(
  Widget child, {
  PlaybackProvider? playback,
  LibraryProvider? library,
  CustomCoverStore? covers,
}) {
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
  Widget wrapped = app;
  if (covers != null) {
    wrapped = Provider<CustomCoverStore>.value(value: covers, child: wrapped);
  }
  if (library != null) {
    wrapped = ChangeNotifierProvider<LibraryProvider>.value(
      value: library,
      child: wrapped,
    );
  }
  if (playback != null) {
    wrapped = ChangeNotifierProvider<PlaybackProvider>.value(
      value: playback,
      child: wrapped,
    );
  }
  return wrapped;
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

  testWidgets('列表头部溢出：详情 / 封面 / 分享 / 导出 / 全部下载', (tester) async {
    final l10n = lookupAppLocalizations(const Locale('zh'));
    var details = 0;
    var cover = 0;
    var share = 0;
    var export = 0;
    var download = 0;
    await tester.pumpWidget(
      host(
        PlaylistHeaderOverflow(
          onEditDetails: () => details++,
          onChangeCover: () => cover++,
          onShare: () => share++,
          onExport: () => export++,
          onDownloadAll: () => download++,
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('playlistHeaderOverflow')));
    await tester.pumpAndSettle();
    for (final label in [
      l10n.playlistEditDetails,
      l10n.playlistCoverChange,
      l10n.playlistShare,
      l10n.playlistExport,
      l10n.downloadAll,
    ]) {
      expect(find.text(label), findsWidgets);
    }
    await tester.tap(find.text(l10n.playlistEditDetails).last);
    await tester.pumpAndSettle();
    expect(details, 1);

    await tester.tap(find.byKey(const Key('playlistHeaderOverflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.playlistCoverChange).last);
    await tester.pumpAndSettle();
    expect(cover, 1);

    await tester.tap(find.byKey(const Key('playlistHeaderOverflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.playlistShare).last);
    await tester.pumpAndSettle();
    expect(share, 1);

    await tester.tap(find.byKey(const Key('playlistHeaderOverflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.playlistExport).last);
    await tester.pumpAndSettle();
    expect(export, 1);

    await tester.tap(find.byKey(const Key('playlistHeaderOverflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.downloadAll).last);
    await tester.pumpAndSettle();
    expect(download, 1);
  });

  testWidgets('列表头部溢出：不可下载时不出现全部下载', (tester) async {
    final l10n = lookupAppLocalizations(const Locale('zh'));
    await tester.pumpWidget(
      host(
        PlaylistHeaderOverflow(
          onEditDetails: () {},
          onChangeCover: () {},
          onShare: () {},
          onExport: () {},
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('playlistHeaderOverflow')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.downloadAll), findsNothing);
  });

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

  testWidgets('列表封面：设置后渲染，重置回退到列表图标', (tester) async {
    final store = _FakePlaylistCoverStore();
    addTearDown(store.revision.dispose);
    await tester.pumpWidget(
      host(PlaylistCover(playlist: playlist(1, '通勤')), covers: store),
    );
    await tester.pump();
    expect(find.byIcon(Icons.queue_music_rounded), findsOneWidget);

    store.url = 'file:///tmp/playlist-cover.png';
    store.revision.value++;
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);

    store.url = null;
    store.revision.value++;
    await tester.pump();
    expect(find.byIcon(Icons.queue_music_rounded), findsOneWidget);
  });

  testWidgets('分享弹层：图片 / 文本两个 section 同层展示', (tester) async {
    final l10n = lookupAppLocalizations(const Locale('zh'));
    await tester.pumpWidget(
      host(
        PlaylistShareSheet(
          content: PlaylistShareContent(
            name: 'Trip',
            description: '说明',
            trackCountLabel: l10n.playlistTrackCount(2),
            andMoreLabel: l10n.playlistShareMore,
            tracks: const [
              PlaylistShareTrack(title: 'A', artist: 'X'),
              PlaylistShareTrack(title: 'B', artist: 'Y'),
            ],
          ),
          loadCovers: () async => const [],
          palette: PosterPalette.fromScheme(
            ColorScheme.fromSeed(seedColor: const Color(0xFF2196F3)),
          ),
          autoGenerate: false,
        ),
      ),
    );
    await tester.pump();
    expect(find.text(l10n.playlistShareImage), findsWidgets);
    expect(find.text(l10n.playlistShareText), findsWidgets);
    expect(find.byKey(const Key('playlistShareImageAction')), findsOneWidget);
    expect(find.byKey(const Key('playlistShareTextAction')), findsOneWidget);
    expect(find.textContaining('/tmp'), findsNothing);
  });

  testWidgets('分组命名对话框：空白 / 超长 / 控制字符都拒绝', (tester) async {
    final l10n = lookupAppLocalizations(const Locale('zh'));
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showPlaylistFolderNameDialog(context),
            child: const Text('folder'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('folder'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('playlistFolderNameField')),
      '   ',
    );
    await tester.tap(find.byKey(const Key('playlistFolderNameConfirm')));
    await tester.pump();
    expect(find.text(l10n.playlistFolderNameRequired), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('playlistFolderNameField')),
      'x' * 41,
    );
    await tester.tap(find.byKey(const Key('playlistFolderNameConfirm')));
    await tester.pump();
    expect(find.text(l10n.playlistFolderNameTooLong), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('playlistFolderNameField')),
      'bad\u0007name',
    );
    await tester.tap(find.byKey(const Key('playlistFolderNameConfirm')));
    await tester.pump();
    expect(find.text(l10n.playlistFolderNameInvalid), findsOneWidget);
  });

  testWidgets('导出弹层：Molia 不可用时保留选项但禁用', (tester) async {
    final l10n = lookupAppLocalizations(const Locale('zh'));
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
    picked = null;

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
    expect(find.byKey(const Key('playlistExportMolia')), findsOneWidget);
    expect(find.text(l10n.playlistExportMoliaUnavailable), findsOneWidget);
    await tester.tap(find.byKey(const Key('playlistExportMolia')));
    await tester.pumpAndSettle();
    expect(picked, isNull, reason: '禁用项不返回格式');
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
    final l10n = lookupAppLocalizations(const Locale('zh'));
    await tester.tap(find.text('review'));
    await tester.pumpAndSettle();
    expect(find.text('missing.mp3'), findsOneWidget);
    expect(
      find.text(l10n.playlistImportReasonLocalUnavailable),
      findsOneWidget,
    );
    expect(find.text(l10n.playlistImportSkipNote(1)), findsOneWidget);
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

  testWidgets('合集弹层：重命名到已收起的分组时会展开目标分组', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final collapse = PlaylistFolderCollapseController(
      initiallyCollapsed: {'Work', 'Office'},
    );
    addTearDown(collapse.dispose);
    final l10n = lookupAppLocalizations(const Locale('zh'));
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showCollectionPicker(
              context,
              title: '切换合集',
              folderCollapse: collapse,
              entries: [
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
                const CollectionPickerEntry(
                  key: 'folder:Office',
                  id: LibraryCollections.unset,
                  name: 'Office',
                  icon: Icons.folder_rounded,
                  trackCount: 0,
                  selected: false,
                  folder: 'Office',
                  isFolderHeader: true,
                ),
              ],
              onOrderChanged: (_) {},
              onCreate: (_) async => 1,
              onDelete: (_) async => const LibraryMutationOutcome.applied(),
              onRename: (_, _) async => const LibraryMutationOutcome.applied(),
              onFolderRename: (_, _) async =>
                  const LibraryMutationOutcome.applied(),
            ),
            child: const Text('picker2'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('picker2'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert_rounded).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.playlistFolderRename));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('playlistFolderNameField')),
      'Office',
    );
    await tester.tap(find.byKey(const Key('playlistFolderNameConfirm')));
    await tester.pumpAndSettle();
    expect(find.text('通勤'), findsOneWidget);
    expect(collapse.isCollapsed('Office'), isFalse);
  });

  testWidgets('队列存为列表：一次新建 + 批量加入，重复项合并', (tester) async {
    final l10n = lookupAppLocalizations(const Locale('zh'));
    final repo = FakeLibraryRepository();
    final facade = FakePlaybackFacade();
    final playback = buildTestPlaybackProvider(
      facade: facade,
      libraryRepository: repo,
    );
    final library = LibraryProvider(
      repository: repo,
      playbackProvider: playback,
    );
    final controller = ScrollController();
    addTearDown(() {
      controller.dispose();
      library.dispose();
      playback.dispose();
    });
    final first = Track(
      id: const TrackId('wy', '1'),
      title: 'One',
      origin: TrackOrigin.builtin,
    );
    final second = Track(
      id: const TrackId('wy', '2'),
      title: 'Two',
      origin: TrackOrigin.builtin,
    );
    facade.emit(
      PlaybackSnapshot(
        current: first,
        queue: [first, first, second],
        currentIndex: 0,
      ),
    );
    await tester.pumpWidget(
      host(
        QueueDisplay(controller: controller),
        playback: playback,
        library: library,
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('queueOverflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.queueSaveAsPlaylist));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).last, '队列 A');
    await tester.tap(find.text(l10n.playlistCreateConfirm));
    await tester.pumpAndSettle();
    final saved = await repo.findPlaylistByName('队列 A');
    expect(saved, isNotNull);
    expect((await repo.listPlaylistTracks(saved!.id)).length, 2);
    expect(
      find.textContaining(l10n.queueSavedAsPlaylist('队列 A', 2, 1)),
      findsOneWidget,
    );
  });

  testWidgets('队列存为列表：批量加入失败删除新列表', (tester) async {
    final l10n = lookupAppLocalizations(const Locale('zh'));
    final repo = FakeLibraryRepository()..failTrackWrites = true;
    final facade = FakePlaybackFacade();
    final playback = buildTestPlaybackProvider(
      facade: facade,
      libraryRepository: repo,
    );
    final library = LibraryProvider(
      repository: repo,
      playbackProvider: playback,
    );
    final controller = ScrollController();
    addTearDown(() {
      controller.dispose();
      library.dispose();
      playback.dispose();
    });
    final track = Track(
      id: const TrackId('wy', '1'),
      title: 'One',
      origin: TrackOrigin.builtin,
    );
    facade.emit(
      PlaybackSnapshot(current: track, queue: [track], currentIndex: 0),
    );
    await tester.pumpWidget(
      host(
        QueueDisplay(controller: controller),
        playback: playback,
        library: library,
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('queueOverflow')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.queueSaveAsPlaylist));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).last, '失败队列');
    await tester.tap(find.text(l10n.playlistCreateConfirm));
    await tester.pumpAndSettle();
    expect(await repo.findPlaylistByName('失败队列'), isNull);
    expect(find.text(l10n.queueSaveFailed), findsOneWidget);
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

class _FakePlaylistCoverStore extends CustomCoverStore {
  _FakePlaylistCoverStore()
    : super(
        supportDirectory: () async => Directory.systemTemp,
        clock: () => DateTime.fromMillisecondsSinceEpoch(1000),
      );

  String? url;

  @override
  String? playlistCoverUrl(String key) => url;
}
