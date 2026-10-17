// 抓取各平台真实「按歌词搜歌」响应，作为 test/fixtures/lyric_search/*.json 快照
// （用于内置歌词搜索解析单测）。用法：node tool/gen_lyric_search_fixtures.mjs
//
// 端点（与 lib/sources/builtin/*_lyric_search.dart 一一对应）：
// kw：`search.kuwo.cn/r.s?stype=lyric`（伪 JSON 或标准 JSON，原样存文本）；
// kg：`songsearch.kugou.com/lyric_search`；
// tx：musicu `music.search.SearchCgiService`（search_type=7，签名同搜索）；
// wy：`api/search/get/web?type=1006`（旧版字段 + 高亮 lyrics）；
//        曲目 raw 由 ids → weapi/v3/song/detail 补全，一并抓 `wy_song_detail.json`；
// mg：jadeite `searchAll`（searchSwitch.lyricSong=1，签名同 mg_search.dart）。
//
// 查询统一用「雨下整夜」（《七里香》歌词）；列表截断到前 3 条控制体积。
import crypto from 'node:crypto';
import fs from 'node:fs';

const outDir = new URL('../test/fixtures/lyric_search/', import.meta.url);
fs.mkdirSync(outDir, { recursive: true });
const write = (name, text) => fs.writeFileSync(new URL(name, outDir), text);

const UA =
  'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36';
const QQ_UA = 'QQMusic 14090508(android 12)';
const MG_UA =
  'Mozilla/5.0 (Linux; U; Android 11.0.0; zh-cn; MI 11 Build+OPR1.170623.032) AppleWebKit/534.30 (KHTML, like Gecko) Version/4.0 Mobile Safari/534.30';

const keyword = '雨下整夜';

// kw
{
  const url =
    'http://search.kuwo.cn/r.s?client=kt&all=' + encodeURIComponent(keyword) +
    '&stype=lyric&pn=0&rn=3&uid=794762570&ver=kwplayer_ar_9.2.2.1&vipver=1' +
    '&newver=1&ft=music&cluster=0&strategy=2012&encoding=utf8&rformat=json' +
    '&vermerge=1&mobi=1&issubtitle=1';
  write('kw.txt', await (await fetch(url, { headers: { 'User-Agent': UA } })).text());
}

// kg
{
  const url =
    'https://songsearch.kugou.com/lyric_search?keyword=' + encodeURIComponent(keyword) +
    '&page=1&pagesize=3';
  const body = await (await fetch(url, { headers: { 'User-Agent': UA } })).json();
  if (Array.isArray(body?.data?.lists)) body.data.lists = body.data.lists.slice(0, 3);
  write('kg.json', JSON.stringify(body));
}

// tx（musicu 签名）
function zzcSign(text) {
  const P1 = [23, 14, 6, 36, 16, 40, 7, 19];
  const P2 = [16, 1, 32, 12, 19, 27, 8, 5];
  const SC = [89, 39, 179, 150, 218, 82, 58, 252, 177, 52, 186, 123, 120, 64, 242, 133, 143, 161, 121, 179];
  const hash = crypto.createHash('sha1').update(text).digest('hex');
  const p1 = P1.map((i) => hash[i] ?? '').join('');
  const p2 = P2.map((i) => hash[i] ?? '').join('');
  const p3 = Buffer.from(SC.map((v, i) => v ^ parseInt(hash.slice(i * 2, i * 2 + 2), 16)));
  const b64 = p3.toString('base64').replace(/[+/=]/g, '');
  return `zzc${p1}${b64}${p2}`.toLowerCase();
}

async function txMusicu(body) {
  const text = JSON.stringify(body);
  const url = 'https://u.y.qq.com/cgi-bin/musics.fcg?sign=' + zzcSign(text);
  return (await fetch(url, {
    method: 'POST',
    headers: { 'User-Agent': QQ_UA, 'Content-Type': 'application/json' },
    body: text,
  })).json();
}

{
  const body = {
    comm: {
      ct: 19, cv: 2151, v: 2151, _platform: 'yqq.json',
      guid: '1F70E520B2EAA7D25E11760783C53CA9', uin: '0',
    },
    'music.search.SearchCgiService': {
      module: 'music.search.SearchCgiService',
      method: 'DoSearchForQQMusicDesktop',
      param: {
        grp: 1, num_per_page: 3, page_num: 1, query: keyword,
        remoteplace: 'txt.newclient.top', search_type: 7,
        searchid: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA12345',
      },
    },
  };
  write('tx.json', JSON.stringify(await txMusicu(body)));
}

// wy
const WY_PUBLIC_KEY = `-----BEGIN PUBLIC KEY-----
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDgtQn2JZ34ZC28NWYpAUd98iZ37BUrX/aKzmFbt7clFSs6sXqHauqKWqdtLkF2KexO40H1YTX8z2lSgBBOAxLsvaklV8k4cBFK9snQXE9/DDaFt6Rr7iVZMldczhC0JNgTz+SHXT6CBHuX3e9SdB1Ua44oncaTWz7OBGLbCiK45wIDAQAB
-----END PUBLIC KEY-----`;
const WY_PRESET_KEY = '0CoJUm6Qyw8W8jud';
const WY_IV = '0102030405060708';
const wyJwk = crypto.createPublicKey(WY_PUBLIC_KEY).export({ format: 'jwk' });
const wyN = BigInt('0x' + Buffer.from(wyJwk.n, 'base64url').toString('hex'));
const wyE = BigInt('0x' + Buffer.from(wyJwk.e, 'base64url').toString('hex'));

function wyRsaNoPaddingHex(message) {
  const m = BigInt('0x' + message.toString('hex'));
  let result = 1n, base = m % wyN, exponent = wyE;
  while (exponent > 0n) {
    if (exponent & 1n) result = (result * base) % wyN;
    base = (base * base) % wyN;
    exponent >>= 1n;
  }
  return result.toString(16).padStart(256, '0');
}

function wyAes(text, key) {
  const cipher = crypto.createCipheriv('aes-128-cbc', Buffer.from(key), Buffer.from(WY_IV));
  return Buffer.concat([cipher.update(Buffer.from(text)), cipher.final()]).toString('base64');
}

function wyWeapiForm(object) {
  const text = JSON.stringify(object);
  const secretKey = Array.from({ length: 16 }, () => Math.floor(Math.random() * 10)).join('');
  const params = wyAes(wyAes(text, WY_PRESET_KEY), secretKey);
  const padded = Buffer.alloc(128);
  Buffer.from(secretKey.split('').reverse().join('')).copy(padded, 128 - 16);
  return { params, encSecKey: wyRsaNoPaddingHex(padded) };
}

async function wyWeapiPost(url, object) {
  return (await fetch(url, {
    method: 'POST',
    headers: {
      'User-Agent': UA,
      'Content-Type': 'application/x-www-form-urlencoded',
      origin: 'https://music.163.com',
      Referer: 'https://music.163.com/',
    },
    body: new URLSearchParams(wyWeapiForm(object)).toString(),
  })).json();
}

{
  const searchUrl =
    'https://music.163.com/api/search/get/web?s=' + encodeURIComponent(keyword) +
    '&type=1006&offset=0&limit=3';
  const search = await (await fetch(searchUrl, {
    headers: { 'User-Agent': UA, Referer: 'https://music.163.com/' },
  })).json();
  const songs = search?.result?.songs ?? [];
  const ids = songs.slice(0, 3).map((song) => song.id);
  if (Array.isArray(search?.result?.songs)) search.result.songs = songs.slice(0, 3);
  write('wy_search.json', JSON.stringify(search));

  const detail = await wyWeapiPost('https://music.163.com/weapi/v3/song/detail', {
    c: `[${ids.map((id) => `{"id":${id}}`).join(',')}]`,
    ids: `[${ids.join(',')}]`,
  });
  if (Array.isArray(detail?.songs)) detail.songs = detail.songs.slice(0, 3);
  if (Array.isArray(detail?.privileges)) detail.privileges = detail.privileges.slice(0, 3);
  write('wy_song_detail.json', JSON.stringify(detail));
}

// mg
const MG_DEVICE_ID = '963B7AA0D21511ED807EE5846EC87D20';
const MG_SIGNATURE_MD5 = '6cdc72a439cef99a3418d2a78aa28c73';
const MG_APP_KEY = 'yyapp2d16148780a1dcc7408e06336b98cfd50';

{
  const time = Date.now().toString();
  const sign = crypto.createHash('md5')
    .update(`${keyword}${MG_SIGNATURE_MD5}${MG_APP_KEY}${MG_DEVICE_ID}${time}`)
    .digest('hex');
  const searchSwitch = {
    song: 0, album: 0, singer: 0, tagSong: 0, mvSong: 0, bestShow: 0,
    songlist: 0, lyricSong: 1,
  };
  const url =
    'https://jadeite.migu.cn/music_search/v3/search/searchAll' +
    `?isCorrect=0&isCopyright=1&searchSwitch=${encodeURIComponent(JSON.stringify(searchSwitch))}` +
    `&pageSize=3&text=${encodeURIComponent(keyword)}&pageNo=1&sort=0&sid=USS`;
  const body = await (await fetch(url, {
    headers: {
      uiVersion: 'A_music_3.6.1', deviceId: MG_DEVICE_ID, timestamp: time, sign,
      channel: '0146921', 'User-Agent': MG_UA,
    },
  })).json();
  const lyricData = body?.lyricResultData;
  if (lyricData && Array.isArray(lyricData.result)) {
    lyricData.result = lyricData.result.slice(0, 3);
  }
  write('mg.json', JSON.stringify(body));
}

console.log('lyric search fixtures updated:', fs.readdirSync(outDir).join(', '));
