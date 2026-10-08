/// LX 引擎通用类型（Web 与原生共用，不依赖 dart:io / flutter_js）。
library;

class LxEngineException implements Exception {
  final String message;
  const LxEngineException(this.message);

  @override
  String toString() => 'LxEngineException: $message';
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
