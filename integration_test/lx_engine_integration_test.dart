import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:molia/pages/sources_page.dart';
import 'package:molia/playback/audio_predownloader.dart';
import 'package:molia/playback/desktop_audio_init.dart';
import 'package:molia/playback/local_playback_service.dart';
import 'package:molia/playback/playing_track_cache_writer.dart';
import 'package:molia/providers/sources_provider.dart';
import 'package:molia/data/downloads/downloads_publisher.dart';
import 'package:molia/services/cache_service.dart';
import 'package:molia/services/window/app_tray.dart';
import 'package:molia/services/window/window_chrome.dart';
import 'package:molia/sources/source_manager.dart';

/// 端到端集成测试：真实 App 运行时 + 真实 LX JS 引擎 + 本地 mock HTTP 服务。
///
/// 走官方 `flutter test integration_test/...` 路径，同一份文件覆盖两类目标：
/// - Linux 桌面：`tool/agent/test.sh linux`
///   （等价 `flutter test integration_test/lx_engine_integration_test.dart -d linux`；
///   播放用例需要 libmpv；默认跑在 Xvfb 上（无窗口），`--window` 才上真实显示）；
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

  /// 缓存用例的曲目 id：每次运行唯一，避免重复跑集成测试时命中上次残留的
  /// 缓存文件（那样「后台写入」用例会假通过）。
  final cacheTrackId = 'cache-${DateTime.now().millisecondsSinceEpoch}';

  setUpAll(() async {
    wavBytes = _buildWav();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;
    server.listen((request) => _handleRequest(request, port, wavBytes));
    script = _buildScript(port, cacheTrackId);
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
    expect(tracks, hasLength(3));
    expect(tracks.first.title, 'Hello LX');
    expect(tracks.first.artist, 'Tester');
    expect(tracks.first.sourceKey, 'test');
    expect(tracks.first.raw['id'], '1');
    // 第三条是缓存用例的曲目（id 每次运行唯一）。
    expect(tracks.last.title, 'Cache Me');
    expect(tracks.last.raw['id'], cacheTrackId);

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

    // 暂停后切歌：新曲目必须自动起播（不能停在暂停态）。
    await player.toggle();
    await waitFor(tester, () => !player.isPlaying, reason: '再次暂停未生效');
    await player.skipToNext();
    await waitFor(
      tester,
      () => player.currentSourceTrack?.title == 'Second Song',
      reason: '下一首未生效',
    );
    await waitFor(
      tester,
      () => player.isPlaying,
      reason: '暂停后切歌未自动播放',
    );

    await player.seek(const Duration(milliseconds: 500));
    await tester.pump();
    expect(player.position,
        greaterThanOrEqualTo(const Duration(milliseconds: 400)));

    await player.stop();
    expect(player.hasTrack, isFalse);
  });

  testWidgets('桌面：播放过的曲目由后台字节下载补齐音频缓存（两档模型的基础）', (tester) async {
    if (!isDesktop) {
      markTestSkipped('Android/iOS 播放用例不可靠：后台缓存写入用例仅桌面运行');
      return;
    }
    if (!desktopAudioAvailable) {
      markTestSkipped(
          'media_kit 不可用，跳过（Linux 需安装 mpv/libmpv）：${desktopAudioInitError ?? ''}');
      return;
    }
    final manager = await freshManager();
    addTearDown(() async {
      await manager.deactivate();
      manager.dispose();
    });
    await manager.importScript(script, activate: true);
    final tracks = (await manager.searchWithMeta('test', 'hello')).tracks;
    final cacheTrack = tracks.firstWhere((track) => track.title == 'Cache Me');

    final cache = CacheService.instance;
    final directory = await cache.audioCacheDirPath();
    if (directory == null) {
      markTestSkipped('当前平台没有音频缓存目录');
      return;
    }
    // 写入侧 key（播放 / 预取的实际入口）。
    final expected = CacheService.audioCacheKeyForSource(cacheTrack);
    final expectedFile = File(p.join(directory, expected));
    if (expectedFile.existsSync()) await expectedFile.delete();

    final player = LocalPlaybackService(
      resolver: (track, {String? quality}) =>
          manager.resolveUrl(track, requestedQuality: quality),
      audioCacheWriter: PlayingTrackCacheWriter(
        predownloader: CacheAudioPredownloader(cacheService: cache),
      ),
    );
    addTearDown(player.dispose);

    await player.playTracks(
      tracks,
      tracks.indexOf(cacheTrack),
      contextName: '集成测试-缓存',
    );
    await waitFor(tester, () => player.isPlaying, reason: '缓存用例播放未开始');

    // 播放仍走网络；缓存由后台下载原子落位（先落位再断言，避免读到半成品）。
    await waitFor(
      tester,
      () => expectedFile.existsSync(),
      timeout: const Duration(seconds: 60),
      reason: '后台缓存未落位: $expected',
    );

    // 读取侧（单曲占用 / 命中探测 / 转存）与写入侧同名：占用必须看见它。
    final usage = await cache.audioUsageForTrack(
      sourceKey: cacheTrack.sourceKey,
      songId: cacheTrack.songId,
    );
    expect(
      usage.count,
      greaterThan(0),
      reason: '写入侧文件名与读取侧不同名（读取侧看不到缓存）',
    );
    expect(usage.bytes, greaterThan(0));

    await player.stop();
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

    // 托盘「关闭时最小化」走的隐藏 / 显示往返：隐藏后不可见，显示后恢复。
    await WindowChrome.hide();
    expect(await WindowChrome.isVisible(), isFalse, reason: '隐藏后窗口不应可见');
    await WindowChrome.show();
    expect(await WindowChrome.isVisible(), isTrue, reason: '显示后窗口应恢复可见');
  });

  testWidgets('桌面托盘：创建 / 更新 / 销毁冒烟（无面板环境不得崩）', (tester) async {
    // Linux/Windows 才有托盘实现；其余平台是空实现（isSupported=false），
    // 本用例直接通过。
    if (!AppTray.isSupported) return;

    const labels = TrayMenuLabels(
      showWindow: 'Show window',
      play: 'Play',
      pause: 'Pause',
      previous: 'Previous track',
      next: 'Next track',
      addFavorite: 'Add to favorites',
      removeFavorite: 'Remove from favorites',
      quit: 'Quit',
    );
    // 环境可能没有 D-Bus / 系统面板（Xvfb）：创建失败由 AppTray 内部
    // 降级，不抛异常；真实 Linux 应用内应能建出图标（资源来自 bundle）。
    AppTray.init(
      labels: labels,
      onShowWindow: () {},
      onTogglePlay: () {},
      onPrevious: () {},
      onNext: () {},
      onToggleFavorite: () {},
      onQuit: () {},
    );
    expect(AppTray.debugIsActive, isTrue, reason: '真实桌面应用内托盘图标应创建成功');
    AppTray.setPlaybackState(hasTrack: true, isPlaying: true);
    AppTray.setFavorite(true);
    AppTray.setTooltip('Molia · Test - Artist');
    AppTray.setLabels(labels);
    AppTray.setPlaybackState(hasTrack: false, isPlaying: false);
    AppTray.dispose();
    expect(AppTray.debugIsActive, isFalse);
    // 销毁后再调用不得抛异常（启动初始化失败 / 已销毁时的空操作语义）。
    AppTray.setFavorite(true);
    AppTray.setTooltip('Molia');
    // 宿主探测：环境不同结果不同（无面板的 Xvfb 为 false 属预期），
    // 只要求不抛异常且结果缓存稳定。
    final hasHost = await AppTray.detectHost();
    expect(await AppTray.detectHost(), hasHost, reason: '宿主探测结果应缓存');
  });

  // 公共下载目录（MediaStore）平台通道：真实设备上发布 → 删除闭环。
  // 其余平台由下载根目录本身承担公共目录语义（发布器 supported=false），
  // 这里跳过（也覆盖了「通道缺失时 no-op 兜底不崩」的语义）。
  testWidgets('公共下载目录通道：发布 → 删除（仅 Android）', (tester) async {
    final publisher = createDownloadsPublisher();
    if (!Platform.isAndroid) {
      expect(publisher.supported, isFalse);
      expect(
        await publisher.publish(
          sourcePath: '/nonexistent.mp3',
          displayName: 'x.mp3',
          mimeType: 'audio/mpeg',
        ),
        isNull,
      );
      expect(await publisher.remove('content://media/external/downloads/0'),
          isFalse);
      markTestSkipped('公共目录发布仅 Android：其余平台下载根目录即公共目录');
      return;
    }

    expect(publisher.supported, isTrue);
    // 源文件：应用私有目录里的真实文件（MediaStore 拷贝的输入）。
    final dir = await getApplicationSupportDirectory();
    final source = File('${dir.path}/publish_it_source.mp3');
    await source.writeAsBytes(List<int>.generate(4096, (i) => i % 256));
    addTearDown(() async {
      if (await source.exists()) await source.delete();
    });

    final uri = await publisher.publish(
      sourcePath: source.path,
      displayName: 'molia_integration_test.mp3',
      mimeType: 'audio/mpeg',
    );
    expect(uri, isNotNull, reason: '发布应返回 MediaStore content URI');
    expect(uri, startsWith('content://media/'));

    // 幂等删除：行已不存在（被用户在文件管理器里删掉）也算成功。
    expect(await publisher.remove(uri!), isTrue);
    expect(await publisher.remove(uri), isTrue);

    // 源文件缺失：发布失败但不抛异常（best-effort 语义）。
    expect(
      await publisher.publish(
        sourcePath: '${dir.path}/missing.mp3',
        displayName: 'missing.mp3',
        mimeType: 'audio/mpeg',
      ),
      isNull,
    );
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
  // 30s 而不是 3s：CI runner（xvfb、无音频设备）起播慢，3 秒的曲目会在
  // 「起播 → 断言当前曲目」之间自然播完并自动切歌，断言拿到的是下一首
  // （2026-10-14 定时集成任务即因此失败）。时长与脚本里的 interval 同步。
  const seconds = 30;
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

String _buildScript(int port, String cacheTrackId) => '''
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
        { id: '1', name: 'Hello LX', singer: 'Tester', albumName: 'Album', source: 'test', interval: '00:30' },
        { id: '2', name: 'Second Song', singer: 'Tester', albumName: 'Album', source: 'test', interval: '00:30' },
        { id: '$cacheTrackId', name: 'Cache Me', singer: 'Tester', albumName: 'Album', source: 'test', interval: '00:30' }
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
