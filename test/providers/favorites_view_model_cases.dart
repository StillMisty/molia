import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/domain/models/library.dart';
import 'package:molia/domain/models/smart_lists.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/collection_io_commands.dart';
import 'package:molia/providers/collection_presenter.dart';
import 'package:molia/providers/favorites_view_model.dart';
import 'package:molia/providers/library_collections.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// FavoritesViewModel：弹层条目 / 导入结果映射 / 定位分支 / dispose 静默。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final l10n = lookupAppLocalizations(const Locale('zh'));

  PlaylistInfo playlist({
    required int id,
    required String name,
    int trackCount = 0,
    String folder = '',
    bool isFavorites = false,
  }) => PlaylistInfo(
    id: id,
    name: name,
    createdAt: 0,
    trackCount: trackCount,
    folder: folder,
    isFavorites: isFavorites,
  );

  CollectionRow row(String sourceKey, String songId) => TrackCollectionRow(
    PlaylistTrack(
      playlistId: 1,
      sourceKey: sourceKey,
      songId: songId,
      title: '$sourceKey $songId',
      addedAt: 0,
    ),
  );

  late FavoritesViewModel viewModel;
  late ScrollController controller;
  var disposedInTest = false;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    disposedInTest = false;
    controller = ScrollController();
    viewModel = FavoritesViewModel(controllerOf: (_) => controller);
  });

  tearDown(() {
    if (!disposedInTest) viewModel.dispose();
    controller.dispose();
  });

  test('合集条目：固定入口 + 自建列表 + 收藏计数', () {
    final playlists = [
      playlist(id: 1, name: '收藏', trackCount: 4, isFavorites: true),
      playlist(id: 2, name: '通勤', trackCount: 2),
    ];
    final entries = viewModel.collectionEntries(
      l10n: l10n,
      playlists: playlists,
      favoritesId: 1,
      selected: LibraryCollections.favoritesSentinel,
      historyCount: 3,
      localSongsSupported: true,
      browseIndex: null,
    );

    expect(entries.map((entry) => entry.key), [
      LibraryCollections.favoritesOrderKey,
      LibraryCollections.historyOrderKey,
      LibraryCollections.downloadsOrderKey,
      LibraryCollections.libraryBrowseOrderKey,
      'playlist:2',
    ]);
    expect(
      entries.firstWhere((e) => e.key == 'favorites').trackCount,
      4,
      reason: '收藏计数来自收藏列表本身',
    );
    expect(
      entries.firstWhere((e) => e.key == 'history').trackCount,
      3,
      reason: '历史计数来自 provider 快照',
    );
    expect(entries.firstWhere((e) => e.key == 'playlist:2').selected, isFalse);
  });

  test('智能列表条目：分组标题 + 每项计数与选中态', () {
    final entries = viewModel.smartPickerEntries(
      l10n: l10n,
      selected: LibraryCollections.smartSentinelFor(SmartListIds.mostPlayed),
      smartRows: {
        SmartListIds.mostPlayed: [row('perf', '1'), row('perf', '2')],
      },
    );

    expect(entries.first.isCollapsibleHeader, isTrue);
    expect(
      entries.firstWhere((e) => e.key == SmartListIds.mostPlayed).trackCount,
      2,
    );
    expect(
      entries.firstWhere((e) => e.key == SmartListIds.mostPlayed).selected,
      isTrue,
    );
    expect(
      entries.firstWhere((e) => e.key == SmartListIds.missingFiles).selected,
      isFalse,
    );
  });

  test('导入结果映射：成功带列表与文案，取消不提示', () {
    final done = viewModel.mapPlaylistImportOutcome(
      const CollectionPlaylistImportDone(
        playlistId: 7,
        name: '导入',
        added: 3,
        skipped: 1,
      ),
      l10n,
    );
    expect(done?.playlistId, 7);
    expect(done?.message, l10n.playlistImportDone(3, 1));

    final empty = viewModel.mapPlaylistImportOutcome(
      const CollectionPlaylistImportEmpty(),
      l10n,
    );
    expect(empty?.playlistId, isNull);
    expect(empty?.message, l10n.playlistImportEmpty);

    final cancelled = viewModel.mapPlaylistImportOutcome(
      const CollectionPlaylistImportCancelled(
        CollectionImportCancelReason.filePick,
      ),
      l10n,
    );
    expect(cancelled, isNull);

    final link = viewModel.mapLinkImportOutcome(
      const CollectionLinkImportAlreadyContains(9),
      l10n,
    );
    expect(link?.playlistId, isNull);
    expect(link?.message, l10n.playlistAlreadyContains);
  });

  test('定位：无曲目 / 不在列表 / 命中行下标', () {
    final rows = [row('perf', 'song-1'), row('perf', 'song-2')];

    expect(viewModel.resolveLocate(rows: rows, trackId: null), isNull);
    viewModel.requestLocate();
    final noTrack = viewModel.resolveLocate(rows: rows, trackId: null);
    expect(noTrack?.kind, FavoritesLocateKind.noTrack);

    viewModel.requestLocate();
    final missing = viewModel.resolveLocate(
      rows: rows,
      trackId: const TrackId('perf', 'song-404'),
    );
    expect(missing?.kind, FavoritesLocateKind.missing);

    viewModel.requestLocate();
    final reveal = viewModel.resolveLocate(
      rows: rows,
      trackId: const TrackId('perf', 'song-2'),
    );
    expect(reveal?.kind, FavoritesLocateKind.reveal);
    expect(reveal?.index, 1);
    expect(viewModel.state.locatePending, isFalse, reason: '一次请求只消费一次');
  });

  test('快照暴露搜索 / 定位 / 合集顺序，命令后通知 changes', () {
    var notifications = 0;
    viewModel.changes.addListener(() => notifications++);

    final initial = viewModel.state;
    expect(initial.searching, isFalse);
    expect(initial.selecting, isFalse);
    expect(initial.collectionOrder, isEmpty);

    viewModel.openSearch();
    expect(viewModel.state.searching, isTrue);
    expect(notifications, 1);

    viewModel.requestLocate();
    expect(viewModel.state.locatePending, isTrue);

    viewModel.exitSearch();
    viewModel.reorderCollections(const ['playlist:2']);
    final snapshot = viewModel.state;
    expect(snapshot.collectionOrder, ['playlist:2']);
    expect(
      () => snapshot.collectionOrder.add('playlist:3'),
      throwsUnsupportedError,
      reason: '快照里的顺序是只读视图',
    );
  });

  test('dispose 后取消订阅且不再通知', () {
    var notifications = 0;
    viewModel.changes.addListener(() => notifications++);
    viewModel.requestLocate();
    expect(notifications, 1);

    viewModel.dispose();
    disposedInTest = true;
    // dispose 后再调用（迟到的壳层信号 / 服务回调）不得通知或抛错。
    viewModel.requestLocate();
    viewModel.toggleSmartVersions(row('perf', 'song-1'));
    expect(notifications, 1);
  });
}
