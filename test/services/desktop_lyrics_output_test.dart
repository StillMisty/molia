import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/models/lyric_line.dart';
import 'package:molia/services/lyrics_display/desktop_lyrics_output.dart';
import 'package:molia/services/lyrics_display/lyrics_channel.dart';
import 'package:molia/services/lyrics_display/lyrics_display_settings.dart';
import 'package:molia/services/lyrics_display/lyrics_output.dart';

/// 桌面输出：通道协议编解码 + 暂停/无歌词回退映射 + 原生动作事件。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelName = 'top.stillmisty.molia/lyrics';
  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(channelName), (call) async {
      calls.add(call);
      switch (call.method) {
        case 'desktop.canDrawOverlays':
        case 'desktop.isSupported':
          return true;
        case 'audioRoute.isA2dpConnected':
          return false;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(channelName), null);
  });

  Future<LyricsDisplaySettings> desktopSettings() async {
    final settings = LyricsDisplaySettings();
    await settings.setDesktopEnabled(true);
    return settings;
  }

  LyricsPresentation presentation({
    String line = 'A',
    bool isPlaying = true,
    bool hasLyrics = true,
    List<String> extended = const [],
    List<String> upcoming = const [],
  }) =>
      LyricsPresentation(
        trackId: 'fake:1',
        title: '歌名',
        line: line,
        extended: extended,
        upcoming: upcoming,
        isPlaying: isPlaying,
        hasLyrics: hasLyrics,
      );

  test('显示 / 配置 / 更新 / 隐藏按协议下发', () async {
    final channel = LyricsChannel();
    final output = DesktopLyricsOutput(channel: channel, supported: true);
    final settings = await desktopSettings();
    await settings.setDesktopFontSize(30);

    // 播放态未知时不抢先建窗（暂停隐藏默认开）：首次投送把窗口带出来。
    await output.start(settings);
    await output.apply(presentation());
    await pumpEventQueue();
    final methods = calls.map((call) => call.method).toList();
    expect(methods, contains('desktop.canDrawOverlays'));
    expect(methods, contains('desktop.show'));
    final showCall = calls.firstWhere((call) => call.method == 'desktop.show');
    expect((showCall.arguments as Map)['fontSize'], 30);

    // 窗口已在且配置没变：再次 start（设置变更触发）不重发 setConfig，
    // 避免原生无谓重建（重建会闪一下横滚位移）。
    calls.clear();
    await output.start(settings);
    await pumpEventQueue();
    expect(
      calls.map((call) => call.method),
      isNot(contains('desktop.setConfig')),
    );

    // 配置真的变了才下发。
    await settings.setDesktopFontSize(32);
    await output.start(settings);
    await pumpEventQueue();
    final configCall =
        calls.lastWhere((call) => call.method == 'desktop.setConfig');
    expect((configCall.arguments as Map)['fontSize'], 32);

    await output.apply(presentation());
    final updateCall =
        calls.lastWhere((call) => call.method == 'desktop.update');
    expect((updateCall.arguments as Map)['line'], 'A');

    // 控制条配色随配置下发（M3E pill 的容器 / 图标色）。
    final config = showCall.arguments as Map;
    expect(config['controlBackground'], isA<int>());
    expect(config['controlTint'], isA<int>());

    await output.stop();
    expect(calls.map((call) => call.method), contains('desktop.hide'));
  });

  test('权限未授予：capability=needsPermission 且不 show', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(channelName), (call) async {
      calls.add(call);
      if (call.method == 'desktop.canDrawOverlays') return false;
      return null;
    });
    final output = DesktopLyricsOutput(
      channel: LyricsChannel(),
      supported: true,
    );
    await output.start(await desktopSettings());
    await pumpEventQueue();
    expect(output.capability, LyricsOutputCapability.needsPermission);
    expect(calls.map((call) => call.method), isNot(contains('desktop.show')));
    await output.stop();
  });

  test('逐字时间轴与位置随更新下发，回退行不带逐字', () async {
    final channel = LyricsChannel();
    final output = DesktopLyricsOutput(channel: channel, supported: true);
    final settings = await desktopSettings();
    // 本用例只看内容映射：关掉暂停隐藏，避免暂停即收起窗口。
    await settings.setDesktopHideOnPause(false);
    await output.start(settings);

    await output.apply(LyricsPresentation(
      trackId: 'fake:1',
      title: '歌名',
      line: 'AB',
      isPlaying: true,
      hasLyrics: true,
      positionMs: 1500,
      positionAtEpochMs: 1700000000000,
      scrollFollowsSinging: false,
      lineStartMs: 1000,
      lineEndMs: 3000,
      words: const [
        LyricWord(
          start: Duration(milliseconds: 1000),
          end: Duration(milliseconds: 2000),
          text: 'A',
        ),
        LyricWord(
          start: Duration(milliseconds: 2000),
          end: Duration(milliseconds: 3000),
          text: 'B',
        ),
      ],
    ));
    await pumpEventQueue();
    final update = calls.lastWhere((call) => call.method == 'desktop.update');
    final map = update.arguments as Map;
    expect(map['positionMs'], 1500);
    expect(map['positionAtEpochMs'], 1700000000000,
        reason: '位置生效时刻要下发：原生据此补偿通道传输延迟');
    expect(map['scrollFollowsSinging'], isFalse);
    expect(map['lineStartMs'], 1000);
    expect(map['lineEndMs'], 3000);
    final words = map['words'] as List;
    expect(words, hasLength(2));
    expect((words.first as Map)['t'], 'A');
    expect((words.first as Map)['s'], 1000);
    expect((words.first as Map)['e'], 2000);

    // 暂停回退为歌名：逐字时间轴必须撤下（歌名没有词轴）。
    await settings.setDesktopPauseBehavior(LyricsPauseBehavior.title);
    await output.apply(LyricsPresentation(
      trackId: 'fake:1',
      title: '歌名',
      line: 'AB',
      isPlaying: false,
      hasLyrics: true,
      positionMs: 1500,
      words: const [
        LyricWord(
          start: Duration(milliseconds: 1000),
          end: Duration(milliseconds: 2000),
          text: 'A',
        ),
      ],
    ));
    await pumpEventQueue();
    final fallback = calls.lastWhere((call) => call.method == 'desktop.update');
    expect((fallback.arguments as Map)['words'], isNull);
    // 回退行同时撤下行时间轴（不参与进度滚动）。
    expect((fallback.arguments as Map)['lineStartMs'], -1);
    expect((fallback.arguments as Map)['lineEndMs'], -1);
    await output.stop();
  });

  test('暂停与无歌词回退在输出映射层应用', () async {
    final channel = LyricsChannel();
    final output = DesktopLyricsOutput(channel: channel, supported: true);
    final settings = await desktopSettings();
    // 本用例只看内容映射：关掉暂停隐藏，避免暂停即收起窗口。
    await settings.setDesktopHideOnPause(false);
    await settings.setDesktopPauseBehavior(LyricsPauseBehavior.title);
    await output.start(settings);

    await output.apply(presentation(
      isPlaying: false,
      extended: const ['翻译'],
      upcoming: const ['下一行'],
    ));
    final paused = calls.lastWhere((call) => call.method == 'desktop.update');
    expect((paused.arguments as Map)['line'], '歌名');
    expect((paused.arguments as Map)['extended'], isEmpty);

    await output.apply(presentation(hasLyrics: false, line: ''));
    final noLyrics = calls.lastWhere((call) => call.method == 'desktop.update');
    expect((noLyrics.arguments as Map)['line'], '歌名');
    expect((noLyrics.arguments as Map)['extended'], isEmpty);

    await output.stop();
  });

  test('暂停回退同步清空翻译/罗马音与后续行（三种策略）', () async {
    final channel = LyricsChannel();
    final output = DesktopLyricsOutput(channel: channel, supported: true);
    final settings = await desktopSettings();
    // 本用例只看内容映射：关掉暂停隐藏，避免暂停即收起窗口。
    await settings.setDesktopHideOnPause(false);
    await output.start(settings);

    Future<Map> lastUpdate() async {
      await pumpEventQueue();
      final call = calls.lastWhere((call) => call.method == 'desktop.update');
      return call.arguments as Map;
    }

    // keep：主行与扩展行原样保留。
    await settings.setDesktopPauseBehavior(LyricsPauseBehavior.keep);
    await output.apply(presentation(
      isPlaying: false,
      line: 'B',
      extended: const ['翻译'],
      upcoming: const ['下一行'],
    ));
    var map = await lastUpdate();
    expect(map['line'], 'B');
    expect(map['extended'], ['翻译']);
    expect(map['upcoming'], ['下一行']);

    // title：主行换歌名，翻译/罗马音与后续行撤下。
    await settings.setDesktopPauseBehavior(LyricsPauseBehavior.title);
    await output.apply(presentation(
      isPlaying: false,
      extended: const ['翻译'],
      upcoming: const ['下一行'],
    ));
    map = await lastUpdate();
    expect(map['line'], '歌名');
    expect(map['extended'], isEmpty);
    expect(map['upcoming'], isEmpty);

    // clear：主行清空，扩展行同样撤下。
    await settings.setDesktopPauseBehavior(LyricsPauseBehavior.clear);
    await output.apply(presentation(
      isPlaying: false,
      line: '',
      extended: const ['翻译'],
      upcoming: const ['下一行'],
    ));
    map = await lastUpdate();
    expect(map['line'], '');
    expect(map['extended'], isEmpty);
    expect(map['upcoming'], isEmpty);

    await output.stop();
  });

  test('暂停隐藏（默认开）：暂停只收起窗口、恢复重建并回投内容', () async {
    final channel = LyricsChannel();
    final output = DesktopLyricsOutput(channel: channel, supported: true);
    final settings = await desktopSettings();
    expect(settings.desktopHideOnPause, isTrue);

    await output.start(settings);
    await output.apply(presentation());
    await pumpEventQueue();

    // 暂停：窗口整体移除，不投送任何内容（区别于「清空」的空窗）。
    calls.clear();
    await output.apply(presentation(isPlaying: false));
    await pumpEventQueue();
    expect(calls.map((call) => call.method), ['desktop.hide']);

    // 暂停期间的位置 tick 反复投送：已隐藏即幂等，不产生通道流量。
    calls.clear();
    await output.apply(presentation(isPlaying: false, line: 'B'));
    await pumpEventQueue();
    expect(calls, isEmpty);

    // 恢复：重建窗口 + 首次内容一起下发（位置由原生持久化）。
    calls.clear();
    await output.apply(presentation(line: 'B'));
    await pumpEventQueue();
    expect(
      calls.map((call) => call.method),
      ['desktop.show', 'desktop.update'],
    );
    expect((calls.last.arguments as Map)['line'], 'B');

    await output.stop();
  });

  test('暂停隐藏期间 start 不复活窗口', () async {
    final channel = LyricsChannel();
    final output = DesktopLyricsOutput(channel: channel, supported: true);
    final settings = await desktopSettings();

    await output.start(settings);
    await output.apply(presentation(isPlaying: false));
    await pumpEventQueue();
    calls.clear();

    // 暂停中改样式 / 回前台复查能力都会再走 start：不得重新显示窗口。
    await output.start(settings);
    await pumpEventQueue();
    expect(calls.map((call) => call.method), isNot(contains('desktop.show')));

    await output.stop();
  });

  test('关闭暂停隐藏：暂停仍按回退策略投送，不收起窗口', () async {
    final channel = LyricsChannel();
    final output = DesktopLyricsOutput(channel: channel, supported: true);
    final settings = await desktopSettings();
    await settings.setDesktopHideOnPause(false);
    await settings.setDesktopPauseBehavior(LyricsPauseBehavior.title);

    await output.start(settings);
    await output.apply(presentation());
    await pumpEventQueue();
    calls.clear();

    await output.apply(presentation(isPlaying: false));
    await pumpEventQueue();
    expect(
      calls.map((call) => call.method),
      isNot(contains('desktop.hide')),
    );
    expect((calls.last.arguments as Map)['line'], '歌名');

    await output.stop();
  });

  test('清空后重新具备条件：窗口自愈重显（不依赖设置变更）', () async {
    final channel = LyricsChannel();
    final output = DesktopLyricsOutput(channel: channel, supported: true);
    final settings = await desktopSettings();

    await output.start(settings);
    await output.apply(presentation());
    await pumpEventQueue();
    await output.clear(); // 无曲目 / 输出停用：窗口移除
    await pumpEventQueue();

    calls.clear();
    await output.apply(presentation(line: 'B'));
    await pumpEventQueue();
    expect(
      calls.map((call) => call.method),
      ['desktop.show', 'desktop.update'],
    );

    await output.stop();
  });

  test('跟随主题：配置下发解析后的 ColorScheme 颜色', () async {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF3366FF));
    final channel = LyricsChannel();
    final output = DesktopLyricsOutput(
      channel: channel,
      supported: true,
      colorScheme: () => scheme,
    );
    final settings = await desktopSettings();
    await settings.setDesktopPlayedColorSource(LyricColorSource.primary);
    await output.start(settings);
    // 窗口随首次投送建立（播放态未知时不抢先显示）。
    await output.apply(presentation());
    await pumpEventQueue();

    final showCall = calls.firstWhere((call) => call.method == 'desktop.show');
    expect(
      (showCall.arguments as Map)['playedColor'],
      scheme.primary.toARGB32(),
    );
    await output.stop();
  });

  test('原生控制条动作进入 actions 流', () async {
    final channel = LyricsChannel();
    final output = DesktopLyricsOutput(channel: channel, supported: true);
    final received = <LyricsOutputAction>[];
    final subscription = output.actions.listen(received.add);

    channel.debugEmit(
      const LyricsChannelEvent('desktop.onAction', {'action': 'next'}),
    );
    await pumpEventQueue();
    expect(received, [LyricsOutputAction.next]);

    await subscription.cancel();
    await output.stop();
  });
}
