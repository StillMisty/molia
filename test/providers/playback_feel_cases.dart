import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/playback_feel.dart';
import 'package:molia/services/playback_feel_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fakes.dart';

/// 播放细节（淡入淡出 / 智能随机）：设备本地持久化与 provider → facade 下发。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('默认档位为 0.2 秒，智能随机默认开', () async {
    final store = PlaybackFeelStore();
    final loaded = await store.load();
    expect(loaded.fade, PlaybackFadePreset.ms200);
    expect(loaded.smartShuffle, isTrue);
  });

  test('两个值合并为一个键往返；损坏 / 未知档位回默认', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = PlaybackFeelStore(preferences: prefs);

    await store.save(fade: PlaybackFadePreset.ms300, smartShuffle: false);
    expect(prefs.getKeys(), {PlaybackFeelStore.keyState});
    expect(jsonDecode(prefs.getString(PlaybackFeelStore.keyState)!), {
      'fadeMs': 300,
      'smartShuffle': false,
    });

    final loaded = await PlaybackFeelStore(preferences: prefs).load();
    expect(loaded.fade, PlaybackFadePreset.ms300);
    expect(loaded.smartShuffle, isFalse);

    await prefs.setString(PlaybackFeelStore.keyState, '{broken');
    final corrupt = await PlaybackFeelStore(preferences: prefs).load();
    expect(corrupt.fade, PlaybackFadePreset.ms200);
    expect(corrupt.smartShuffle, isTrue);

    await prefs.setString(
      PlaybackFeelStore.keyState,
      jsonEncode({'fadeMs': 999, 'smartShuffle': true}),
    );
    final unknown = await PlaybackFeelStore(preferences: prefs).load();
    expect(unknown.fade, PlaybackFadePreset.ms200, reason: '未知档位回默认');
  });

  test('provider 启动把默认手感推给播放服务', () async {
    final backend = FakePlaybackFacade();
    final provider = buildTestPlaybackProvider(facade: backend);
    addTearDown(provider.dispose);

    expect(provider.fadePreset, PlaybackFadePreset.ms200);
    expect(provider.smartShuffleEnabled, isTrue);

    await provider.preferencesReady;
    expect(backend.fadeDuration, const Duration(milliseconds: 200));
    expect(backend.smartShuffle, isTrue);
  });

  test('改档位 / 开关立即下发并落盘，不动音量与播放快照', () async {
    final backend = FakePlaybackFacade();
    final provider = buildTestPlaybackProvider(facade: backend);
    addTearDown(provider.dispose);
    await provider.preferencesReady;
    final snapshotBefore = provider.snapshot;
    final volumeCallsBefore = backend.volumes.length;

    await provider.setFadePreset(PlaybackFadePreset.ms150);
    await provider.setSmartShuffleEnabled(false);

    expect(backend.fadeDuration, const Duration(milliseconds: 150));
    expect(backend.smartShuffle, isFalse);
    expect(provider.fadePreset, PlaybackFadePreset.ms150);
    expect(provider.smartShuffleEnabled, isFalse);
    expect(provider.snapshot, snapshotBefore, reason: '手感不是播放事件');
    expect(backend.volumes.length, volumeCallsBefore, reason: '淡变不改变用户音量');

    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getString(PlaybackFeelStore.keyState)!), {
      'fadeMs': 150,
      'smartShuffle': false,
    });
  });

  test('重建 provider 后手感从设备本地恢复', () async {
    final first = buildTestPlaybackProvider();
    addTearDown(first.dispose);
    await first.preferencesReady;
    await first.setFadePreset(PlaybackFadePreset.off);
    await first.setSmartShuffleEnabled(false);

    final backend = FakePlaybackFacade();
    final second = buildTestPlaybackProvider(facade: backend);
    addTearDown(second.dispose);
    await second.preferencesReady;

    expect(second.fadePreset, PlaybackFadePreset.off);
    expect(second.smartShuffleEnabled, isFalse);
    expect(backend.fadeDuration, Duration.zero);
    expect(backend.smartShuffle, isFalse);
  });

  test('关闭淡入淡出：暂停不再等待淡出窗口', () async {
    final backend = FakePlaybackFacade();
    final provider = buildTestPlaybackProvider(facade: backend);
    addTearDown(provider.dispose);
    await provider.preferencesReady;

    await provider.setFadePreset(PlaybackFadePreset.off);
    expect(backend.fadeDuration, Duration.zero);
  });
}
