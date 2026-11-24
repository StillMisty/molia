/// 音源管理测试替身：给 `SourcesProvider` 一份可控的注册表 / 偏好数据，
/// 不构造真实 `SourceManager`、引擎或设置存储。
library;

import 'package:flutter/foundation.dart';
import 'package:molia/domain/models/any_listen.dart';
import 'package:molia/domain/models/source.dart' show SourceDescriptor;
import 'package:molia/providers/sources_backend.dart';
import 'package:molia/sources/lx/lx_engine_types.dart';
import 'package:molia/sources/lx/lx_script_info.dart';

class FakeSourcesBackend extends ChangeNotifier implements SourcesBackend {
  FakeSourcesBackend({
    this.initialized = true,
    this.channels = const [],
    this.preferredQuality = '320k',
    this.hasActiveSource = false,
    this.isActivating = false,
    this.activeError,
    this.activeScript,
    this.activeSources = const {},
    this.scripts = const [],
    this.searchableSources = const [],
    this.sourceOrder = const [],
    this.lastUpdateAlert,
    this.anyListenConfig = AnyListenConfig.empty,
    this.anyListenAvailable = false,
  });

  @override
  bool initialized;

  @override
  List<SourceDescriptor> channels;

  @override
  String preferredQuality;

  @override
  bool hasActiveSource;

  @override
  bool isActivating;

  @override
  String? activeError;

  @override
  LxScriptInfo? activeScript;

  @override
  Map<String, LxSourceDecl> activeSources;

  @override
  List<LxScriptInfo> scripts;

  @override
  List<SourceDescriptor> searchableSources;

  @override
  List<String> sourceOrder;

  @override
  LxUpdateAlert? lastUpdateAlert;

  @override
  AnyListenConfig anyListenConfig;

  @override
  bool anyListenAvailable;

  /// 渠道启停命令的调用记录（onboarding 等用例断言）。
  final List<(String, bool)> channelCalls = [];

  /// 默认音质命令的调用记录。
  final List<String> qualityCalls = [];

  @override
  Future<void> setChannelEnabled(String key, bool enabled) async {
    channelCalls.add((key, enabled));
  }

  @override
  Future<void> setPreferredQuality(String quality) async {
    preferredQuality = quality;
    qualityCalls.add(quality);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('测试替身未实现 ${invocation.memberName}');
}
