/// 内置平台「曲目 raw → 原生歌词」适配器集合。
///
/// 原来这些字段派发写在 `BuiltinLyricDispatch._fetchFor` 的六路 switch 里，
/// 导致「平台有没有取词实现」只有派发函数知道，`SourceCapabilities.lyrics`
/// 只能按「是不是内置平台」一刀切。现在每个实现登记成注册表条目
/// （[BuiltinPlatforms]），能力位与派发共用同一份事实。
///
/// 适配器只做字段挑选与结果归一；平台实现自己的失败语义保持不变
/// （返回 null / 抛错都由 `BuiltinLyricDispatch` 统一收口为 null）。
library;

import 'bili_lyric.dart';
import 'kg_lyric.dart';
import 'kw_lyric.dart';
import 'lyric_result.dart';
import 'mg_lyric.dart';
import 'tx_lyric.dart';
import 'wy_lyric.dart';

/// 网易云：songmid / id → eapi 歌词（逐字 yrc 转 LX 格式）。
Future<BuiltinLyricResult?> wyBuiltinLyric(Map<String, dynamic> raw) async {
  final songId = raw['songmid'] ?? raw['id'];
  if (songId == null) return null;
  final info = await WyLyric.fetch(songId.toString());
  return BuiltinLyricResult(
    lyric: info.lyric,
    tlyric: info.tlyric,
    rlyric: info.rlyric,
    lxlyric: info.lxlyric,
  );
}

/// QQ 音乐：数字 songId 优先，songmid 兜底。
Future<BuiltinLyricResult?> txBuiltinLyric(Map<String, dynamic> raw) =>
    TxLyric.fetch(
      songId: raw['songId']?.toString(),
      songMid: raw['songmid']?.toString(),
    );

/// 酷狗：hash + 歌名 + 时长（时长影响平台是否返回逐字歌词）。
Future<BuiltinLyricResult?> kgBuiltinLyric(Map<String, dynamic> raw) {
  final hash = raw['hash']?.toString();
  final name = raw['name']?.toString();
  if (hash == null || hash.isEmpty || name == null || name.isEmpty) {
    return Future.value(null);
  }
  return KgLyric.fetch(
    name: name,
    hash: hash,
    timelengthSeconds: _intervalSecondsOf(raw),
  );
}

/// 酷我：songmid → LRCX。
Future<BuiltinLyricResult?> kwBuiltinLyric(Map<String, dynamic> raw) {
  final songmid = raw['songmid']?.toString();
  if (songmid == null || songmid.isEmpty) return Future.value(null);
  return KwLyric.fetch(songmid);
}

/// 咪咕：songmid + MRC/LRC/TRC 直链。
Future<BuiltinLyricResult?> mgBuiltinLyric(Map<String, dynamic> raw) =>
    MgLyric.fetch(
      songId: raw['songmid']?.toString(),
      mrcUrl: raw['mrcUrl']?.toString(),
      lrcUrl: raw['lrcUrl']?.toString(),
      trcUrl: raw['trcUrl']?.toString(),
    );

/// B 站：CC 字幕轨（中文优先）。
Future<BuiltinLyricResult?> biliBuiltinLyric(Map<String, dynamic> raw) =>
    BiliLyric.fetch(raw);

/// 曲目时长（秒）：优先 `_interval`，否则解析 `mm:ss` 文本。
int _intervalSecondsOf(Map<String, dynamic> raw) {
  final rawInterval = raw['_interval'];
  if (rawInterval is num) return rawInterval.toInt();
  if (rawInterval is String) {
    final parsed = int.tryParse(rawInterval);
    if (parsed != null) return parsed;
  }
  final interval = raw['interval']?.toString() ?? '';
  final match = RegExp(r'^(\d{1,3}):(\d{2})').firstMatch(interval);
  if (match == null) return 0;
  return int.parse(match.group(1)!) * 60 + int.parse(match.group(2)!);
}
