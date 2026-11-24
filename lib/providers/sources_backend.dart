/// 音源管理门面的底层依赖。
///
/// [SourcesProvider] 只通过本接口读脚本仓库 / 渠道偏好 / any-listen 配置并
/// 转发命令；生产实现是 [SourceManagerBackend]（包住启动期的 `SourceManager`），
/// 测试可以注入假实现，不必构造真实引擎或设置存储。
library;

import 'package:flutter/foundation.dart';

import '../domain/models/any_listen.dart';
import '../domain/models/source.dart' show SourceDescriptor;
import '../sources/any_listen/any_listen_source.dart';
import '../sources/lx/lx_engine_types.dart';
import '../sources/lx/lx_script_info.dart';
import '../sources/source_manager.dart';

/// 音源管理需要的读写面（状态 + 命令 + 变更信号）。
abstract interface class SourcesBackend implements Listenable {
  bool get initialized;

  bool get hasActiveSource;

  bool get isActivating;

  String? get activeError;

  LxScriptInfo? get activeScript;

  Map<String, LxSourceDecl> get activeSources;

  List<LxScriptInfo> get scripts;

  List<SourceDescriptor> get searchableSources;

  List<SourceDescriptor> get channels;

  String get preferredQuality;

  List<String> get sourceOrder;

  LxUpdateAlert? get lastUpdateAlert;

  AnyListenConfig get anyListenConfig;

  bool get anyListenAvailable;

  Future<LxScriptInfo> importScript(String script, {bool activate = false});

  Future<void> removeScript(String id);

  Future<void> activate(String id);

  Future<void> deactivate();

  Future<bool> retryEngine();

  Future<void> reorderChannel(int oldIndex, int newIndex);

  Future<void> setChannelEnabled(String key, bool enabled);

  Future<void> resetChannelOrder();

  Future<void> setPreferredQuality(String quality);

  Future<ScriptUpdateCheck> checkScriptUpdate(String id);

  Future<LxScriptInfo> applyScriptUpdate(String id, {ScriptUpdateCheck? check});

  Future<bool> updateAnyListenConfig(AnyListenConfig config);

  AnyListenSource createProbeSource();

  Future<void> reloadAnyListenConfig();

  void clearUpdateAlert();
}

/// [SourcesBackend] 的生产实现：状态读 [SourceManager.state] 快照，命令
/// 仍由 manager 自己执行。
///
/// 生命周期仍归组合根：本适配器不 dispose 被包住的 manager；监听直接挂在
/// manager 的 [SourceManager.changes] 上，适配器本身不另存订阅。
class SourceManagerBackend implements SourcesBackend {
  SourceManagerBackend(this._manager);

  final SourceManager _manager;

  SourceManagerState get _state => _manager.state;

  @override
  void addListener(VoidCallback listener) =>
      _manager.changes.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _manager.changes.removeListener(listener);

  @override
  bool get initialized => _state.initialized;

  @override
  bool get hasActiveSource => _state.hasActiveSource;

  @override
  bool get isActivating => _state.isActivating;

  @override
  String? get activeError => _state.activeError;

  @override
  LxScriptInfo? get activeScript => _state.activeScript;

  @override
  Map<String, LxSourceDecl> get activeSources => _state.activeSources;

  @override
  List<LxScriptInfo> get scripts => _state.scripts;

  @override
  List<SourceDescriptor> get searchableSources => _state.searchableSources;

  @override
  List<SourceDescriptor> get channels => _state.channels;

  @override
  String get preferredQuality => _state.preferredQuality;

  @override
  List<String> get sourceOrder => _state.sourceOrder;

  @override
  LxUpdateAlert? get lastUpdateAlert => _state.lastUpdateAlert;

  @override
  AnyListenConfig get anyListenConfig => _state.anyListenConfig;

  @override
  bool get anyListenAvailable => _state.anyListenAvailable;

  @override
  Future<LxScriptInfo> importScript(String script, {bool activate = false}) =>
      _manager.importScript(script, activate: activate);

  @override
  Future<void> removeScript(String id) => _manager.removeScript(id);

  @override
  Future<void> activate(String id) => _manager.activate(id);

  @override
  Future<void> deactivate() => _manager.deactivate();

  @override
  Future<bool> retryEngine() => _manager.retryEngine();

  @override
  Future<void> reorderChannel(int oldIndex, int newIndex) =>
      _manager.reorderChannel(oldIndex, newIndex);

  @override
  Future<void> setChannelEnabled(String key, bool enabled) =>
      _manager.setChannelEnabled(key, enabled);

  @override
  Future<void> resetChannelOrder() => _manager.resetChannelOrder();

  @override
  Future<void> setPreferredQuality(String quality) =>
      _manager.setPreferredQuality(quality);

  @override
  Future<ScriptUpdateCheck> checkScriptUpdate(String id) =>
      _manager.checkScriptUpdate(id);

  @override
  Future<LxScriptInfo> applyScriptUpdate(
    String id, {
    ScriptUpdateCheck? check,
  }) => _manager.applyScriptUpdate(id, check: check);

  @override
  Future<bool> updateAnyListenConfig(AnyListenConfig config) =>
      _manager.updateAnyListenConfig(config);

  @override
  AnyListenSource createProbeSource() => _manager.createProbeSource();

  @override
  Future<void> reloadAnyListenConfig() => _manager.reloadAnyListenConfig();

  @override
  void clearUpdateAlert() => _manager.clearUpdateAlert();
}
