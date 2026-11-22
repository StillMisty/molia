import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/window/playback_menu.dart';
import 'package:molia/services/window/tray_menu_labels.dart';

/// macOS 播放菜单的 Dart 端：命令路由与载荷去重（不构建 AppKit 菜单）。
/// ADR-0036。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelName = 'top.stillmisty.molia/playback_menu';
  const labels = TrayMenuLabels(
    showWindow: 'Show window',
    menuTitle: 'Playback',
    play: 'Play',
    pause: 'Pause',
    previous: 'Previous track',
    next: 'Next track',
    addFavorite: 'Add to favorites',
    removeFavorite: 'Remove from favorites',
    quit: 'Quit',
  );

  late MethodChannel channel;
  late List<MethodCall> updates;

  setUp(() {
    channel = MethodChannel(channelName);
    updates = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          updates.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  PlaybackMenu createMenu() {
    return PlaybackMenu(channel: channel, supported: true);
  }

  Future<void> sendCommand(String method) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channelName,
          const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
          (_) {},
        );
  }

  test('菜单命令落到托盘同一批闭包；初始化前与 dispose 后忽略', () async {
    final menu = createMenu();
    var toggles = 0;
    var previous = 0;
    var next = 0;

    await sendCommand('togglePlayPause');
    expect(toggles, 0, reason: '初始化前没有处理函数，命令忽略');

    await menu.init(
      labels: labels,
      hasTrack: true,
      isPlaying: false,
      onTogglePlay: () => toggles++,
      onPrevious: () => previous++,
      onNext: () => next++,
    );
    await sendCommand('togglePlayPause');
    await sendCommand('previousTrack');
    await sendCommand('nextTrack');
    await sendCommand('unknownCommand');
    expect((toggles, previous, next), (1, 1, 1));

    menu.dispose();
    await sendCommand('togglePlayPause');
    expect(toggles, 1, reason: 'dispose 后摘掉处理函数');
  });

  test('首份状态与变化后的载荷；相同状态不重复发送', () async {
    final menu = createMenu();
    await menu.init(
      labels: labels,
      hasTrack: false,
      isPlaying: false,
      onTogglePlay: () {},
      onPrevious: () {},
      onNext: () {},
    );
    expect(updates, hasLength(1));
    expect(updates.single.method, 'update');
    expect(updates.single.arguments, {
      'menuTitle': 'Playback',
      'playPauseLabel': 'Play',
      'previousLabel': 'Previous track',
      'nextLabel': 'Next track',
      'hasTrack': false,
      'isPlaying': false,
    });

    menu.sync(labels: labels, hasTrack: false, isPlaying: false);
    await pumpEventQueue();
    expect(updates, hasLength(1), reason: '相同状态不再下发');

    menu.sync(labels: labels, hasTrack: true, isPlaying: true);
    await pumpEventQueue();
    expect(updates, hasLength(2));
    expect(updates.last.arguments, containsPair('playPauseLabel', 'Pause'));
    expect(updates.last.arguments, containsPair('hasTrack', true));
    expect(updates.last.arguments, containsPair('isPlaying', true));

    menu.sync(labels: labels, hasTrack: true, isPlaying: false);
    await pumpEventQueue();
    expect(updates, hasLength(3));
    expect(updates.last.arguments, containsPair('playPauseLabel', 'Play'));
  });

  test('非 macOS 平台不碰通道', () async {
    final menu = PlaybackMenu(channel: channel, supported: false);
    await menu.init(
      labels: labels,
      hasTrack: true,
      isPlaying: true,
      onTogglePlay: () {},
      onPrevious: () {},
      onNext: () {},
    );
    menu.sync(labels: labels, hasTrack: true, isPlaying: false);
    await pumpEventQueue();
    expect(updates, isEmpty);
  });
}
