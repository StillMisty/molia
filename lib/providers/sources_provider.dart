import 'package:flutter/foundation.dart';

import '../domain/models/any_listen.dart';
import '../domain/models/source.dart' show SourceDescriptor;
import '../domain/models/source_script.dart';
import '../sources/any_listen/any_listen_source.dart';
import '../sources/lx/lx_engine_types.dart' show LxEngineException;
import '../sources/lx/lx_script_info.dart';
import '../sources/lx/lx_script_update.dart';
import '../sources/source_track.dart' show kLxQualityOrder;
import 'snapshot_source.dart';
import 'sources_backend.dart';

/// 音源管理页读到的不可变快照。
///
/// 字段名沿用旧 [SourcesProvider] 的公开 getter；命令仍落在
/// [SourcesProvider] 上，经 `sourcesControllerProvider` 取实例。
@immutable
class SourcesState {
  const SourcesState({
    required this.initialized,
    required this.hasActiveSource,
    required this.isActivating,
    required this.activeError,
    required this.activeScript,
    required this.activeSourceEntries,
    required this.scripts,
    required this.searchableSources,
    required this.channels,
    required this.preferredQuality,
    required this.qualityOptions,
    required this.sourceOrder,
    required this.lastUpdateAlert,
    required this.anyListenConfig,
    required this.anyListenAvailable,
  });

  /// manager 是否已完成初始化（false 时页面显示加载态）。
  final bool initialized;

  /// 当前音源是否可用（激活了脚本且引擎就绪）。
  final bool hasActiveSource;

  /// 是否正在激活（页面显示进度）。
  final bool isActivating;

  /// 最近一次激活失败的可读原因（无失败为 null）。
  final String? activeError;

  /// 当前激活脚本的纯数据视图（无激活为 null）。
  final SourceScriptInfo? activeScript;

  /// 激活脚本声明的源（展示用：name / actions / qualitys）。
  final List<SourceScriptDecl> activeSourceEntries;

  /// 已导入脚本列表（不含脚本原文）。
  final List<SourceScriptInfo> scripts;

  /// 可供搜索/播放的音源（仅启用项；按用户自定义顺序排列）。
  final List<SourceDescriptor> searchableSources;

  /// 全部渠道（可搜索源 + 内置发现平台的并集，含停用项；按用户顺序）。
  final List<SourceDescriptor> channels;

  /// 默认音质偏好。
  final String preferredQuality;

  /// 默认音质可选项（值 + 通用显示名；本地化由 UI 按 value 覆盖）。
  final List<SourceQualityOption> qualityOptions;

  /// 用户自定义音源顺序。
  final List<String> sourceOrder;

  /// 运行期更新提示的纯数据视图（无提示为 null）。
  final SourceUpdateAlert? lastUpdateAlert;

  /// any-listen 当前配置。
  final AnyListenConfig anyListenConfig;

  /// any-listen 是否「已配置且启用」。
  final bool anyListenAvailable;

  /// 当前激活脚本 id（无激活为 null）。
  String? get activeScriptId => activeScript?.id;
}

/// 音源管理的 UI 门面：把 [SourcesBackend]（脚本仓库 / 引擎 / any-listen
/// 适配器）适配为纯领域视图与命令。
///
/// 分层约定（docs/architecture.md §1 第 5 条）：`lib/pages/**` 只依赖本
/// provider 与 `lib/domain/**`，不直接 import `lib/sources/**`。
///
/// 生命周期：provider 订阅 backend 的通知并转发；**不负责** dispose
/// backend（由 composition root / 测试各自管理），仅释放自己持有的资源。
///
/// 对外形态是「不可变快照 + 控制器」（ADR-0041「启动期状态对象」）：UI 经
/// `sourcesProvider` 读 [SourcesState]，命令经 `sourcesControllerProvider`
/// 调用。
class SourcesProvider implements SnapshotSource<SourcesState> {
  SourcesProvider(this._backend) {
    _backend.addListener(_onBackendChanged);
  }

  final SourcesBackend _backend;

  /// 变更信号（替代 `ChangeNotifier.notifyListeners` 的订阅面）。
  final SnapshotSignal _changes = SnapshotSignal();

  /// 独立连接测试兜底：页面可独立打开探测表单值，不依赖 manager.init()。
  AnyListenSource? _testSource;

  /// 最近一次 [checkScriptUpdate] 的完整结果：供 [applyScriptUpdate] 复用，
  /// 避免同一轮更新重复下载。
  String? _pendingCheckId;
  ScriptUpdateCheck? _pendingCheck;

  void _onBackendChanged() => _changes.notify();

  /// manager 是否已完成初始化（false 时页面显示加载态）。
  bool get initialized => _backend.initialized;

  /// 当前音源是否可用（激活了脚本且引擎就绪）。
  bool get hasActiveSource => _backend.hasActiveSource;

  /// 是否正在激活（页面显示进度）。
  bool get isActivating => _backend.isActivating;

  /// 最近一次激活失败的可读原因（无失败为 null）。
  String? get activeError => _backend.activeError;

  /// 当前激活脚本的纯数据视图（无激活为 null）。
  SourceScriptInfo? get activeScript {
    final script = _backend.activeScript;
    return script == null ? null : _toInfo(script);
  }

  /// 当前激活脚本 id（无激活为 null）。
  String? get activeScriptId => _backend.activeScript?.id;

  /// 激活脚本声明的源（展示用：name / actions / qualitys）。
  List<SourceScriptDecl> get activeSourceEntries =>
      _backend.activeSources.values.map(_toDecl).toList(growable: false);

  /// 已导入脚本列表（不含脚本原文）。
  List<SourceScriptInfo> get scripts =>
      _backend.scripts.map(_toInfo).toList(growable: false);

  /// 可供搜索/播放的音源（仅启用项；按用户自定义顺序排列）。
  List<SourceDescriptor> get searchableSources => _backend.searchableSources;

  /// 全部渠道（可搜索源 + 内置发现平台的并集，含停用项；按用户顺序）。
  List<SourceDescriptor> get channels => _backend.channels;

  /// 默认音质偏好。
  String get preferredQuality => _backend.preferredQuality;

  /// 默认音质可选项（值 + 通用显示名；本地化由 UI 按 value 覆盖）。
  List<SourceQualityOption> get qualityOptions => kLxQualityOrder
      .map(
        (value) => SourceQualityOption(
          value: value,
          displayName: qualityDisplayName(value),
        ),
      )
      .toList(growable: false);

  /// 用户自定义音源顺序。
  List<String> get sourceOrder => _backend.sourceOrder;

  /// 运行期更新提示的纯数据视图（无提示为 null）。
  SourceUpdateAlert? get lastUpdateAlert {
    final alert = _backend.lastUpdateAlert;
    return alert == null
        ? null
        : SourceUpdateAlert(log: alert.log, updateUrl: alert.updateUrl);
  }

  /// any-listen 当前配置。
  AnyListenConfig get anyListenConfig => _backend.anyListenConfig;

  /// any-listen 是否「已配置且启用」。
  bool get anyListenAvailable => _backend.anyListenAvailable;

  /// 导入脚本（activate 为 true 或当前无激活脚本时自动激活）。
  ///
  /// 纯委托：解析失败抛原始 FormatException、激活失败抛 LxEngineException
  /// （URL 导入路径在 [importFromUrl] 归一化）。
  Future<SourceScriptInfo> importScript(
    String script, {
    bool activate = false,
  }) async {
    final info = await _backend.importScript(script, activate: activate);
    return _toInfo(info);
  }

  /// 从 URL 下载并导入（无 scheme 自动补 https://；10s 超时）。
  ///
  /// 下载/校验复用 `lx_script_update.dart` 的工具，失败抛可读的
  /// [SourceScriptException]；脚本内容非法时由解析抛 FormatException。
  Future<SourceScriptInfo> importFromUrl(String input) async {
    var url = input.trim();
    final parsed = Uri.tryParse(url);
    if (parsed == null || parsed.scheme.isEmpty) {
      url = 'https://$url';
    }
    try {
      final text = await downloadLxScriptText(url);
      final info = await _backend.importScript(text, activate: true);
      return _toInfo(info);
    } catch (e) {
      throw _wrap(e);
    }
  }

  Future<void> removeScript(String id) => _backend.removeScript(id);

  Future<void> activate(String id) => _backend.activate(id);

  Future<void> deactivate() => _backend.deactivate();

  /// 立即重试引擎恢复（绕过冷却）；失败原因由 [activeError] 自动刷新。
  Future<bool> retryEngine() => _backend.retryEngine();

  /// 将渠道在渠道列表中上移/下移（含内置发现平台与停用项）。
  Future<void> reorderChannel(int oldIndex, int newIndex) =>
      _backend.reorderChannel(oldIndex, newIndex);

  /// 启用 / 停用渠道（停用后不出现在资料页与搜索结果中）。
  Future<void> setChannelEnabled(String key, bool enabled) =>
      _backend.setChannelEnabled(key, enabled);

  Future<void> resetChannelOrder() => _backend.resetChannelOrder();

  Future<void> setPreferredQuality(String quality) =>
      _backend.setPreferredQuality(quality);

  /// 检查在线更新；下载失败等以可读 [SourceScriptException] 抛出。
  Future<SourceUpdateCheck> checkScriptUpdate(String id) async {
    try {
      final check = await _backend.checkScriptUpdate(id);
      _pendingCheckId = id;
      _pendingCheck = check;
      return SourceUpdateCheck(
        hasUpdate: check.hasUpdate,
        currentVersion: check.currentVersion,
        latestVersion: check.latestVersion,
      );
    } catch (e) {
      throw _wrap(e);
    }
  }

  /// 应用在线更新（原地替换并保留 id / 导入时间 / 激活态）。
  ///
  /// 紧跟 [checkScriptUpdate] 调用时复用其下载结果，不重复下载。
  Future<SourceScriptInfo> applyScriptUpdate(String id) async {
    final check = _pendingCheckId == id ? _pendingCheck : null;
    _pendingCheckId = null;
    _pendingCheck = null;
    try {
      final updated = await _backend.applyScriptUpdate(id, check: check);
      return _toInfo(updated);
    } catch (e) {
      throw _wrap(e);
    }
  }

  /// 保存 any-listen 配置并刷新音源可见性；返回是否持久化成功。
  Future<bool> saveAnyListenConfig(AnyListenConfig config) =>
      _backend.updateAnyListenConfig(config);

  /// 连接测试（用表单当前值探测，不要求先保存；绝不抛异常）。
  Future<AnyListenTestResult> testAnyListenConfig(AnyListenConfig config) {
    final source = _testSource ??= _backend.createProbeSource();
    return source.testConnection(overrideConfig: config);
  }

  /// 重新从 shared_preferences 加载 any-listen 配置（页面打开时刷新表单）。
  Future<void> reloadAnyListenConfig() => _backend.reloadAnyListenConfig();

  void clearUpdateAlert() => _backend.clearUpdateAlert();

  /// 不可变快照：UI 经 `sourcesProvider` 读它（每次 [changes] 通知后重建）。
  @override
  SourcesState get state => SourcesState(
    initialized: initialized,
    hasActiveSource: hasActiveSource,
    isActivating: isActivating,
    activeError: activeError,
    activeScript: activeScript,
    activeSourceEntries: List.unmodifiable(activeSourceEntries),
    scripts: List.unmodifiable(scripts),
    searchableSources: List.unmodifiable(searchableSources),
    channels: List.unmodifiable(channels),
    preferredQuality: preferredQuality,
    qualityOptions: List.unmodifiable(qualityOptions),
    sourceOrder: List.unmodifiable(sourceOrder),
    lastUpdateAlert: lastUpdateAlert,
    anyListenConfig: anyListenConfig,
    anyListenAvailable: anyListenAvailable,
  );

  /// 变更信号（backend 每次通知后由 provider 重新读取快照）。
  @override
  Listenable get changes => _changes;

  void dispose() {
    _backend.removeListener(_onBackendChanged);
    _testSource?.dispose();
    _pendingCheck = null;
    _pendingCheckId = null;
  }

  /// 把 sources 层异常归一化为可读的 [SourceScriptException]
  /// （更新网页地址可识别）。
  SourceScriptException _wrap(Object error) {
    if (error is ScriptUpdateException) {
      return SourceScriptException(
        error.message,
        htmlPage: error.kind == ScriptUpdateError.htmlPage,
      );
    }
    if (error is LxEngineException) return SourceScriptException(error.message);
    final text = error.toString();
    const prefix = 'Exception: ';
    return SourceScriptException(
      text.startsWith(prefix) ? text.substring(prefix.length) : text,
    );
  }

  SourceScriptInfo _toInfo(LxScriptInfo script) => SourceScriptInfo(
    id: script.id,
    name: script.name,
    description: script.description,
    version: script.version,
    author: script.author,
    homepage: script.homepage,
    updateUrl: script.updateUrl,
    importedAt: script.importedAt,
    sources: script.sources.map((key, decl) => MapEntry(key, _toDecl(decl))),
  );

  SourceScriptDecl _toDecl(LxSourceDecl decl) => SourceScriptDecl(
    key: decl.key,
    name: decl.name,
    actions: decl.actions,
    qualitys: decl.qualitys,
  );
}
