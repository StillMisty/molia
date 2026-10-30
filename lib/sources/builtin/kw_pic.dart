import 'builtin_search.dart';

/// 酷我封面获取（移植自 lx-music-mobile `kw/pic.js`）。
///
/// 搜索 / 榜单 / 歌单 / 专辑响应里通常已带封面字段，由
/// `builtin_cover_urls.dart` 直接解析；旧 payload 或字段缺失时，才按 rid
/// 请求 pic.web（接口返回纯文本，正文即封面 URL，`^http` 校验，非法内容按
/// 无封面处理）。
class KwPic {
  KwPic._();

  static const Map<String, String> _headers = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36',
  };

  /// 获取封面 URL；失败返回 null。
  static Future<String?> fetch(String songmid) async {
    // 旧 payload / 导入数据可能保留 `MUSIC_` 前缀；pic.web 只认数字 rid，
    // 带前缀会直接返回 `NO_PIC`。
    final rid = songmid.trim().replaceFirst(RegExp('^MUSIC_'), '');
    if (rid.isEmpty) return null;
    try {
      final text = await lxHttpGetText(
        'http://artistpicserver.kuwo.cn/pic.web?corp=kuwo'
        '&type=rid_pic&pictype=500&size=500&rid=$rid',
        headers: _headers,
      );
      final trimmed = text.trim();
      return RegExp(r'^http').hasMatch(trimmed) ? trimmed : null;
    } catch (_) {
      return null;
    }
  }
}
