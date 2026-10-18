import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/window/taskbar_thumb_bar.dart';
import 'package:molia/services/window/tray_menu_labels.dart';

/// Windows 任务栏缩略图按钮的通道契约：Dart 状态同步 ↔ 原生点击回调。
///
/// 原生实现见 `windows/runner/taskbar_thumb_bar.cpp` 与 `flutter_window.cpp`；
/// 这里用 mock 通道锁住方法名 / 字段名 / 按钮 id，两端改名后测试先红，
/// 而不是在 Windows 上表现成「按钮点了没反应」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('top.stillmisty.molia/taskbar');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  const labels = TrayMenuLabels(
    showWindow: 'Show window',
    play: 'Play',
    pause: 'Pause',
    previous: 'Previous',
    next: 'Next',
    addFavorite: 'Add to favorites',
    removeFavorite: 'Remove from favorites',
    quit: 'Quit',
  );

  late List<MethodCall> calls;
  late TaskbarThumbBar taskbar;
  late int playCount;
  late int previousCount;
  late int nextCount;
  late int favoriteCount;

  setUp(() {
    calls = <MethodCall>[];
    playCount = previousCount = nextCount = favoriteCount = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    taskbar = TaskbarThumbBar(channel: channel, supported: true);
  });

  tearDown(() {
    taskbar.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> init() => taskbar.init(
        labels: labels,
        onTogglePlay: () => playCount++,
        onPrevious: () => previousCount++,
        onNext: () => nextCount++,
        onToggleFavorite: () => favoriteCount++,
      );

  Future<void> flush() => Future<void>.delayed(const Duration(milliseconds: 10));

  Map<Object?, Object?> argsOf(MethodCall call) =>
      call.arguments as Map<Object?, Object?>;

  /// 模拟原生侧按钮点击（与 `taskbar_thumb_bar.cpp` 的按下发一致）。
  Future<void> press(String action) async {
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('pressed', action),
      ),
      (ByteData? _) {},
    );
  }

  test('初始化把首帧状态下发给原生（字段名即原生解析的键）', () async {
    await init();
    await flush();

    expect(calls, hasLength(1));
    expect(calls.single.method, 'update');
    final args = argsOf(calls.single);
    expect(args['hasTrack'], isFalse);
    expect(args['isPlaying'], isFalse);
    expect(args['isFavorite'], isFalse);
    expect(args['tooltipPlayPause'], 'Play');
    expect(args['tooltipFavorite'], 'Add to favorites');
    expect(args['tooltipPrevious'], 'Previous');
    expect(args['tooltipNext'], 'Next');
  });

  test('播放 / 收藏 / 文案变化各下发一次；重复值不下发', () async {
    await init();
    calls.clear();

    taskbar.setPlaybackState(hasTrack: true, isPlaying: true);
    taskbar.setFavorite(true);
    // 与当前值相同：不下发（原生每次都会重画，白跑没有意义）。
    taskbar.setPlaybackState(hasTrack: true, isPlaying: true);
    taskbar.setFavorite(true);
    taskbar.setLabels(labels);
    await flush();

    expect(calls, hasLength(2), reason: '播放态一次 + 收藏态一次');
    final args = argsOf(calls.last);
    expect(args['hasTrack'], isTrue);
    expect(args['isPlaying'], isTrue);
    expect(args['isFavorite'], isTrue);
    expect(args['tooltipPlayPause'], 'Pause');
    expect(args['tooltipFavorite'], 'Remove from favorites');
  });

  test('文案切换单独下发（语言变化）', () async {
    await init();
    calls.clear();

    taskbar.setLabels(
      TrayMenuLabels(
        showWindow: '显示主窗口',
        play: '播放',
        pause: '暂停',
        previous: '上一首',
        next: '下一首',
        addFavorite: '收藏',
        removeFavorite: '取消收藏',
        quit: '退出',
      ),
    );
    await flush();

    expect(calls, hasLength(1));
    expect(argsOf(calls.single)['tooltipPlayPause'], '播放');
  });

  test('原生点击按按钮 id 分发到对应动作', () async {
    await init();

    await press('previous');
    await press('playPause');
    await press('next');
    await press('favorite');
    await press('unknown');
    await flush();

    expect(previousCount, 1);
    expect(playCount, 1);
    expect(nextCount, 1);
    expect(favoriteCount, 1);
  });

  test('未初始化 / 非 Windows：全部空操作', () async {
    final unsupported = TaskbarThumbBar(channel: channel, supported: false);
    await unsupported.init(
      labels: labels,
      onTogglePlay: () => playCount++,
      onPrevious: () => previousCount++,
      onNext: () => nextCount++,
      onToggleFavorite: () => favoriteCount++,
    );
    unsupported.setPlaybackState(hasTrack: true, isPlaying: true);
    unsupported.setFavorite(true);
    await press('playPause');
    await flush();

    expect(calls, isEmpty);
    expect(playCount, 0);
    unsupported.dispose();
  });

  test('dispose 后不再接收点击', () async {
    await init();
    taskbar.dispose();

    await press('playPause');
    await flush();

    expect(playCount, 0);
  });

  test('init 幂等：重复调用不再下发', () async {
    await init();
    await init();
    await flush();

    expect(calls, hasLength(1));
  });
}
