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

    await output.start(settings);
    await pumpEventQueue();
    final methods = calls.map((call) => call.method).toList();
    expect(methods, contains('desktop.canDrawOverlays'));
    expect(methods, contains('desktop.show'));
    expect(methods, contains('desktop.setConfig'));
    final showCall = calls.firstWhere((call) => call.method == 'desktop.show');
    expect((showCall.arguments as Map)['fontSize'], 30);

    await output.apply(presentation());
    final updateCall =
        calls.firstWhere((call) => call.method == 'desktop.update');
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
    await output.start(settings);

    await output.apply(LyricsPresentation(
      trackId: 'fake:1',
      title: '歌名',
      line: 'AB',
      isPlaying: true,
      hasLyrics: true,
      positionMs: 1500,
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
