import 'dart:async';

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
    expect(output.applied.length, baseline, reason: '同一行不应重复下发');

    provider.updatePosition(const Duration(seconds: 6));
    await pumpEventQueue();
    expect(output.applied.length, baseline + 1);
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
