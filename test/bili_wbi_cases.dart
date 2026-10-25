import 'package:flutter_test/flutter_test.dart';
import 'package:molia/sources/builtin/bili_api.dart';
import 'package:molia/sources/builtin/crypto_utils.dart';

/// WBI 签名算法：用 B 站公开文档给出的固定向量钉住重排表与签名顺序。
void main() {
  test('mixinKey：imgKey + subKey 按 64 位表重排取前 32 位', () {
    final mixin = biliMixinKey(
      '7cd084941338484aae1ad9425b84077c',
      '4932caff0ff746eab6f01bf08b70ac45',
    );
    expect(mixin, 'ea1db124af3c7062474693fa704f4ff8');
    expect(mixin.length, 32);
  });

  test('signQuery：排序 + 去敏感字符 + wts + w_rid 固定向量', () {
    final query = biliSignQuery(
      {'foo': 114, 'bar': 514, 'zab': 1919810},
      'ea1db124af3c7062474693fa704f4ff8',
      1702204169,
    );
    expect(
      query,
      'bar=514&foo=114&wts=1702204169&zab=1919810'
      '&w_rid=8f6f2b5b3d485fe1886cec6a0be8c5d4',
    );
  });

  test('signQuery：值先去掉 !\'()* 再编码', () {
    final query = biliSignQuery(
      {'keyword': "a!b'c(d)e*f 歌&曲", 'page': 1},
      'ea1db124af3c7062474693fa704f4ff8',
      1702204169,
    );
    final parts = query.split('&');
    expect(parts, contains('page=1'));
    expect(parts, contains('keyword=${Uri.encodeComponent('abcdef 歌&曲')}'));
    expect(query, contains('wts=1702204169'));
    expect(query, contains('&w_rid='));
  });

  test('签名结果由 query + mixinKey 的 md5 得出（与实现同源校验）', () {
    const mixin = 'ea1db124af3c7062474693fa704f4ff8';
    final query = biliSignQuery({'foo': 114}, mixin, 1702204169);
    final body = query.substring(0, query.indexOf('&w_rid='));
    final rid = query.substring(query.indexOf('&w_rid=') + 7);
    expect(rid, md5Hex('$body$mixin'));
  });

  test('BiliSession.signUrl：追加/合并查询串并带签名', () {
    const session = BiliSession(buvid3: 'b3', buvid4: 'b4', mixinKey: 'k');
    final url = session.signUrl(
      'https://api.bilibili.com/x/player/wbi/playurl',
      {'cid': 1, 'fnval': 16},
      wts: 1702204169,
    );
    expect(url, startsWith('https://api.bilibili.com/x/player/wbi/playurl?'));
    final query = Uri.splitQueryString(url.split('?').last);
    expect(query['cid'], '1');
    expect(query['fnval'], '16');
    expect(query['wts'], '1702204169');
    expect(query['w_rid'], isNotEmpty);

    final withExisting = session.signUrl(
      'https://example.com/x?a=1',
      {'b': 2},
      wts: 1702204169,
    );
    expect(withExisting, contains('/x?a=1&b=2&wts='));
  });

  test('apiHeaders 带 buvid Cookie，直链 headers 只留 UA + Referer', () {
    const session = BiliSession(buvid3: 'b3', buvid4: 'b4', mixinKey: 'k');
    expect(session.apiHeaders['Cookie'], 'buvid3=b3; buvid4=b4');
    expect(session.apiHeaders['Referer'], BiliApi.referer);
    expect(session.apiHeaders['User-Agent'], BiliApi.browserUserAgent);
    expect(BiliApi.streamHeaders.keys.toSet(), {'User-Agent', 'Referer'});
    expect(BiliApi.browserUserAgent, contains('Chrome/'));
    expect(BiliApi.browserUserAgent, isNot(contains('curl')));
  });
}
