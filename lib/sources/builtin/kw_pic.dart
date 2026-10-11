import 'builtin_search.dart';

/// 酷我封面获取（移植自 lx-music-mobile `kw/pic.js`）。
///
/// 接口返回纯文本，正文即封面 URL（`^http` 校验，非法内容按无封面处理）。
class KwPic {
  KwPic._();

  static const Map<String, String> _headers = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36',
  };

  /// 获取封面 URL；失败返回 null。
  static Future<String?> fetch(String songmid) async {
    if (songmid.isEmpty) return null;
    try {
      final text = await lxHttpGetText(
        'http://artistpicserver.kuwo.cn/pic.web?corp=kuwo'
        '&type=rid_pic&pictype=500&size=500&rid=$songmid',
        headers: _headers,
      );
      final trimmed = text.trim();
      return RegExp(r'^http').hasMatch(trimmed) ? trimmed : null;
    } catch (_) {
      return null;
    }
  }
}
