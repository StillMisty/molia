/// 资料库读投影：一个视图的「读快照 vs 写 / 其它读」唯一仲裁。
///
/// 为什么单独一层：收藏键、播放历史、列表清单、列表曲目原先各写一套
/// generation / in-flight / pending 状态机，规则相同但散在 provider 的
/// 不同方法里。一次读取落地时到底该写回、合并、丢弃，还是等最后一个读取
/// 结束再重放缓冲写入，需要和写入路径一起看；收进这里后，`LibraryProvider`
/// 只负责扇出与业务补丁。
///
/// 这个类不知道资料库的领域形状：值、quiet 合并、写缓冲重放、失败阶段都由
/// 持有方注入，因此四个视图可以各持一份，而不是长成一个 God object。
library;

import 'dart:async';

import 'library_outcome.dart';

/// 一次读取的意图。
///
/// quiet：仓库变更后的后台校准，保持当前数据可见、不翻转 loading。
/// explicit：首屏 / 页面请求 / 失败重试，可以显示 loading。
enum LibraryReadIntent { quiet, explicit }

/// 一帧读投影快照。
class LibraryReadSnapshot<T> {
  const LibraryReadSnapshot({
    required this.value,
    required this.state,
    required this.loaded,
    required this.authoritative,
    required this.reading,
  });

  /// 当前采用的数据。
  final T value;

  /// 读取阶段（loading / ready / failed）。
  final LibraryReadState state;

  /// 是否至少成功读到过一次整表快照。
  final bool loaded;

  /// 当前 [value] 是否来自一次完整的仓库快照（收藏计数校准用）。
  final bool authoritative;

  /// 是否有读取在途。
  final bool reading;
}

/// 一次读取的结果。
///
/// [value] 是仓库读到的原始快照（失败时为空）；[accepted] 表示它是否被
/// 写回投影。代际过期 / 释放后的结果仍原样返回给显式等待方，只是不进入
/// 缓存——与既有 `loadPlaylistTracks` 的返回语义一致。
class LibraryReadResult<T> {
  const LibraryReadResult._({
    required this.accepted,
    required this.generation,
    this.value,
    this.error,
  });

  final bool accepted;
  final int generation;
  final T? value;
  final Object? error;

  bool get failed => error != null;

  bool get succeeded => error == null;
}

/// 通用读投影协调器。
///
/// 职责：
/// - 记录读取阶段、loaded / authoritative / 最近错误；
/// - 每次读取捕获代际，只有仍有效的读取能写回（[supersedeReads] 为真时
///   后发起的读取还会抢占先发起的读取）；
/// - 记录在途读取，读取期间到达的写入先缓冲，最后一个读取落地后重放；
/// - quiet 读取按 [mergeQuiet] 合并、不翻 loading；explicit 读取替换快照。
class ReadReconciliation<T, W> {
  ReadReconciliation({
    required T initialValue,
    required this.mergeQuiet,
    required this.replayWrites,
    required this.failureState,
    this.supersedeReads = false,
    this.canReadQuietly,
    this.replayRequiresLoaded = true,
  }) : _initialValue = initialValue,
       _value = initialValue;

  final T _initialValue;

  /// quiet 读取落地时如何与当前快照合并。
  final T Function(T current, T fresh) mergeQuiet;

  /// 最后一个在途读取结束后，把缓冲写入重放进快照。
  final T Function(T current, List<W> pending) replayWrites;

  /// 失败时给出读取阶段：空数据 failed，有旧数据 ready。
  final LibraryReadState Function(T value, Object error) failureState;

  /// 后发起的读取是否让先发起的读取作废。
  ///
  /// 收藏键必须为 true：启动 ensure 与变更后的静默校准可能重叠，旧快照
  /// 最后落地时不能回滚较新的读取。历史 / 列表 / 列表曲目保持 false：
  /// 它们的并发读取按落地顺序写回，只有显式释放才整体代际失效。
  final bool supersedeReads;

  /// quiet 读取的前置条件；null = 总是允许。
  ///
  /// 列表曲目用它表达「静默重载只刷新已缓存列表」。
  final bool Function(T value)? canReadQuietly;

  /// 重放缓冲写入前是否要求已经成功读过整表。
  ///
  /// 历史在从未加载成功时保留缓冲，等下一次首屏读取再合并；收藏切换的
  /// 重放是幂等补丁，失败后也照常重放。
  final bool replayRequiresLoaded;

  T _value;
  LibraryReadState _state = const LibraryReadState.loading();
  bool _loaded = false;
  bool _authoritative = false;
  Object? _error;
  int _generation = 0;
  int _inFlight = 0;
  bool _explicitLoading = false;
  bool _explicitQueued = false;
  List<W> _pending = const [];
  bool _disposed = false;

  T get value => _value;
  LibraryReadState get state => _state;
  bool get loaded => _loaded;
  bool get authoritative => _authoritative;
  Object? get error => _error;
  int get generation => _generation;
  bool get reading => _inFlight > 0;

  /// 显式读取是否已标记（build 期 ensure 的同步占位也算）。
  bool get explicitLoading => _explicitLoading || _explicitQueued;

  LibraryReadSnapshot<T> get snapshot => LibraryReadSnapshot(
    value: _value,
    state: _state,
    loaded: _loaded,
    authoritative: _authoritative,
    reading: reading,
  );

  /// 同步占位一次显式读取（build 期内可调用；通知由调用方推迟到微任务）。
  ///
  /// 返回 false 表示已有显式读取在途 / 已占位，调用方不要再发起查询。
  /// 只挡显式读取：静默重载与显式读取可以并存，和原 `_loadingPlaylistIds`
  /// 的集合语义一致。
  bool markExplicitLoading() {
    if (_disposed || _explicitQueued || _explicitLoading) return false;
    _explicitQueued = true;
    _state = const LibraryReadState.loading();
    return true;
  }

  /// 读取期间到达的写：能缓冲就返回 true，调用方不要再直接补快照。
  bool bufferWrite(W write) {
    if (_inFlight <= 0) return false;
    _pending = [..._pending, write];
    return true;
  }

  /// 直接修改快照（乐观写 / 收藏行补丁 / 导入预置）。
  ///
  /// 不改变读取阶段；[loaded] 非空时一并修正 loaded（清空历史的乐观写会
  /// 把「从未加载」变成「已加载且为空」）。
  void patch(T Function(T current) update, {bool? loaded}) {
    _value = update(_value);
    if (loaded != null) _loaded = loaded;
  }

  /// 写路径已经拿到落库行：直接铺进快照并清掉旧错误。
  void seed(T value) {
    _value = value;
    _error = null;
  }

  /// 仓库变更事件表明旧错误不再代表当前数据（页面下一次 ensure 可重读）。
  void clearFailure() {
    _error = null;
    if (_state.isFailed) _state = const LibraryReadState.loading();
  }

  /// 失效当前快照。
  ///
  /// [staleReads] 让释放前发出的读取结果作废（托盘释放浏览缓存）；
  /// [discardValue] 丢掉旧值（重试 / 全量失效）；
  /// [discardPending] 丢掉缓冲写入（历史整表重读前）。
  void invalidate({
    bool staleReads = false,
    bool discardValue = false,
    bool discardPending = false,
  }) {
    if (staleReads) _generation++;
    _loaded = false;
    _authoritative = false;
    if (discardPending) _pending = const [];
    if (discardValue) {
      _value = _initialValue;
      _error = null;
      _state = const LibraryReadState.loading();
    }
  }

  /// 读取一次仓库快照。
  ///
  /// [duringRead] 在结果已受理、但本次读取仍算在途时执行：收藏校准要在
  /// 「收藏键 → 收藏列表 → 列表清单」全部落地后才重放期间的 toggle，回调
  /// 因此不能等 in-flight 归零后再跑。
  Future<LibraryReadResult<T>> load({
    required LibraryReadIntent intent,
    required Future<T> Function() fetch,
    bool discardPendingOnStart = false,
    FutureOr<void> Function(LibraryReadResult<T> result)? duringRead,
  }) async {
    final canReadQuietly = this.canReadQuietly;
    if (intent == LibraryReadIntent.quiet &&
        canReadQuietly != null &&
        !canReadQuietly(_value)) {
      return LibraryReadResult<T>._(accepted: false, generation: _generation);
    }
    if (_disposed) {
      return LibraryReadResult<T>._(accepted: false, generation: _generation);
    }

    if (intent == LibraryReadIntent.explicit) {
      _explicitQueued = false;
      _explicitLoading = true;
      _state = const LibraryReadState.loading();
    }
    final generation = supersedeReads ? ++_generation : _generation;
    if (discardPendingOnStart) _pending = const [];
    _inFlight++;

    LibraryReadResult<T> result;
    try {
      final fresh = await fetch();
      final accepted = !_disposed && generation == _generation;
      if (accepted) {
        _value = intent == LibraryReadIntent.quiet
            ? mergeQuiet(_value, fresh)
            : fresh;
        _loaded = true;
        _authoritative = true;
        _error = null;
        _state = const LibraryReadState.ready();
      }
      result = LibraryReadResult<T>._(
        accepted: accepted,
        generation: generation,
        value: fresh,
      );
    } catch (e) {
      final accepted = !_disposed && generation == _generation;
      if (accepted) {
        _error = e;
        _state = failureState(_value, e);
      }
      result = LibraryReadResult<T>._(
        accepted: accepted,
        generation: generation,
        error: e,
      );
    }

    if (duringRead != null) {
      try {
        await duringRead(result);
      } finally {
        _finishRead(intent, generation);
      }
    } else {
      _finishRead(intent, generation);
    }
    return result;
  }

  /// 收尾：归还在途计数、回收 loading 占位，并在最后一个读取落地后重放缓冲。
  void _finishRead(LibraryReadIntent intent, int generation) {
    _inFlight--;
    if (intent == LibraryReadIntent.explicit &&
        !_disposed &&
        generation == _generation) {
      // 与原来的 loading 集合一致：每个显式请求落地都回收自己那份标记。
      _explicitLoading = false;
    }
    _drainPending();
  }

  /// 最后一个读取落地后重放缓冲写入；只在没有读取在途时消费缓冲。
  void _drainPending() {
    if (_inFlight > 0 || _pending.isEmpty) return;
    if (replayRequiresLoaded && !_loaded) return;
    final pending = _pending;
    _pending = const [];
    _value = replayWrites(_value, pending);
  }

  /// dispose 后晚到的读取结果不再写回。
  void dispose() {
    _disposed = true;
    _generation++;
    _pending = const [];
  }
}
