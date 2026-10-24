import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_media_session/flutter_media_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/app/bootstrap/library_stack.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/models/play_mode.dart';
import 'package:molia/playback/local_audio_handler.dart';
import 'package:molia/playback/media_session_copy.dart';
import 'package:molia/playback/playback_commands.dart';
import 'package:molia/providers/library_provider.dart';
import 'package:molia/services/lyrics_display/media_lyric_composer.dart';
import 'package:molia/sources/source_track.dart';

import '../support/fake_library_repository.dart';
import '../support/fake_media_session_backend.dart';
import '../support/fake_media_session_read_model.dart';
import '../support/fakes.dart';
import '../support/settings_test_support.dart';

/// 测试用文案来源：默认中文；语言切换用例直接改 [_copy].value。
late ValueNotifier<MediaSessionCopy> _copy;

MediaSessionCopy _copyFor(Locale locale) =>
    MediaSessionCopy.of(lookupAppLocalizations(locale));

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

/// 记录型命令面：handler 只该把系统动作翻译成这些命令。
///
/// 不直接改读取面，测试因此能同时断言「命令被调用」与「handler 没有绕过
/// 命令面改播放状态」；通知映射由测试显式 `emit*` 推进读取面。
class _FakeCommands implements PlaybackCommandPort {
  final List<String> calls = [];

  /// 命令返回的结果（handler 不消费，测试可用来模拟恢复态）。
  PlaybackCommandOutcome outcome = PlaybackCommandOutcome.trackOnly;

  /// seek 完成闸门：验证 handler 等命令（及命令里的提交）返回才返回。
  Completer<void>? seekGate;

  @override
  Future<PlaybackCommandOutcome> play() async {
    calls.add('play');
    return outcome;
  }

  @override
  Future<PlaybackCommandOutcome> pause() async {
    calls.add('pause');
    return outcome;
  }

  @override
  Future<PlaybackCommandOutcome> togglePlayPause() async {
    calls.add('togglePlayPause');
    return outcome;
  }

  @override
  Future<PlaybackCommandOutcome> skipToNext() async {
    calls.add('skipToNext');
    return outcome;
  }

  @override
  Future<PlaybackCommandOutcome> skipToPrevious() async {
    calls.add('skipToPrevious');
    return outcome;
  }

  @override
  Future<PlaybackCommandOutcome> playQueueIndex(int index) async {
    calls.add('playQueueIndex:$index');
    return outcome;
  }

  @override
  Future<PlaybackCommandOutcome> replaceQueueTrack(
    String trackUri,
    Track newTrack,
  ) async {
    calls.add('replaceQueueTrack:$trackUri');
    return outcome;
  }

  @override
  Future<PlaybackCommandOutcome> seekToPosition(Duration position) async {
    calls.add('seek:${position.inMilliseconds}');
    final gate = seekGate;
    if (gate != null) await gate.future;
    return outcome;
  }

  @override
  Future<PlaybackCommandOutcome> setPlayMode(PlayMode mode) async {
    calls.add('setPlayMode:${mode.name}');
    return outcome;
  }

  @override
  Future<PlaybackCommandOutcome> togglePlayMode() async {
    calls.add('togglePlayMode');
    return outcome;
  }

  @override
  Future<PlaybackCommandOutcome> stop() async {
    calls.add('stop');
    return outcome;
  }
}

/// 创建 handler 并注入记录型后端；默认封面解析返回 null（不触网）。
Future<(LocalAudioHandler, FakeMediaSessionBackend)> _handler(
  FakeMediaSessionReadModel readModel, {
  PlaybackCommandPort? commands,
  bool Function()? artworkBlocked,
  Future<String?> Function(String url)? artworkUriResolver,
  bool? periodicPositionStateUpdates,
}) async {
  final backend = FakeMediaSessionBackend();
  final handler = LocalAudioHandler(
    readModel,
    commands: commands ?? _FakeCommands(),
    copy: _copy,
    backend: backend,
    artworkBlocked: artworkBlocked,
    artworkUriResolver: artworkUriResolver ?? (_) async => null,
    periodicPositionStateUpdates: periodicPositionStateUpdates,
  );
  await handler.activate();
  await pumpEventQueue();
  addTearDown(handler.dispose);
  return (handler, backend);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _copy = ValueNotifier(_copyFor(const Locale('zh')));
    addTearDown(_copy.dispose);
  });

  group('mediaMetadataForTrack：系统媒体会话元数据', () {
    test('标题 / 歌手 / 专辑 / 时长 / 封面原样映射', () {
      final metadata = mediaMetadataForTrack(
        _track(
          coverUrl:
              'http://p2.music.126.net/81BsxxhomJ4aJZYvEbyPkw==/109951165671182684.jpg',
        ),
        duration: const Duration(seconds: 269),
        artworkUri:
            'http://p2.music.126.net/81BsxxhomJ4aJZYvEbyPkw==/109951165671182684.jpg',
        unknownArtist: '未知歌手',
      );

      expect(metadata.title, '晴天');
      expect(metadata.artist, '周杰伦');
      expect(metadata.album, '叶惠美');
      expect(metadata.duration, const Duration(seconds: 269));
      expect(
        metadata.artworkUri,
        'http://p2.music.126.net/81BsxxhomJ4aJZYvEbyPkw==/109951165671182684.jpg',
      );
    });

    test('空歌手回退「未知歌手」、空专辑为 null', () {
      final metadata = mediaMetadataForTrack(
        SourceTrack(
          sourceKey: 'kw',
          origin: 'builtin',
          title: '歌名',
          artist: '',
          album: '',
          raw: const {'id': 1},
        ),
        duration: null,
        artworkUri: null,
        unknownArtist: '未知歌手',
      );

      expect(metadata.artist, '未知歌手');
      expect(metadata.album, isNull);
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
      expect(parseArtUri('data:image/png;base64,AAAA'), isNotNull);
      expect(parseArtUri('a.com/x.jpg'), isNull);
      expect(parseArtUri(null), isNull);
    });
  });

  group('元数据 / 状态 / 动作映射', () {
    test('初始同步：曲目元数据、暂停状态与完整动作集', () async {
      final service = FakeMediaSessionReadModel()..currentTrack = _track();
      addTearDown(service.dispose);
      final (_, backend) = await _handler(service);

      expect(backend.activateCalls, 1);
      expect(backend.lastMetadata?.title, '晴天');
      expect(backend.lastState?.status, PlaybackStatus.paused);
      expect(backend.lastState?.position, Duration.zero);
      expect(backend.lastState?.repeatMode, MediaRepeatMode.none);
      expect(backend.lastState?.shuffleModeEnabled, isFalse);

      final actions = backend.lastActions!;
      expect(
          actions.map((action) => action.name),
          containsAll([
            'play',
            'pause',
            'skipToPrevious',
            'skipToNext',
            'stop',
            'seekTo',
            favoriteActionId,
            playModeActionId,
          ]));
      // 自定义动作之间的相对顺序（Android 通知按这个顺序发给系统）：收藏在前。
      final names = actions.map((action) => action.name).toList();
      expect(
        names.indexOf(favoriteActionId),
        lessThan(names.indexOf(playModeActionId)),
      );
      expect(backend.favoriteAction?.customLabel, '收藏');
      expect(
        backend.favoriteAction?.customIconResource,
        'ic_notification_favorite',
      );
      expect(backend.playModeAction?.customLabel, '顺序播放');
      expect(
        backend.playModeAction?.customIconResource,
        'audio_service_sequential',
      );
    });

    test('播放 / 缓冲状态映射', () async {
      final service = FakeMediaSessionReadModel()..currentTrack = _track();
      addTearDown(service.dispose);
      final (_, backend) = await _handler(service);

      service.emitPlaying(playing: true);
      await pumpEventQueue();
      expect(backend.lastState?.status, PlaybackStatus.playing);

      service.emitPlaying(playing: true, loading: true);
      await pumpEventQueue();
      expect(backend.lastState?.status, PlaybackStatus.buffering);

      service.emitPlaying(playing: false, loading: false);
      await pumpEventQueue();
      expect(backend.lastState?.status, PlaybackStatus.paused);
    });

    test('播放模式：repeat / shuffle 与自定义动作文案图标同步', () async {
      final service = FakeMediaSessionReadModel()..currentTrack = _track();
      addTearDown(service.dispose);
      final (_, backend) = await _handler(service);

      service.emitMode(PlayMode.listLoop);
      await pumpEventQueue();
      expect(backend.lastState?.repeatMode, MediaRepeatMode.all);
      expect(backend.lastState?.shuffleModeEnabled, isFalse);
      expect(backend.playModeAction?.customLabel, '列表循环');
      expect(
        backend.playModeAction?.customIconResource,
        'audio_service_repeat_all',
      );

      service.emitMode(PlayMode.sequential);
      await pumpEventQueue();
      expect(backend.lastState?.repeatMode, MediaRepeatMode.none);

      service.emitMode(PlayMode.singleRepeat);
      await pumpEventQueue();
      expect(backend.lastState?.repeatMode, MediaRepeatMode.one);
      expect(backend.lastState?.shuffleModeEnabled, isFalse);
      expect(backend.playModeAction?.customLabel, '单曲循环');
      expect(
        backend.playModeAction?.customIconResource,
        'audio_service_repeat_one',
      );

      service.emitMode(PlayMode.shuffle);
      await pumpEventQueue();
      expect(backend.lastState?.repeatMode, MediaRepeatMode.all);
      expect(backend.lastState?.shuffleModeEnabled, isTrue);
      expect(backend.playModeAction?.customLabel, '随机播放');
      expect(
        backend.playModeAction?.customIconResource,
        'audio_service_shuffle',
      );
    });

    test('语言切换后重新发布播放顺序动作文案', () async {
      final service = FakeMediaSessionReadModel()..currentTrack = _track();
      addTearDown(service.dispose);
      final (_, backend) = await _handler(service);
      expect(backend.playModeAction?.customLabel, '顺序播放');

      _copy.value = _copyFor(const Locale('en'));
      await pumpEventQueue();
      expect(backend.playModeAction?.customLabel, 'Sequential');
    });

    test('位置 tick 只更新状态，不重发元数据（非 Android 平台）', () async {
      final service = FakeMediaSessionReadModel()..currentTrack = _track();
      addTearDown(service.dispose);
      // Linux MPRIS 的 GetPosition 不插值，非 Android 平台保留按位置差的
      // 周期 state 判定；Android 关闭（见下方「媒体会话更新节流」组）。
      final (_, backend) = await _handler(
        service,
        periodicPositionStateUpdates: true,
      );
      final metadataCount = backend.metadataUpdates.length;
      final stateCount = backend.stateUpdates.length;

      service.emitPosition(const Duration(seconds: 2));
      await pumpEventQueue();
      expect(backend.metadataUpdates.length, metadataCount);
      expect(backend.stateUpdates.length, stateCount + 1);
      expect(backend.lastState?.position, const Duration(seconds: 2));
    });

    test('解析出真实时长后补发元数据', () async {
      final service = FakeMediaSessionReadModel()..currentTrack = _track();
      addTearDown(service.dispose);
      final (_, backend) = await _handler(service);
      expect(backend.lastMetadata?.duration, const Duration(seconds: 269));

      service.duration = Duration.zero;
      service.emitDuration(const Duration(seconds: 272));
      await pumpEventQueue();
      expect(backend.lastMetadata?.duration, const Duration(seconds: 272));
    });

    test('无曲目：清空元数据、idle 状态与动作', () async {
      final service = FakeMediaSessionReadModel();
      addTearDown(service.dispose);
      final (_, backend) = await _handler(service);

      expect(backend.lastMetadata?.title, isNull);
      expect(backend.lastState?.status, PlaybackStatus.idle);
      expect(backend.lastActions, isEmpty);
    });
  });

  group('媒体会话更新节流（Android）', () {
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    test('正常进度推进不补发播放态（平台自身插值）', () async {
      final service = FakeMediaSessionReadModel()..currentTrack = _track();
      addTearDown(service.dispose);
      final (_, backend) = await _handler(
        service,
        periodicPositionStateUpdates: false,
      );
      final metadataCount = backend.metadataUpdates.length;
      final stateCount = backend.stateUpdates.length;
      final actionCount = backend.actionUpdates.length;

      service.emitPosition(const Duration(seconds: 2));
      service.emitPosition(const Duration(seconds: 4));
      await pumpEventQueue();

      expect(backend.stateUpdates.length, stateCount);
      expect(backend.metadataUpdates.length, metadataCount);
      expect(backend.actionUpdates.length, actionCount);
    });

    test('seekRevision 变化补发播放态（显式 seek / 内部回跳）', () async {
      final service = FakeMediaSessionReadModel()..currentTrack = _track();
      addTearDown(service.dispose);
      final (_, backend) = await _handler(
        service,
        periodicPositionStateUpdates: false,
      );
      // 正常推进先走一段：不应触发 state。
      service.emitPosition(const Duration(seconds: 2));
      await pumpEventQueue();
      final stateCount = backend.stateUpdates.length;

      service.emitSeek(const Duration(seconds: 42));
      await pumpEventQueue();

      expect(backend.stateUpdates.length, stateCount + 1);
      expect(backend.lastState?.position, const Duration(seconds: 42));
    });

    test('平台默认：Android 关闭周期 state，Linux 保留', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final androidService = FakeMediaSessionReadModel()
        ..currentTrack = _track();
      addTearDown(androidService.dispose);
      final (_, androidBackend) = await _handler(androidService);
      final androidStateCount = androidBackend.stateUpdates.length;
      androidService.emitPosition(const Duration(seconds: 2));
      await pumpEventQueue();
      expect(
        androidBackend.stateUpdates.length,
        androidStateCount,
        reason: 'Android 的媒体会话按 lastPositionMs + elapsed 自行插值',
      );

      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final linuxService = FakeMediaSessionReadModel()..currentTrack = _track();
      addTearDown(linuxService.dispose);
      final (_, linuxBackend) = await _handler(linuxService);
      final linuxStateCount = linuxBackend.stateUpdates.length;
      linuxService.emitPosition(const Duration(seconds: 2));
      await pumpEventQueue();
      expect(
        linuxBackend.stateUpdates.length,
        linuxStateCount + 1,
        reason: 'MPRIS 的 GetPosition 不插值，需保持周期更新',
      );
    });
  });

  group('metadata-only 补发（歌词覆盖 / 封面本地化）', () {
    test('歌词覆盖只发元数据，不重建播放态与动作', () async {
      final service = FakeMediaSessionReadModel()..currentTrack = _track();
      addTearDown(service.dispose);
      final (handler, backend) = await _handler(service);
      final metadataCount = backend.metadataUpdates.length;
      final stateCount = backend.stateUpdates.length;
      final actionCount = backend.actionUpdates.length;

      handler.setLyricMetadataOverride(
        const LyricMetadataOverride(title: '晴天 · 从前从前'),
      );
      await pumpEventQueue();

      expect(backend.metadataUpdates.length, metadataCount + 1);
      expect(backend.lastMetadata?.title, '晴天 · 从前从前');
      expect(backend.stateUpdates.length, stateCount);
      expect(backend.actionUpdates.length, actionCount);

      handler.setLyricMetadataOverride(null);
      await pumpEventQueue();

      expect(backend.metadataUpdates.length, metadataCount + 2);
      expect(backend.lastMetadata?.title, '晴天');
      expect(backend.stateUpdates.length, stateCount);
      expect(backend.actionUpdates.length, actionCount);
    });

    test('无曲目时歌词覆盖不发空元数据', () async {
      final service = FakeMediaSessionReadModel();
      addTearDown(service.dispose);
      final (handler, backend) = await _handler(service);
      final metadataCount = backend.metadataUpdates.length;

      handler.setLyricMetadataOverride(
        const LyricMetadataOverride(title: '不该出现'),
      );
      await pumpEventQueue();

      expect(backend.metadataUpdates.length, metadataCount);
    });

    test('封面本地化完成只补发元数据', () async {
      const cover = 'https://p1.music.126.net/cover.jpg';
      final service = FakeMediaSessionReadModel()
        ..currentTrack = _track(coverUrl: cover);
      addTearDown(service.dispose);
      final completer = Completer<String?>();
      final (_, backend) = await _handler(
        service,
        artworkUriResolver: (_) => completer.future,
      );
      final metadataCount = backend.metadataUpdates.length;
      final stateCount = backend.stateUpdates.length;
      final actionCount = backend.actionUpdates.length;

      completer.complete('file:///tmp/molia-artwork/cover.jpg');
      await pumpEventQueue();

      expect(backend.metadataUpdates.length, metadataCount + 1);
      expect(
        backend.lastMetadata?.artworkUri,
        'file:///tmp/molia-artwork/cover.jpg',
      );
      expect(backend.stateUpdates.length, stateCount);
      expect(backend.actionUpdates.length, actionCount);
    });
  });

  group('歌词元数据覆盖', () {
    test('title / artist / album 覆盖，清除后还原', () async {
      final service = FakeMediaSessionReadModel()..currentTrack = _track();
      addTearDown(service.dispose);
      final (handler, backend) = await _handler(service);

      handler.setLyricMetadataOverride(
        const LyricMetadataOverride(
          title: '晴天 · 从前从前',
          artist: '周杰伦 / 伴奏',
          album: '叶惠美',
          displaySubtitle: '副标题',
        ),
      );
      await pumpEventQueue();
      expect(backend.lastMetadata?.title, '晴天 · 从前从前');
      expect(backend.lastMetadata?.artist, '周杰伦 / 伴奏');
      expect(backend.lastMetadata?.album, '叶惠美');

      handler.setLyricMetadataOverride(null);
      await pumpEventQueue();
      expect(backend.lastMetadata?.title, '晴天');
      expect(backend.lastMetadata?.artist, '周杰伦');
    });
  });

  group('封面：省流与本地化', () {
    test('先发远程 URL 兜底，异步补发本地 file URI', () async {
      const cover =
          'http://p2.music.126.net/81BsxxhomJ4aJZYvEbyPkw==/109951165671182684.jpg';
      final service = FakeMediaSessionReadModel()
        ..currentTrack = _track(coverUrl: cover);
      addTearDown(service.dispose);
      final completer = Completer<String?>();
      final (_, backend) = await _handler(
        service,
        artworkUriResolver: (url) {
          expect(url, cover);
          return completer.future;
        },
      );

      expect(backend.lastMetadata?.artworkUri, cover);

      completer.complete('file:///tmp/molia-artwork/cover.jpg');
      await pumpEventQueue();
      expect(
        backend.lastMetadata?.artworkUri,
        'file:///tmp/molia-artwork/cover.jpg',
      );
    });

    test('本地化失败保留远程 URL（不影响播放）', () async {
      const cover = 'https://p1.music.126.net/cover.jpg';
      final service = FakeMediaSessionReadModel()
        ..currentTrack = _track(coverUrl: cover);
      addTearDown(service.dispose);
      final (_, backend) = await _handler(
        service,
        artworkUriResolver: (_) async => null,
      );

      expect(backend.lastMetadata?.artworkUri, cover);
    });

    test('省流模式：元数据不带封面且不触发本地化', () async {
      var resolverCalls = 0;
      final service = FakeMediaSessionReadModel()
        ..currentTrack = _track(coverUrl: 'https://p1.music.126.net/cover.jpg');
      addTearDown(service.dispose);
      final (_, backend) = await _handler(
        service,
        artworkBlocked: () => true,
        artworkUriResolver: (_) async {
          resolverCalls++;
          return 'file:///tmp/cover.jpg';
        },
      );

      expect(backend.lastMetadata?.artworkUri, isNull);
      expect(resolverCalls, 0);
    });

    test('data URL 原样保留、不触发本地化', () async {
      const data = 'data:image/png;base64,AAAA';
      var resolverCalls = 0;
      final service = FakeMediaSessionReadModel()
        ..currentTrack = _track(coverUrl: data);
      addTearDown(service.dispose);
      final (_, backend) = await _handler(
        service,
        artworkUriResolver: (_) async {
          resolverCalls++;
          return null;
        },
      );

      expect(backend.lastMetadata?.artworkUri, data);
      expect(resolverCalls, 0);
    });
  });

  group('系统控制回调：只翻译成命令', () {
    test('play / pause / stop / next / previous / seek / 队列跳转', () async {
      final service = FakeMediaSessionReadModel()..currentTrack = _track();
      addTearDown(service.dispose);
      final commands = _FakeCommands();
      final (handler, backend) = await _handler(service, commands: commands);

      backend.emit(MediaAction.play);
      await pumpEventQueue();
      expect(commands.calls, ['play']);

      backend.emit(MediaAction.pause);
      await pumpEventQueue();
      expect(commands.calls, ['play', 'pause']);

      backend.emit(MediaAction.skipToNext);
      await pumpEventQueue();
      expect(commands.calls.last, 'skipToNext');

      backend.emit(MediaAction.skipToPrevious);
      await pumpEventQueue();
      expect(commands.calls.last, 'skipToPrevious');

      backend.emit(
        const MediaAction('seekTo', seekPosition: Duration(seconds: 42)),
      );
      await pumpEventQueue();
      expect(commands.calls.last, 'seek:42000');

      await handler.skipToQueueItem(3);
      expect(commands.calls.last, 'playQueueIndex:3');

      backend.emit(MediaAction.stop);
      await pumpEventQueue();
      expect(commands.calls.last, 'stop');

      // 读取面只提供读事实；播放控制没有可直写的服务方法（唯一写面是命令面）。
    });

    test('播放顺序自定义动作：走命令面并刷新通知文案', () async {
      final service = FakeMediaSessionReadModel()..currentTrack = _track();
      addTearDown(service.dispose);
      final commands = _FakeCommands();
      final (handler, backend) = await _handler(service, commands: commands);

      backend.emit(const MediaAction(playModeActionId));
      await pumpEventQueue();

      expect(commands.calls, ['togglePlayMode']);
      // 命令面会改后端 → 读取面会 emitMode；这里模拟结果，验证通知跟随读路径。
      service.emitMode(PlayMode.singleRepeat);
      await pumpEventQueue();
      expect(backend.playModeAction?.customLabel, '单曲循环');
    });
  });

  group('收藏动作（通知栏）', () {
    test('收藏态驱动图标与文案：未收藏空心 / 已收藏实心', () async {
      final service = FakeMediaSessionReadModel()..currentTrack = _track();
      addTearDown(service.dispose);
      var favorite = false;
      final (handler, backend) = await _handler(service);
      handler.attachFavoriteActions(
        isFavorite: (_) => favorite,
        toggle: (_) async {},
      );
      await pumpEventQueue();

      expect(backend.favoriteAction?.customLabel, '收藏');
      expect(
        backend.favoriteAction?.customIconResource,
        'ic_notification_favorite',
      );

      favorite = true;
      final updatesBefore = backend.actionUpdates.length;
      handler.refreshFavoriteState();
      await pumpEventQueue();

      expect(
        backend.actionUpdates.length,
        updatesBefore + 1,
        reason: '收藏态变了要重发动作',
      );
      expect(backend.favoriteAction?.customLabel, '取消收藏');
      expect(
        backend.favoriteAction?.customIconResource,
        'ic_notification_favorite_filled',
      );
    });

    test('收藏态没变：不重发动作', () async {
      final service = FakeMediaSessionReadModel()..currentTrack = _track();
      addTearDown(service.dispose);
      final (handler, backend) = await _handler(service);
      handler.attachFavoriteActions(
        isFavorite: (_) => false,
        toggle: (_) async {},
      );
      await pumpEventQueue();
      final updatesBefore = backend.actionUpdates.length;

      handler.refreshFavoriteState();
      await pumpEventQueue();

      expect(backend.actionUpdates.length, updatesBefore);
    });

    test('通知点击：落到注入的曲库写入，并立即换图标', () async {
      final service = FakeMediaSessionReadModel()..currentTrack = _track();
      addTearDown(service.dispose);
      var favorite = false;
      final toggled = <String>[];
      final (handler, backend) = await _handler(service);
      handler.attachFavoriteActions(
        isFavorite: (_) => favorite,
        toggle: (track) async {
          toggled.add(track.title);
          favorite = !favorite;
        },
      );

      backend.emit(const MediaAction(favoriteActionId));
      await pumpEventQueue();

      expect(toggled, ['晴天']);
      expect(
        backend.favoriteAction?.customIconResource,
        'ic_notification_favorite_filled',
      );
    });

    test('没绑定收藏回调（无曲库 / 平台不支持）：点击是空操作', () async {
      final service = FakeMediaSessionReadModel()..currentTrack = _track();
      addTearDown(service.dispose);
      final (handler, backend) = await _handler(service);
      final updatesBefore = backend.actionUpdates.length;

      backend.emit(const MediaAction(favoriteActionId));
      await pumpEventQueue();

      expect(backend.actionUpdates.length, updatesBefore);
      expect(
        backend.favoriteAction?.customIconResource,
        'ic_notification_favorite',
      );
    });

    test('语言切换后收藏动作文案跟随', () async {
      final service = FakeMediaSessionReadModel()..currentTrack = _track();
      addTearDown(service.dispose);
      final (handler, backend) = await _handler(service);
      handler.attachFavoriteActions(
        isFavorite: (_) => false,
        toggle: (_) async {},
      );
      expect(backend.favoriteAction?.customLabel, '收藏');

      _copy.value = _copyFor(const Locale('en'));
      await pumpEventQueue();
      expect(backend.favoriteAction?.customLabel, 'Add to favorites');
    });

    test('接线后点收藏：曲库写入 + 通知图标换实心', () async {
      // 真仓库 + 真 provider：锁住「读收藏用的键」与写入口径一致
      // （`SourceTrack.id` 是 `sourceKey:songId` 复合键，直接当 songId 传会永远读 false，
      // 真机表现就是「点收藏没反应」）。
      final repository = FakeLibraryRepository();
      addTearDown(repository.dispose);
      final playback = buildTestPlaybackProvider(
        settings: testSettingsRegistry(),
        libraryRepository: repository,
      );
      addTearDown(playback.dispose);
      final library = LibraryProvider(
        repository: repository,
        playbackProvider: playback,
      );
      addTearDown(library.dispose);

      final track = _track();
      final service = FakeMediaSessionReadModel()..currentTrack = track;
      addTearDown(service.dispose);
      final (handler, backend) = await _handler(service);
      wireNotificationFavorite(audioHandler: handler, libraryProvider: library);
      await pumpEventQueue();

      expect(library.isFavorite(track.sourceKey, track.songId), isFalse);

      backend.emit(const MediaAction(favoriteActionId));
      await pumpEventQueue();

      expect(library.isFavorite(track.sourceKey, track.songId), isTrue);
      expect(
        backend.favoriteAction?.customIconResource,
        'ic_notification_favorite_filled',
      );
    });
  });

  group('切歌 / seek 命令委托', () {
    test('读取面无曲目（冷启动恢复态）：仍走命令面，由它按阶段恢复', () async {
      final service = FakeMediaSessionReadModel();
      addTearDown(service.dispose);
      final commands = _FakeCommands()
        ..outcome = PlaybackCommandOutcome.trackAndQueue;
      final (handler, _) = await _handler(service, commands: commands);

      await handler.skipToNext();
      await handler.skipToPrevious();

      expect(commands.calls, ['skipToNext', 'skipToPrevious']);
    });

    test('读取面已有真实曲目：同样只发命令，不在 handler 里判断 phase', () async {
      final service = FakeMediaSessionReadModel()..currentTrack = _track();
      addTearDown(service.dispose);
      final commands = _FakeCommands();
      final (handler, _) = await _handler(service, commands: commands);

      await handler.skipToNext();

      expect(commands.calls, ['skipToNext']);
    });

    test('seek 等命令（含命令内的提交）完成才返回', () async {
      final service = FakeMediaSessionReadModel()..currentTrack = _track();
      addTearDown(service.dispose);
      final gate = Completer<void>();
      final commands = _FakeCommands()..seekGate = gate;
      final (handler, _) = await _handler(service, commands: commands);

      var returned = false;
      final seek = handler.seek(const Duration(seconds: 10)).then((_) {
        returned = true;
      });
      await pumpEventQueue();
      expect(commands.calls, ['seek:10000']);
      expect(returned, isFalse, reason: '命令还没提交完，handler 不能提前返回');

      gate.complete();
      await seek;
      expect(returned, isTrue);
    });

    test('自定义播放顺序动作：切模式命令，handler 不碰读取面', () async {
      final service = FakeMediaSessionReadModel()..currentTrack = _track();
      addTearDown(service.dispose);
      final commands = _FakeCommands();
      final (handler, _) = await _handler(service, commands: commands);

      await handler.customAction(playModeActionId);

      expect(commands.calls, ['togglePlayMode']);
    });

    test('其它自定义动作透传且不产生命令', () async {
      final service = FakeMediaSessionReadModel()..currentTrack = _track();
      addTearDown(service.dispose);
      final commands = _FakeCommands();
      final (handler, _) = await _handler(service, commands: commands);

      await handler.customAction('lx.other');

      expect(commands.calls, isEmpty);
    });
  });

  group('isSystemMediaSessionSupported', () {
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    test('Android / iOS / macOS / Windows / Linux 支持，Fuchsia 不支持', () {
      for (final platform in [
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(isSystemMediaSessionSupported, isTrue, reason: '$platform');
      }
      debugDefaultTargetPlatformOverride = TargetPlatform.fuchsia;
      expect(isSystemMediaSessionSupported, isFalse);
    });
  });
}
