import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:molia/pages/sources_page.dart';
import 'package:molia/playback/desktop_audio_init.dart';
import 'package:molia/playback/local_playback_service.dart';
import 'package:molia/providers/sources_provider.dart';
import 'package:molia/services/window/window_chrome.dart';
import 'package:molia/sources/source_manager.dart';

/// 端到端集成测试：真实 App 运行时 + 真实 LX JS 引擎 + 本地 mock HTTP 服务。
///
/// 走官方 `flutter test integration_test/...` 路径，同一份文件覆盖两类目标：
/// - Linux 桌面：`tool/agent/test.sh linux`
///   （等价 `flutter test integration_test/lx_engine_integration_test.dart -d linux`；
///   播放用例需要 libmpv，无 DISPLAY 的环境用 xvfb-run）；
/// - Android 模拟器：`tool/agent/test.sh android`（播放用例跳过，模拟器音频不可靠）。
///
/// 不要拆成多个集成测试文件：桌面端逐文件重启 App 会互相踩（flutter#101031）。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // 播放用例仅桌面运行：Android/iOS 的 just_audio 后端依赖模拟器音频设备，
  // 结果不可靠（见本文件播放用例内的跳过分支）。
  final isDesktop =
      Platform.isLinux || Platform.isWindows || Platform.isMacOS;
  // Linux/Windows 上为 just_audio 注册 media_kit 后端
  initDesktopAudioIfNeeded();

  late HttpServer server;
  late int port;
  late Uint8List wavBytes;
  late String script;

  setUpAll(() async {
    wavBytes = _buildWav();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;
    server.listen((request) => _handleRequest(request, port, wavBytes));
    script = _buildScript(port);
  });

  tearDownAll(() async {
    await server.close(force: true);
    // 桌面端 media_kit（libmpv）的全局原生事件循环会阻止测试进程退出，
    // 导致 `flutter test integration_test/... -d linux` 挂起（CI/子代理卡死）。
    // 测试结果已通过 VM service 上报，这里给出短暂上报窗口后强制退出。
    // Android 不注册：官方 teardown（stopApp/uninstall）能干净退出，注册反而会
    // 抢在卸载/回收之前退出进程（见 docs/pitfalls.md #11）。
    if (Platform.isLinux || Platform.isWindows) {
      Future<void>.delayed(const Duration(seconds: 2), () => exit(0));
    }
  });

  Future<SourceManager> freshManager() async {
    final manager = SourceManager();
    await manager.init();
    for (final existing in manager.scripts.toList()) {
      await manager.removeScript(existing.id);
    }
    return manager;
  }

  Future<void> waitFor(
    WidgetTester tester,
    bool Function() predicate, {
    // 90s：Android 模拟器（无 KVM 直通时尤其慢）冷启动 QuickJS + 首次搜索
    // 远超桌面耗时，40s 会误报超时。
    Duration timeout = const Duration(seconds: 90),
    String reason = '',
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (predicate()) return;
      await tester.pump(const Duration(milliseconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fail('等待超时: $reason');
  }

  /// 把目标滚进可见区（目标可能尚未构建，处于列表懒构建范围之外）。
  ///
  /// 不要用 `tester.scrollUntilVisible`：它内部逐次 `drag` 增量滚动，而
  /// Android 真机/模拟器（live binding）下 `drag` 不产生滚动位移（实测
  /// `ScrollPosition.pixels` 恒为 0），会一直滚到 50 次上限后抛
  /// `Bad state: No element`。改用 `fling`（真实速度手势），实测可滚。
  /// 详见 docs/pitfalls.md #24。
  Future<void> scrollTo(
    WidgetTester tester,
    Finder target, {
    bool up = false,
  }) async {
    final scrollable = find.byType(Scrollable).first;
    for (var i = 0; i < 10 && target.evaluate().isEmpty; i++) {
      await tester.fling(scrollable, Offset(0, up ? 300 : -300), 1200);
      await tester.pumpAndSettle();
    }
    if (target.evaluate().isEmpty) {
      fail('滚动后仍找不到目标: $target');
    }
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
  }

  testWidgets('LX 引擎：导入 → 初始化 → 搜索 → 取链 → 歌词', (tester) async {
    final manager = await freshManager();
    addTearDown(() async {
      await manager.deactivate();
      manager.dispose();
    });

    final info = await manager.importScript(script, activate: true);
    expect(info.name, '集成测试音源');
    expect(manager.hasActiveSource, isTrue);
    expect(manager.activeSources['test'], isNotNull);
    expect(manager.activeSources['test']!.actions,
        containsAll(['musicUrl', 'search', 'lyric']));

    final tracks = (await manager.searchWithMeta('test', 'hello')).tracks;
    expect(tracks, hasLength(2));
    expect(tracks.first.title, 'Hello LX');
    expect(tracks.first.artist, 'Tester');
    expect(tracks.first.sourceKey, 'test');
    expect(tracks.first.raw['id'], '1');

    final url = await manager.resolveUrl(tracks.first);
    expect(url, 'http://127.0.0.1:$port/audio.wav');

    final lyric = await manager.fetchLyric(tracks.first);
    expect(lyric, isNotNull);
    expect(lyric!.lyric, contains('[00:00.00]hello'));

    // 错误路径：脚本拒绝的 action
    expect(
      () => manager.searchWithMeta('不存在的源', 'x'),
      throwsA(anything),
    );
  });

  testWidgets('本地播放：播放 mock 音频，进度推进，暂停/继续/停止', (tester) async {
    if (!isDesktop) {
      markTestSkipped('Android/iOS 音频依赖模拟器音频设备、结果不可靠：播放用例仅桌面运行');
      return;
    }
    if (!desktopAudioAvailable) {
      markTestSkipped(
          'media_kit 不可用，跳过播放测试（Linux 需安装 mpv/libmpv）：${desktopAudioInitError ?? ''}');
      return;
    }
    final manager = await freshManager();
    addTearDown(() async {
      await manager.deactivate();
      manager.dispose();
    });
    await manager.importScript(script, activate: true);
    final tracks = (await manager.searchWithMeta('test', 'hello')).tracks;

    final player = LocalPlaybackService(
      resolver: (track, {String? quality}) =>
          manager.resolveUrl(track, requestedQuality: quality),
    );
    addTearDown(player.dispose);

    await player.playTracks(tracks, 0, contextName: '集成测试');

    await waitFor(
      tester,
      () => player.hasTrack && player.isPlaying,
      reason: '播放未开始: ${player.lastError ?? ''}',
    );

    final track = player.currentSourceTrack!;
    expect(track.title, 'Hello LX');
    expect(player.isPlaying, isTrue);
    expect(player.contextName, '集成测试');

    await Future<void>.delayed(const Duration(seconds: 2));
    await tester.pump();
    expect(player.position, greaterThan(Duration.zero),
        reason: '播放进度没有推进');

    await player.toggle();
    await waitFor(tester, () => !player.isPlaying, reason: '暂停未生效');
    await player.toggle();
    await waitFor(tester, () => player.isPlaying, reason: '继续播放未生效');

    await player.skipToNext();
    await waitFor(
      tester,
      () => player.currentSourceTrack?.title == 'Second Song',
      reason: '下一首未生效',
    );

    await player.seek(const Duration(milliseconds: 500));
    await tester.pump();
    expect(player.position,
        greaterThanOrEqualTo(const Duration(milliseconds: 400)));

    await player.stop();
    expect(player.hasTrack, isFalse);
  });

  testWidgets('设置页 UI：粘贴导入音源脚本并激活', (tester) async {
    final manager = await freshManager();
    addTearDown(() async {
      await manager.deactivate();
      manager.dispose();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SourceManager>.value(value: manager),
          ChangeNotifierProvider<SourcesProvider>(
            create: (_) => SourcesProvider(manager),
          ),
        ],
        child: const MaterialApp(home: SourcesPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('音源管理'), findsOneWidget);
    // 空态卡片可能落在首屏视口之外（布局随版本变化）：先滚动到可见。
    final noScripts = find.textContaining('还没有导入音源脚本');
    await scrollTo(tester, noScripts);
    expect(noScripts, findsOneWidget);

    // 粘贴导入（回滚到导入卡片，可能已在视口上方）
    await scrollTo(tester, find.text('粘贴脚本导入'), up: true);
    await tester.tap(find.text('粘贴脚本导入'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(M3ETextField), script);
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();

    // 免责声明
    expect(find.text('导入音源脚本'), findsOneWidget);
    await tester.tap(find.text('继续导入'));

    // 等待引擎激活（看 manager 状态；激活卡片可能在首屏视口之外）
    await waitFor(
      tester,
      () => manager.hasActiveSource,
      reason: '导入后激活失败',
    );
    // 滚动到激活卡片并断言 UI 展示（状态卡在列表顶部，向上滚）
    await scrollTo(tester, find.textContaining('当前音源：集成测试音源'), up: true);
    expect(find.textContaining('当前音源：集成测试音源'), findsOneWidget);

    // 列表中脚本与源声明可见
    expect(find.textContaining('集成测试源'), findsWidgets);
    expect(find.textContaining('音源管理'), findsWidgets);

    // 默认音质入口在设置 › 播放；这里验证 manager 的读写闭环，
    // UI 交互由 settings_page_test 覆盖。
    await manager.setPreferredQuality('128k');
    await tester.pumpAndSettle();
    expect(manager.preferredQuality, '128k');
    await manager.setPreferredQuality('320k');
    await tester.pumpAndSettle();
    expect(manager.preferredQuality, '320k');
  });

  testWidgets('桌面窗口 chrome：隐藏标题栏后系统标题栏高度为 0', (tester) async {
    // 仅 Linux/Windows 有窗口 chrome；Android/iOS 上 isSupported 为 false，
    // 本用例直接通过（不触碰插件 API，见 docs/pitfalls.md #30）。
    if (!WindowChrome.isSupported) return;
    // 与 lib/main.dart 同一条调用路径：初始化插件 → 隐藏标题栏 → 显示窗口。
    await WindowChrome.ensureInitialized();
    final height = await WindowChrome.debugTitleBarHeight();
    expect(height, 0, reason: '隐藏标题栏后系统标题栏高度应为 0，实际 $height');
  });
}

void _handleRequest(HttpRequest request, int port, Uint8List wavBytes) {
  final path = request.uri.path;
  if (path == '/api/url') {
    request.response.headers.contentType = ContentType.json;
    request.response.write('{"url":"http://127.0.0.1:$port/audio.wav"}');
    request.response.close();
    return;
  }
  if (path == '/audio.wav') {
    _serveAudio(request, wavBytes);
    return;
  }
  request.response.statusCode = HttpStatus.notFound;
  request.response.close();
}

Future<void> _serveAudio(HttpRequest request, Uint8List wavBytes) async {
  final total = wavBytes.length;
  final range = request.headers.value(HttpHeaders.rangeHeader);
  request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
  request.response.headers.contentType = ContentType('audio', 'wav');
  if (range != null && range.startsWith('bytes=')) {
    final parts = range.substring('bytes='.length).split('-');
    final start = int.tryParse(parts[0]) ?? 0;
    final requestedEnd = parts.length > 1 && parts[1].isNotEmpty
        ? int.tryParse(parts[1]) ?? total - 1
        : total - 1;
    final end = requestedEnd.clamp(0, total - 1);
    if (start >= total || start > end) {
      request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      await request.response.close();
      return;
    }
    request.response.statusCode = HttpStatus.partialContent;
    request.response.headers
        .set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$total');
    request.response.add(wavBytes.sublist(start, end + 1));
  } else {
    request.response.add(wavBytes);
  }
  await request.response.close();
}

Uint8List _buildWav() {
  const sampleRate = 8000;
  const seconds = 3;
  const samples = sampleRate * seconds;
  const dataSize = samples; // 8-bit mono
  final builder = BytesBuilder();
  void writeString(String value) => builder.add(utf8.encode(value));
  void writeUint32(int value) => builder.add([
        value & 0xff,
        (value >> 8) & 0xff,
        (value >> 16) & 0xff,
        (value >> 24) & 0xff,
      ]);
  void writeUint16(int value) => builder.add([
        value & 0xff,
        (value >> 8) & 0xff,
      ]);

  writeString('RIFF');
  writeUint32(36 + dataSize);
  writeString('WAVE');
  writeString('fmt ');
  writeUint32(16);
  writeUint16(1); // PCM
  writeUint16(1); // mono
  writeUint32(sampleRate);
  writeUint32(sampleRate); // byte rate
  writeUint16(1); // block align
  writeUint16(8); // bits per sample
  writeString('data');
  writeUint32(dataSize);
  for (var i = 0; i < samples; i++) {
    final sample = 128 +
        (32 * math.sin(2 * math.pi * 440 * i / sampleRate)).round();
    builder.addByte(sample.clamp(0, 255));
  }
  return builder.toBytes();
}

String _buildScript(int port) => '''
/**
 * @name 集成测试音源
 * @description 仅用于 Molia 集成测试
 * @version 1.0.0
 * @author StillMisty
 */

const { EVENT_NAMES, request, on, send } = globalThis.lx

function httpGet(url) {
  return new Promise(function (resolve, reject) {
    request(url, { method: 'GET' }, function (err, resp) {
      if (err) return reject(err)
      resolve(resp.body)
    })
  })
}

on(EVENT_NAMES.request, function (payload) {
  const source = payload.source
  const action = payload.action
  const info = payload.info || {}
  if (action === 'musicUrl') {
    const id = info.musicInfo ? info.musicInfo.id : ''
    return httpGet('http://127.0.0.1:$port/api/url?mid=' + id).then(function (data) {
      return data.url
    })
  }
  if (action === 'search') {
    return Promise.resolve({
      isEnd: true,
      list: [
        { id: '1', name: 'Hello LX', singer: 'Tester', albumName: 'Album', source: 'test', interval: '00:03' },
        { id: '2', name: 'Second Song', singer: 'Tester', albumName: 'Album', source: 'test', interval: '00:03' }
      ]
    })
  }
  if (action === 'lyric') {
    return Promise.resolve({ lyric: '[00:00.00]hello\\n[00:00.50]world', tlyric: null, rlyric: null, lxlyric: null })
  }
  return Promise.reject(new Error('action not support: ' + action + '/' + source))
})

send(EVENT_NAMES.inited, {
  sources: {
    test: {
      name: '集成测试源',
      type: 'music',
      actions: ['musicUrl', 'search', 'lyric'],
      qualitys: ['128k', '320k']
    }
  }
})
''';
