// 抓取汽水音乐（qs）真实响应，作为 test/fixtures 快照（内置平台解析测试用）。
//
// 用法：node tool/gen_qs_fixtures.mjs
//
// 与其它平台脚本一样只保留前若干条（解析测试不需要整页）。汽水的匿名接口
// 会概率性返回 200 + 空 body，脚本里按同一策略重试；分享页 SSR 的
// `_ROUTER_DATA` 只取 loaderData 里对应的 page 节点。
import fs from 'node:fs';

const root = new URL('../test/fixtures/', import.meta.url);
const write = (path, value) =>
  fs.writeFileSync(new URL(path, root), `${JSON.stringify(value, null, 2)}\n`);

const PC = 'https://api.qishui.com';
const SHARE = 'https://www.qishui.com';
const pcHeaders = {
  'User-Agent': 'LunaPC/3.0.0(290101097)',
  'Content-Type': 'application/json; charset=utf-8',
};
const webHeaders = {
  'User-Agent':
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
    '(KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36',
};
const digits = (n) =>
  Array.from({ length: n }, () => Math.floor(Math.random() * 10)).join('');
const deviceId = digits(16);
const installId = digits(16);
const pcParams = {
  aid: '386088',
  app_name: 'luna_pc',
  region: 'cn',
  geo_region: 'cn',
  os_region: 'cn',
  sim_region: '',
  device_id: deviceId,
  cdid: '',
  iid: installId,
  version_name: '3.0.0',
  version_code: '30000000',
  channel: 'official',
  build_mode: 'master',
  network_carrier: '',
  ac: 'wifi',
  tz_name: 'Asia/Shanghai',
  resolution: '',
  device_platform: 'windows',
  device_type: 'Windows',
  os_version: 'Windows 11',
  fp: deviceId,
};

async function withRetry(run, tries = 6) {
  let last = '';
  for (let i = 0; i < tries; i++) {
    const text = await run();
    if (text.trim()) return text;
    last = text;
    await new Promise((resolve) => setTimeout(resolve, 300 * (i + 1)));
  }
  return last;
}

async function getJson(path, query = {}) {
  const url = new URL(path, PC);
  for (const [key, value] of Object.entries({ ...pcParams, ...query })) {
    url.searchParams.set(key, String(value));
  }
  const text = await withRetry(
    async () => (await fetch(url, { headers: pcHeaders })).text(),
  );
  if (!text.trim()) throw new Error(`空响应: ${url}`);
  return JSON.parse(text);
}

async function shareLoaderData(path, query) {
  const url = new URL(path, SHARE);
  for (const [key, value] of Object.entries(query)) {
    url.searchParams.set(key, value);
  }
  const html = await withRetry(
    async () => (await fetch(url, { headers: webHeaders })).text(),
  );
  const marker = html.indexOf('_ROUTER_DATA = ');
  if (marker < 0) throw new Error(`分享页缺少 _ROUTER_DATA: ${url}`);
  const start = html.indexOf('{', marker);
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let i = start; i < html.length; i++) {
    const char = html[i];
    if (inString) {
      if (escaped) escaped = false;
      else if (char === '\\') escaped = true;
      else if (char === '"') inString = false;
      continue;
    }
    if (char === '"') inString = true;
    else if (char === '{') depth++;
    else if (char === '}') {
      depth--;
      if (depth === 0) return JSON.parse(html.slice(start, i + 1)).loaderData;
    }
  }
  throw new Error(`分享页 JSON 未闭合: ${url}`);
}

const trim = (list, count) => (Array.isArray(list) ? list.slice(0, count) : list);

// 1. 单曲搜索
const search = await getJson('/luna/search/track', {
  q: '陈粒',
  cursor: '0',
  search_id: '',
  search_method: 'input',
});
for (const group of search.result_groups ?? []) {
  if (Array.isArray(group.data)) group.data = trim(group.data, 3);
}
write('qs.json', search);

// 2. 专辑
const albumLoader = await shareLoaderData('/share/album', {
  album_id: '7079108425841379335',
});
const albumPage = albumLoader.album_page;
albumPage.trackList = trim(albumPage.trackList, 3);
write('albums/qs.json', albumPage);

// 3. 歌手搜索 + 歌手页
const artistSearch = await getJson('/luna/search/artist', {
  q: '陈粒',
  cursor: '0',
  search_id: '',
  search_method: 'input',
});
for (const group of artistSearch.result_groups ?? []) {
  if (Array.isArray(group.data)) group.data = trim(group.data, 3);
}
write('artists/qs_search.json', artistSearch);

const artistLoader = await shareLoaderData('/share/artist', {
  artist_id: '6776144869279664130',
});
const artistPage = artistLoader.artist_page;
artistPage.trackList = trim(artistPage.trackList, 4);
artistPage.albumList = trim(artistPage.albumList, 3);
write('artists/qs_page.json', artistPage);

// 4. 评论（平台只有一个排序，测试用同一份快照覆盖 hot/latest）
const comments = await getJson('/luna/pc/comments', {
  group_id: '7079108541549643812',
  group_type: '1',
  cursor: '0',
  count: '10',
});
comments.comments = trim(comments.comments, 5);
write('comments/qs.json', comments);

console.log('qs fixtures 已写入 test/fixtures/');
