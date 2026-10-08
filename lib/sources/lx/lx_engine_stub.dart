/// Web 平台占位实现：LX 音源引擎依赖 QuickJS/JavaScriptCore，不支持 Web。
library;

import 'lx_engine_types.dart';
import 'lx_script_info.dart';

const bool kLxEngineSupported = false;

class LxEngine {
  bool get isRunning => false;
  Stream<LxLogEntry> get logs => const Stream<LxLogEntry>.empty();
  Stream<LxUpdateAlert> get updateAlerts => const Stream<LxUpdateAlert>.empty();
  Map<String, LxSourceDecl> get sources => const <String, LxSourceDecl>{};
  LxScriptInfo? get script => null;

  Future<Map<String, LxSourceDecl>> start(
    LxScriptInfo script, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    throw UnsupportedError('当前平台不支持 LX 音源引擎');
  }

  Future<String> getMusicUrl({
    required String source,
    required Map<String, dynamic> musicInfo,
    required String quality,
    Duration timeout = const Duration(seconds: 20),
  }) {
    throw UnsupportedError('当前平台不支持 LX 音源引擎');
  }

  Future<LxLyricResult> getLyric({
    required String source,
    required Map<String, dynamic> musicInfo,
    Duration timeout = const Duration(seconds: 20),
  }) {
    throw UnsupportedError('当前平台不支持 LX 音源引擎');
  }

  Future<String> getPic({
    required String source,
    required Map<String, dynamic> musicInfo,
    Duration timeout = const Duration(seconds: 15),
  }) {
    throw UnsupportedError('当前平台不支持 LX 音源引擎');
  }

  Future<dynamic> search({
    required String source,
    required String action,
    required String keyword,
    int page = 1,
    int limit = 20,
    Duration timeout = const Duration(seconds: 20),
  }) {
    throw UnsupportedError('当前平台不支持 LX 音源引擎');
  }

  Future<void> dispose() async {}

  Future<void> close() async {}
}
