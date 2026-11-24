import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../data/settings/settings_access.dart';
import 'any_listen/any_listen_config.dart';
import 'any_listen/any_listen_source.dart';
import 'builtin/artist_source.dart';
import 'builtin/builtin_transport.dart';
import 'builtin/lyric_hit.dart';
import 'lx/lx_engine_supervisor.dart';
import 'lx/lx_engine_types.dart';
import 'lx/lx_script_info.dart';
import 'lx/lx_script_repository.dart';
import 'lx/lx_script_update.dart';
import 'source_manager_state.dart';
import 'source_preferences.dart';
import 'source_profiles.dart';
import 'source_route_executor.dart';
import 'source_search_result.dart';
import 'source_track.dart';
import '../domain/models/album.dart';
import '../domain/models/artist.dart';
import '../domain/models/comment.dart';
import '../domain/models/source.dart' show SourceCapabilities, SourceDescriptor;
import '../domain/models/source_script.dart' show SourceScriptUpdate;
import '../domain/ports/music_source.dart' show PlayableStream;
import '../utils/snapshot_source.dart';

// UI（音源页）白名单仅允许直连 source_manager，这里把在线更新流程的
// 返回/异常类型随管理器一起导出，避免扩大分层豁免。
export 'lx/lx_engine_types.dart' show LxEngineException;
export 'lx/lx_script_update.dart'
    show ScriptUpdateCheck, ScriptUpdateError, ScriptUpdateException;
// SourceKind 定义在 sources/source_profiles.dart（画像模块的唯一事实），
// 这里 re-export 保持既有 import 路径与调用方不变。
export 'source_profiles.dart' show SourceKind, SourceProfile, SourceProfiles;
// 快照类型随管理器一起导出，保持既有 import 路径可用。
export 'source_manager_state.dart';

/// 音源管理器：
/// - 管理已导入的 LX 音源脚本（导入 / 删除 / 激活）；
/// - 聚合内置平台搜索、脚本扩展搜索与 any-listen 远程音源；
/// - 统一对外提供取链 / 歌词 / 封面能力。
///
/// 该抽象与 any-listen 的接入隔离：上层只依赖 [SourceManager] 的
/// search / resolveStream / fetchLyric / fetchPic 能力；any-listen 通过
/// [AnyListenSource] 适配为 [SourceKind.anyListen]。仅当「已配置且启用」
/// 时才出现在 [searchableSources]，未配置/连接失败时对现有功能零影响。
///
/// 本类只保留生命周期（引擎 / 脚本仓库 / 偏好 / any-listen 配置）与画像
/// facade；搜索 / 取链 / 歌词 / 封面 / 评论 / 专辑 / 歌手 / 歌词搜索的实际
/// 路线执行在 [SourceRouteExecutor]，公开签名与错误语义保持不变。
class SourceManager implements SnapshotSource<SourceManagerState> {
  final LxScriptRepository repository = LxScriptRepository();

  /// 变更信号（替代 `ChangeNotifier.notifyListeners` 的订阅面）。
  final SnapshotSignal _changes = SnapshotSignal();

  /// 引擎自愈包装：超时/isolate 退出后自动按退避重启。
  /// 构造参数仅用于测试注入（默认创建真实 supervisor，行为不变）。
  final LxEngineSupervisor _engine;
  final SettingsAccess _settings;
  final AnyListenSource _anyListenSource;
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  /// 渠道偏好（音质 / 顺序 / 停用）的唯一持有者；变化经本类转发给 UI。
  late final SourcePreferences _preferences;

  /// 内置平台的唯一 HTTP 传输（组合根注入；测试各自构造）。
  ///
  /// 生产只构造一次并同时注入发现 / 歌词来源等消费方，缓存 / single-flight
  /// / 重试预算因此共享；测试传自己的实例即可完全隔离。
  final BuiltinTransport _builtinTransport;

  /// 能力执行器：不持有画像 / 路由状态，只持有由管理器转交清理的内置取词 /
  /// 取图缓存；画像快照与惰性激活回调仍由本管理器提供。
  late final SourceRouteExecutor _executor;

  SourceManager({
    LxEngineSupervisor? engine,
    BuiltinTransport? builtinTransport,
    required SettingsAccess settings,
    List<Duration> activationRetryDelays = const [
      Duration(seconds: 5),
      Duration(seconds: 20),
    ],
    Duration lazyActivationCooldown = const Duration(seconds: 5),
  }) : _engine = engine ?? LxEngineSupervisor(),
       _builtinTransport = builtinTransport ?? BuiltinTransport(),
       _settings = settings,
       _anyListenSource = AnyListenSource(settings: settings),
       _activationRetryDelays = List<Duration>.unmodifiable(
         activationRetryDelays,
       ),
       // 公开参数名保持 lazyActivationCooldown（测试注入短冷却要能具名传参），
       // 字段按本类惯例私有。
       // ignore: prefer_initializing_formals
       _lazyActivationCooldown = lazyActivationCooldown {
    _preferences = SourcePreferences(_settings)
      ..changes.addListener(_onPreferencesChanged);
    _executor = SourceRouteExecutor(
      engine: _engine,
      anyListenSource: _anyListenSource,
      builtinTransport: _builtinTransport,
      preferences: _preferences,
      profiles: () => sourceProfiles,
      ensureActiveScript: _ensureActiveScript,
    );
    _engine.onStateChanged = _onEngineStateChanged;
  }

  /// 启动激活失败的延迟重试间隔（次数 = 长度）。生产默认 5s / 20s；
  /// 测试注入短间隔，不等待真实秒级定时器。
  final List<Duration> _activationRetryDelays;

  /// 惰性激活（首次使用触发）的冷却：失败后短时间内不重复重跑脚本。
  final Duration _lazyActivationCooldown;

  bool _initialized = false;

  /// 脚本仓库读完即可做批量更新检查（不必等引擎激活完成）。
  final Completer<void> _scriptsReady = Completer<void>();

  String? _activatingId;
  String? _activeError;
  Map<String, LxSourceDecl> _activeSources = {};
  LxUpdateAlert? _lastUpdateAlert;

  /// 启动激活失败的延迟重试计时器（用户主动停用 / 激活成功即取消）。
  Timer? _activationRetryTimer;
  int _activationRetryAttempt = 0;

  /// 最近一次惰性激活的尝试时刻（限流用；见 [_ensureActiveScript]）。
  DateTime? _lastLazyActivationAt;

  /// 在途的 [retryEngine]（连点「重试」/ 网络事件连发时合并成一次）。
  Future<bool>? _retryEngineInFlight;

  bool get initialized => _initialized;
  Future<void> get scriptsReady => _scriptsReady.future;
  bool get isActivating => _activatingId != null;
  String? get activeError => _activeError;
  Map<String, LxSourceDecl> get activeSources =>
      Map.unmodifiable(_activeSources);
  List<LxScriptInfo> get scripts => repository.scripts;
  LxScriptInfo? get activeScript => repository.activeScript;
  bool get engineReady => _engine.isRunning;

  /// 引擎是否处于「已停止、等冷却后半开恢复」状态（网络恢复触发读这里）。
  bool get engineFailed => _engine.isFailed;

  String get preferredQuality => _preferences.preferredQuality;
  LxUpdateAlert? get lastUpdateAlert => _lastUpdateAlert;

  /// 用户自定义的渠道顺序（持久化于 shared_preferences；同时决定渠道路由
  /// 之外的展示顺序与搜索音源顺序）。
  List<String> get sourceOrder => _preferences.sourceOrder;

  /// 已停用的渠道集合（持久化；停用只影响列表/选择，不影响已保存曲目的取链）。
  Set<String> get disabledChannels => _preferences.disabledChannels;

  /// 当前音源是否可用（激活了脚本且引擎就绪）。
  bool get hasActiveSource => _engine.isRunning && _activeSources.isNotEmpty;

  /// 不可变快照：UI / 日志经 [changes] 通知后重建。
  @override
  SourceManagerState get state {
    final profiles = sourceProfiles;
    return SourceManagerState(
      initialized: _initialized,
      isActivating: _activatingId != null,
      activeError: _activeError,
      activeScript: repository.activeScript,
      activeSources: _activeSources,
      scripts: repository.scripts,
      engineReady: _engine.isRunning,
      engineFailed: _engine.isFailed,
      hasActiveSource: hasActiveSource,
      preferredQuality: _preferences.preferredQuality,
      lastUpdateAlert: _lastUpdateAlert,
      sourceOrder: _preferences.sourceOrder,
      disabledChannels: _preferences.disabledChannels,
      channels: profiles.channels.toDescriptors(),
      searchableSources: profiles.searchable.toDescriptors(),
      anyListenConfig: _anyListenSource.config,
      anyListenAvailable: _anyListenSource.isUsable,
    );
  }

  /// 变更信号（音源页 / 播放门面 / 同步桥 / 注册表适配器共同订阅）。
  @override
  Listenable get changes => _changes;

  void _onPreferencesChanged() => _changes.notify();

  /// 内置平台 HTTP 传输（组合根与其它栈共享同一实例；只读）。
  BuiltinTransport get builtinTransport => _builtinTransport;

  /// 释放内置平台的共享响应缓存（托盘隐藏 / 系统低内存）。
  void clearBuiltinCache() => _builtinTransport.clearCache();

  /// any-listen 适配器（搜索 / 取链 / 歌词 / 封面 / 连接测试）。
  AnyListenSource get anyListenSource => _anyListenSource;

  /// 供连接测试用的独立适配器：复用本管理器的按键作用域，不另建注册表。
  ///
  /// 页面可独立打开探测表单值，不要求先 `init()`；配置存取路径用不到，
  /// 但构造仍要求一个合法的设置来源。
  AnyListenSource createProbeSource() => AnyListenSource(settings: _settings);

  /// any-listen 当前配置。
  AnyListenConfig get anyListenConfig => _anyListenSource.config;

  /// any-listen 是否「已配置且启用」；只有此时才出现在 [searchableSources]。
  bool get anyListenAvailable => _anyListenSource.isUsable;

  /// 当前音源画像快照（渠道 / 能力 / 可见性的唯一事实）。
  ///
  /// 每次读取按当前激活脚本、any-listen 配置与渠道偏好重建；个位数条目，
  /// 不做缓存就没有失效逻辑，也不会出现「能力位更新了、渠道没更新」。
  SourceProfiles get sourceProfiles => SourceProfiles.build(
    activeSources: _activeSources,
    anyListenUsable: _anyListenSource.isUsable,
    disabledChannels: _preferences.disabledChannels,
    sourceOrder: _preferences.sourceOrder,
  );

  /// 全部渠道（可搜索源 + 内置发现平台的并集，含停用项；按用户顺序排列）。
  ///
  /// 资料页的渠道选择与「音源管理」的渠道排序都消费该列表；脚本扩展源 /
  /// any-listen 只有搜索能力，内置发现平台无论是否有脚本都保留发现入口。
  List<SourceDescriptor> get channels =>
      sourceProfiles.channels.toDescriptors();

  /// 可供搜索/播放的音源列表（仅启用项；按用户自定义顺序排列）。
  List<SourceDescriptor> get searchableSources =>
      sourceProfiles.searchable.toDescriptors();

  /// 音源能力：直接读 [SourceProfiles]（registry / 领域适配器共用同一答案）。
  SourceCapabilities capabilitiesFor(String key) =>
      sourceProfiles.forKey(key)?.capabilities ?? const SourceCapabilities();

  /// supervisor 状态回调：重启 / 半开恢复成功后用引擎当前声明的源刷新
  /// [activeSources]，修复“引擎死了源列表还在”（超时 kill 后脚本重新执行，
  /// 声明可能变化）；进入 failed 时把失败原因写进 [activeError]，
  /// 让音源页立刻出现「重试」入口（不必等下一次取链失败）。
  void _onEngineStateChanged(LxEngineState state) {
    switch (state) {
      case LxEngineState.ready:
        _activeSources = Map<String, LxSourceDecl>.from(_engine.sources);
        _activeError = null;
      case LxEngineState.failed:
        // 不清 _activeSources：惰性激活只在“该源没有声明”时触发，留着声明
        // 才能让 failed 的冷却由 supervisor 统一裁决（而不是每次请求都跑脚本）。
        _activeError = _engine.failureReason ?? '音源引擎已停止';
      case LxEngineState.stopped:
      case LxEngineState.starting:
      case LxEngineState.restarting:
        return;
    }
    _changes.notify();
  }

  Future<void> init() async {
    try {
      await repository.init();
    } finally {
      // 批量更新检查只需要脚本仓库，不跟引擎激活串行。
      if (!_scriptsReady.isCompleted) _scriptsReady.complete();
    }
    await _preferences.load();
    // 只读本地配置，不发起网络请求；失败时 AnyListenSource 维持默认（未配置）。
    await _anyListenSource.init();

    _subscriptions.add(
      _engine.logs.listen((entry) {
        if (kDebugMode) debugPrint('[LX:${entry.level}] ${entry.message}');
      }),
    );
    _subscriptions.add(
      _engine.updateAlerts.listen((alert) {
        _lastUpdateAlert = alert;
        // 运行期上报的更新地址记入当前激活脚本，供「立即更新」使用。
        unawaited(_recordUpdateUrl(alert));
        _changes.notify();
      }),
    );

    _initialized = true;
    _changes.notify();

    final activeId = repository.activeId;
    if (activeId != null) {
      try {
        await activate(activeId);
      } catch (_) {
        // 激活失败保留错误信息供 UI 展示（activate 已写入 _activeError），
        // 并安排延迟重试：启动阶段的脚本加载 / 网络抖动不该让音源一直不可用。
        _scheduleActivationRetry(activeId);
      }
    }
  }

  /// 重新读取渠道偏好（顺序 / 停用 / 音质）。跨设备同步应用远端设置后由
  /// 组合根挂载的 reload 触发；先重置为默认再加载，
  /// 保证远端「清空」也能生效。状态与重载实现见 [SourcePreferences]。
  Future<void> reloadPreferences() => _preferences.reload();

  /// 脚本被外部（跨设备同步）增删改后刷新引擎状态：
  /// 有激活脚本则重新激活（重新执行脚本、收集声明的源），否则停用引擎。
  Future<void> refreshScriptsFromStorage() async {
    final activeId = repository.activeId;
    if (activeId == null) {
      if (_activeSources.isNotEmpty) {
        await _engine.dispose();
        _activeSources = {};
      }
      _changes.notify();
      return;
    }
    try {
      await activate(activeId);
    } catch (_) {
      // 激活失败保留错误信息供 UI 展示（activate 已写入 _activeError）。
    }
  }

  Future<void> setPreferredQuality(String quality) =>
      _preferences.setPreferredQuality(quality);

  /// 覆盖音源顺序（去重后持久化）。
  Future<void> setSourceOrder(List<String> keys) =>
      _preferences.setSourceOrder(keys);

  /// 拖拽排序：把渠道列表（含内置发现平台；停用项同样参与排序）第
  /// [oldIndex] 项移动到 [newIndex]。
  ///
  /// [newIndex] 是 `ReorderableListView.onReorderItem` 语义（已按「移除
  /// oldIndex 后」校正），直接按下标搬移。
  Future<void> reorderChannel(int oldIndex, int newIndex) async {
    final keys = channels.map((o) => o.key).toList();
    if (oldIndex < 0 || oldIndex >= keys.length) return;
    final target = newIndex.clamp(0, keys.length - 1);
    if (target == oldIndex) return;
    final moved = keys.removeAt(oldIndex);
    keys.insert(target, moved);
    await setSourceOrder(keys);
  }

  /// 启用 / 停用渠道（持久化）。停用后该渠道不再出现在资料页渠道选择
  /// 与搜索结果中；已保存内容仍可通过内部路由取链播放。
  Future<void> setChannelEnabled(String key, bool enabled) =>
      _preferences.setChannelEnabled(key, enabled);

  /// 本机脚本写入钩子（组合根接线：同步层立即登记并追加增量日志）。
  ///
  /// 只在**本机**导入 / 更新 / 删除脚本时触发；应用远端脚本走仓库层，
  /// 不经过这些方法。
  void Function(String id)? onScriptWritten;
  void Function(String id)? onScriptRemoved;

  /// 清空自定义渠道顺序，恢复「脚本音源在前、内置平台在后」的默认排序。
  Future<void> resetChannelOrder() => _preferences.resetChannelOrder();

  /// 保存 any-listen 配置（设置页调用），并刷新音源可见性。
  ///
  /// 只写本地，不发起网络请求；返回是否持久化成功。
  Future<bool> updateAnyListenConfig(AnyListenConfig config) async {
    final saved = await _anyListenSource.updateConfig(config);
    _changes.notify();
    return saved;
  }

  /// 重新从 shared_preferences 加载 any-listen 配置（例如设置页直接写入后）。
  Future<void> reloadAnyListenConfig() async {
    await _anyListenSource.init();
    _changes.notify();
  }

  /// 导入脚本（不激活时可用于预览）。
  Future<LxScriptInfo> importScript(
    String script, {
    bool activate = false,
  }) async {
    final info = LxScriptInfo.parse(script);
    if (info == null) {
      throw const FormatException('无法解析音源脚本：缺少以 /** @name ... */ 开头的元信息');
    }
    await repository.add(info);
    onScriptWritten?.call(info.id);
    _changes.notify();
    if (activate || repository.activeScript == null) {
      await this.activate(info.id);
    }
    return info;
  }

  /// 激活指定脚本（重新执行脚本并收集其声明的源）。
  Future<void> activate(String id) async {
    final script = repository.scripts.where((s) => s.id == id).firstOrNull;
    if (script == null) {
      throw LxEngineException('音源脚本不存在: $id');
    }
    _cancelActivationRetry();
    _activatingId = id;
    _activeError = null;
    _changes.notify();
    try {
      final sources = await _engine.start(script);
      _activeSources = sources;
      _activationRetryAttempt = 0;
      await repository.setActive(id);
      await repository.cacheSources(id, sources);
    } catch (e) {
      _activeError = e is LxEngineException ? e.message : e.toString();
      _activeSources = {};
      rethrow;
    } finally {
      _activatingId = null;
      _changes.notify();
    }
  }

  /// 停用当前音源。
  ///
  /// 这是用户的显式决定：取消待执行的激活重试并清掉错误提示，之后的惰性
  /// 激活（[_ensureActiveScript]）也不会再把脚本拉起来。
  Future<void> deactivate() async {
    _cancelActivationRetry();
    await _engine.dispose();
    _activeSources = {};
    _activeError = null;
    _activationRetryAttempt = 0;
    await repository.setActive(null);
    _changes.notify();
  }

  /// 安排一次延迟激活重试（[_activationRetryDelays] 用尽后不再重试）。
  void _scheduleActivationRetry(String id) {
    if (_activationRetryAttempt >= _activationRetryDelays.length) return;
    final delay = _activationRetryDelays[_activationRetryAttempt++];
    _activationRetryTimer?.cancel();
    _activationRetryTimer = Timer(delay, () {
      _activationRetryTimer = null;
      unawaited(_retryActivation(id));
    });
  }

  /// 延迟重试回调：用户已切换 / 停用脚本或另有激活在途时直接放弃。
  Future<void> _retryActivation(String id) async {
    if (!_initialized || _activatingId != null) return;
    if (repository.activeId != id) return;
    try {
      await activate(id);
    } catch (_) {
      // 失败仍写 _activeError；按剩余间隔继续重试。
      _scheduleActivationRetry(id);
    }
  }

  void _cancelActivationRetry() {
    _activationRetryTimer?.cancel();
    _activationRetryTimer = null;
  }

  /// 惰性激活兜底（脚本源的搜索 / 取链 / 歌词 / 封面入口调用）。
  ///
  /// 只有「用户保存了激活脚本、但引擎没跑起来」（启动激活失败、半开冷却中）
  /// 才补一次激活：没有激活脚本（`repository.activeScript == null`，含用户
  /// 主动停用）绝不自动拉起；引擎已就绪或该源已声明时无事可做。用
  /// [_lazyActivationCooldown] 限流，避免每次失败请求都重跑脚本
  /// （激活本身要几百毫秒到数秒）。
  Future<void> _ensureActiveScript(String sourceKey) async {
    if (_activeSources[sourceKey] != null) return;
    // 用 activeScript 而不是 activeId：脚本被删除 / 仓库里找不到时没有可
    // 重放的内容，不能每隔几秒撞一次「脚本不存在」。
    final activeScript = repository.activeScript;
    if (activeScript == null || _engine.isRunning || _activatingId != null) {
      return;
    }
    final now = DateTime.now();
    final lastAttempt = _lastLazyActivationAt;
    if (lastAttempt != null &&
        now.difference(lastAttempt) < _lazyActivationCooldown) {
      return;
    }
    _lastLazyActivationAt = now;
    try {
      await activate(activeScript.id);
    } catch (_) {
      // 失败已写入 _activeError（UI 展示 + 重试按钮），调用方按原路失败。
    }
  }

  /// 立即重试引擎恢复（音源页「重试」与网络恢复触发）。
  ///
  /// 绕过 supervisor 的半开冷却；成功时用引擎当前声明的源刷新
  /// [activeSources] 并清掉 [activeError]，失败保留可读原因。
  /// 无激活脚本 / 引擎已就绪时视为成功（没有可恢复的东西）。
  Future<bool> retryEngine() => _retryEngineInFlight ??= _retryEngine()
      .whenComplete(() => _retryEngineInFlight = null);

  Future<bool> _retryEngine() async {
    _cancelActivationRetry();
    _activationRetryAttempt = 0;
    final ok = await _engine.retryNow();
    if (ok) {
      _activeError = null;
      if (_engine.isRunning) {
        _activeSources = Map<String, LxSourceDecl>.from(_engine.sources);
      }
    } else {
      _activeError = _engine.failureReason ?? '音源引擎仍未恢复，请稍后重试';
    }
    _changes.notify();
    return ok;
  }

  Future<void> removeScript(String id) async {
    await repository.remove(id);
    onScriptRemoved?.call(id);
    if (repository.activeId == null) {
      // 脚本被删掉后没有可激活目标：连待执行的启动重试一起取消。
      _cancelActivationRetry();
      _activationRetryAttempt = 0;
      await _engine.dispose();
      _activeSources = {};
    }
    _changes.notify();
  }

  /// 分页搜索；路由与失败语义见 [SourceRouteExecutor.searchWithMeta]。
  Future<SourceSearchResult> searchWithMeta(
    String sourceKey,
    String keyword, {
    int page = 1,
    int limit = 30,
  }) => _executor.searchWithMeta(sourceKey, keyword, page: page, limit: limit);

  /// 解析播放流（音质降档 / 请求头透传 / 惰性激活细节见
  /// [SourceRouteExecutor.resolveStream]）。
  Future<PlayableStream> resolveStream(
    SourceTrack track, {
    String? requestedQuality,
    Duration? timeout,
  }) => _executor.resolveStream(
    track,
    requestedQuality: requestedQuality,
    timeout: timeout,
  );

  /// 获取歌词（脚本优先、内置平台原生回退）；细节见
  /// [SourceRouteExecutor.fetchLyric]。
  Future<LxLyricResult?> fetchLyric(SourceTrack track) =>
      _executor.fetchLyric(track);

  /// 清掉某平台的原生取词缓存（B 站扫码登录后调用）。
  ///
  /// `BuiltinLyricDispatch` 会缓存 null 5 分钟；登录态从无到有时必须清掉，
  /// 否则当前曲目仍会走跨平台回退。
  void invalidateLyricCacheFor(String sourceKey) =>
      _executor.invalidateLyricCacheFor(sourceKey);

  /// 托盘隐藏 / 系统低内存：释放内置平台原生取词缓存。
  ///
  /// 只动结果缓存，脚本仓库 / 引擎 / 渠道偏好都不在这里清；幂等。
  void releaseBuiltinLyricCache() => _executor.releaseBuiltinLyricCache();

  /// 托盘隐藏 / 系统低内存：释放内置平台原生取图缓存（同上，幂等）。
  void releaseBuiltinPicCache() => _executor.releaseBuiltinPicCache();

  /// 获取曲目评论（内置平台）；失败统一为 [SourceFailure]。细节见
  /// [SourceRouteExecutor.fetchComments]。
  Future<CommentPage> fetchComments(
    SourceTrack track, {
    required CommentKind kind,
    int page = 1,
    int limit = kCommentPageSize,
  }) => _executor.fetchComments(track, kind: kind, page: page, limit: limit);

  /// 获取专辑（内置平台）；失败统一为 [SourceFailure]。细节见
  /// [SourceRouteExecutor.fetchAlbum]。
  Future<Album> fetchAlbum(
    String sourceKey,
    String albumId, {
    int page = 1,
    int limit = kAlbumPageSize,
  }) => _executor.fetchAlbum(sourceKey, albumId, page: page, limit: limit);

  /// 获取歌手详情与一页歌曲（内置平台）；失败统一为 [SourceFailure]。细节见
  /// [SourceRouteExecutor.fetchArtist]。
  Future<ArtistDetail> fetchArtist(
    String sourceKey,
    String artistId, {
    int page = 1,
    int limit = kArtistPageSize,
  }) => _executor.fetchArtist(sourceKey, artistId, page: page, limit: limit);

  /// 歌手搜索（内置平台）；失败统一为 [SourceFailure]。细节见
  /// [SourceRouteExecutor.searchArtists]。
  Future<ArtistSearchPage> searchArtists(
    String sourceKey,
    String keyword, {
    int page = 1,
    int limit = 30,
  }) => _executor.searchArtists(sourceKey, keyword, page: page, limit: limit);

  /// 按歌词搜歌（内置平台）；失败统一为 [SourceFailure]。细节见
  /// [SourceRouteExecutor.searchLyrics]。
  Future<LyricSearchPage> searchLyrics(
    String sourceKey,
    String keyword, {
    int page = 1,
    int limit = 30,
  }) => _executor.searchLyrics(sourceKey, keyword, page: page, limit: limit);

  /// 获取封面（脚本优先、内置平台原生回退）；细节见
  /// [SourceRouteExecutor.fetchPic]。
  Future<String?> fetchPic(SourceTrack track) => _executor.fetchPic(track);

  /// 运行期 `updateAlert` 上报的更新地址记入当前激活脚本。
  Future<void> _recordUpdateUrl(LxUpdateAlert alert) async {
    final url = alert.updateUrl?.trim();
    if (url == null || url.isEmpty) return;
    final active = repository.activeScript;
    if (active == null || active.updateUrl == url) return;
    try {
      await repository.replace(active.id, active.copyWith(updateUrl: url));
      _changes.notify();
    } catch (e) {
      debugPrint('[SourceManager] 记录更新地址失败: $e');
    }
  }

  LxScriptInfo _scriptById(String id) {
    final script = repository.scripts.where((s) => s.id == id).firstOrNull;
    if (script == null) {
      throw const ScriptUpdateException(
        ScriptUpdateError.scriptNotFound,
        '音源脚本不存在或已被删除',
      );
    }
    return script;
  }

  /// 检查脚本是否有在线更新（下载 [LxScriptInfo.updateUrl] 并与本地对比）。
  ///
  /// 判定规则：版本号不同即视为有更新；版本号相同（含都为空）再比较脚本
  /// 内容 hash，内容变化同样视为有更新。无 updateUrl、下载失败、内容非法
  /// 时抛可读的 [ScriptUpdateException]。
  Future<ScriptUpdateCheck> checkScriptUpdate(String id) async {
    final current = _scriptById(id);
    final url = current.updateUrl?.trim();
    if (url == null || url.isEmpty) {
      throw const ScriptUpdateException(
        ScriptUpdateError.noUpdateUrl,
        '该音源未提供更新地址，请手动导入新版本',
      );
    }
    final text = await downloadLxScriptText(url);
    final latest = parseDownloadedScript(text, id: current.id);
    final hasUpdate =
        latest.version != current.version ||
        _scriptHash(latest.script) != _scriptHash(current.script);
    return ScriptUpdateCheck(
      hasUpdate: hasUpdate,
      currentVersion: current.version,
      latestVersion: latest.version,
      latestScript: latest,
    );
  }

  /// 批量检查所有声明了更新地址的脚本（自动检查用）。
  ///
  /// 单个脚本失败（下载超时 / 页面不是脚本 / 地址失效）只跳过它，不让整轮
  /// 检查失败；无更新地址的脚本不参与。并发上限 3，避免启动时同时打开太多
  /// 连接。调用前应等 [scriptsReady]。
  Future<List<SourceScriptUpdate>> checkScriptUpdates() async {
    final candidates = repository.scripts
        .where((script) => (script.updateUrl?.trim().isNotEmpty ?? false))
        .toList(growable: false);
    final updates = <SourceScriptUpdate>[];
    const batchSize = 3;
    for (var start = 0; start < candidates.length; start += batchSize) {
      final end = (start + batchSize).clamp(0, candidates.length);
      final batch = candidates.sublist(start, end);
      final results = await Future.wait(
        batch.map((script) async {
          try {
            final check = await checkScriptUpdate(script.id);
            if (!check.hasUpdate) return null;
            return SourceScriptUpdate(
              id: script.id,
              name: script.name,
              currentVersion: check.currentVersion,
              latestVersion: check.latestVersion,
            );
          } catch (e) {
            debugPrint('[SourceManager] 检查音源更新失败（${script.id}）: $e');
            return null;
          }
        }),
      );
      updates.addAll(results.whereType<SourceScriptUpdate>());
    }
    return updates;
  }

  /// 应用在线更新：下载最新脚本并原地替换（保留 id / 导入时间 / 激活态）。
  ///
  /// 传入 [check] 可复用 [checkScriptUpdate] 已下载的结果，避免重复下载。
  /// 若该脚本正在激活中，替换后重新激活（引擎重放新脚本并刷新
  /// [activeSources]）。
  Future<LxScriptInfo> applyScriptUpdate(
    String id, {
    ScriptUpdateCheck? check,
  }) async {
    _scriptById(id);
    final result = check ?? await checkScriptUpdate(id);
    final replaced = await repository.replace(id, result.latestScript);
    onScriptWritten?.call(id);
    if (repository.activeId == id) {
      await activate(id);
    } else {
      _changes.notify();
    }
    return replaced;
  }

  static String _scriptHash(String script) =>
      md5.convert(utf8.encode(script)).toString();

  void clearUpdateAlert() {
    _lastUpdateAlert = null;
    _changes.notify();
  }

  void dispose() {
    _cancelActivationRetry();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _preferences.changes.removeListener(_onPreferencesChanged);
    _anyListenSource.dispose();
    _engine.onStateChanged = null;
    _engine.close();
  }
}
