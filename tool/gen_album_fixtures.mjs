// 抓取各平台真实专辑响应，作为 test/fixtures/albums/*.json 快照
// （用于内置专辑解析单测）。用法：node tool/gen_album_fixtures.mjs
//
// 端点（与 lib/sources/builtin/*_album.dart 一一对应）：
// - wy：GET https://music.163.com/api/v1/album/{id}（响应 album + songs）
// - tx：GET  u.y.qq.com/cgi-bin/musicu.fcg（albumSonglist 模块，data 参数）
// - kg：GET  mobilecdn.kugou.com/api/v3/album/song + album/info（http）
// - kw：GET  search.kuwo.cn/r.s?stype=albuminfo（伪 JSON 文本，原样存）
// - mg：GET  app.c.nf.migu.cn queryAlbumSong + MIGUM3.0 resource/album
//
// 为控制体积，歌曲列表统一截断到前 3 条（保留总数 / 分页字段原值）。
import fs from 'node:fs';

const outDir = new URL('../test/fixtures/albums/', import.meta.url);
fs.mkdirSync(outDir, { recursive: true });
const write = (name, text) => fs.writeFileSync(new URL(name, outDir), text);

const UA =
  'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36';

// wy：神的游戏（张悬）
{
  const resp = await fetch('https://music.163.com/api/v1/album/32311', {
    headers: { 'User-Agent': UA },
  });
  const body = await resp.json();
  body.songs = body.songs.slice(0, 3);
  write('wy.json', JSON.stringify(body));
}

// tx：叶惠美（周杰伦，albumMid 000MkMni19ClKG）
{
  const payload = {
    comm: { ct: 24, cv: 10000 },
    albumSonglist: {
      method: 'GetAlbumSongList',
      param: {
        albumMid: '000MkMni19ClKG',
        albumID: 0,
        begin: 0,
        num: 3,
        order: 2,
      },
      module: 'music.musichallAlbum.AlbumSongList',
    },
  };
  const url =
    'https://u.y.qq.com/cgi-bin/musicu.fcg?g_tk=5381&format=json&inCharset=utf8&outCharset=utf-8&data=' +
    encodeURIComponent(JSON.stringify(payload));
  const resp = await fetch(url, { headers: { 'User-Agent': UA } });
  const body = await resp.json();
  body.albumSonglist.data.songList =
    body.albumSonglist.data.songList.slice(0, 3);
  write('tx.json', JSON.stringify(body));
}

// kg：Kids Learn Animals（albumid 1234567）
{
  const songsResp = await fetch(
    'http://mobilecdn.kugou.com/api/v3/album/song?version=9108' +
      '&albumid=1234567&plat=0&pagesize=3&area_code=0&page=1&with_res_tag=0',
    { headers: { 'User-Agent': UA } },
  );
  write('kg_songs.json', await songsResp.text());

  const infoResp = await fetch(
    'http://mobilecdn.kugou.com/api/v3/album/info?albumid=1234567&with_res_tag=0',
    { headers: { 'User-Agent': UA } },
  );
  write('kg_info.json', await infoResp.text());
}

// kw：黑色香水（曹方，albumid 1433）；响应为伪 JSON（单引号），原样存文本
{
  const resp = await fetch(
    'http://search.kuwo.cn/r.s?pn=0&rn=3&stype=albuminfo&albumid=1433' +
      '&show_copyright_off=0&encoding=utf&vipver=MUSIC_9.1.0',
    { headers: { 'User-Agent': UA } },
  );
  write('kw.json', await resp.text());
}

// mg：太阳之子（周杰伦，albumId 1142521343）
{
  const songsResp = await fetch(
    'http://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/queryAlbumSong?albumId=1142521343&pageNo=1',
    { headers: { 'User-Agent': UA } },
  );
  const songs = await songsResp.json();
  songs.data.songList = songs.data.songList.slice(0, 3);
  write('mg_songs.json', JSON.stringify(songs));

  const infoResp = await fetch(
    'https://app.c.nf.migu.cn/MIGUM3.0/resource/album/v2.0?albumId=1142521343',
    { headers: { 'User-Agent': UA } },
  );
  const info = await infoResp.json();
  // imgItems / singerImgs 体积较大，截断到 1 条（解析只取首图）。
  if (Array.isArray(info.data?.imgItems)) {
    info.data.imgItems = info.data.imgItems.slice(0, 1);
  }
  if (Array.isArray(info.data?.singerImgs)) {
    info.data.singerImgs = info.data.singerImgs.slice(0, 1);
  }
  write('mg_info.json', JSON.stringify(info));
}

console.log('album fixtures updated:', fs.readdirSync(outDir).join(', '));
