import 'package:flutter/services.dart' show SystemChannels;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/models/play_mode.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:molia/services/haptics.dart';
import 'package:molia/widgets/playback_transport.dart';
import 'package:molia/widgets/seek_bar.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fakes.dart';

/// 共享播放传输语义的契约钉死：
/// - 四个宿主共用同一组启用谓词 / 图标 / 标签 / 触感 / 命令；
/// - `PlayMode` 图标与标签只有一份映射；
/// - seek 宿主的控制器生命周期与低频快照订阅不再由页面各写一遍。
Track _track(String id) => Track(
      id: TrackId('fake', id),
      title: 'Title $id',
      artists: [Artist(name: 'Artist $id')],
      album: 'Album',
      duration: const Duration(seconds: 30),
      origin: TrackOrigin.lx,
      payload: {'id': id},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePlaybackBackend backend;
  late PlaybackProvider playback;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    backend = FakePlaybackBackend();
    playback = buildTestPlaybackProvider(backend: backend);
    // 会话读取是异步 DB；等它完成再让用例推快照，避免 dispose 后回调通知。
    await playback.preferencesReady;
  });

  tearDown(() => playback.dispose());

  /// 推一帧带曲目 / 播放态的快照（position 走独立通道，duration 在快照里）。
  void emit({
    Track? current,
    bool isPlaying = false,
    Duration position = const Duration(seconds: 5),
    Duration duration = const Duration(seconds: 30),
    PlayMode mode = PlayMode.listLoop,
  }) {
    final track = current ?? _track('a');
    backend.emit(BackendSnapshot(
      current: track,
      queue: [track],
      currentIndex: 0,
      isPlaying: isPlaying,
      position: position,
      duration: duration,
      mode: mode,
    ));
  }

  Future<void> pumpControl(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<PlaybackProvider>.value(
        value: playback,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: const [Locale('zh')],
          home: Scaffold(body: Center(child: child)),
        ),
      ),
    );
    await tester.pump();
  }

  M3EIconButton onlyButton(WidgetTester tester) =>
      tester.widget<M3EIconButton>(find.byType(M3EIconButton));

  /// 记录平台通道上的震动请求（值即 `HapticFeedbackType` 字符串）。
  List<String> recordVibrations(WidgetTester tester) {
    final vibrations = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          vibrations.add(call.arguments as String? ?? '');
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
      HapticsService.enabledNotifier.value = HapticsService.defaultEnabled;
    });
    return vibrations;
  }

  group('PlayMode 唯一映射', () {
    test('四个模式的图标与语义标签同源', () {
      final l10n = lookupAppLocalizations(const Locale('zh'));
      expect(PlayMode.shuffle.transportIcon, Icons.shuffle_rounded);
      expect(PlayMode.listLoop.transportIcon, Icons.repeat_rounded);
      expect(PlayMode.sequential.transportIcon, Icons.playlist_play_rounded);
      expect(PlayMode.singleRepeat.transportIcon, Icons.repeat_one_rounded);

      expect(PlayMode.listLoop.transportLabel(l10n), l10n.playModeListLoop);
      expect(PlayMode.sequential.transportLabel(l10n), l10n.playModeSequential);
      expect(PlayMode.shuffle.transportLabel(l10n), l10n.playModeShuffle);
      expect(
        PlayMode.singleRepeat.transportLabel(l10n),
        l10n.playModeSingleRepeat,
      );
    });

    testWidgets('按钮跟随 provider 模式：图标 / 标签换档，无曲目也可切换', (tester) async {
      final l10n = lookupAppLocalizations(const Locale('zh'));
      emit(mode: PlayMode.shuffle);
      await pumpControl(tester, const PlaybackModeButton());

      expect(find.byIcon(Icons.shuffle_rounded), findsOneWidget);
      expect(onlyButton(tester).semanticLabel, l10n.playModeShuffle);
      expect(onlyButton(tester).onPressed, isNotNull, reason: '模式是会话偏好');

      final before = List<String>.of(backend.calls);
      await tester.tap(find.byType(M3EIconButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        backend.calls.where((call) => call == 'setMode').length,
        greaterThan(0),
      );
      expect(backend.calls, isNot(before));
      // shuffle.next = listLoop：模式图标 / 标签跟着换。
      expect(playback.currentMode, PlayMode.listLoop);
      expect(find.byIcon(Icons.repeat_rounded), findsOneWidget);
      expect(onlyButton(tester).semanticLabel, l10n.playModeListLoop);
    });
  });

  group('播放 / 暂停', () {
    testWidgets('无曲目禁用：不触感、不发命令', (tester) async {
      final vibrations = recordVibrations(tester);
      await pumpControl(tester, const PlaybackPlayPauseButton());

      expect(onlyButton(tester).onPressed, isNull);
      expect(onlyButton(tester).semanticLabel, '播放');

      await tester.tap(find.byType(M3EIconButton), warnIfMissed: false);
      await tester.pump();
      expect(backend.calls, isEmpty);
      expect(vibrations, isEmpty);
    });

    testWidgets('有曲目：图标 / 标签随播放态，点按一次 = 一次触感 + 一次命令', (tester) async {
      final l10n = lookupAppLocalizations(const Locale('zh'));
      final vibrations = recordVibrations(tester);
      emit(isPlaying: false);
      await pumpControl(tester, const PlaybackPlayPauseButton());

      expect(searchIcon(tester), Icons.play_arrow_rounded);
      expect(onlyButton(tester).semanticLabel, l10n.play);
      expect(onlyButton(tester).onPressed, isNotNull);

      await tester.tap(find.byType(M3EIconButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(backend.calls, ['play']);
      expect(vibrations, ['HapticFeedbackType.lightImpact']);

      emit(isPlaying: true);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(searchIcon(tester), Icons.pause_rounded);
      expect(onlyButton(tester).semanticLabel, l10n.pause);

      await tester.tap(find.byType(M3EIconButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(backend.calls, ['play', 'pause']);
      expect(vibrations, [
        'HapticFeedbackType.lightImpact',
        'HapticFeedbackType.lightImpact',
      ]);
    });
  });

  group('上一首 / 下一首矩阵', () {
    final List<
        ({
          String name,
          Widget Function() build,
          IconData icon,
          String Function(AppLocalizations l10n) labelOf,
          String call,
        })> cases = [
      (
        name: '上一首',
        build: () => const PlaybackPreviousButton(),
        icon: Icons.skip_previous_rounded,
        labelOf: (l10n) => l10n.previousTrackTooltip,
        call: 'previous',
      ),
      (
        name: '下一首',
        build: () => const PlaybackNextButton(),
        icon: Icons.skip_next_rounded,
        labelOf: (l10n) => l10n.nextTrackTooltip,
        call: 'next',
      ),
    ];

    for (final testCase in cases) {
      testWidgets('${testCase.name}：无曲目禁用、有曲目一次触感 + 一次命令', (tester) async {
        final l10n = lookupAppLocalizations(const Locale('zh'));
        final vibrations = recordVibrations(tester);

        await pumpControl(tester, testCase.build());
        expect(find.byIcon(testCase.icon), findsOneWidget);
        expect(onlyButton(tester).semanticLabel, testCase.labelOf(l10n));
        expect(onlyButton(tester).onPressed, isNull);

        await tester.tap(find.byType(M3EIconButton), warnIfMissed: false);
        await tester.pump();
        expect(backend.calls, isEmpty);
        expect(vibrations, isEmpty);

        emit();
        await tester.pump();
        expect(onlyButton(tester).onPressed, isNotNull);

        await tester.tap(find.byType(M3EIconButton));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        expect(backend.calls, [testCase.call]);
        expect(vibrations, ['HapticFeedbackType.lightImpact']);
      });
    }
  });

  group('PlaybackSeekBar 宿主', () {
    Future<void> pumpSeek(
      WidgetTester tester, {
      SeekTimeLabels timeLabels = SeekTimeLabels.inline,
    }) =>
        pumpControl(tester, PlaybackSeekBar(timeLabels: timeLabels));

    M3ESlider slider(WidgetTester tester) =>
        tester.widget<M3ESlider>(find.byType(M3ESlider));

    testWidgets('时间标签档位由宿主选择，取值与 provider 同源', (tester) async {
      emit();
      await pumpSeek(tester, timeLabels: SeekTimeLabels.below);

      final seekBar = tester.widget<SeekBar>(find.byType(SeekBar));
      expect(seekBar.timeLabels, SeekTimeLabels.below);
      expect(find.text('0:05'), findsOneWidget);
      expect(find.text('0:30'), findsOneWidget);
    });

    testWidgets('拖动提交走 provider.seekToPosition', (tester) async {
      emit();
      await pumpSeek(tester);
      final rect = tester.getRect(find.byType(M3ESlider));

      await tester.dragFrom(
        Offset(rect.left + rect.width * 0.17, rect.center.dy),
        Offset(rect.width * 0.5, 0),
      );
      await tester.pump();

      expect(backend.calls, contains('seek'));
      expect(slider(tester).value, greaterThan(15000));
      // 落点等待（1500ms 兜底）跑完，避免测试结束报 pending timer。
      await tester.pump(const Duration(milliseconds: 1600));
    });

    testWidgets('低频快照变化只更新滑杆：播放态 / 无曲目占位', (tester) async {
      emit(isPlaying: true);
      await pumpSeek(tester);
      expect(slider(tester).wavy, isTrue);

      emit(isPlaying: false);
      await tester.pump(const Duration(milliseconds: 60));
      expect(slider(tester).wavy, isFalse);

      backend.emit(BackendSnapshot.empty);
      await tester.pump(const Duration(milliseconds: 350));
      expect(slider(tester).enabled, isFalse);
      expect(find.text('--:--'), findsNWidgets(2));
    });

    testWidgets('换曲按身份撤下预览（控制器生命周期接在宿主内）', (tester) async {
      emit();
      await pumpSeek(tester);
      final rect = tester.getRect(find.byType(M3ESlider));

      await tester.tapAt(Offset(rect.left + rect.width * 0.5, rect.center.dy));
      await tester.pump();
      expect(slider(tester).value, closeTo(15000, 1000));

      emit(current: _track('b'), position: Duration.zero);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(slider(tester).value, closeTo(0, 1), reason: '旧曲目预览不得残留');
    });

    testWidgets('宿主卸载后 dispose：兜底计时器不再回写', (tester) async {
      emit();
      await pumpSeek(tester);
      final rect = tester.getRect(find.byType(M3ESlider));

      await tester.tapAt(Offset(rect.left + rect.width * 0.5, rect.center.dy));
      await tester.pump();
      await pumpControl(tester, const SizedBox.shrink());

      await tester.pump(const Duration(milliseconds: 1600));
      expect(tester.takeException(), isNull);
    });
  });
}

/// 当前按钮里的播放态图标（`IconSwap` 落定后只留一份）。
IconData searchIcon(WidgetTester tester) {
  final icons = tester
      .widgetList<Icon>(find.descendant(
        of: find.byType(M3EIconButton),
        matching: find.byType(Icon),
      ))
      .map((icon) => icon.icon)
      .toList();
  if (icons.contains(Icons.pause_rounded)) return Icons.pause_rounded;
  if (icons.contains(Icons.play_arrow_rounded)) return Icons.play_arrow_rounded;
  throw TestFailure('按钮里没有播放 / 暂停图标：$icons');
}
