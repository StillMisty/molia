import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/playback.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/models/lyric_line.dart';
import 'package:molia/providers/lyrics_display_provider.dart';
import 'package:molia/providers/lyrics_provider.dart';
import 'package:molia/services/lyrics_display/lyrics_display_settings.dart';
import 'package:molia/services/lyrics_display/lyrics_output.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 调度：启用/停用生命周期、行变化去重、自动取词、控制条动作分发。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Track track() => Track(
        id: TrackId('fake', '1'),
        title: '歌名',
        artists: const [Artist(name: '歌手')],
        origin: TrackOrigin.lx,
        payload: const {'id': '1'},
      );

  LyricsState readyState() => LyricsState(
        trackId: 'fake:1',
        status: LyricsStatus.ready,
        lines: const [
          LyricLine(Duration.zero, 'A'),
          LyricLine(Duration(seconds: 5), 'B'),
        ],
      );

  test('启用时取词一次、行变化去重、关闭时 clear', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = LyricsDisplaySettings();
    await settings.setDesktopEnabled(true);
    final output = _FakeOutput(LyricsOutputIds.desktop);
    final requested = <String>[];
    final provider = LyricsDisplayProvider(
      settings: settings,
      outputs: [output],
      ensureLyrics: (t) async => requested.add(t.id.uri),
    );
    await pumpEventQueue();
    expect(output.starts, 1);

    provider.syncPlayback(PlaybackSnapshot(current: track(), isPlaying: true));
    await pumpEventQueue();
    expect(requested, ['fake:1']);
    // 同一曲目再次通知不重复取词。
    provider.syncPlayback(PlaybackSnapshot(current: track(), isPlaying: true));
    await pumpEventQueue();
    expect(requested, ['fake:1']);

    provider.syncLyrics(readyState());
    await pumpEventQueue();
    expect(output.applied.last.line, 'A');
    final baseline = output.applied.length;

    provider.updatePosition(const Duration(seconds: 1));
    await pumpEventQueue();
    expect(output.applied.length, baseline + 1,
        reason: '位置变化要转发给输出（逐字渐染的进度来源）');
    expect(output.applied.last.line, 'A');
    expect(output.applied.last.positionMs, 1000);

    // 位置没有变化时不重复下发（去重仍然有效）。
    provider.updatePosition(const Duration(seconds: 1));
    await pumpEventQueue();
    expect(output.applied.length, baseline + 1);

    provider.updatePosition(const Duration(seconds: 6));
    await pumpEventQueue();
    expect(output.applied.length, baseline + 2);
    expect(output.applied.last.line, 'B');

    await settings.setDesktopEnabled(false);
    await pumpEventQueue();
    expect(output.clears, greaterThan(0));

    provider.dispose();
    await pumpEventQueue();
    expect(output.stopped, isTrue);
  });

  test('关闭全部输出时不主动取词', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = LyricsDisplaySettings();
    final requested = <String>[];
    final provider = LyricsDisplayProvider(
      settings: settings,
      outputs: [_FakeOutput(LyricsOutputIds.desktop)],
      ensureLyrics: (t) async => requested.add(t.id.uri),
    );
    await pumpEventQueue();
    provider.syncPlayback(PlaybackSnapshot(current: track(), isPlaying: true));
    await pumpEventQueue();
    expect(requested, isEmpty);
    provider.dispose();
  });

  test('无曲目时 clear；控制条动作分发到命令与配置', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = LyricsDisplaySettings();
    await settings.setDesktopEnabled(true);
    final output = _FakeInteractiveOutput(LyricsOutputIds.desktop);
    final commands = <LyricsPlaybackCommand>[];
    final provider = LyricsDisplayProvider(
      settings: settings,
      outputs: [output],
      onPlaybackCommand: commands.add,
    );
    await pumpEventQueue();

    provider.syncPlayback(PlaybackSnapshot(current: track(), isPlaying: true));
    provider.syncLyrics(readyState());
    await pumpEventQueue();
    expect(output.applied, isNotEmpty);

    provider.syncPlayback(const PlaybackSnapshot());
    await pumpEventQueue();
    expect(output.clears, greaterThan(0));

    output.controller.add(LyricsOutputAction.playPause);
    output.controller.add(LyricsOutputAction.previous);
    output.controller.add(LyricsOutputAction.next);
    output.controller.add(LyricsOutputAction.lock);
    output.controller.add(LyricsOutputAction.close);
    await pumpEventQueue();

    expect(commands, [
      LyricsPlaybackCommand.playPause,
      LyricsPlaybackCommand.previous,
      LyricsPlaybackCommand.next,
    ]);
    expect(settings.desktopLock, isTrue);
    expect(settings.desktopEnabled, isFalse);
    provider.dispose();
    await output.controller.close();
  });

  test('主题变化时重新下发输出配置（跟随主题颜色）', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = LyricsDisplaySettings();
    await settings.setDesktopEnabled(true);
    final output = _FakeOutput(LyricsOutputIds.desktop);
    final theme = ChangeNotifier();
    final provider = LyricsDisplayProvider(
      settings: settings,
      outputs: [output],
      themeListenable: theme,
    );
    await pumpEventQueue();
    expect(output.starts, 1);

    theme.notifyListeners();
    await pumpEventQueue();
    expect(output.starts, 2);

    provider.dispose();
    // 释放后主题通知不再触发输出。
    theme.notifyListeners();
    await pumpEventQueue();
    expect(output.starts, 2);
    theme.dispose();
  });

  test('匀速滚动模式：跨度取首词到末词，位置带生效时刻', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = LyricsDisplaySettings();
    await settings.setDesktopEnabled(true);
    final output = _FakeOutput(LyricsOutputIds.desktop);
    final provider = LyricsDisplayProvider(settings: settings, outputs: [output]);
    await pumpEventQueue();

    provider.syncPlayback(PlaybackSnapshot(current: track(), isPlaying: true));
    provider.syncLyrics(LyricsState(
      trackId: 'fake:1',
      status: LyricsStatus.ready,
      lines: const [
        LyricLine(Duration.zero, 'A', words: [
          LyricWord(
            start: Duration(milliseconds: 100),
            end: Duration(milliseconds: 600),
            text: 'A',
          ),
        ]),
        LyricLine(Duration(seconds: 5), 'B'),
      ],
    ));
    await pumpEventQueue();

    final before = DateTime.now().millisecondsSinceEpoch;
    provider.updatePosition(const Duration(milliseconds: 300));
    await pumpEventQueue();
    final follows = output.applied.last;
    expect(follows.positionAtEpochMs, greaterThanOrEqualTo(before),
        reason: '位置生效时刻随投送下发（输出端据此补偿传输延迟）');
    expect(follows.scrollFollowsSinging, isTrue);
    expect(follows.lineStartMs, 0);
    expect(follows.lineEndMs, 5000, reason: '跟随演唱用行时间轴（下一行时间戳）');

    await settings.setDesktopScrollMode(DesktopScrollMode.constant);
    await pumpEventQueue();
    final constant = output.applied.last;
    expect(constant.scrollFollowsSinging, isFalse);
    expect(constant.lineStartMs, 100, reason: '匀速用「首词开始 → 末词结束」跨度');
    expect(constant.lineEndMs, 600);

    // 脏词轴：末词越过切行时刻（9s > 下一行 5s）时，匀速跨度夹到行尾——
    // 否则切行时还没滚完，行尾永远看不到。
    provider.syncLyrics(LyricsState(
      trackId: 'fake:1',
      status: LyricsStatus.ready,
      lines: const [
        LyricLine(Duration.zero, 'A', words: [
          LyricWord(
            start: Duration(milliseconds: 100),
            end: Duration(milliseconds: 9000),
            text: 'A',
          ),
        ]),
        LyricLine(Duration(seconds: 5), 'B'),
      ],
    ));
    await pumpEventQueue();
    final clamped = output.applied.last;
    expect(clamped.scrollFollowsSinging, isFalse);
    expect(clamped.lineStartMs, 100);
    expect(clamped.lineEndMs, 5000,
        reason: '末词越过切行时刻：匀速跨度夹到行时间轴终点');

    provider.dispose();
  });

  test('能力查询返回输出自身能力', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = LyricsDisplaySettings();
    final output = _FakeOutput(
      LyricsOutputIds.media,
      capability: LyricsOutputCapability.unsupported,
    );
    final provider = LyricsDisplayProvider(settings: settings, outputs: [output]);
    await pumpEventQueue();
    expect(
      provider.capabilityOf(LyricsOutputIds.media),
      LyricsOutputCapability.unsupported,
    );
    expect(
      provider.capabilityOf('missing'),
      LyricsOutputCapability.unsupported,
    );
    provider.dispose();
  });
}

class _FakeOutput implements LyricsOutput {
  _FakeOutput(this.id, {this.capability = LyricsOutputCapability.ready});

  @override
  final String id;

  @override
  LyricsOutputCapability capability;

  final List<LyricsPresentation> applied = [];
  int clears = 0;
  int starts = 0;
  bool stopped = false;

  @override
  Future<void> start(LyricsDisplaySettings settings) async => starts++;

  @override
  Future<void> apply(LyricsPresentation presentation) async =>
      applied.add(presentation);

  @override
  Future<void> clear() async => clears++;

  @override
  Future<void> stop() async => stopped = true;
}

class _FakeInteractiveOutput extends _FakeOutput
    implements InteractiveLyricsOutput {
  _FakeInteractiveOutput(super.id);

  final StreamController<LyricsOutputAction> controller =
      StreamController<LyricsOutputAction>.broadcast();

  @override
  Stream<LyricsOutputAction> get actions => controller.stream;
}
