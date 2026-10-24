/// 合集列表 module 的脚手架与行形状测试：滚动条 / 固定行高 / 行 key /
/// 空态（共享 EmptyState 配方 + 搜索空态）/ 排序模式 / 行动作构成与两平台
/// 入口（触摸端左滑胶囊 / 桌面右键菜单）/ 本地歌曲行映射。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/download.dart';
import 'package:molia/domain/models/library.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/providers/collection_presenter.dart';
import 'package:molia/providers/local_songs_collection.dart';
import 'package:molia/widgets/collection_track_list.dart';
import 'package:molia/widgets/empty_state.dart';
import 'package:molia/widgets/row_actions.dart';
import 'package:molia/widgets/swipe_reveal_row.dart';
import 'package:molia/widgets/track_row.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

/// 行动作流程桩：本组只断言动作构成 / 图标 / 文案，不触发真实写入。
Future<void> _noop() async {}

/// 挂载最小宿主（注册 l10n delegate；M3E 主题走包内默认回退）。
Future<void> pumpHost(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: const [
      AppLocalizations.delegate,
      ...GlobalMaterialLocalizations.delegates,
    ],
    supportedLocales: const [Locale('zh')],
    home: Scaffold(body: child),
  ));
  await tester.pumpAndSettle();
}

AppLocalizations l10nOf(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(Scaffold)))!;

/// 窄屏（400 逻辑宽）的 browse 水平留白 = 16。
const EdgeInsets _narrowListPadding = EdgeInsets.fromLTRB(16, 8, 16, 8);

Future<void> pumpTrackList(
  WidgetTester tester, {
  required int count,
  Widget? empty,
  void Function(int from, int to)? onReorder,
  Key Function(int index)? keyOf,
  bool tableColumns = false,
}) {
  return pumpHost(
    tester,
    CollectionTrackList<int>(
      controller: ScrollController(),
      rows: [for (var i = 0; i < count; i++) i],
      keyOf: keyOf ?? (row) => ValueKey<String>('row-$row'),
      empty: empty ?? const Text('空'),
      onReorder: onReorder,
      tableColumns: tableColumns,
      itemBuilder: (context, row, index) => Text('行 $row'),
    ),
  );
}

void main() {
  group('CollectionTrackList 脚手架', () {
    testWidgets('常显可拖动滚动条 + 固定行高懒加载列表 + 响应式内边距', (tester) async {
      await pumpTrackList(tester, count: 200);

      final scrollbar = tester.widget<Scrollbar>(find.byType(Scrollbar));
      expect(scrollbar.thumbVisibility, isTrue);
      expect(scrollbar.interactive, isTrue);
      expect(scrollbar.controller, isNotNull);

      final list = tester.widget<ListView>(find.byType(ListView));
      expect(list.padding, _narrowListPadding);
      final gap = TrackRow.gapOf(tester.element(find.byType(ListView)));
      expect(list.itemExtent, TrackRow.extent + gap);

      // 懒加载：200 行只构建视口附近的行。
      expect(find.byType(Text), findsWidgets);
      expect(tester.widgetList<Text>(find.byType(Text)).length, lessThan(60));
    });

    testWidgets('表格档：itemExtent 与行渲染同档（单行 56 + 行距）', (tester) async {
      await pumpTrackList(tester, count: 20, tableColumns: true);

      final list = tester.widget<ListView>(find.byType(ListView));
      final context = tester.element(find.byType(ListView));
      final extent = TrackRow.extentOf(context, tableColumns: true);
      expect(extent, M3EListItemTheme.defaults.minHeight,
          reason: 'M3E 列表 token');
      expect(list.itemExtent, extent + TrackRow.gapOf(context));
    });

    testWidgets('行 key 由 keyOf 落定（列表原地刷新用）', (tester) async {
      await pumpTrackList(tester, count: 5);

      expect(find.byKey(const ValueKey<String>('row-3')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('row-9')), findsNothing);
    });

    testWidgets('无可见行：只展示空态，不建列表', (tester) async {
      await pumpTrackList(
        tester,
        count: 0,
        empty: const Text('合集为空'),
      );

      expect(find.text('合集为空'), findsOneWidget);
      expect(find.byType(Scrollbar), findsNothing);
      expect(find.byType(ListView), findsNothing);
    });

    testWidgets('排序模式：重排列表 + 逐行拖动监听 + onReorderItem 转发', (tester) async {
      final calls = <(int, int)>[];
      await pumpTrackList(
        tester,
        count: 5,
        onReorder: (from, to) => calls.add((from, to)),
      );

      expect(find.byType(ListView), findsNothing);
      final reorderable =
          tester.widget<ReorderableListView>(find.byType(ReorderableListView));
      final sliver = tester.widget<SliverReorderableList>(
        find.byType(SliverReorderableList),
      );
      final gap =
          TrackRow.gapOf(tester.element(find.byType(SliverReorderableList)));
      expect(sliver.itemExtent, TrackRow.extent + gap);
      expect(reorderable.padding, _narrowListPadding);
      expect(reorderable.itemExtent, TrackRow.extent + gap);

      expect(
        find.byType(ReorderableDelayedDragStartListener),
        findsNWidgets(5),
      );
      expect(find.byKey(const ValueKey<String>('row-2')), findsOneWidget);

      reorderable.onReorderItem!(2, 0);
      expect(calls, [(2, 0)]);
    });
  });

  group('CollectionTrackRow 行外壳', () {
    testWidgets('无动作 = 纯行；有动作 = 左滑外壳', (tester) async {
      await pumpHost(
        tester,
        Column(
          children: [
            CollectionTrackRow(
              title: '无动作',
              position: M3ECardPosition.first,
              actions: null,
            ),
            CollectionTrackRow(
              title: '有空列表',
              position: M3ECardPosition.middle,
              actions: const [],
            ),
            CollectionTrackRow(
              title: '有动作',
              position: M3ECardPosition.last,
              actions: [
                RowAction(
                  icon: Icons.delete_rounded,
                  label: '删除',
                  onPressed: () {},
                ),
              ],
            ),
          ],
        ),
      );

      expect(find.byType(TrackRow), findsNWidgets(3));
      expect(find.byType(SwipeRevealRow), findsOneWidget);
    });

    testWidgets('桌面：无左滑外壳，右键行表面弹动作菜单，选中触发对应回调', (tester) async {
      var copyPressed = 0;
      var removePressed = 0;
      await pumpHost(
        tester,
        CollectionTrackRow(
          title: '有动作',
          position: M3ECardPosition.single,
          actions: [
            RowAction(
              icon: Icons.playlist_add_rounded,
              label: '加入列表',
              onPressed: () => copyPressed++,
            ),
            RowAction(
              icon: Icons.delete_rounded,
              label: '取消收藏',
              destructive: true,
              onPressed: () => removePressed++,
            ),
          ],
        ),
      );

      expect(
        find.byType(SwipeRevealRow),
        findsNothing,
        reason: '桌面不再有鼠标左滑，动作走行表面右键',
      );

      // 右键行表面 → 菜单在落点展开，条目与动作 label 一一对应。
      final rowRect = tester.getRect(find.byType(TrackRow));
      await tester.tapAt(
        Offset(rowRect.left + 40, rowRect.center.dy),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(find.text('加入列表'), findsOneWidget);
      expect(find.text('取消收藏'), findsOneWidget);

      // 选中条目（value = 动作下标）→ 对应动作回调，选中即关菜单。
      await tester.tap(find.text('取消收藏'));
      await tester.pumpAndSettle();
      expect(removePressed, 1);
      expect(copyPressed, 0);
      expect(find.text('加入列表'), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('桌面：无动作时右键不弹菜单（纯行）', (tester) async {
      var taps = 0;
      await pumpHost(
        tester,
        CollectionTrackRow(
          title: '无动作',
          position: M3ECardPosition.single,
          onTap: () => taps++,
          actions: const [],
        ),
      );

      await tester.tap(
        find.byType(TrackRow),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(
        find.byType(M3EMenuPopup),
        findsNothing,
        reason: '无动作 = 纯行，无右键菜单',
      );
      expect(taps, 0, reason: '右键不触发行点击');

      await tester.tap(find.byType(TrackRow));
      await tester.pump();
      expect(taps, 1);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('多选态：行尾插槽与勾选态透传', (tester) async {
      await pumpHost(
        tester,
        CollectionTrackRow(
          title: 'Song',
          artist: 'Artist',
          trailingText: '3:00',
          trailing: const Icon(Icons.drag_handle_rounded),
          position: M3ECardPosition.single,
          selected: true,
        ),
      );

      final row = tester.widget<TrackRow>(find.byType(TrackRow));
      expect(row.selected, isTrue);
      expect(row.trailingText, '3:00');
      expect(row.trailing, isA<Icon>());
      expect(find.byIcon(Icons.drag_handle_rounded), findsOneWidget);
    });
  });

  group('空态', () {
    testWidgets('共享空态：图标 + 文案 + 可选行动', (tester) async {
      await pumpHost(
        tester,
        const EmptyState(
          icon: Icons.favorite_border_rounded,
          message: '还没有收藏记录',
          action: Text('导入本地歌曲'),
        ),
      );

      expect(find.byType(EmptyState), findsOneWidget);
      expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
      expect(find.text('还没有收藏记录'), findsOneWidget);
      expect(find.text('导入本地歌曲'), findsOneWidget);
    });

    testWidgets('共享空态：无行动时不渲染行动位', (tester) async {
      await pumpHost(
        tester,
        const EmptyState(icon: Icons.queue_music_rounded, message: '合集为空'),
      );

      expect(find.byType(EmptyState), findsOneWidget);
      expect(find.text('合集为空'), findsOneWidget);
      expect(find.byType(M3EButton), findsNothing);
    });

    testWidgets('搜索空态：只给文案', (tester) async {
      await pumpHost(
        tester,
        const CollectionSearchEmpty(message: '没有匹配的歌曲'),
      );

      expect(find.text('没有匹配的歌曲'), findsOneWidget);
    });
  });

  group('行动作形状与构成', () {
    testWidgets('触摸端编译：中性 = 默认胶囊；移除类 = primary + error 配色', (tester) async {
      await pumpHost(tester, const SizedBox());
      final context = tester.element(find.byType(SizedBox));
      final scheme = Theme.of(context).colorScheme;
      var neutralPressed = false;
      var destructivePressed = false;

      final actions = collectionSwipeActions(context, [
        RowAction(
          icon: Icons.playlist_add_rounded,
          label: '加入列表',
          onPressed: () => neutralPressed = true,
        ),
        RowAction(
          icon: Icons.delete_rounded,
          label: '删除',
          destructive: true,
          onPressed: () => destructivePressed = true,
        ),
      ]);

      expect(actions, hasLength(2));
      expect(actions[0].isPrimary, isFalse);
      expect(actions[0].backgroundColor, isNull);
      expect(actions[0].foregroundColor, isNull);
      expect(actions[1].isPrimary, isTrue);
      expect(actions[1].backgroundColor, scheme.error);
      expect(actions[1].foregroundColor, scheme.onError);

      // 图标 semanticLabel 承担无障碍语义（提示气泡不做）。
      final icon = actions[0].icon;
      expect(icon, isA<Icon>());
      expect((icon as Icon).semanticLabel, '加入列表');

      actions[0].onPressed!();
      actions[1].onPressed!();
      expect(neutralPressed, isTrue);
      expect(destructivePressed, isTrue);
    });

    testWidgets('接线缺席 = 动作不出现（不生成点了没反应的条目）', (tester) async {
      await pumpHost(tester, const SizedBox());
      final l10n = l10nOf(tester);
      final presenter = CollectionPresenter();
      const identity = CollectionIdentity(
        selectedId: -3,
        kind: CollectionKind.history,
        playlistId: null,
        displayName: '播放历史',
      );
      final row = HistoryCollectionRow(
        PlayHistoryEntry(
          sourceKey: 'wy',
          songId: '1',
          title: 'Song',
          artist: 'Artist',
          album: 'Album',
          durationMs: 180000,
          raw: const {'songId': '1'},
          playedAt: 1,
        ),
      );
      final specs = presenter.rowActionsFor(row, identity);
      expect(specs, hasLength(3), reason: '投影器给出了三条动作');

      // 页面只接了「加入列表」：另两条动作（换源 / 删除）不出现，
      // 而不是留在菜单里点了没反应。
      final wired = buildCollectionRowActions(
        l10n: l10n,
        specs: specs,
        wiring: const CollectionRowActionWiring(onCopy: _noop),
      );
      expect(wired, hasLength(1));
      expect(wired.single.label, l10n.addToPlaylist);

      // 一条都没接：不产生任何动作（调用方据此不渲染菜单 / 左滑入口）。
      expect(
        buildCollectionRowActions(
          l10n: l10n,
          specs: specs,
          wiring: const CollectionRowActionWiring(),
        ),
        isEmpty,
      );
    });

    testWidgets('曲目行：加入列表 + 换源（非本地）+ 移除类', (tester) async {
      await pumpHost(tester, const SizedBox());
      final l10n = l10nOf(tester);
      const wiring = CollectionRowActionWiring(
        onCopy: _noop,
        onSwap: _noop,
        onRemoveFromPlaylist: _noop,
        onRemoveFromFavorites: _noop,
      );
      final presenter = CollectionPresenter();

      CollectionIdentity identity(
        CollectionKind kind, {
        int? playlistId,
      }) =>
          CollectionIdentity(
            selectedId: playlistId ?? 1,
            kind: kind,
            playlistId: playlistId,
            displayName: '合集',
          );

      List<RowAction> actionsFor({
        required CollectionIdentity identity,
        String sourceKey = 'wy',
      }) {
        final row = TrackCollectionRow(
          PlaylistTrack(
            playlistId: identity.playlistId ?? 0,
            sourceKey: sourceKey,
            songId: '1',
            title: 'Song',
            artist: 'Artist',
            album: 'Album',
            addedAt: 1,
          ),
        );
        return buildCollectionRowActions(
          l10n: l10n,
          specs: presenter.rowActionsFor(row, identity),
          wiring: wiring,
        );
      }

      // 收藏：加入列表 + 换源 + 取消收藏。
      final favorites = actionsFor(
        identity: identity(CollectionKind.favorites, playlistId: 9),
      );
      expect(favorites, hasLength(3));
      expect(favorites[0].label, l10n.addToPlaylist);
      expect(favorites[1].label, l10n.sourceSwap);
      expect(favorites[1].icon, Icons.swap_horiz_rounded);
      expect(favorites[2].label, l10n.favoriteRemove);
      expect(favorites[2].destructive, isTrue);
      // 自建列表：移除类为「从本列表移除」。
      final custom = actionsFor(
        identity: identity(CollectionKind.custom, playlistId: 9),
      );
      expect(custom, hasLength(3));
      expect(custom[2].label, l10n.playlistRemoveTrack);
      expect(custom[2].destructive, isTrue);
      // 本地曲目：无换源。
      expect(
        actionsFor(
          identity: identity(CollectionKind.favorites, playlistId: 9),
          sourceKey: kLocalSourceKey,
        ),
        hasLength(2),
      );
      // 自建列表 id 尚未落定：只有加入列表。
      expect(
        actionsFor(identity: identity(CollectionKind.custom)),
        hasLength(1),
      );
    });

    testWidgets('历史行：本地记录无换源', (tester) async {
      await pumpHost(tester, const SizedBox());
      final l10n = l10nOf(tester);
      final presenter = CollectionPresenter();
      const identity = CollectionIdentity(
        selectedId: -3,
        kind: CollectionKind.history,
        playlistId: null,
        displayName: '播放历史',
      );
      const wiring = CollectionRowActionWiring(
        onCopy: _noop,
        onSwap: _noop,
        onDeleteHistory: _noop,
      );

      List<RowAction> actionsFor(String sourceKey) {
        final row = HistoryCollectionRow(
          PlayHistoryEntry(
            sourceKey: sourceKey,
            songId: '1',
            title: 'Song',
            artist: 'Artist',
            album: 'Album',
            durationMs: 180000,
            raw: const {'songId': '1'},
            playedAt: 1,
          ),
        );
        return buildCollectionRowActions(
          l10n: l10n,
          specs: presenter.rowActionsFor(row, identity),
          wiring: wiring,
        );
      }

      final remote = actionsFor('wy');
      expect(remote, hasLength(3));
      expect(remote[0].label, l10n.addToPlaylist);
      expect(remote[1].label, l10n.sourceSwap);
      expect(remote[2].label, l10n.historyDeleteEntry);
      expect(remote[2].destructive, isTrue);
      expect(actionsFor(kLocalSourceKey), hasLength(2));
    });

    testWidgets('本地歌曲行：删除文案按来源区分，收藏开关切换图标与文案', (tester) async {
      await pumpHost(tester, const SizedBox());
      final l10n = l10nOf(tester);
      final presenter = CollectionPresenter();
      const identity = CollectionIdentity(
        selectedId: -4,
        kind: CollectionKind.localSongs,
        playlistId: null,
        displayName: '本地歌曲',
      );
      final row = LocalSongCollectionRow(
        CollectionLocalSong.download(
          const DownloadedTrack(
            originSourceKey: 'wy',
            originSongId: '1',
            title: '下载的歌',
            filePath: '/downloads/1.mp3',
            downloadedAt: 1,
          ),
        ),
      );

      List<RowAction> actionsFor({
        required bool isFavorite,
        required bool isCached,
        required bool isImported,
      }) {
        return buildCollectionRowActions(
          l10n: l10n,
          specs: presenter.rowActionsFor(row, identity),
          wiring: CollectionRowActionWiring(
            onCopy: _noop,
            onToggleFavorite: _noop,
            onDeleteLocalSong: _noop,
            isFavorite: isFavorite,
            localSongCached: isCached,
            localSongImported: isImported,
          ),
        );
      }

      final deleteDownload = actionsFor(
        isFavorite: false,
        isCached: false,
        isImported: false,
      )[2];
      final deleteImport = actionsFor(
        isFavorite: false,
        isCached: false,
        isImported: true,
      )[2];
      final deleteCached = actionsFor(
        isFavorite: false,
        isCached: true,
        isImported: false,
      )[2];
      expect(deleteDownload.label, l10n.downloadDelete);
      expect(deleteImport.label, l10n.localSongsRemove);
      expect(deleteCached.label, l10n.localSongsCachedRemove);
      expect(deleteDownload.destructive, isTrue);
      expect(deleteImport.destructive, isTrue);
      expect(deleteCached.destructive, isTrue);

      final notFavorite = actionsFor(
        isFavorite: false,
        isCached: false,
        isImported: false,
      )[1];
      final favorite = actionsFor(
        isFavorite: true,
        isCached: false,
        isImported: false,
      )[1];
      expect(notFavorite.label, l10n.favoriteAdd);
      expect(notFavorite.icon, Icons.favorite_border_rounded);
      expect(favorite.label, l10n.favoriteRemove);
      expect(favorite.icon, Icons.heart_broken_rounded);
    });
  });

  group('CollectionLocalSong 本地歌曲行映射', () {
    PlayHistoryEntry history({int? durationMs = 180000, String? coverUrl}) =>
        PlayHistoryEntry(
          sourceKey: 'wy',
          songId: '1',
          title: 'Song 1',
          artist: 'Artist 1',
          album: 'Album',
          coverUrl: coverUrl,
          durationMs: durationMs,
          raw: const {'songId': '1'},
          playedAt: 1,
        );

    test('下载副本行：local 音源身份 + 本地封面优先', () {
      const download = DownloadedTrack(
        originSourceKey: 'wy',
        originSongId: '1',
        title: '下载的歌',
        artist: '歌手',
        durationMs: 180000,
        coverUrl: 'https://cdn.example/cover.jpg',
        coverPath: '/downloads/covers/1.jpg',
        filePath: '/downloads/1.mp3',
        downloadedAt: 1,
      );
      final row = CollectionLocalSong.download(download);

      expect(row.isCached, isFalse);
      expect(row.isImported, isFalse);
      expect(row.key, 'wy:1');
      expect(row.title, '下载的歌');
      expect(row.durationMs, 180000);
      expect(row.artworkUri, 'file:///downloads/covers/1.jpg');
      expect(row.favoriteKey, (sourceKey: kLocalSourceKey, songId: 'wy:1'));
      final track = row.toPlaylistTrack(addedAt: 7);
      expect(track.sourceKey, kLocalSourceKey);
      expect(track.songId, 'wy:1');
      expect(track.addedAt, 7);
    });

    test('导入行：只移出列表语义由 isImported 表达', () {
      const download = DownloadedTrack(
        originSourceKey: kLocalSourceKey,
        originSongId: '/music/local.flac',
        title: '导入的歌',
        filePath: '/music/local.flac',
        imported: true,
        downloadedAt: 1,
      );
      final row = CollectionLocalSong.download(download);

      expect(row.isImported, isTrue);
      expect(row.isCached, isFalse);
      expect(row.favoriteKey,
          (sourceKey: kLocalSourceKey, songId: 'local:/music/local.flac'));
    });

    test('缓存行：保留原曲身份，删除 = 清缓存（无下载记录）', () {
      final row = CollectionLocalSong.cached(
        history(coverUrl: 'https://cdn.example/cover.jpg'),
      );

      expect(row.isCached, isTrue);
      expect(row.isImported, isFalse);
      expect(row.key, 'wy:1');
      expect(row.record, isNull);
      expect(row.artworkUri, 'https://cdn.example/cover.jpg');
      expect(row.favoriteKey, (sourceKey: 'wy', songId: '1'));
      final track = row.toPlaylistTrack(addedAt: 9);
      expect(track.sourceKey, 'wy');
      expect(track.songId, '1');
    });

    test('时长缺失：下载副本行返回 null，缓存行沿用历史', () {
      const download = DownloadedTrack(
        originSourceKey: 'wy',
        originSongId: '1',
        title: '下载的歌',
        filePath: '/downloads/1.mp3',
        downloadedAt: 1,
      );
      expect(CollectionLocalSong.download(download).durationMs, isNull);
      expect(
        CollectionLocalSong.cached(history(durationMs: null)).durationMs,
        isNull,
      );
    });
  });
}
