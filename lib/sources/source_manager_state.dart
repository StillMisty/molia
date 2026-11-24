/// 音源管理器的不可变快照类型（从 `source_manager.dart` 拆出，控制单文件体积）。
library;

import 'package:flutter/foundation.dart';

import '../domain/models/any_listen.dart';
import '../domain/models/source.dart' show SourceDescriptor;
import 'lx/lx_engine_types.dart' show LxUpdateAlert;
import 'lx/lx_script_info.dart';

/// 音源管理器对 UI / 日志暴露的不可变快照。
///
/// 字段名沿用旧 `SourceManager` 的公开 getter；画像（渠道 / 能力 / 可见性）
/// 也在快照里给出，消费方不必再为同一轮状态重复推导。
@immutable
class SourceManagerState {
  SourceManagerState({
    required this.initialized,
    required this.isActivating,
    required this.activeError,
    required this.activeScript,
    required Map<String, LxSourceDecl> activeSources,
    required List<LxScriptInfo> scripts,
    required this.engineReady,
    required this.engineFailed,
    required this.hasActiveSource,
    required this.preferredQuality,
    required this.lastUpdateAlert,
    required List<String> sourceOrder,
    required Set<String> disabledChannels,
    required List<SourceDescriptor> channels,
    required List<SourceDescriptor> searchableSources,
    required this.anyListenConfig,
    required this.anyListenAvailable,
  }) : activeSources = Map.unmodifiable(activeSources),
       scripts = List.unmodifiable(scripts),
       sourceOrder = List.unmodifiable(sourceOrder),
       disabledChannels = Set.unmodifiable(disabledChannels),
       channels = List.unmodifiable(channels),
       searchableSources = List.unmodifiable(searchableSources);

  /// manager 是否已完成初始化。
  final bool initialized;

  /// 是否正在激活（页面显示进度）。
  final bool isActivating;

  /// 最近一次激活 / 引擎失败的可读原因（无失败为 null）。
  final String? activeError;

  /// 当前激活脚本（无激活为 null）。
  final LxScriptInfo? activeScript;

  /// 激活脚本声明的源（按 key 索引）。
  final Map<String, LxSourceDecl> activeSources;

  /// 已导入脚本列表（不含脚本原文）。
  final List<LxScriptInfo> scripts;

  /// 引擎当前是否在运行。
  final bool engineReady;

  /// 引擎是否处于「已停止、等冷却后半开恢复」状态。
  final bool engineFailed;

  /// 当前音源是否可用（激活了脚本且引擎就绪）。
  final bool hasActiveSource;

  /// 默认音质偏好。
  final String preferredQuality;

  /// 运行期更新提示（无提示为 null）。
  final LxUpdateAlert? lastUpdateAlert;

  /// 用户自定义的渠道顺序。
  final List<String> sourceOrder;

  /// 已停用的渠道集合。
  final Set<String> disabledChannels;

  /// 全部渠道（含停用项；按用户顺序排列）。
  final List<SourceDescriptor> channels;

  /// 可供搜索/播放的音源（仅启用项；按用户顺序排列）。
  final List<SourceDescriptor> searchableSources;

  /// any-listen 当前配置。
  final AnyListenConfig anyListenConfig;

  /// any-listen 是否「已配置且启用」。
  final bool anyListenAvailable;
}
