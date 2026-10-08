import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/data_saver_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 省流模式服务单测：持久化、生效条件（仅移动数据）、音质上限与封面省流。
///
/// 网络探测全部注入 fake，不触碰 connectivity_plus 平台通道。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  DataSaverService build({bool cellular = false}) => DataSaverService(
        prefs: prefs,
        cellularProbe: () async => cellular,
        cellularChanges: const Stream<bool>.empty(),
      );

  test('默认值：关闭 / 128k 上限 / 封面省流开启', () async {
    final service = build();
    addTearDown(service.dispose);
    await service.init();

    expect(service.enabled, isFalse);
    expect(service.qualityCap, '128k');
    expect(service.coversSaverEnabled, isTrue);
    expect(service.active, isFalse);
  });

  test('持久化：开关 / 音质上限 / 封面省流写入并恢复', () async {
    final service = build(cellular: true);
    await service.init();
    await service.setEnabled(true);
    await service.setQualityCap('192k');
    await service.setCoversSaverEnabled(false);

    expect(prefs.getBool(DataSaverService.keyEnabled), isTrue);
    expect(prefs.getString(DataSaverService.keyQuality), '192k');
    expect(prefs.getBool(DataSaverService.keyCovers), isFalse);
    service.dispose();

    final restored = build(cellular: true);
    addTearDown(restored.dispose);
    await restored.init();
    expect(restored.enabled, isTrue);
    expect(restored.qualityCap, '192k');
    expect(restored.coversSaverEnabled, isFalse);
  });

  test('非法音质上限被忽略', () async {
    final service = build();
    addTearDown(service.dispose);
    await service.init();

    await service.setQualityCap('flac');
    expect(service.qualityCap, '128k');
  });

  test('生效条件：开启且移动数据；Wi-Fi 下不生效', () async {
    final service = build(cellular: false);
    addTearDown(service.dispose);
    await service.init();
    await service.setEnabled(true);

    expect(service.active, isFalse);
    expect(service.blockNetworkArtwork, isFalse);
    expect(service.effectiveQuality('flac'), 'flac');
  });

  test('effectiveQuality：生效时压到上限，不高于上限时保持', () async {
    final service = build(cellular: true);
    addTearDown(service.dispose);
    await service.init();
    await service.setEnabled(true);

    expect(service.effectiveQuality('flac'), '128k');
    expect(service.effectiveQuality('flac24bit'), '128k');
    expect(service.effectiveQuality('320k'), '128k');
    expect(service.effectiveQuality('128k'), '128k');

    await service.setQualityCap('320k');
    expect(service.effectiveQuality('flac'), '320k');
    expect(service.effectiveQuality('192k'), '192k');
    expect(service.effectiveQuality('128k'), '128k');
  });

  test('非标准偏好音质：按上限处理', () async {
    final service = build(cellular: true);
    addTearDown(service.dispose);
    await service.init();
    await service.setEnabled(true);

    expect(service.effectiveQuality('dolby'), '128k');
  });

  test('blockNetworkArtwork：生效且封面省流开启才拦截', () async {
    final service = build(cellular: true);
    addTearDown(service.dispose);
    await service.init();
    await service.setEnabled(true);

    expect(service.blockNetworkArtwork, isTrue);

    await service.setCoversSaverEnabled(false);
    expect(service.blockNetworkArtwork, isFalse);
    expect(service.active, isTrue, reason: '音质省流仍生效');
  });

  test('网络变化流：切换移动数据后 active 变化并通知', () async {
    final controller = StreamController<bool>();
    final service = DataSaverService(
      prefs: prefs,
      cellularProbe: () async => false,
      cellularChanges: controller.stream,
    );
    addTearDown(service.dispose);
    var notified = 0;
    service.addListener(() => notified++);
    await service.init();
    await service.setEnabled(true);
    expect(service.active, isFalse);

    controller.add(true);
    await Future<void>.delayed(Duration.zero);
    expect(service.active, isTrue);
    expect(notified, greaterThan(0));

    controller.add(false);
    await Future<void>.delayed(Duration.zero);
    expect(service.active, isFalse);

    await controller.close();
  });

  test('探测失败：detectionAvailable=false 且保守不生效', () async {
    final service = DataSaverService(
      prefs: prefs,
      cellularProbe: () async => throw StateError('no plugin'),
      cellularChanges: const Stream<bool>.empty(),
    );
    addTearDown(service.dispose);
    await service.init();
    await service.setEnabled(true);

    expect(service.detectionAvailable, isFalse);
    expect(service.active, isFalse);
  });
}
