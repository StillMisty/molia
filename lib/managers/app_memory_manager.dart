/// 托盘 / 移动端后台内存守卫：窗口隐藏或应用退到后台后把界面侧可回收的
/// 内存交还系统。
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
/// 移动端不写 [AppPresence]（那是桌面窗口语义），由组合根在生命周期回调里
/// 调 [onAppBackground] / [onAppForeground]：退后台 30s 后才清图片缓存并压低
/// 上限，回前台取消并恢复；Android 不卸载界面，所以**不清 live 图片**，恢复
/// 时当前封面还在。系统低内存（`didHaveMemoryPressure`）走
/// [onMemoryPressure]，只在那时释放可重建的浏览 / 搜索 / 目录缓存；普通退
/// 后台不释放列表，避免恢复时出现空列表。
///
/// 每次翻转打一行 `molia.memory`（RSS + 缓存占用），release 也输出，作为
/// 托盘 / 后台内存回归的观测点（见 `tool/agent/memory.sh` 与 `docs/memory.md`）。
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

/// 正常前台 / 窗口可见时的图片缓存预算（`main.dart` 在 attach 前显式设置）。
///
/// 为什么不是 Flutter 默认的 100 MiB：移动端常驻进程的预算要更保守，且
/// 托盘 / 移动端后台还需要一个明确的恢复上限。64 MiB 仍够一屏列表、当前
/// 封面与播放预取使用；超出部分按需重解码。
const int kFullImageCacheLimitBytes = 64 * 1024 * 1024;

/// 托盘隐藏 / 移动端后台期间允许的图片缓存上限：留一点预算给漏网的解码
/// （系统媒体会话封面本地化、用户点托盘菜单切歌时的即时解码），又不至于
/// 重新堆到完整预算。
const int kTrayImageCacheLimitBytes = 16 * 1024 * 1024;

/// 托盘隐藏后第二次系统 trim 的延迟。
///
/// 第一次 trim 发生在休眠帧落定、原生窗口尚未隐藏时；`Window.hide()` 的
/// 引擎收尾和窗口层释放还会 touch 一批页，单次 trim 会被这些页重新填回。
/// 隐藏后补一次只处理「可换出的空闲页」，不重复清业务缓存。
const Duration kTrayLateTrimDelay = Duration(seconds: 2);

/// 移动端退后台多久后清理：给短暂切走 / 快速切回留出跟手恢复的窗口。
const Duration kMobileBackgroundTrimDelay = Duration(seconds: 30);

/// 低内存信号的去抖时间。
///
/// Android 的 `TRIM_MEMORY_UI_HIDDEN` 也会被引擎映射成
/// `didHaveMemoryPressure`；延迟一拍再释放，让紧随其后的退后台生命周期
/// 取消这次「伪低内存」，避免每次退后台都清空浏览 / 搜索缓存。
const Duration kMemoryPressureDebounce = Duration(seconds: 1);

/// 退后台后多久内的内存压力仍视为 UI_HIDDEN 过渡（不是真低内存）。
const Duration kMemoryPressureTransitionGuard = Duration(seconds: 2);

/// glibc `malloc_trim(0)` 的 Dart 签名（size_t → IntPtr）。
typedef _MallocTrimNative = Int32 Function(IntPtr pad);
typedef _MallocTrimDart = int Function(int pad);

/// `EmptyWorkingSet(HANDLE)` 的 Dart 签名（BOOL；伪句柄 -1 = 当前进程）。
typedef _EmptyWorkingSetNative = Int32 Function(IntPtr process);
typedef _EmptyWorkingSetDart = int Function(int process);

/// `malloc_zone_pressure_relief(zone, goal)` 的 Dart 签名（size_t）。
typedef _MallocZonePressureReliefNative = IntPtr Function(
  Pointer<Void> zone,
  IntPtr goal,
);
typedef _MallocZonePressureReliefDart = int Function(
  Pointer<Void> zone,
  int goal,
);

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
      final relief = DynamicLibrary.process()
          .lookupFunction<
            _MallocZonePressureReliefNative,
            _MallocZonePressureReliefDart
          >('malloc_zone_pressure_relief');
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
            'EmptyWorkingSet',
          );
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
    void Function()? releaseToOs,
  }) : _presence = presence ?? AppPresence.instance,
       _cache = imageCache ?? const PaintingImageCache(),
       _releaseToOs = releaseToOs ?? _releaseFreedMemoryToOs {
    _fullLimitBytes = _cache.maximumSizeBytes;
  }

  /// 全局单例（组合根 attach 一次）。
  static final AppMemoryManager instance = AppMemoryManager();

  static final Logger _logger = Logger('molia.memory');

  final AppPresence _presence;
  final ImageCacheTarget _cache;

  /// 把 allocator / 工作集里的空闲页交还系统；测试可注入计数替身。
  final void Function() _releaseToOs;

  /// attach 时的原始上限（恢复时还原；不硬编码 100 MiB，跟随 Flutter 默认
  /// 或未来的显式配置）。`main.dart` 在首次访问本类之前把全局图片缓存设为
  /// [kFullImageCacheLimitBytes]，因此生产环境捕获的就是 64 MiB。
  late final int _fullLimitBytes;

  /// 清理代数：隐藏→恢复快速往返时让在途清理作废。
  int _trimToken = 0;

  /// 隐藏后第二次 trim：第一次发生在原生窗口隐藏前，收尾 touch 的页需要
  /// 再归还一次。恢复 / 再次隐藏时取消。
  Timer? _trayLateTrimTimer;

  /// 移动端后台清理计时与代数：`onAppBackground` 起 30s 计时，
  /// `onAppForeground` 取消并让在途回调作废。
  Timer? _mobileTrimTimer;
  int _mobileTrimToken = 0;
  bool _mobileBackground = false;

  /// 是否处于「刚退后台」的过渡窗口：用于识别紧随其后的 UI_HIDDEN 伪低内存。
  bool _inBackgroundTransition = false;
  Timer? _backgroundTransitionTimer;

  /// 低内存释放的去抖计时（见 [kMemoryPressureDebounce]）。
  Timer? _lowMemoryTimer;

  /// 业务缓存释放回调（组合根注册；本类只负责时机，不认识 provider 类型）。
  ///
  /// 用回调列表而不是让 managers 层 import provider：托盘隐藏时释放什么
  /// （浏览列表曲目 / 搜索结果 / 目录分页）属于各自持有者的知识，这里只保证
  /// 「休眠帧已换上、且仍在托盘隐藏」时统一触发。
  final List<void Function()> _releasers = [];

  /// 系统低内存信号触发时释放的回调。
  ///
  /// 与 [_releasers] 分开：普通退后台 / 托盘隐藏不释放列表（恢复时会空一帧），
  /// 只有系统明确报告内存压力时才放弃可重建的浏览 / 搜索 / 目录缓存。
  final List<void Function()> _lowMemoryReleasers = [];

  bool _attached = false;

  /// 订阅存在态并立即校正一次（启动即处于托盘隐藏时也要清理）。
  void attach() {
    if (_attached) return;
    _attached = true;
    _presence.addListener(_onPresenceChanged);
    if (_presence.isTrayHidden) unawaited(_trimForTray());
  }

  /// 注册托盘隐藏时的业务缓存释放回调（组合根在创建持有者后调用）。
  ///
  /// 回调必须是幂等的：托盘可能反复隐藏 / 恢复，每次隐藏都会再触发一次。
  void addReleaser(void Function() releaser) => _releasers.add(releaser);

  /// 取消注册（持有者先于本类销毁时调用，避免回调打到已 dispose 的对象）。
  void removeReleaser(void Function() releaser) => _releasers.remove(releaser);

  /// 注册系统低内存时释放的业务缓存回调。
  ///
  /// 与 [addReleaser] 分开注册：正常退后台 / 托盘隐藏不清列表，只有
  /// `didHaveMemoryPressure` 才触发这些回调。回调同样必须幂等。
  void addLowMemoryReleaser(void Function() releaser) =>
      _lowMemoryReleasers.add(releaser);

  /// 取消注册低内存回调。
  void removeLowMemoryReleaser(void Function() releaser) =>
      _lowMemoryReleasers.remove(releaser);

  /// 移动端退后台（组合根在 `mobilePowerPolicy` 为 true 时调用）。
  ///
  /// 不写 [AppPresence]：移动端没有桌面托盘语义，生命周期与窗口可见性是
  /// 两条独立信号。这里只起 30s 计时；快速切回时由 [onAppForeground] 取消，
  /// 不会白白清掉用户马上要看的封面。重复的 pause / hide 只保留第一次计时。
  void onAppBackground() {
    // Android 的 TRIM_MEMORY_UI_HIDDEN 会在退后台前后触发
    // didHaveMemoryPressure；它是生命周期事件，不是真低内存。取消刚排上的
    // 低内存释放，避免每次退后台都清空浏览 / 搜索缓存。
    if (_lowMemoryTimer != null) {
      _lowMemoryTimer!.cancel();
      _lowMemoryTimer = null;
      _log('退后台取消低内存清理（UI_HIDDEN）');
    }
    if (_mobileBackground) return;
    _mobileBackground = true;
    _inBackgroundTransition = true;
    _backgroundTransitionTimer?.cancel();
    _backgroundTransitionTimer = Timer(kMemoryPressureTransitionGuard, () {
      _inBackgroundTransition = false;
    });
    final token = ++_mobileTrimToken;
    _log('移动端退后台（${kMobileBackgroundTrimDelay.inSeconds}s 后清理）');
    _mobileTrimTimer = Timer(kMobileBackgroundTrimDelay, () {
      if (token != _mobileTrimToken) return;
      _mobileTrimTimer = null;
      _trimForMobileBackground();
    });
  }

  /// 移动端回前台：取消待执行的清理并恢复完整图片缓存预算（幂等）。
  void onAppForeground() {
    final wasBackground = _mobileBackground;
    _mobileBackground = false;
    _inBackgroundTransition = false;
    _backgroundTransitionTimer?.cancel();
    _backgroundTransitionTimer = null;
    _mobileTrimToken++;
    _mobileTrimTimer?.cancel();
    _mobileTrimTimer = null;
    if (wasBackground && _lowMemoryTimer != null) {
      _lowMemoryTimer!.cancel();
      _lowMemoryTimer = null;
      _log('回前台取消低内存清理（UI_HIDDEN）');
    }
    if (!wasBackground) return;
    _restoreLimit(phase: '移动端回前台');
  }

  /// 系统低内存（`WidgetsBindingObserver.didHaveMemoryPressure`）。
  ///
  /// 只在这种情况下释放可重建的浏览 / 搜索 / 目录缓存；同时清掉图片缓存的
  /// pending / keepAlive。live 图片仍被当前界面引用，保留不动（Android 恢复
  /// 时当前封面不会闪空）。上限保持完整预算，避免一次低内存后长期降质。
  ///
  /// 去抖 [kMemoryPressureDebounce]：Android 退后台的 UI_HIDDEN 也会走到
  /// 这里，真正的低内存不应被一次普通的切后台触发。紧随其后的
  /// [onAppBackground] 会取消这次释放；已经后台一段时间后再收到压力则照常
  /// 释放（那才可能是真正的后台低内存）。
  void onMemoryPressure() {
    _log('系统低内存');
    _lowMemoryTimer?.cancel();
    _lowMemoryTimer = Timer(kMemoryPressureDebounce, () {
      _lowMemoryTimer = null;
      if (_inBackgroundTransition) {
        _log('低内存信号来自退后台（UI_HIDDEN），跳过业务缓存清理');
        return;
      }
      _releaseLowMemoryCaches();
    });
  }

  /// 低内存清理的实际执行点（去抖 / 过渡判断之后）。
  void _releaseLowMemoryCaches() {
    _runReleasers(_lowMemoryReleasers, failureMessage: '低内存业务缓存释放失败');
    _cache.clear();
    _releaseToOs();
    _log('系统低内存清理完成');
  }

  void dispose() {
    _trayLateTrimTimer?.cancel();
    _trayLateTrimTimer = null;
    _mobileTrimToken++;
    _mobileTrimTimer?.cancel();
    _mobileTrimTimer = null;
    _lowMemoryTimer?.cancel();
    _lowMemoryTimer = null;
    _mobileBackground = false;
    _inBackgroundTransition = false;
    _backgroundTransitionTimer?.cancel();
    _backgroundTransitionTimer = null;
    _releasers.clear();
    _lowMemoryReleasers.clear();
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

  void _restoreLimit({String phase = '窗口可见'}) {
    _trimToken++;
    _trayLateTrimTimer?.cancel();
    _trayLateTrimTimer = null;
    if (_cache.maximumSizeBytes != _fullLimitBytes) {
      _cache.maximumSizeBytes = _fullLimitBytes;
    }
    _log(phase);
  }

  Future<void> _trimForTray() async {
    final token = ++_trimToken;
    _log('托盘隐藏（等休眠帧）');
    // 休眠树在下一次 build 换上：等这一帧结束，页面里的 live 图片引用先释放，
    // 再清缓存才能真正把像素交还。
    await SchedulerBinding.instance.endOfFrame.timeout(
      const Duration(seconds: 2),
      onTimeout: () {},
    );
    if (token != _trimToken || !_presence.isTrayHidden) return;
    // 业务缓存先放掉：纯 Dart 对象不依赖休眠帧，但同样挂住列表 / 搜索的
    // raw payload；快速隐藏→恢复（token 已变）时跳过，避免白白触发重载。
    _runReleasers(_releasers, failureMessage: '托盘业务缓存释放失败');
    _cache.clear();
    _cache.clearLiveImages();
    _cache.maximumSizeBytes = math.min(
      _fullLimitBytes,
      kTrayImageCacheLimitBytes,
    );
    // 清完再 trim：不然日志里的 RSS / 工作集还是「已释放未归还」的那笔数。
    _releaseToOs();
    _log('托盘隐藏完成');
    _scheduleTrayLateTrim(token);
  }

  /// 隐藏后第二次 trim：原生窗口 hide 与引擎收尾还会 touch 一批页，第一次
  /// trim 之后它们可能重新回到工作集。只归还空闲页，不重复清缓存 / 不跑
  /// 业务 releaser；恢复或再次隐藏时由 token 作废。
  void _scheduleTrayLateTrim(int token) {
    _trayLateTrimTimer?.cancel();
    _trayLateTrimTimer = Timer(kTrayLateTrimDelay, () {
      _trayLateTrimTimer = null;
      if (token != _trimToken || !_presence.isTrayHidden) return;
      _releaseToOs();
      _log('托盘隐藏延迟 trim');
    });
  }

  /// 移动端后台 30s 后的清理。
  ///
  /// Android 退后台不卸载界面，live 图片仍被页面引用——绝不能
  /// `clearLiveImages()`，否则回前台当前封面会短暂空白。只清 pending /
  /// keepAlive，并把新解码预算压到托盘档位；恢复由 [onAppForeground] 负责。
  void _trimForMobileBackground() {
    _log('移动端后台清理');
    _cache.clear();
    _cache.maximumSizeBytes = math.min(
      _fullLimitBytes,
      kTrayImageCacheLimitBytes,
    );
    _releaseToOs();
    _log('移动端后台清理完成');
  }

  /// 依次执行释放回调：单个失败只记日志，不影响图片缓存清理与其它持有者。
  void _runReleasers(
    List<void Function()> releasers, {
    required String failureMessage,
  }) {
    for (final releaser in List<void Function()>.of(releasers)) {
      try {
        releaser();
      } catch (e, stackTrace) {
        _logger.warning(failureMessage, e, stackTrace);
      }
    }
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
