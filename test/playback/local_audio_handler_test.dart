import 'package:audio_service/audio_service.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/managers/artwork_cache.dart';
import 'package:molia/models/play_mode.dart';
import 'package:molia/playback/local_audio_handler.dart';
import 'package:molia/playback/local_playback_service.dart';
import 'package:molia/services/language_service.dart';
import 'package:molia/sources/source_track.dart';

SourceTrack _track({String? coverUrl}) => SourceTrack(
      sourceKey: 'wy',
      origin: 'builtin',
      title: '晴天',
      artist: '周杰伦',
      album: '叶惠美',
      coverUrl: coverUrl,
      duration: const Duration(seconds: 269),
      raw: const {'songmid': 186016},
    );

/// 只覆写状态的假服务：不触碰 just_audio 平台通道（同
/// local_playback_backend_test 的模式）。
class _FakeService extends LocalPlaybackService {
  _FakeService()
      : super(
          resolver: (track, {String? quality}) async =>
              'http://127.0.0.1/a.wav',
        );

  bool playingValue = false;
  SourceTrack? trackValue;
  int skipToNextCalls = 0;
  int skipToPreviousCalls = 0;
  int stopCalls = 0;
  PlayMode modeValue = PlayMode.sequential;
  Duration positionValue = Duration.zero;
  int queueRevisionValue = 0;

  /// 控制动作调用台账（断言调用与顺序）。
  final List<String> calls = [];

  @override
  bool get hasTrack => trackValue != null;

  @override
  bool get isPlaying => playingValue;

  @override
  bool get isLoading => false;

  @override
  PlayMode get mode => modeValue;

  @override
  SourceTrack? get currentSourceTrack => trackValue;

  @override
  Duration get position => positionValue;

  @override
  Duration get duration => Duration.zero;

  @override
  List<SourceTrack> get queueTracks =>
      trackValue == null ? const [] : [trackValue!];

  @override
  int get currentIndex => trackValue == null ? -1 : 0;

  @override
  int get queueRevision => queueRevisionValue;

  /// 模拟播放推进（位置通道 tick）。
  void emitPosition(Duration position) {
    positionValue = position;
    notifyListeners();
  }

  /// 模拟 App 内切换播放模式（后端 → 服务 → 快照链路）。
  void emitMode(PlayMode mode) {
    modeValue = mode;
    notifyListeners();
  }

  @override
  Future<void> skipToNext() async {
    skipToNextCalls++;
  }

  @override
  Future<void> skipToPrevious() async {
    skipToPreviousCalls++;
  }

  @override
  Future<void> toggle() async {
    calls.add('toggle');
    playingValue = !playingValue;
    notifyListeners();
  }

  @override
  Future<void> toggleMode() async {
    calls.add('toggleMode');
    modeValue = PlayMode.values[(modeValue.index + 1) % PlayMode.values.length];
    notifyListeners();
  }

  @override
  Future<void> stop({bool clear = true}) async {
    stopCalls++;
    calls.add('stop');
    playingValue = false;
    if (clear) trackValue = null;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('mediaItemForTrack：系统媒体会话封面', () {
    test('封面 URL 带统一请求头（修复通知封面 403）', () {
      final item = mediaItemForTrack(
        _track(
          coverUrl:
              'http://p2.music.126.net/81BsxxhomJ4aJZYvEbyPkw==/109951165671182684.jpg',
        ),
        duration: const Duration(seconds: 269),
        artworkBlocked: false,
      );

      expect(
        item.artUri,
        Uri.parse(
          'http://p2.music.126.net/81BsxxhomJ4aJZYvEbyPkw==/109951165671182684.jpg',
        ),
      );
      // audio_service 在 Dart 侧用默认 UA（Dart/x）下载封面会被网易 CDN
      // 403，必须带上与 App 内封面一致的浏览器 UA + 平台 Referer。
      expect(item.artHeaders?['User-Agent'], ArtworkCache.browserUserAgent);
      expect(item.artHeaders?['Referer'], 'https://music.163.com/');
      expect(item.duration, const Duration(seconds: 269));
      expect(item.id, 'lx:wy:186016');
    });

    test('协议相对封面地址补全为 https', () {
      final item = mediaItemForTrack(
        _track(coverUrl: '//p2.music.126.net/cover.jpg'),
        duration: null,
        artworkBlocked: false,
      );

      expect(item.artUri, Uri.parse('https://p2.music.126.net/cover.jpg'));
      expect(item.artHeaders?['Referer'], 'https://music.163.com/');
    });

    test('省流模式整体置空封面（不触发通知封面下载）', () {
      final item = mediaItemForTrack(
        _track(coverUrl: 'https://p1.music.126.net/cover.jpg'),
        duration: null,
        artworkBlocked: true,
      );

      expect(item.artUri, isNull);
      expect(item.artHeaders, isNull);
    });

    test('无封面 / 非法地址不带 artUri 与 artHeaders', () {
      for (final cover in <String?>[null, '', 'not a url']) {
        final item = mediaItemForTrack(
          _track(coverUrl: cover),
          duration: null,
          artworkBlocked: false,
        );
        expect(item.artUri, isNull, reason: 'cover=$cover');
        expect(item.artHeaders, isNull, reason: 'cover=$cover');
      }
    });

    test('空歌手回退「未知歌手」、空专辑为 null', () {
      final item = mediaItemForTrack(
        SourceTrack(
          sourceKey: 'kw',
          origin: 'builtin',
          title: '歌名',
          artist: '',
          album: '',
          raw: const {'id': 1},
        ),
        duration: null,
        artworkBlocked: false,
      );

      expect(item.artist, '未知歌手');
      expect(item.album, isNull);
    });
  });

  group('parseArtUri', () {
    test('保留绝对地址、补全协议相对地址、拒绝无 scheme', () {
      expect(
        parseArtUri('https://a.com/x.jpg'),
        Uri.parse('https://a.com/x.jpg'),
      );
      expect(
        parseArtUri('//a.com/x.jpg'),
        Uri.parse('https://a.com/x.jpg'),
      );
      expect(parseArtUri('a.com/x.jpg'), isNull);
      expect(parseArtUri(null), isNull);
    });
  });

  group('恢复态切歌键回落', () {
    test('服务无曲目（冷启动恢复态）：回落给注入的 provider 回调', () async {
      final service = _FakeService();
      addTearDown(service.dispose);
      var restoredNext = 0;
      var restoredPrevious = 0;
      final handler = LocalAudioHandler(
        service,
        onRestoredSkipToNext: () async => restoredNext++,
        onRestoredSkipToPrevious: () async => restoredPrevious++,
      );

      await handler.skipToNext();
      await handler.skipToPrevious();

      expect(restoredNext, 1);
      expect(restoredPrevious, 1);
      expect(service.skipToNextCalls, 0);
      expect(service.skipToPreviousCalls, 0);
    });

    test('服务已有真实曲目：走正常切歌，不触发回落', () async {
      final service = _FakeService()..trackValue = _track();
      addTearDown(service.dispose);
      var restoredCalls = 0;
      final handler = LocalAudioHandler(
        service,
        onRestoredSkipToNext: () async => restoredCalls++,
      );

      await handler.skipToNext();

      expect(service.skipToNextCalls, 1);
      expect(restoredCalls, 0);
    });
  });

  group('增量下发：位置推进不重发整份队列', () {
    test('位置 tick 只更新 playbackState；队列版本变化才重发队列', () async {
      final service = _FakeService()..trackValue = _track();
      addTearDown(service.dispose);
      final handler = LocalAudioHandler(service);

      final queueEmissions = <List<MediaItem>>[];
      final itemEmissions = <MediaItem?>[];
      final stateEmissions = <PlaybackState>[];
      final subs = [
        handler.queue.listen(queueEmissions.add),
        handler.mediaItem.listen(itemEmissions.add),
        handler.playbackState.listen(stateEmissions.add),
      ];
      addTearDown(() {
        for (final sub in subs) {
          sub.cancel();
        }
      });
      // rxdart 的初始回放走微任务：先让订阅排空，再记录基线（只看增量）。
      await Future<void>.delayed(Duration.zero);
      final baseQueue = queueEmissions.length;
      final baseItem = itemEmissions.length;
      final baseState = stateEmissions.length;

      // 位置推进（超过 1s 的投影修正窗口）：只发 playbackState。
      service.emitPosition(const Duration(seconds: 2));
      await Future<void>.delayed(Duration.zero);
      expect(queueEmissions.length, baseQueue, reason: '位置 tick 不应重发队列');
      expect(itemEmissions.length, baseItem);
      expect(stateEmissions.length, baseState + 1);
      expect(stateEmissions.last.updatePosition, const Duration(seconds: 2));

      // 队列内容变化（如追加 / 原地替换）：队列重发，媒体项不动。
      service.queueRevisionValue++;
      service.emitPosition(const Duration(seconds: 3));
      await Future<void>.delayed(Duration.zero);
      expect(queueEmissions.length, baseQueue + 1);
      expect(itemEmissions.length, baseItem);
    });
  });

  group('播放顺序动作（通知自定义动作）', () {
    setUp(() {
      // 文案走 l10n：固定界面语言让标签可精确断言。
      LanguageService.localeNotifier.value = const Locale('zh');
    });
    tearDown(() {
      LanguageService.localeNotifier.value = null;
    });

    MediaControl? playModeControl(LocalAudioHandler handler) {
      for (final control in handler.playbackState.value.controls) {
        if (control.customAction?.name == playModeActionId) return control;
      }
      return null;
    }

    test('通知动作：上一首/播放暂停/下一首/播放顺序/停止，紧凑视图仍指前三', () {
      final service = _FakeService()
        ..trackValue = _track()
        ..playingValue = true;
      addTearDown(service.dispose);
      final handler = LocalAudioHandler(service);

      final state = handler.playbackState.value;
      expect(
        state.controls.map((control) => control.action),
        [
          MediaAction.skipToPrevious,
          MediaAction.pause,
          MediaAction.skipToNext,
          MediaAction.custom,
          MediaAction.stop,
        ],
      );
      // 紧凑视图（通知收起态 / 锁屏）保持「上一首 / 播放暂停 / 下一首」。
      expect(state.androidCompactActionIndices, const [0, 1, 2]);
    });

    test('图标与文案反映当前模式（顺序 / 单曲循环 / 随机）', () {
      final service = _FakeService()..trackValue = _track();
      addTearDown(service.dispose);
      final handler = LocalAudioHandler(service);

      const expected = {
        PlayMode.sequential: ('顺序播放', 'drawable/audio_service_repeat_all'),
        PlayMode.singleRepeat: ('单曲循环', 'drawable/audio_service_repeat_one'),
        PlayMode.shuffle: ('随机播放', 'drawable/audio_service_shuffle'),
      };
      for (final entry in expected.entries) {
        // App 内切模式（后端 → 服务）与通知动作读同一份模式。
        service.emitMode(entry.key);
        final control = playModeControl(handler);
        expect(control, isNotNull, reason: '缺播放顺序动作: ${entry.key}');
        expect(control!.label, entry.value.$1, reason: '${entry.key} 文案');
        expect(control.androidIcon, entry.value.$2, reason: '${entry.key} 图标');
      }
    });

    test('点按动作：循环模式（与 App 内同一顺序）并立即落盘会话', () async {
      final service = _FakeService()..trackValue = _track();
      addTearDown(service.dispose);
      var persisted = 0;
      final handler = LocalAudioHandler(service)
        ..attachSessionPersister(() async => persisted++);

      await handler.customAction(playModeActionId);
      // PlayMode.values = 单曲循环 / 顺序 / 随机：与 PlaybackProvider 一致。
      expect(service.calls, ['toggleMode']);
      expect(service.modeValue, PlayMode.shuffle);
      expect(playModeControl(handler)!.label, '随机播放');
      expect(persisted, 1, reason: '模式是会话的一部分，改后立即落盘');

      await handler.customAction(playModeActionId);
      expect(service.modeValue, PlayMode.singleRepeat);
      expect(playModeControl(handler)!.label, '单曲循环');

      // 其它自定义动作透传，不影响播放模式。
      await handler.customAction('lx.other');
      expect(service.calls, ['toggleMode', 'toggleMode']);
      expect(persisted, 2);
    });

    test('暂停 / 停止：动作返回前落盘会话（停止先落盘再清空队列）', () async {
      final service = _FakeService()
        ..trackValue = _track()
        ..playingValue = true;
      addTearDown(service.dispose);
      final log = <String>[];
      final handler = LocalAudioHandler(service)
        ..attachSessionPersister(() async => log.add('persist'));

      await handler.pause();
      expect(service.calls, ['toggle']);
      expect(service.playingValue, isFalse);
      expect(log, ['persist']);

      // 停止清空服务队列：必须在清空**之前**落盘，否则会话无从恢复。
      service.calls.clear();
      await handler.stop();
      expect(service.calls, ['stop']);
      expect(log, ['persist', 'persist']);
      expect(handler.playbackState.value.controls, isEmpty);
    });
  });
}
