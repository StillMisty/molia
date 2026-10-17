/// LX 引擎通用类型（不依赖 `dart:io` / quickjs_engine，引擎抽象与测试假件共用）。
library;

class LxEngineException implements Exception {
  final String message;
  const LxEngineException(this.message);

  @override
  String toString() => 'LxEngineException: $message';
}

/// 单次请求超时（引擎本身仍在运行）。
///
/// 与普通 [LxEngineException] 区分开：超时意味着脚本「活着但不回响应」，
/// 上层（LxEngineSupervisor）据此累计熔断，而不是立刻重启引擎。
class LxEngineTimeoutException extends LxEngineException {
  const LxEngineTimeoutException(super.message);

  @override
  String toString() => 'LxEngineTimeoutException: $message';
}

class LxLogEntry {
  final String level; // log / info / warn / error
  final String message;
  const LxLogEntry(this.level, this.message);
}

class LxUpdateAlert {
  final String log;
  final String? updateUrl;
  const LxUpdateAlert({required this.log, this.updateUrl});
}

/// 脚本 `lyric` action 的返回结构。
class LxLyricResult {
  final String lyric;
  final String? tlyric;
  final String? rlyric;
  final String? lxlyric;

  const LxLyricResult({
    required this.lyric,
    this.tlyric,
    this.rlyric,
    this.lxlyric,
  });

  factory LxLyricResult.fromJson(Map<dynamic, dynamic> json) {
    return LxLyricResult(
      lyric: json['lyric']?.toString() ?? '',
      tlyric: json['tlyric']?.toString(),
      rlyric: json['rlyric']?.toString(),
      lxlyric: json['lxlyric']?.toString(),
    );
  }
}
