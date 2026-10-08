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

// 模拟脚本信息
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
  }
})
send(EVENT_NAMES.inited, { openDevTools: false, sources: { kw: { name: '酷我音乐', type: 'music', actions: ['musicUrl', 'search'], qualitys: ['128k','320k','flac'] } } })
if (utils.crypto.md5('a') !== '0cc175b9c0f1b6a831c399e269772661') throw new Error('md5 bridge broken')
if (utils.buffer.bufToString(utils.buffer.from('hello'), 'base64') !== 'aGVsbG8=') throw new Error('buffer bridge broken')
console.log('script init done')
`;
vm.runInContext(userScript, sandbox);

const types = sent.map((m) => m.type);
if (!types.includes('inited')) throw new Error('no inited event: ' + JSON.stringify(sent));

// 模拟宿主发起 musicUrl 请求
vm.runInContext(`__lxDeliver(${JSON.stringify({ type: 'invoke', reqId: 'r1', payload: { source: 'kw', action: 'musicUrl', info: { type: '320k', musicInfo: { songmid: '42' } } } })})`, sandbox);
const httpMsg = sent.find((m) => m.type === 'http');
if (!httpMsg) throw new Error('no http bridge message');

// 模拟 HTTP 返回
vm.runInContext(`__lxDeliver(${JSON.stringify({ type: 'httpResult', reqId: httpMsg.data.reqId, error: null, response: { statusCode: 200, statusMessage: 'OK', headers: {} }, raw: '{"url":"http://cdn.example.com/42.mp3"}', body: { url: 'http://cdn.example.com/42.mp3' } })})`, sandbox);

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

console.log('PROTOCOL OK');
console.log('log lines captured:', sent.filter(m => m.type === 'log').length);
