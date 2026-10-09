import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
  }) =>
      LyricsPresentation(
        trackId: 'fake:1',
        title: '歌名',
        line: line,
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

  test('暂停与无歌词回退在输出映射层应用', () async {
    final channel = LyricsChannel();
    final output = DesktopLyricsOutput(channel: channel, supported: true);
    final settings = await desktopSettings();
    await settings.setDesktopPauseBehavior(LyricsPauseBehavior.title);
    await output.start(settings);

    await output.apply(presentation(isPlaying: false));
    final paused = calls.lastWhere((call) => call.method == 'desktop.update');
    expect((paused.arguments as Map)['line'], '歌名');

    await output.apply(presentation(hasLyrics: false, line: ''));
    final noLyrics = calls.lastWhere((call) => call.method == 'desktop.update');
    expect((noLyrics.arguments as Map)['line'], '歌名');

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
