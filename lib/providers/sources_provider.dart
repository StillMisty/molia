import 'package:flutter/foundation.dart';

import '../domain/models/any_listen.dart';
import '../domain/models/source.dart' as domain;
import '../domain/models/source_script.dart';
import '../sources/any_listen/any_listen_source.dart';
import '../sources/lx/lx_script_info.dart';
import '../sources/lx/lx_script_update.dart';
import '../sources/source_manager.dart';
import '../sources/source_track.dart' show kLxQualityOrder;

/// 音源管理的 UI 门面（ChangeNotifier）：把 [SourceManager]（脚本仓库 /
/// 引擎 / any-listen 适配器）适配为纯领域视图与命令。
///
/// 分层约定（docs/architecture.md §2.1 R5）：`lib/pages/**` 只依赖本
/// provider 与 `lib/domain/**`，不直接 import `lib/sources/**`。
///
/// 生命周期：provider 订阅 manager 的通知并转发；**不负责** dispose
/// manager（由 composition root / 测试各自管理），仅释放自己持有的资源。
class SourcesProvider extends ChangeNotifier {
  SourcesProvider(this._manager) {
    _manager.addListener(_onManagerChanged);
  }

  final SourceManager _manager;

  /// 独立连接测试兜底：页面可独立打开探测表单值，不依赖 manager.init()。
  /// 与旧页面「无 manager 时自建 AnyListenSource」的行为等价。
  AnyListenSource? _testSource;

  /// 最近一次 [checkScriptUpdate] 的完整结果：供 [applyScriptUpdate] 复用，
  /// 避免同一轮更新重复下载（对齐旧页面传 `check` 的行为）。
  String? _pendingCheckId;
  ScriptUpdateCheck? _pendingCheck;

  void _onManagerChanged() => notifyListeners();

  // ——————————————————————— 数据视图 ———————————————————————

  /// manager 是否已完成初始化（false 时页面显示加载态）。
  bool get initialized => _manager.initialized;

  /// 当前音源是否可用（激活了脚本且引擎就绪）。
  bool get hasActiveSource => _manager.hasActiveSource;

  /// 是否正在激活（页面显示进度）。
  bool get isActivating => _manager.isActivating;

  /// 最近一次激活失败的可读原因（无失败为 null）。
  String? get activeError => _manager.activeError;

  /// 当前激活脚本的纯数据视图（无激活为 null）。
  SourceScriptInfo? get activeScript {
    final script = _manager.activeScript;
    return script == null ? null : _toInfo(script);
  }

  /// 当前激活脚本 id（无激活为 null）。
  String? get activeScriptId => _manager.activeScript?.id;

  /// 激活脚本声明的源（展示用：name / actions / qualitys）。
  List<SourceScriptDecl> get activeSourceEntries =>
      _manager.activeSources.values.map(_toDecl).toList(growable: false);

  /// 已导入脚本列表（不含脚本原文）。
  List<SourceScriptInfo> get scripts =>
      _manager.scripts.map(_toInfo).toList(growable: false);

  /// 可供搜索/播放的音源（仅启用项；按用户自定义顺序排列）。
  List<SourceEntry> get searchableSources => _manager.searchableSources
      .map((option) => SourceEntry(
            key: option.key,
            name: option.name,
            kind: _toDomainKind(option.kind),
            canSearch: option.canSearch,
            discoverable: option.discoverable,
            enabled: option.enabled,
          ))
      .toList(growable: false);

  /// 全部渠道（可搜索源 + 内置发现平台的并集，含停用项；按用户顺序）。
  List<SourceEntry> get channels => _manager.channels
      .map((option) => SourceEntry(
            key: option.key,
            name: option.name,
            kind: _toDomainKind(option.kind),
            canSearch: option.canSearch,
            discoverable: option.discoverable,
            enabled: option.enabled,
          ))
      .toList(growable: false);

  /// 默认音质偏好。
  String get preferredQuality => _manager.preferredQuality;

  /// 默认音质可选项（值 + 通用显示名；本地化由 UI 按 value 覆盖）。
  List<SourceQualityOption> get qualityOptions => kLxQualityOrder
      .map((value) => SourceQualityOption(
            value: value,
            displayName: qualityDisplayName(value),
          ))
      .toList(growable: false);

  /// 用户自定义音源顺序。
  List<String> get sourceOrder => _manager.sourceOrder;

  /// 运行期更新提示的纯数据视图（无提示为 null）。
  SourceUpdateAlert? get lastUpdateAlert {
    final alert = _manager.lastUpdateAlert;
    return alert == null
        ? null
        : SourceUpdateAlert(log: alert.log, updateUrl: alert.updateUrl);
  }

  /// any-listen 当前配置。
  AnyListenConfig get anyListenConfig => _manager.anyListenConfig;

  /// any-listen 是否「已配置且启用」。
  bool get anyListenAvailable => _manager.anyListenAvailable;

  // ——————————————————————— 命令 ———————————————————————

  /// 导入脚本（activate 为 true 或当前无激活脚本时自动激活）。
  ///
  /// 纯委托：解析失败抛原始 FormatException、激活失败抛 LxEngineException，
  /// 与旧页面对应的 `$e` 展示保持一致（URL 导入路径在 [importFromUrl] 归一化）。
  Future<SourceScriptInfo> importScript(
    String script, {
    bool activate = false,
  }) async {
    final info = await _manager.importScript(script, activate: activate);
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
      final info = await _manager.importScript(text, activate: true);
      return _toInfo(info);
    } catch (e) {
      throw _wrap(e);
    }
  }

  Future<void> removeScript(String id) => _manager.removeScript(id);

  Future<void> activate(String id) => _manager.activate(id);

  Future<void> deactivate() => _manager.deactivate();

  /// 将渠道在渠道列表中上移/下移（含内置发现平台与停用项）。
  Future<void> moveChannel(String key, int delta) =>
      _manager.moveChannel(key, delta);

  /// 启用 / 停用渠道（停用后不出现在资料页与搜索结果中）。
  Future<void> setChannelEnabled(String key, bool enabled) =>
      _manager.setChannelEnabled(key, enabled);

  Future<void> resetChannelOrder() => _manager.resetChannelOrder();

  Future<void> setPreferredQuality(String quality) =>
      _manager.setPreferredQuality(quality);

  /// 检查在线更新；下载失败等以可读 [SourceScriptException] 抛出。
  Future<SourceUpdateCheck> checkScriptUpdate(String id) async {
    try {
      final check = await _manager.checkScriptUpdate(id);
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
      final updated = await _manager.applyScriptUpdate(id, check: check);
      return _toInfo(updated);
    } catch (e) {
      throw _wrap(e);
    }
  }

  /// 保存 any-listen 配置并刷新音源可见性；返回是否持久化成功。
  Future<bool> saveAnyListenConfig(AnyListenConfig config) =>
      _manager.updateAnyListenConfig(config);

  /// 连接测试（用表单当前值探测，不要求先保存；绝不抛异常）。
  Future<AnyListenTestResult> testAnyListenConfig(AnyListenConfig config) {
    final source = _testSource ??= AnyListenSource();
    return source.testConnection(overrideConfig: config);
  }

  /// 重新从 shared_preferences 加载 any-listen 配置（页面打开时刷新表单）。
  Future<void> reloadAnyListenConfig() => _manager.reloadAnyListenConfig();

  void clearUpdateAlert() => _manager.clearUpdateAlert();

  @override
  void dispose() {
    _manager.removeListener(_onManagerChanged);
    _testSource?.dispose();
    _pendingCheck = null;
    _pendingCheckId = null;
    super.dispose();
  }

  // ——————————————————————— 领域转换 ———————————————————————

  /// 把 sources 层异常归一化为可读的 [SourceScriptException]：
  /// 与旧页面 `_readableError` 的文案保持一致（更新网页地址可识别）。
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

  domain.SourceKind _toDomainKind(SourceKind kind) => switch (kind) {
        SourceKind.builtin => domain.SourceKind.builtin,
        SourceKind.lx => domain.SourceKind.lx,
        SourceKind.anyListen => domain.SourceKind.anyListen,
      };
}
