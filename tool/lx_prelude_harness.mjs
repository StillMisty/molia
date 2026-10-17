import fs from 'node:fs';
import crypto from 'node:crypto';
import zlib from 'node:zlib';
import vm from 'node:vm';

const sent = [];
const sandbox = {
  sendMessage: (channel, msg) => { sent.push(JSON.parse(msg)); return undefined; },
  setTimeout, clearTimeout, clearInterval, setInterval, console: { log: (...a) => process.stdout.write("vm> " + a.join(" ") + "\n"), error: (...a) => process.stderr.write("vm! " + a.join(" ") + "\n"), info: () => {}, warn: (...a) => process.stderr.write("vm! " + a.join(" ") + "\n"), debug: () => {} },
  process, Buffer,
  __lxMd5: (s) => crypto.createHash('md5').update(s).digest('hex'),
  __lxAesEncrypt: (buf, mode, key, iv) => {
    const m = /aes-(\d+)-(cbc|ecb)/.exec(mode);
    const c = crypto.createCipheriv(mode, Buffer.from(key), iv ? Buffer.from(iv) : null);
    return new Uint8Array(Buffer.concat([c.update(Buffer.from(buf)), c.final()]));
  },
  __lxRsaEncrypt: () => { throw new Error('rsa not mocked'); },
  __lxRandomBytes: (n) => crypto.randomBytes(n),
  __lxZlibInflate: (d) => zlib.inflateSync(Buffer.from(d)),
  __lxZlibDeflate: (d) => zlib.deflateSync(Buffer.from(d)),
};
vm.createContext(sandbox);

const prelude = fs.readFileSync(new URL('../assets/lx/lx_prelude.js', import.meta.url), 'utf8');
vm.runInContext(prelude, sandbox);

vm.runInContext(`__lxSetup(${JSON.stringify({
  name: '测试音乐源', description: '我只是一个测试音乐源哦', version: '1.0.0', author: 'xxx', homepage: 'http://xxx', rawScript: 'RAW',
})})`, sandbox);

// 文档中的官方示例脚本（去掉网络差异，musicUrl 直接返回 request 结果中的 url）
const userScript = `
const { EVENT_NAMES, request, on, send, utils } = globalThis.lx
const httpRequest = (url, options) => new Promise((resolve, reject) => {
  request(url, options, (err, resp) => {
    if (err) return reject(err)
    resolve(resp.body)
  })
})
const qualitys = { kw: { '128k': '128', '320k': '320', flac: 'flac', flac24bit: 'flac24bit' } }
on(EVENT_NAMES.request, ({ source, action, info }) => {
  switch (action) {
    case 'musicUrl':
      return httpRequest('http://example.com/api', { method: 'GET' }).then(data => data.url)
    case 'lyric':
      return Promise.resolve({ lyric: '[00:00.00]test', tlyric: null, rlyric: null, lxlyric: null })
    case 'search':
      return Promise.resolve({ isEnd: true, list: [{ name: '歌曲', singer: '歌手', songmid: '1', source }] })
    case 'httpProbe':
      // 把 HTTP 桥的内部观察原样回报：raw 原文 / body / 回调第三参数 / 是否同一对象
      return new Promise((resolve, reject) => {
        request('http://example.com/probe', { method: 'GET' }, (err, resp, body) => {
          if (err) return reject(err)
          resolve({ raw: resp.raw, body: resp.body, third: body, sameObject: resp.body === body, statusCode: resp.statusCode })
        })
      })
  }
})
send(EVENT_NAMES.inited, { openDevTools: false, sources: { kw: { name: '酷我音乐', type: 'music', actions: ['musicUrl', 'search', 'httpProbe'], qualitys: ['128k','320k','flac'] } } })
if (utils.crypto.md5('a') !== '0cc175b9c0f1b6a831c399e269772661') throw new Error('md5 bridge broken')
if (utils.buffer.bufToString(utils.buffer.from('hello'), 'base64') !== 'aGVsbG8=') throw new Error('buffer bridge broken')
console.log('script init done')
`;
vm.runInContext(userScript, sandbox);

const types = sent.map((m) => m.type);
if (!types.includes('inited')) throw new Error('no inited event: ' + JSON.stringify(sent));

vm.runInContext(`__lxDeliver(${JSON.stringify({ type: 'invoke', reqId: 'r1', payload: { source: 'kw', action: 'musicUrl', info: { type: '320k', musicInfo: { songmid: '42' } } } })})`, sandbox);
const httpMsg = sent.find((m) => m.type === 'http');
if (!httpMsg) throw new Error('no http bridge message');

// 宿主只回原文（raw）：body 不存在，由 prelude 在 JS 侧 JSON.parse 还原
vm.runInContext(`__lxDeliver(${JSON.stringify({ type: 'httpResult', reqId: httpMsg.data.reqId, error: null, response: { statusCode: 200, statusMessage: 'OK', headers: {} }, raw: '{"url":"http://cdn.example.com/42.mp3"}' })})`, sandbox);

await new Promise((r) => setImmediate(r));
const response = sent.find((m) => m.type === 'response');
if (!response) throw new Error('no response event; got: ' + JSON.stringify(sent.map(m => m.type)));
if (!response.data.ok) throw new Error('response not ok: ' + JSON.stringify(response.data));
if (response.data.data !== 'http://cdn.example.com/42.mp3') throw new Error('bad url: ' + response.data.data);

// search 扩展 action
vm.runInContext(`__lxDeliver(${JSON.stringify({ type: 'invoke', reqId: 'r2', payload: { source: 'kw', action: 'search', info: { keyword: 'x' } } })})`, sandbox);
await new Promise((r) => setImmediate(r));
const searchResp = sent.filter((m) => m.type === 'response').find((m) => m.data.reqId === 'r2');
if (!searchResp || !searchResp.data.ok) throw new Error('search response failed: ' + JSON.stringify(searchResp));
if (searchResp.data.data.list[0].name !== '歌曲') throw new Error('search payload wrong');

// —— HTTP 桥细节：raw-only / 非 JSON / 空 body / 回调第三参数与 resp.body 同一对象 ——

/// 发起一次 httpProbe invoke，投递给定的 httpResult（hostBody 省略时不带 body 字段），
/// 返回脚本回报的观察对象。
async function httpProbe(label, raw, hostBody) {
  const reqId = 'probe_' + label;
  vm.runInContext(`__lxDeliver(${JSON.stringify({ type: 'invoke', reqId, payload: { source: 'kw', action: 'httpProbe', info: { label } } })})`, sandbox);
  const httpMsg = sent.filter((m) => m.type === 'http').pop();
  if (!httpMsg) throw new Error('no http bridge message for ' + label);
  const result = { type: 'httpResult', reqId: httpMsg.data.reqId, error: null, response: { statusCode: 200, statusMessage: 'OK', headers: {} }, raw };
  if (hostBody !== undefined) result.body = hostBody;
  vm.runInContext(`__lxDeliver(${JSON.stringify(result)})`, sandbox);
  await new Promise((r) => setImmediate(r));
  const resp = sent.filter((m) => m.type === 'response').find((m) => m.data.reqId === reqId);
  if (!resp || !resp.data.ok) throw new Error('probe failed [' + label + ']: ' + JSON.stringify(resp));
  return resp.data.data;
}

// raw-only JSON：原文原样保留，body 解析为对象，回调第三参数与 resp.body 同一对象
const rawJson = '{"url":"http://cdn.example.com/9.mp3","list":[1,2,3]}';
const parsed = await httpProbe('raw-only', rawJson);
if (parsed.raw !== rawJson) throw new Error('raw not preserved: ' + JSON.stringify(parsed));
if (!parsed.body || parsed.body.url !== 'http://cdn.example.com/9.mp3') throw new Error('raw-only body not parsed: ' + JSON.stringify(parsed));
if (parsed.third.url !== parsed.body.url) throw new Error('third arg mismatch: ' + JSON.stringify(parsed));
if (parsed.sameObject !== true) throw new Error('third arg is not resp.body: ' + JSON.stringify(parsed));

// 非 JSON：body 退化为原文（HTML / 纯文本脚本仍可消费）
const textRaw = '<html>not json</html>';
const text = await httpProbe('non-json', textRaw);
if (text.body !== textRaw) throw new Error('non-JSON body should fall back to raw: ' + JSON.stringify(text));
if (text.third !== textRaw || text.sameObject !== true) throw new Error('non-JSON third arg mismatch: ' + JSON.stringify(text));

// 空 body：body 为空字符串（而非 null / 解析报错）
const empty = await httpProbe('empty', '');
if (empty.body !== '') throw new Error('empty raw should yield empty body: ' + JSON.stringify(empty));
if (empty.third !== '' || empty.sameObject !== true) throw new Error('empty third arg mismatch: ' + JSON.stringify(empty));

// 宿主显式给了 body 时优先用它（测试桩 / 未来宿主兼容路径）
const explicit = await httpProbe('host-body', '{"ignored":true}', { from: 'host' });
if (!explicit.body || explicit.body.from !== 'host') throw new Error('host-provided body not honored: ' + JSON.stringify(explicit));

console.log('PROTOCOL OK');
console.log('log lines captured:', sent.filter(m => m.type === 'log').length);
