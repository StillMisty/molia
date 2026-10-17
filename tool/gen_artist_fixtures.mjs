// 抓取各平台真实「歌手」响应，作为 test/fixtures/artists/*.json 快照
// （用于内置歌手解析 / 歌手页单测）。用法：node tool/gen_artist_fixtures.mjs
//
// 端点（与 lib/sources/builtin/*_artist.dart 一一对应）：
// kw：搜索 `r.s?ft=artist`（伪 JSON，原样存 txt）；
//       详情 `wbd/api/bd/artist/artist_info`、歌曲 `…/artist_music`
//       （签名 GET，响应为 percent-encoded base64 密文，原样存文本，
//        测试里跑 kwWbdDecodeData 解密）；
// kg：搜索 `mobiles.kugou.com/api/v3/search/singer`；
//       详情 `…/api/v5/singer/info`、歌曲 `…/api/v5/singer/song`；
// tx：musicu `music.search.SearchCgiService`（search_type=1 歌手搜索）；
//       详情/歌曲 `music.web_singer_info_svr`（get_singer_detail_info）；
// wy：搜索 `api/search/get/web?type=100`；详情 `weapi/v1/artist/{id}`（weapi 加密）；
//       歌曲 `api/v1/artist/songs`（免签名；曲目 raw 由 ids → weapi/v3/song/detail 补全，
//       一并抓 `wy_song_detail.json`）；
// mg：搜索 `jadeite…/searchAll`（searchSwitch.singer=1，签名同 mg_search.dart）；
//       详情 `app.c.nf.migu.cn/pc/bmw/singer/info/v1.1`、歌曲 `…/singer/song/v1.0`。
//
// 为控制体积，歌手 / 歌曲列表统一截断到前 3 条（保留总数 / 分页字段原值）。
import crypto from 'node:crypto';
import fs from 'node:fs';

const outDir = new URL('../test/fixtures/artists/', import.meta.url);
fs.mkdirSync(outDir, { recursive: true });
const write = (name, text) => fs.writeFileSync(new URL(name, outDir), text);

/// 截断长文本字段（简介 / 歌词等）控制 fixture 体积。
const clip = (text, max) => {
  if (typeof text !== 'string' || text.length <= max) return text;
  return text.slice(0, max);
};

const UA =
  'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36';
const KW_UA = 'kwplayercar_ar_6.0.1.0_apk_keluze.apk';
const QQ_UA = 'QQMusic 14090508(android 12)';
const MG_UA =
  'Mozilla/5.0 (Linux; U; Android 11.0.0; zh-cn; MI 11 Build/OPR1.170623.032) AppleWebKit/534.30 (KHTML, like Gecko) Version/4.0 Mobile Safari/534.30';

const artistId = { kw: '336', kg: '3520', tx: '0025NhlN2yWrP4', wy: '6452', mg: '112' };

// kw（wbd 签名）
const KW_WBD_APPID = 'y67sprxhhpws';
const KW_WBD_KEY = Buffer.from('cFcnPcf6Kb85RC1y3V6M5A==', 'base64');

function kwWbdDecode(text) {
  const data = Buffer.from(decodeURIComponent(text.trim()), 'base64');
  const decipher = crypto.createDecipheriv('aes-128-ecb', KW_WBD_KEY, null);
  return JSON.parse(Buffer.concat([decipher.update(data), decipher.final()]).toString());
}

function kwWbdEncode(json) {
  const cipher = crypto.createCipheriv('aes-128-ecb', KW_WBD_KEY, null);
  return encodeURIComponent(
    Buffer.concat([cipher.update(Buffer.from(JSON.stringify(json))), cipher.final()]).toString('base64'),
  );
}

function kwWbdBuildParam(data) {
  const ts = Date.now();
  const cipher = crypto.createCipheriv('aes-128-ecb', KW_WBD_KEY, null);
  const encrypted = Buffer.concat([cipher.update(Buffer.from(JSON.stringify(data))), cipher.final()]).toString('base64');
  const sign = crypto.createHash('md5').update(`${KW_WBD_APPID}${encrypted}${ts}`).digest('hex').toUpperCase();
  return `data=${encodeURIComponent(encrypted)}&time=${ts}&appId=${KW_WBD_APPID}&sign=${sign}`;
}

{
  const searchUrl =
    'http://search.kuwo.cn/r.s?client=kt&all=' + encodeURIComponent('周杰伦') +
    '&pn=0&rn=3&ft=artist&uid=794762570&ver=kwplayer_ar_9.2.2.1&vipver=1' +
    '&show_copyright_off=1&newver=1&cluster=0&strategy=2012&encoding=utf8' +
    '&rformat=json&vermerge=1&mobi=1&issubtitle=1';
  const kwSearch = await (await fetch(searchUrl, { headers: { 'User-Agent': UA } })).json();
  if (Array.isArray(kwSearch?.abslist)) {
    kwSearch.abslist = kwSearch.abslist.slice(0, 3).map((item) => ({ ...item, desc: clip(item.desc ?? '', 120) }));
  }
  write('kw_search.json', JSON.stringify(kwSearch));

  const base = {
    uid: '', devId: '', sFrom: 'kuwo_sdk', user_type: 'AP',
    carSource: KW_UA,
  };
  const infoUrl = `https://wbd.kuwo.cn/api/bd/artist/artist_info?${kwWbdBuildParam({ ...base, id: artistId.kw, pn: 0, rn: 3 })}`;
  // 存「截断后重新加密」的响应：fixture 保持密文形态（测试跑解密），体积可控。
  const kwInfo = kwWbdDecode(await (await fetch(infoUrl, { headers: { 'User-Agent': KW_UA } })).text());
  if (typeof kwInfo?.data?.desc === 'string') kwInfo.data.desc = clip(kwInfo.data.desc, 400);
  write('kw_info.txt', kwWbdEncode(kwInfo));

  const musicUrl = `https://wbd.kuwo.cn/api/bd/artist/artist_music?${kwWbdBuildParam({ ...base, id: artistId.kw, pn: 0, rn: 3 })}`;
  write('kw_songs.txt', await (await fetch(musicUrl, { headers: { 'User-Agent': KW_UA } })).text());
}

// kg
{
  const searchUrl =
    'https://mobiles.kugou.com/api/v3/search/singer?keyword=' +
    encodeURIComponent('周杰伦') + '&page=1&pagesize=3&showtype=1';
  write('kg_search.json', await (await fetch(searchUrl, { headers: { 'User-Agent': UA } })).text());

  const infoUrl = `http://mobiles.kugou.com/api/v5/singer/info?singerid=${artistId.kg}`;
  const info = await (await fetch(infoUrl, { headers: { 'User-Agent': UA } })).json();
  if (typeof info?.data?.intro === 'string') info.data.intro = clip(info.data.intro, 300);
  if (typeof info?.data?.profile === 'string') info.data.profile = clip(info.data.profile, 0);
  write('kg_info.json', JSON.stringify(info));

  const songUrl = `http://mobiles.kugou.com/api/v5/singer/song?singerid=${artistId.kg}&page=1&pagesize=3`;
  const songs = await (await fetch(songUrl, { headers: { 'User-Agent': UA } })).json();
  if (Array.isArray(songs.data?.info)) songs.data.info = songs.data.info.slice(0, 3);
  write('kg_songs.json', JSON.stringify(songs));
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
  const resp = await fetch(url, {
    method: 'POST',
    headers: { 'User-Agent': QQ_UA, 'Content-Type': 'application/json' },
    body: text,
  });
  return resp.json();
}

{
  const comm = {
    ct: 19, cv: 2151, v: 2151, _platform: 'yqq.json',
    guid: '1F70E520B2EAA7D25E11760783C53CA9', uin: '0',
  };
  const search = await txMusicu({
    comm,
    'music.search.SearchCgiService': {
      module: 'music.search.SearchCgiService',
      method: 'DoSearchForQQMusicDesktop',
      param: {
        grp: 1, num_per_page: 3, page_num: 1, query: '周杰伦',
        remoteplace: 'txt.newclient.top', search_type: 1,
        searchid: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA12345',
      },
    },
  });
  write('tx_search.json', JSON.stringify(search));

  const detail = await txMusicu({
    comm,
    'music.web_singer_info_svr': {
      module: 'music.web_singer_info_svr',
      method: 'get_singer_detail_info',
      param: { sort: 5, singermid: artistId.tx, begin: 0, num: 3 },
    },
  });
  if (Array.isArray(detail?.singer?.data?.songlist)) {
    detail.singer.data.songlist = detail.singer.data.songlist.slice(0, 3);
  }
  const brief = detail?.singer?.data?.singer_brief;
  if (typeof brief === 'string') {
    detail.singer.data.singer_brief = clip(brief, 300);
  }
  write('tx_detail.json', JSON.stringify(detail));
}

// wy（weapi 加密）
const WY_PUBLIC_KEY = `-----BEGIN PUBLIC KEY-----
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDgtQn2JZ34ZC28NWYpAUd98iZ37BUrX/aKzmFbt7clFSs6sXqHauqKWqdtLkF2KexO40H1YTX8z2lSgBBOAxLsvaklV8k4cBFK9snQXE9/DDaFt6Rr7iVZMldczhC0JNgTz+SHXT6CBHuX3e9SdB1Ua44oncaTWz7OBGLbCiK45wIDAQAB
-----END PUBLIC KEY-----`;
const WY_PRESET_KEY = '0CoJUm6Qyw8W8jud';
const WY_IV = '0102030405060708';

function wyWeapiAes(text, key) {
  const cipher = crypto.createCipheriv('aes-128-cbc', Buffer.from(key), Buffer.from(WY_IV));
  return Buffer.concat([cipher.update(Buffer.from(text)), cipher.final()]).toString('base64');
}

// LX weapi 的 encSecKey 是 RSA/NoPadding（secretKey 反转左补零到 128 字节），
// node 的 publicEncrypt 只有 PKCS1/OAEP，因此手写模幂。
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

function wyWeapiForm(object) {
  const text = JSON.stringify(object);
  const secretKey = Array.from({ length: 16 }, () => Math.floor(Math.random() * 10)).join('');
  const params = wyWeapiAes(wyWeapiAes(text, WY_PRESET_KEY), secretKey);
  const padded = Buffer.alloc(128);
  Buffer.from(secretKey.split('').reverse().join('')).copy(padded, 128 - 16);
  return { params, encSecKey: wyRsaNoPaddingHex(padded) };
}

async function wyWeapiPost(url, object) {
  const form = wyWeapiForm(object);
  const resp = await fetch(url, {
    method: 'POST',
    headers: {
      'User-Agent': UA,
      'Content-Type': 'application/x-www-form-urlencoded',
      origin: 'https://music.163.com',
      Referer: 'https://music.163.com/',
    },
    body: new URLSearchParams(form).toString(),
  });
  return resp.json();
}

{
  const searchUrl =
    'https://music.163.com/api/search/get/web?s=' + encodeURIComponent('周杰伦') +
    '&type=100&offset=0&limit=3';
  const search = await (await fetch(searchUrl, {
    headers: { 'User-Agent': UA, Referer: 'https://music.163.com/' },
  })).json();
  if (Array.isArray(search?.result?.artists)) {
    search.result.artists = search.result.artists.slice(0, 3);
  }
  write('wy_search.json', JSON.stringify(search));

  const info = await wyWeapiPost(`https://music.163.com/weapi/v1/artist/${artistId.wy}`, {});
  if (info?.artist) {
    info.artist.briefDesc = clip(info.artist.briefDesc ?? '', 300);
  }
  if (Array.isArray(info?.hotSongs)) info.hotSongs = info.hotSongs.slice(0, 3);
  write('wy_info.json', JSON.stringify(info));

  const songsUrl = `https://music.163.com/api/v1/artist/songs?id=${artistId.wy}&offset=0&limit=3&order=hot`;
  const songs = await (await fetch(songsUrl, {
    headers: { 'User-Agent': UA, Referer: 'https://music.163.com/' },
  })).json();
  const ids = (songs.songs ?? []).slice(0, 3).map((song) => song.id);
  if (Array.isArray(songs.songs)) songs.songs = songs.songs.slice(0, 3);
  write('wy_songs.json', JSON.stringify(songs));

  // 曲目 raw 规范化的二次请求（与 wy_songlist.dart 同一流程）。
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

async function mgSearchAll(text, searchSwitch) {
  const time = Date.now().toString();
  const sign = crypto.createHash('md5')
    .update(`${text}${MG_SIGNATURE_MD5}${MG_APP_KEY}${MG_DEVICE_ID}${time}`)
    .digest('hex');
  const url =
    'https://jadeite.migu.cn/music_search/v3/search/searchAll' +
    `?isCorrect=0&isCopyright=1&searchSwitch=${encodeURIComponent(JSON.stringify(searchSwitch))}` +
    `&pageSize=3&text=${encodeURIComponent(text)}&pageNo=1&sort=0&sid=USS`;
  return (await fetch(url, {
    headers: {
      uiVersion: 'A_music_3.6.1', deviceId: MG_DEVICE_ID, timestamp: time, sign,
      channel: '0146921', 'User-Agent': MG_UA,
    },
  })).json();
}

{
  const switchAll = {
    song: 0, album: 0, singer: 1, tagSong: 0, mvSong: 0, bestShow: 0,
    songlist: 0, lyricSong: 0,
  };
  const search = await mgSearchAll('周杰伦', switchAll);
  if (Array.isArray(search?.singerResultData?.result)) {
    search.singerResultData.result = search.singerResultData.result.slice(0, 3);
  }
  write('mg_search.json', JSON.stringify(search));

  const info = await (await fetch(
    `https://app.c.nf.migu.cn/pc/bmw/singer/info/v1.1?singerId=${artistId.mg}`,
    { headers: { 'User-Agent': MG_UA, Referer: 'https://music.migu.cn/' } },
  )).json();
  write('mg_info.json', JSON.stringify(info));

  const songs = await (await fetch(
    `https://app.c.nf.migu.cn/pc/bmw/singer/song/v1.0?pageNo=1&singerId=${artistId.mg}&type=1`,
    { headers: { 'User-Agent': MG_UA, Referer: 'https://music.migu.cn/' } },
  )).json();
  const scroll = (songs?.data?.contents ?? []).find((c) => c.view === 'ZJ-Singer-Song-Scroll');
  if (scroll && Array.isArray(scroll.contents)) scroll.contents = scroll.contents.slice(0, 3);
  write('mg_songs.json', JSON.stringify(songs));
}

console.log('artist fixtures updated:', fs.readdirSync(outDir).join(', '));
