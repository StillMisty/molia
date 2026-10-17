/// 合集列表 module 的脚手架与行形状测试：滚动条 / 固定行高 / 行 key /
/// 空态 / 排序模式 / 左滑动作配色与构成 / 本地歌曲行映射。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/download.dart';
import 'package:molia/domain/models/library.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/widgets/collection_track_list.dart';
import 'package:molia/widgets/swipe_reveal_row.dart';
import 'package:molia/widgets/track_row.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

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
      expect(extent, M3EListItemTheme.defaults.minHeight, reason: 'M3E 列表 token');
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
      const action = M3EListSwipeAction(icon: Icon(Icons.delete_rounded));
      await pumpHost(
        tester,
        Column(
          children: [
            CollectionTrackRow(
              title: '无动作',
              position: M3ECardPosition.first,
              swipeActions: null,
            ),
            CollectionTrackRow(
              title: '有空列表',
              position: M3ECardPosition.middle,
              swipeActions: const [],
            ),
            CollectionTrackRow(
              title: '有动作',
              position: M3ECardPosition.last,
              swipeActions: const [action],
            ),
          ],
        ),
      );

      expect(find.byType(TrackRow), findsNWidgets(3));
      expect(find.byType(SwipeRevealRow), findsOneWidget);
    });

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
    testWidgets('合集空态：图标 + 文案 + 动作', (tester) async {
      await pumpHost(
        tester,
        const CollectionEmptyState(
          icon: Icons.favorite_border_rounded,
          message: '还没有收藏记录',
          action: Text('导入本地歌曲'),
        ),
      );

      expect(find.byIcon(Icons.favorite_border_rounded), findsOneWidget);
      expect(find.text('还没有收藏记录'), findsOneWidget);
      expect(find.text('导入本地歌曲'), findsOneWidget);
      // 空态口径：图标 40（不占满全屏，与资料库 / 发现页空态同档）。
      expect(
        tester.getSize(find.byIcon(Icons.favorite_border_rounded)),
        const Size(40, 40),
      );
    });

    testWidgets('搜索空态：只给文案', (tester) async {
      await pumpHost(
        tester,
        const CollectionSearchEmpty(message: '没有匹配的歌曲'),
      );

      expect(find.text('没有匹配的歌曲'), findsOneWidget);
    });
  });

  group('左滑动作形状与构成', () {
    testWidgets('中性 = 默认胶囊；移除类 = primary + error 配色', (tester) async {
      await pumpHost(tester, const SizedBox());
      final context = tester.element(find.byType(SizedBox));
      final scheme = Theme.of(context).colorScheme;
      var neutralPressed = false;
      var destructivePressed = false;

      final actions = collectionSwipeActions(context, [
        CollectionSwipeAction(
          icon: Icons.playlist_add_rounded,
          label: '加入列表',
          onPressed: () => neutralPressed = true,
        ),
        CollectionSwipeAction(
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

      // 图标 tooltip 承担无障碍语义。
      final icon = actions[0].icon;
      expect(icon, isA<Tooltip>());
      expect((icon as Tooltip).message, '加入列表');

      actions[0].onPressed!();
      actions[1].onPressed!();
      expect(neutralPressed, isTrue);
      expect(destructivePressed, isTrue);
    });

    testWidgets('曲目行：加入列表 + 换源（非本地）+ 移除类', (tester) async {
      await pumpHost(tester, const SizedBox());
      final context = tester.element(find.byType(SizedBox));
      final l10n = l10nOf(tester);

      List<M3EListSwipeAction> actionsFor({
        required bool isFavorites,
        required bool isCustom,
        int? playlistId,
        String sourceKey = 'wy',
      }) {
        return collectionTrackRowSwipeActions(
          context,
          l10n: l10n,
          track: PlaylistTrack(
            playlistId: playlistId ?? 0,
            sourceKey: sourceKey,
            songId: '1',
            title: 'Song',
            artist: 'Artist',
            album: 'Album',
            addedAt: 1,
          ),
          isFavorites: isFavorites,
          isCustom: isCustom,
          playlistId: playlistId,
          onCopy: () async {},
          onSwap: () async {},
          onRemoveFromPlaylist: () async {},
          onRemoveFromFavorites: () async {},
        );
      }

      // 收藏：加入列表 + 换源 + 取消收藏。
      expect(
        actionsFor(isFavorites: true, isCustom: false, playlistId: 9),
        hasLength(3),
      );
      expect(
        actionsFor(isFavorites: true, isCustom: false, playlistId: 9)[2]
            .isPrimary,
        isTrue,
      );
      // 自建列表：移除类为「从本列表移除」。
      expect(
        actionsFor(isFavorites: false, isCustom: true, playlistId: 9),
        hasLength(3),
      );
      // 本地曲目：无换源。
      expect(
        actionsFor(
          isFavorites: true,
          isCustom: false,
          playlistId: 9,
          sourceKey: kLocalSourceKey,
        ),
        hasLength(2),
      );
      // 自建列表 id 尚未落定：只有加入列表。
      expect(
        actionsFor(isFavorites: false, isCustom: true, playlistId: null),
        hasLength(1),
      );
    });

    testWidgets('历史行：本地记录无换源', (tester) async {
      await pumpHost(tester, const SizedBox());
      final context = tester.element(find.byType(SizedBox));
      final l10n = l10nOf(tester);

      List<M3EListSwipeAction> actionsFor(String sourceKey) {
        return collectionHistoryRowSwipeActions(
          context,
          l10n: l10n,
          entry: PlayHistoryEntry(
            sourceKey: sourceKey,
            songId: '1',
            title: 'Song',
            artist: 'Artist',
            album: 'Album',
            durationMs: 180000,
            raw: const {'songId': '1'},
            playedAt: 1,
          ),
          onCopy: () async {},
          onSwap: () async {},
          onDelete: () async {},
        );
      }

      expect(actionsFor('wy'), hasLength(3));
      expect(actionsFor(kLocalSourceKey), hasLength(2));
    });

    testWidgets('本地歌曲行：删除文案按来源区分，收藏开关切换图标与文案', (tester) async {
      await pumpHost(tester, const SizedBox());
      final context = tester.element(find.byType(SizedBox));
      final l10n = l10nOf(tester);

      List<M3EListSwipeAction> actionsFor({
        required bool isFavorite,
        required bool isCached,
        required bool isImported,
      }) {
        return localSongRowSwipeActions(
          context,
          l10n: l10n,
          isFavorite: isFavorite,
          isCached: isCached,
          isImported: isImported,
          onCopy: () async {},
          onToggleFavorite: () async {},
          onDelete: () async {},
        );
      }

      String labelOf(M3EListSwipeAction action) =>
          ((action.icon as Tooltip).message)!;

      expect(
          labelOf(actionsFor(
            isFavorite: false,
            isCached: false,
            isImported: false,
          )[2]),
          l10n.downloadDelete);
      expect(
          labelOf(actionsFor(
            isFavorite: false,
            isCached: false,
            isImported: true,
          )[2]),
          l10n.localSongsRemove);
      expect(
          labelOf(actionsFor(
            isFavorite: false,
            isCached: true,
            isImported: false,
          )[2]),
          l10n.localSongsCachedRemove);

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
      expect(labelOf(notFavorite), l10n.favoriteAdd);
      expect(labelOf(favorite), l10n.favoriteRemove);
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
