/// 歌词滚动行为测试：
/// - 手动滚动只暂停跟随，停手静置后自动恢复并滚回当前行（暂停播放时不拽回）；
/// - 激活行锚点位于视口中上部（顶栏比底栏高，居中会视觉偏下）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/source.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/domain/ports/source_registry.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/models/play_mode.dart';
import 'package:molia/providers/lyrics_provider.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/lyrics_display/lyrics_display_settings.dart';
import 'package:molia/services/lyrics_service.dart';
import 'package:molia/services/notification_service.dart';
import 'package:molia/widgets/lyric_karaoke_text.dart';
import 'package:molia/widgets/lyrics.dart';

import '../support/fake_music_source.dart';
import '../support/fakes.dart';
import '../support/settings_test_support.dart';

/// 30 行、每行 5 秒的时间轴歌词：60s 处正好是第 12 行。
String _buildLrc() {
  final buffer = StringBuffer();
  for (var i = 0; i < 30; i++) {
    final seconds = i * 5;
    final mm = (seconds ~/ 60).toString().padLeft(2, '0');
    final ss = (seconds % 60).toString().padLeft(2, '0');
    buffer.writeln('[$mm:$ss.00]Line $i');
  }
  return buffer.toString();
}

/// 偶数行带扩展文本、奇数行为空：同时覆盖「空翻译不占位」。
String _buildExtendedLrc(String prefix) {
  final buffer = StringBuffer();
  for (var i = 0; i < 30; i += 2) {
    final seconds = i * 5;
    final mm = (seconds ~/ 60).toString().padLeft(2, '0');
    final ss = (seconds % 60).toString().padLeft(2, '0');
    buffer.writeln('[$mm:$ss.00]$prefix $i');
  }
  return buffer.toString();
}

/// 第 12 行（60s，测试的当前行）的逐字时间轴：词文本拼接与主行一致（合约）。
String _buildWordLrc() => '[01:00.00]<0,500>Line <500,500>12';

class _FakeLyricsService extends LyricsService {
  _FakeLyricsService(this.lrc, {this.translation, this.roma, this.lxlyric});

  final String lrc;
  final String? translation;
  final String? roma;
  final String? lxlyric;

  @override
  Future<LyricsResult?> getLyrics(
    String songName,
    String artistName,
    String trackId, {
    Track? track,
  }) async =>
      LyricsResult(
        lyric: lrc,
        translation: translation,
        roma: roma,
        lxlyric: lxlyric,
        provider: 'test',
      );
}

Track _track() => Track(
      id: const TrackId('fake', 'lyrics-scroll'),
      title: 'Title',
      artists: const [Artist(name: 'Artist')],
      album: 'Album',
      duration: const Duration(minutes: 10),
      origin: TrackOrigin.lx,
      payload: const {'id': 'lyrics-scroll'},
    );

BackendSnapshot _snapshot({
  bool isPlaying = true,
  int positionSeconds = 60,
}) =>
    BackendSnapshot(
      current: _track(),
      queue: [_track()],
      currentIndex: 0,
      isPlaying: isPlaying,
      position: Duration(seconds: positionSeconds),
      duration: const Duration(minutes: 10),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePlaybackBackend backend;
  late PlaybackProvider playback;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    backend = FakePlaybackBackend();
    playback = buildTestPlaybackProvider(backend: backend);
  });

  tearDown(() => playback.dispose());

  /// 挂载歌词组件：420x900、进度 60s（第 12 行），等首轮歌词加载与自动滚动落定。
  ///
  /// [fontFamily] 注入 MaterialApp 主题（模拟设置页的「应用字体」）。
  Future<ScrollController> pumpLyrics(
    WidgetTester tester, {
    LyricsService? service,
    LyricsDisplaySettings? settings,
    SourceRegistry? registry,
    String? fontFamily,
  }) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    backend.emit(_snapshot());

    final controller = ScrollController();
    addTearDown(controller.dispose);
    final effectiveSettings =
        settings ?? LyricsDisplaySettings(settings: testSettingsRegistry());
    addTearDown(effectiveSettings.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlaybackProvider>.value(value: playback),
          ChangeNotifierProvider<LyricsProvider>.value(
            value: LyricsProvider(
              service: service ?? _FakeLyricsService(_buildLrc()),
            ),
          ),
          ChangeNotifierProvider<LyricsDisplaySettings>.value(
            value: effectiveSettings,
          ),
          Provider<NotificationService>.value(
            value: NotificationService(GlobalKey<ScaffoldMessengerState>()),
          ),
          // 评论入口的能力判定来源（未注册 = 视为不支持，入口禁用）。
          Provider<SourceRegistry?>.value(value: registry),
        ],
        child: MaterialApp(
          // 不注入字体时保持与原来一致的默认主题（MaterialApp 默认主题）。
          theme: fontFamily == null ? null : ThemeData(fontFamily: fontFamily),
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: Scaffold(
            body: LyricsWidget(controller: controller),
          ),
        ),
      ),
    );

    // 首帧 post-frame 触发取词 → 完成 setState → 首个自动滚动动画（600ms）。
    // 多次计时 pump 让滚动/行样式动画完整推进（首帧 tick 常为 0 进度）。
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    return controller;
  }

  /// 慢速上滑：每段移动后停顿再抬手，速度趋近 0（不产生惯性滑行），
  /// 保证拖动后停在哪里就停在哪里，测试不被甩动干扰。
  Future<void> dragUpSlowly(WidgetTester tester, double dy) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
    );
    await tester.pump(const Duration(milliseconds: 200));
    const steps = 3;
    for (var i = 0; i < steps; i++) {
      await gesture.moveBy(Offset(0, dy / steps));
      await tester.pump(const Duration(milliseconds: 400));
    }
    await gesture.up();
    await tester.pump();
  }

  /// 触发恢复计时并让后续滚动动画完整跑完。
  Future<void> pumpResume(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 3));
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }
  }

  /// FAB menu 的项（组件常驻挂载，未展开也可读取）。
  List<M3EFabMenuItem> fabItems(WidgetTester tester) =>
      tester.widget<M3EFabMenu>(find.byType(M3EFabMenu)).items;

  /// FAB menu 项的图标（顺序即菜单自上而下的顺序）。
  List<IconData> fabIcons(WidgetTester tester) => [
        for (final item in fabItems(tester)) (item.icon as Icon).icon!,
      ];

  /// 展开 FAB menu 并点击指定 label 的项（等菜单弹簧落定）。
  Future<void> tapFabItem(WidgetTester tester, String label) async {
    await tester.tap(find.byKey(const Key('lyricsQuickActions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  /// 文本实际生效的字体族：环境 DefaultTextStyle 合并组件自身样式后的结果
  /// （与 Text / RichText 的解析口径一致）。歌词行若用字面量行样式替换掉
  /// 主题样式，这里就会是 null（引擎默认字体）而不是主题注入的应用字体。
  String? resolvedFontFamily(WidgetTester tester, Finder finder) {
    final element = tester.element(finder);
    return DefaultTextStyle.of(element)
        .style
        .merge(tester.widget<Text>(finder).style)
        .fontFamily;
  }

  testWidgets('手动滚动后延迟自动恢复跟随并滚回当前行', (tester) async {
    final controller = await pumpLyrics(tester);

    // 初次加载即自动跟随：菜单里不应出现「居中当前行」。
    expect(
      fabIcons(tester),
      isNot(contains(Icons.vertical_align_center_rounded)),
      reason: '自动跟随中不显示恢复项',
    );
    final double followingOffset = controller.offset;

    // 手动上滑远离当前行：暂停跟随，菜单出现恢复项。
    await dragUpSlowly(tester, -300);
    expect(
      fabIcons(tester),
      contains(Icons.vertical_align_center_rounded),
      reason: '手动滚动后应暂停跟随并显示恢复项',
    );
    final double pausedOffset = controller.offset;
    expect(pausedOffset, greaterThan(followingOffset));

    // 停手静置满恢复延迟：自动跟随恢复，滚回当前行，恢复项消失。
    await pumpResume(tester);
    expect(
      fabIcons(tester),
      isNot(contains(Icons.vertical_align_center_rounded)),
      reason: '延迟到点后应自动恢复跟随',
    );
    expect(controller.offset, closeTo(followingOffset, 2.0));
  });

  testWidgets('进入复制模式会取消待恢复的自动跟随', (tester) async {
    final controller = await pumpLyrics(tester);
    final double followingOffset = controller.offset;

    // 手动滚动：暂停跟随并排队「延迟恢复」。
    await dragUpSlowly(tester, -260);
    expect(fabIcons(tester), contains(Icons.edit_note_rounded));

    // 恢复计时到点前进入复制模式：队列中的恢复应被取消。
    await tapFabItem(tester, '复制歌词模式');
    expect(playback.currentMode, PlayMode.singleRepeat);
    final double pausedOffset = controller.offset;
    expect(pausedOffset, greaterThan(followingOffset));

    await pumpResume(tester);
    expect(
      controller.offset,
      closeTo(pausedOffset, 1.0),
      reason: '复制模式下不应自动恢复跟随',
    );
    // 复制模式出口保留：菜单项文案变为「退出复制模式」。
    expect(fabItems(tester).map((item) => item.label), contains('退出复制模式'));
  });

  testWidgets('暂停中恢复只还原跟随状态，播放后继续跟随', (tester) async {
    final controller = await pumpLyrics(tester);
    final double followingOffset = controller.offset;

    // 暂停播放后手动滚动。
    backend.emit(_snapshot(isPlaying: false));
    await tester.pump();
    await dragUpSlowly(tester, -300);
    final double pausedOffset = controller.offset;
    expect(pausedOffset, greaterThan(followingOffset));

    // 延迟到点：暂停中不把视图从用户停留处拽回。
    await pumpResume(tester);
    expect(controller.offset, closeTo(pausedOffset, 1.0));

    // 恢复播放并推进到下一行：跟随继续，滚回当前行。
    backend.emit(_snapshot(positionSeconds: 65));
    await tester.pump();
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(
      controller.offset,
      lessThan(pausedOffset - 50),
      reason: '恢复播放后应滚回当前行',
    );
  });

  testWidgets('激活行锚点位于视口中上部', (tester) async {
    await pumpLyrics(tester);

    final viewport = tester.getRect(find.byType(ListView));
    // 锚定对象是「主行文本块」的顶边：直接落在锚点比例处（不按目标高度
    // 缩放，长行换行 / 带扩展行的项越高，落点也不会偏）。
    final textRect = tester.getRect(find.text('Line 12'));

    // 自动跟随中底栏隐藏：锚点 = 可见区域中线（40px 顶部渐变带）再上移
    // 14% 视口高度（落在约 38%–40% 的中上位置）。
    final double anchorFraction =
        ((40.0 + viewport.height) / 2.0 - viewport.height * 0.14) /
            viewport.height;
    final double expectedTop = viewport.top + anchorFraction * viewport.height;
    expect(textRect.top, closeTo(expectedTop, 1.0));
    expect(
      (textRect.top - viewport.top) / viewport.height,
      inInclusiveRange(0.36, 0.42),
      reason: '激活行应位于视口中上部（约 38%–40%）',
    );
  });

  testWidgets('长行换行时仍按主行顶边锚定（扩展行不影响落点）', (tester) async {
    final settings = LyricsDisplaySettings(settings: testSettingsRegistry());
    const longLine = '这是一句特别特别长的歌词要换很多行才能放得下';
    // 12 行引导 + 60s 处的长行（换行多行）+ 扩展行；当前行前要有足够内容，
    // 锚点位置才可达（贴顶时列表无法把行往上推）。
    final buffer = StringBuffer();
    for (var i = 0; i < 12; i++) {
      final seconds = i * 5;
      final mm = (seconds ~/ 60).toString().padLeft(2, '0');
      final ss = (seconds % 60).toString().padLeft(2, '0');
      buffer.writeln('[$mm:$ss.00]Line $i');
    }
    buffer.writeln('[01:00.00]$longLine$longLine$longLine');
    buffer.writeln('[02:00.00]结束');
    await pumpLyrics(
      tester,
      settings: settings,
      service: _FakeLyricsService(
        buffer.toString(),
        translation: '[01:00.00]这是当前行的翻译',
      ),
    );

    final viewport = tester.getRect(find.byType(ListView));
    final textRect = tester.getRect(find.text('$longLine$longLine$longLine'));
    // 长行确实换行了：高度是多行（远超普通单行）。
    final double singleRowHeight = tester.getRect(find.text('Line 11')).height;
    expect(textRect.height, greaterThan(singleRowHeight * 3));
    // 扩展行显示在当前行下方，但落点仍以主行顶边为准。
    expect(find.text('这是当前行的翻译'), findsOneWidget);
    final double anchorFraction =
        ((40.0 + viewport.height) / 2.0 - viewport.height * 0.14) /
            viewport.height;
    expect(
      textRect.top,
      closeTo(viewport.top + anchorFraction * viewport.height, 1.0),
    );
  });

  testWidgets('歌词页每行显示自己的翻译，且不受输出侧开关影响', (tester) async {
    final settings = LyricsDisplaySettings(settings: testSettingsRegistry());
    await pumpLyrics(
      tester,
      settings: settings,
      service: _FakeLyricsService(
        _buildLrc(),
        translation: _buildExtendedLrc('译'),
      ),
    );

    // 偶数行（10 / 12 / 14）各自有翻译就渲染；奇数行无翻译不占位。
    expect(find.text('译 10'), findsOneWidget);
    expect(find.text('译 12'), findsOneWidget);
    expect(find.text('译 14'), findsOneWidget);
    expect(find.text('译 11'), findsNothing);

    // 输出侧（桌面 / 通知 / 蓝牙）开关与歌词页无关。
    await settings.setTranslationEnabled(false);
    await tester.pump();
    expect(find.text('译 12'), findsOneWidget);

    // 歌词页开关关闭后所有行翻译消失（收起动画走完）。
    await settings.setPageTranslationEnabled(false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('译 10'), findsNothing);
    expect(find.text('译 12'), findsNothing);
    expect(find.text('译 14'), findsNothing);
  });

  testWidgets('行切换不改变其他行的翻译（逐行常显）', (tester) async {
    final settings = LyricsDisplaySettings(settings: testSettingsRegistry());
    await pumpLyrics(
      tester,
      settings: settings,
      service: _FakeLyricsService(
        _buildLrc(),
        translation: _buildExtendedLrc('译'),
      ),
    );
    expect(find.text('译 12'), findsOneWidget);

    // 推进到第 14 行：12 不再是当前行，但它的翻译仍随行保留；
    // 14 成为当前行后翻译同样在。
    backend.emit(_snapshot(positionSeconds: 70));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('译 12'), findsOneWidget);
    expect(find.text('译 14'), findsOneWidget);
  });

  testWidgets('罗马音按歌词页开关独立门控', (tester) async {
    final settings = LyricsDisplaySettings(settings: testSettingsRegistry());
    await pumpLyrics(
      tester,
      settings: settings,
      service: _FakeLyricsService(
        _buildLrc(),
        translation: _buildExtendedLrc('译'),
        roma: _buildExtendedLrc('Roma'),
      ),
    );

    // 默认关：罗马音不显示；翻译逐行照常。
    expect(find.text('Roma 12'), findsNothing);
    expect(find.text('Roma 14'), findsNothing);
    expect(find.text('译 12'), findsOneWidget);

    await settings.setPageRomaEnabled(true);
    await tester.pump();
    expect(find.text('Roma 12'), findsOneWidget);
    expect(find.text('Roma 14'), findsOneWidget);

    await settings.setPageTranslationEnabled(false);
    await tester.pump();
    expect(find.text('译 12'), findsNothing);
    expect(find.text('Roma 12'), findsOneWidget);
  });

  testWidgets('歌词行跟随应用字体：主行 / 逐字 / 翻译 / 罗马音', (tester) async {
    // 歌词行的行样式是「替换式」的 DefaultTextStyle：一旦写字面量样式，
    // 字体族就丢成引擎默认字体，与本页其它文字、设置页所选「应用字体」不一致。
    const applied = 'Noto Serif CJK SC';
    final settings = LyricsDisplaySettings(settings: testSettingsRegistry());
    await settings.setPageRomaEnabled(true);
    await pumpLyrics(
      tester,
      settings: settings,
      fontFamily: applied,
      service: _FakeLyricsService(
        _buildLrc(),
        translation: _buildExtendedLrc('译'),
        roma: _buildExtendedLrc('Roma'),
        // 当前行（第 12 行）带逐字时间轴 → 走 KaraokeLyricText 分支。
        lxlyric: _buildWordLrc(),
      ),
    );

    // 普通行主行（非当前行）。
    expect(resolvedFontFamily(tester, find.text('Line 10')), applied);
    // 当前行翻译 / 罗马音（行样式下的扩展行）。
    expect(resolvedFontFamily(tester, find.text('译 12')), applied);
    expect(resolvedFontFamily(tester, find.text('Roma 12')), applied);
    // 当前行逐字渲染（KaraokeLyricText 内部 Text.rich 的根样式）。
    expect(
      resolvedFontFamily(
        tester,
        find.descendant(
          of: find.byType(KaraokeLyricText),
          matching: find.byType(Text),
        ),
      ),
      applied,
    );
  });

  testWidgets('歌词页操作 FAB menu：项集与显隐随状态同步', (tester) async {
    await pumpLyrics(
      tester,
      // 渠道支持评论：与信息页入口共享能力位（歌词页不再放评论项）。
      registry: FakeSourceRegistry({
        'fake': FakeMusicSource(
          'fake',
          capabilities: const SourceCapabilities(search: true, comment: true),
        ),
      }),
    );

    // 取 FAB menu 最近一层包装：隐藏态判定用 IgnorePointer，透明度用 Opacity。
    IgnorePointer nearestIgnore() => tester.widget<IgnorePointer>(
          find
              .ancestor(
                of: find.byType(M3EFabMenu),
                matching: find.byType(IgnorePointer),
              )
              .first,
        );
    Opacity nearestOpacity() => tester.widget<Opacity>(
          find
              .ancestor(
                of: find.byType(M3EFabMenu),
                matching: find.byType(Opacity),
              )
              .first,
        );

    // 自动跟随中：操作栏收起（弹簧落定），手势穿透不挡歌词滚动。
    expect(nearestIgnore().ignoring, isTrue);
    expect(nearestOpacity().opacity, 0);

    // 项集与顺序：跟随中不含「居中当前行」；评论已迁到信息页。
    expect(
      fabIcons(tester),
      const [
        Icons.swap_horiz_rounded,
        Icons.edit_note_rounded,
        Icons.checklist_rounded,
      ],
    );

    // 手动滚动暂停跟随：居中项入列，操作栏展开且可交互。
    await dragUpSlowly(tester, -300);
    expect(fabIcons(tester), contains(Icons.vertical_align_center_rounded));
    expect(nearestIgnore().ignoring, isFalse);
    expect(nearestOpacity().opacity, 1);

    // 进入复制模式：菜单项文案切换为出口。
    await tapFabItem(tester, '复制歌词模式');
    expect(playback.currentMode, PlayMode.singleRepeat);
    expect(fabItems(tester).map((item) => item.label), contains('退出复制模式'));
    expect(fabIcons(tester), contains(Icons.playlist_play_rounded));

    // 播放模式切换的通知节流计时器跑完，避免 pending timer 报错。
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('评论入口不在歌词页：评论已迁到歌曲信息页', (tester) async {
    await pumpLyrics(tester);

    expect(fabIcons(tester), isNot(contains(Icons.comment_rounded)));
  });

  testWidgets('歌词页操作 FAB menu：停靠右下角、项文案长短齐整', (tester) async {
    await pumpLyrics(tester);
    // 手动滚动暂停跟随 → 操作栏展开（收起态只验几何会被 IgnorePointer 掩盖）。
    await dragUpSlowly(tester, -300);

    // 位置：贴在歌词区的右下角（屏边距 16），不再压着左侧的阅读边。
    final fab = tester.getRect(find.byKey(const Key('lyricsQuickActions')));
    final lyrics = tester.getRect(find.byType(LyricsWidget));
    expect(lyrics.right - fab.right, closeTo(16, 0.5), reason: 'FAB 贴右缘');
    expect(lyrics.bottom - fab.bottom, closeTo(16, 0.5), reason: 'FAB 贴下缘');

    // 文案：海报入口用短名（与其余项同档），不吃整句说明。
    expect(
      fabItems(tester).map((item) => item.label),
      contains('歌词海报'),
    );
    expect(
      fabItems(tester).map((item) => item.label),
      isNot(contains('选择歌词片段生成海报或分享')),
    );

    await tester.tap(find.byKey(const Key('lyricsQuickActions')));
    await tester.pumpAndSettle();
    expect(find.text('歌词海报'), findsOneWidget);
  });

  testWidgets('本地下载曲目：FAB menu 隐藏「换歌词」入口', (tester) async {
    await pumpLyrics(tester);

    const localTrack = Track(
      id: TrackId('local', 'fake:lyrics-scroll'),
      title: '本地歌曲',
      artists: [Artist(name: 'Artist')],
      origin: TrackOrigin.localFile,
      payload: {'path': '/downloads/a.mp3', 'songId': 'fake:lyrics-scroll'},
    );
    backend.emit(const BackendSnapshot(
      current: localTrack,
      queue: [localTrack],
      currentIndex: 0,
      isPlaying: true,
      position: Duration(seconds: 60),
      duration: Duration(minutes: 10),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final icons = fabIcons(tester);
    expect(icons, isNot(contains(Icons.swap_horiz_rounded)));
    expect(icons, contains(Icons.checklist_rounded));

    await tester.pump(const Duration(milliseconds: 300));
  });
}
