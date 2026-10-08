// 抓取各平台真实搜索结果，作为 test/fixtures/*.json 快照（用于内置搜索解析测试）。
// 用法：node tool/gen_search_fixtures.mjs
import crypto from 'node:crypto';
import fs from 'node:fs';

const outDir = new URL('../test/fixtures/', import.meta.url);
const write = (name, text) => fs.writeFileSync(new URL(name, outDir), text);

function zzcSign(text) {
  const P1 = [23, 14, 6, 36, 16, 40, 7, 19];
  const P2 = [16, 1, 32, 12, 19, 27, 8, 5];
  const SC = [89, 39, 179, 150, 218, 82, 58, 252, 177, 52, 186, 123, 120, 64, 242, 133, 143, 161, 121, 179];
  const hash = crypto.createHash('sha1').update(text).digest('hex');
  const p1 = P1.map((i) => hash[i] ?? '').join('');
  const p2 = P2.map((i) => hash[i] ?? '').join('');
  const p3 = Buffer.from(SC.map((v, i) => v ^ parseInt(hash.slice(i * 2, i * 2 + 2), 16)));
  const b64 = p3.toString('base64').replace(/[\\/+=]/g, '');
  return `zzc${p1}${b64}${p2}`.toLowerCase();
}

function eapiParams(url, object) {
  const text = JSON.stringify(object);
  const digest = crypto.createHash('md5').update(`nobody${url}use${text}md5forencrypt`).digest('hex');
  const data = `${url}-36cd479b6b5-${text}-36cd479b6b5-${digest}`;
  const c = crypto.createCipheriv('aes-128-ecb', Buffer.from('e82ckenh8dichen8'), null);
  return Buffer.concat([c.update(Buffer.from(data)), c.final()]).toString('hex').toUpperCase();
}

const kwUrl =
  'http://search.kuwo.cn/r.s?client=kt&all=' + encodeURIComponent('周杰伦') +
  '&pn=0&rn=2&uid=794762570&ver=kwplayer_ar_9.2.2.1&vipver=1&show_copyright_off=1&newver=1' +
  '&ft=music&cluster=0&strategy=2012&encoding=utf8&rformat=json&vermerge=1&mobi=1&issubtitle=1';
write('kw.json', await (await fetch(kwUrl)).text());

const kgUrl =
  'https://songsearch.kugou.com/song_search_v2?keyword=' + encodeURIComponent('周杰伦') +
  '&page=1&pagesize=2&userid=0&clientver=&platform=WebFilter&filter=2&iscorrection=1&privilege_filter=0&area_code=1';
write('kg.json', await (await fetch(kgUrl)).text());

const txBody = {
  comm: {
    _channelid: '0', _os_version: '6.2.9200-2', ct: '19', cv: '2151',
    guid: '1F70E520B2EAA7D25E11760783C53CA9', patch: '118',
    psrf_access_token_expiresAt: 0, psrf_qqaccess_token: '', psrf_qqopenid: '',
    psrf_qqunionid: '', tmeAppID: 'qqmusic', tmeLoginType: 0, uin: '0',
    wid: '7223299733393904640',
  },
  'music.search.SearchCgiService': {
    module: 'music.search.SearchCgiService',
    method: 'DoSearchForQQMusicDesktop',
    param: {
      grp: 1, num_per_page: 2, page_num: 1, query: '周杰伦',
      remoteplace: 'txt.newclient.top', search_type: 0,
      searchid: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA12345',
    },
  },
};
const txText = JSON.stringify(txBody);
const txResp = await fetch('https://u.y.qq.com/cgi-bin/musics.fcg?sign=' + zzcSign(txText), {
  method: 'POST',
  headers: { 'User-Agent': 'QQMusic 14090508(android 12)', 'Content-Type': 'application/json' },
  body: txText,
});
write('tx.json', await txResp.text());

const wyParams = eapiParams('/api/search/song/list/page', {
  keyword: '周杰伦', needCorrect: '1', channel: 'typing', offset: 0,
  scene: 'normal', total: true, limit: 2,
});
const wyResp = await fetch('http://interface.music.163.com/eapi/batch', {
  method: 'POST',
  headers: {
    'User-Agent':
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/60.0.3112.90 Safari/537.36',
    origin: 'https://music.163.com',
    'Content-Type': 'application/x-www-form-urlencoded',
  },
  body: 'params=' + encodeURIComponent(wyParams),
});
write('wy.json', await wyResp.text());

const time = Date.now().toString();
const deviceId = '963B7AA0D21511ED807EE5846EC87D20';
const sign = crypto.createHash('md5')
  .update('周杰伦' + '6cdc72a439cef99a3418d2a78aa28c73' + 'yyapp2d16148780a1dcc7408e06336b98cfd50' + deviceId + time)
  .digest('hex');
const mgSwitch =
  '%7B%22song%22%3A1%2C%22album%22%3A0%2C%22singer%22%3A0%2C%22tagSong%22%3A1%2C%22mvSong%22%3A0%2C%22bestShow%22%3A1%2C%22songlist%22%3A0%2C%22lyricSong%22%3A0%7D';
const mgUrl =
  `https://jadeite.migu.cn/music_search/v3/search/searchAll?isCorrect=0&isCopyright=1&searchSwitch=${mgSwitch}` +
  `&pageSize=2&text=${encodeURIComponent('周杰伦')}&pageNo=1&sort=0&sid=USS`;
const mgResp = await fetch(mgUrl, {
  headers: {
    uiVersion: 'A_music_3.6.1', deviceId, timestamp: time, sign, channel: '0146921',
    'User-Agent':
      'Mozilla/5.0 (Linux; U; Android 11.0.0; zh-cn; MI 11 Build/OPR1.170623.032) AppleWebKit/534.30 (KHTML, like Gecko) Version/4.0 Mobile Safari/534.30',
  },
});
write('mg.json', await mgResp.text());

console.log('fixtures updated:', fs.readdirSync(outDir).join(', '));
