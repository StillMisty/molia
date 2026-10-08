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
import 'package:molia/sources/source_manager.dart';

/// 端到端集成测试：真实 App 运行时 + 真实 LX JS 引擎 + 本地 mock HTTP 服务。
///
/// 运行：flutter test integration_test/lx_engine_integration_test.dart -d linux
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
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
    Future<void>.delayed(const Duration(seconds: 2), () => exit(0));
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
    Duration timeout = const Duration(seconds: 40),
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

    final tracks = await manager.search('test', 'hello');
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
      () => manager.search('不存在的源', 'x'),
      throwsA(anything),
    );
  });

  testWidgets('本地播放：播放 mock 音频，进度推进，暂停/继续/停止', (tester) async {
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
    final tracks = await manager.search('test', 'hello');

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

    final map = player.currentTrackMap!;
    expect(map['item']['name'], 'Hello LX');
    expect(map['is_playing'], isTrue);
    expect(map['context']['name'], '集成测试');

    // 等进度推进
    await Future<void>.delayed(const Duration(seconds: 2));
    await tester.pump();
    expect(player.currentTrackMap!['progress_ms'], greaterThan(0),
        reason: '播放进度没有推进');

    // 暂停 / 继续
    await player.toggle();
    await waitFor(tester, () => !player.isPlaying, reason: '暂停未生效');
    await player.toggle();
    await waitFor(tester, () => player.isPlaying, reason: '继续播放未生效');

    // 切歌
    await player.skipToNext();
    await waitFor(
      tester,
      () => player.currentTrackMap!['item']['name'] == 'Second Song',
      reason: '下一首未生效',
    );

    // seek
    await player.seek(const Duration(milliseconds: 500));
    await tester.pump();
    expect(player.currentTrackMap!['progress_ms'], greaterThanOrEqualTo(400));

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
    expect(find.text('还没有导入音源脚本。社区音源可在 Github 搜索 “lx-music-source” 获取。'),
        findsOneWidget);

    // 粘贴导入
    await tester.tap(find.text('粘贴脚本导入'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(M3ETextField), script);
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();

    // 免责声明
    expect(find.text('导入音源脚本'), findsOneWidget);
    await tester.tap(find.text('继续导入'));

    // 等待引擎激活
    await waitFor(
      tester,
      () => find.textContaining('当前音源：集成测试音源').evaluate().isNotEmpty,
      reason: '导入后未显示当前音源（激活失败）',
    );

    // 列表中脚本与源声明可见
    expect(find.textContaining('集成测试源'), findsWidgets);
    expect(find.textContaining('音源管理'), findsWidgets);

    // 默认音质设置：先切到 128k，再点 320K 验证切换生效
    await manager.setPreferredQuality('128k');
    await tester.pumpAndSettle();
    final chip320 = find.text('320K');
    await tester.ensureVisible(chip320);
    await tester.tap(chip320);
    await tester.pumpAndSettle();
    expect(manager.preferredQuality, '320k');
  });
}

// ---------------------------------------------------------------------------
// 测试辅助
// ---------------------------------------------------------------------------

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
