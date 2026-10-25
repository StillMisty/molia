/// 托盘期内存守卫：窗口隐藏后把界面侧可回收的内存交还系统。
///
/// 背景：关到托盘只隐藏窗口，进程、引擎、provider 与播放全部继续；Flutter 的
/// 图片缓存（默认上限 100 MiB）与常驻页面里解码好的封面会原样挂到用户重新
/// 打开窗口为止，而托盘听歌时每次切歌还会继续往里塞图。这里监听
/// [AppPresence]：
///
/// - `trayHidden`：等一帧（应用壳先把休眠占位树换上、释放 live 图片引用），
///   然后清空图片缓存并把上限临时压低，避免隐藏期间的新解码再次堆积；
/// - `visible`：恢复原始上限，让恢复后的列表滚动与封面预取有正常预算；
/// - `minimized`：不动缓存（最小化通常短暂且要跟手恢复），后台解码类工作的
///   停产由各自的消费者按 [AppPresence] 判定。
///
/// 每次翻转打一行 `molia.memory`（RSS + 缓存占用），release 也输出，作为
/// 托盘内存回归的观测点（见 `tool/agent/memory.sh` 与 `docs/memory.md`）。
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io' show Platform, ProcessInfo;
import 'dart:math' as math;

import 'package:flutter/painting.dart' show ImageCache, PaintingBinding;
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:logging/logging.dart';

import '../services/app_presence.dart';

/// 图片缓存的最小操作面（测试注入假实现；生产走 [PaintingImageCache]）。
abstract interface class ImageCacheTarget {
  int get currentSizeBytes;

  int get maximumSizeBytes;

  set maximumSizeBytes(int value);

  /// 清 keepAlive 与 pending（正在显示的 live 图片不动）。
  void clear();

  /// 清 live 引用（休眠树已换上后，这些引用不再被界面持有）。
  void clearLiveImages();
}

/// 生产实现：Flutter 全局 `ImageCache`。
class PaintingImageCache implements ImageCacheTarget {
  const PaintingImageCache();

  ImageCache get _cache => PaintingBinding.instance.imageCache;

  @override
  int get currentSizeBytes => _cache.currentSizeBytes;

  @override
  int get maximumSizeBytes => _cache.maximumSizeBytes;

  @override
  set maximumSizeBytes(int value) => _cache.maximumSizeBytes = value;

  @override
  void clear() => _cache.clear();

  @override
  void clearLiveImages() => _cache.clearLiveImages();
}

/// 托盘隐藏期间允许的图片缓存上限：留一点预算给漏网的解码（系统媒体会话
/// 封面本地化、用户点托盘菜单切歌时的即时解码），又不至于重新堆到 100 MiB。
const int kTrayImageCacheLimitBytes = 16 * 1024 * 1024;

/// glibc `malloc_trim(0)` 的 Dart 签名（size_t → IntPtr）。
typedef _MallocTrimNative = Int32 Function(IntPtr pad);
typedef _MallocTrimDart = int Function(int pad);

/// `EmptyWorkingSet(HANDLE)` 的 Dart 签名（BOOL；伪句柄 -1 = 当前进程）。
typedef _EmptyWorkingSetNative = Int32 Function(IntPtr process);
typedef _EmptyWorkingSetDart = int Function(int process);

/// `malloc_zone_pressure_relief(zone, goal)` 的 Dart 签名（size_t）。
typedef _MallocZonePressureReliefNative = IntPtr Function(
    Pointer<Void> zone, IntPtr goal);
typedef _MallocZonePressureReliefDart = int Function(
    Pointer<Void> zone, int goal);

/// 把已 free / 可换出的页交还系统（平台或符号不可用时静默跳过）。
///
/// 为什么需要：清空图片缓存只是把像素 free 回 allocator，空闲页留在 arena /
/// 工作集里不会自动归还，系统观测（RSS / 任务管理器）看不到下降；浏览器 /
/// 播放器这类「缩到托盘」的应用普遍在释放后补一次 trim。
///
/// - Linux/glibc：`malloc_trim(0)` 归还 arena 的空闲页；
/// - macOS：`malloc_zone_pressure_relief(NULL, 0)` 让所有 zone 归还空闲页；
/// - Windows：`EmptyWorkingSet` 把工作集里可换出的页移出。任务管理器的
///   「内存」列是专用工作集（不是已 free 字节数），free 后不会自动缩；
///   这里只影响工作集，「提交大小」仍由上面的 `imageCache.clear()` 决定。
///
/// mpv 自带 allocator 与 Dart 堆不受这里影响，只解决 allocator / 页表这一层。
void _releaseFreedMemoryToOs() {
  if (Platform.isLinux) {
    try {
      final trim = DynamicLibrary.process()
          .lookupFunction<_MallocTrimNative, _MallocTrimDart>('malloc_trim');
      trim(0);
    } catch (_) {
      // musl / 静态链接等场景没有该符号：跳过即可，不影响释放逻辑本身。
    }
    return;
  }
  if (Platform.isMacOS) {
    try {
      final relief = DynamicLibrary.process().lookupFunction<
          _MallocZonePressureReliefNative,
          _MallocZonePressureReliefDart>('malloc_zone_pressure_relief');
      // zone = NULL：对所有 zone 生效；goal = 0：尽力归还全部可释放页。
      relief(nullptr, 0);
    } catch (_) {
      // 符号缺失（极少见）：跳过，系统仍会在内存压力下自行回收。
    }
    return;
  }
  if (Platform.isWindows) {
    try {
      final psapi = DynamicLibrary.open('psapi.dll');
      final emptyWorkingSet = psapi
          .lookupFunction<_EmptyWorkingSetNative, _EmptyWorkingSetDart>(
              'EmptyWorkingSet');
      // 伪句柄 -1 = 当前进程（GetCurrentProcess）。
      emptyWorkingSet(-1);
    } catch (_) {
      // psapi 不可用 / 符号缺失：跳过；系统仍会在内存压力下自行回收。
    }
  }
}

/// 托盘期内存守卫（单例入口 [AppMemoryManager.instance]）。
class AppMemoryManager {
  AppMemoryManager({
    AppPresence? presence,
    ImageCacheTarget? imageCache,
  })  : _presence = presence ?? AppPresence.instance,
        _cache = imageCache ?? const PaintingImageCache() {
    _fullLimitBytes = _cache.maximumSizeBytes;
  }

  /// 全局单例（组合根 attach 一次）。
  static final AppMemoryManager instance = AppMemoryManager();

  static final Logger _logger = Logger('molia.memory');

  final AppPresence _presence;
  final ImageCacheTarget _cache;

  /// attach 时的原始上限（恢复时还原；不硬编码 100 MiB，跟随 Flutter 默认
  /// 或未来的显式配置）。
  late final int _fullLimitBytes;

  /// 清理代数：隐藏→恢复快速往返时让在途清理作废。
  int _trimToken = 0;

  bool _attached = false;

  /// 订阅存在态并立即校正一次（启动即处于托盘隐藏时也要清理）。
  void attach() {
    if (_attached) return;
    _attached = true;
    _presence.addListener(_onPresenceChanged);
    if (_presence.isTrayHidden) unawaited(_trimForTray());
  }

  void dispose() {
    if (!_attached) return;
    _attached = false;
    _presence.removeListener(_onPresenceChanged);
  }

  void _onPresenceChanged() {
    switch (_presence.value) {
      case AppPresenceState.visible:
        _restoreLimit();
      case AppPresenceState.minimized:
        _log('最小化');
      case AppPresenceState.trayHidden:
        unawaited(_trimForTray());
    }
  }

  void _restoreLimit() {
    _trimToken++;
    if (_cache.maximumSizeBytes != _fullLimitBytes) {
      _cache.maximumSizeBytes = _fullLimitBytes;
    }
    _log('窗口可见');
  }

  Future<void> _trimForTray() async {
    final token = ++_trimToken;
    _log('托盘隐藏（等休眠帧）');
    // 休眠树在下一次 build 换上：等这一帧结束，页面里的 live 图片引用先释放，
    // 再清缓存才能真正把像素交还。
    await SchedulerBinding.instance.endOfFrame
        .timeout(const Duration(seconds: 2), onTimeout: () {});
    if (token != _trimToken || !_presence.isTrayHidden) return;
    _cache.clear();
    _cache.clearLiveImages();
    _cache.maximumSizeBytes =
        math.min(_fullLimitBytes, kTrayImageCacheLimitBytes);
    // 清完再 trim：不然日志里的 RSS / 工作集还是「已释放未归还」的那笔数。
    _releaseFreedMemoryToOs();
    _log('托盘隐藏完成');
  }

  void _log(String phase) {
    final rssMb = ProcessInfo.currentRss / (1024 * 1024);
    final cacheMb = _cache.currentSizeBytes / (1024 * 1024);
    final capMb = _cache.maximumSizeBytes / (1024 * 1024);
    _logger.info(
      '$phase：RSS=${rssMb.toStringAsFixed(1)}MB，'
      'imageCache=${cacheMb.toStringAsFixed(1)}MB/'
      '${capMb.toStringAsFixed(0)}MB',
    );
  }
}
