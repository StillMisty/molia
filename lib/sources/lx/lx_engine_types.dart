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

/// 引擎未运行 / 重启等待超时：请求根本没被执行。
///
/// 与脚本业务失败区分开：这是**可恢复的暂时不可用**，重启完成后同一请求
/// 可以成功，取链策略据此重试（而不是降档或终止）。
class LxEngineUnavailableException extends LxEngineException {
  const LxEngineUnavailableException(super.message);

  @override
  String toString() => 'LxEngineUnavailableException: $message';
}

/// 脚本明确拒绝给出播放地址（返回空串 / 非法值）。
///
/// 语义是「该档位/该曲目取链不可用」：原样重发同一请求大概率还是空，
/// 取链策略应换低一档或换源，而不是退避重试。
class LxResolveRejectedException extends LxEngineException {
  const LxResolveRejectedException(super.message);

  @override
  String toString() => 'LxResolveRejectedException: $message';
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
