// 用 Node 复刻 lx-music-mobile 的 wy 加密管线（crypto.js + Android AES/RSA 原生模块语义），
// 生成 Dart 单测使用的固定向量。可重复执行：node tool/gen_wy_crypto_vectors.mjs
//
// 语义要点：
// - AES.encrypt(String data, String key, String iv, String mode) 对 data/key/iv 先做 base64 解码；
// - AES_MODE.CBC_128_PKCS7Padding = "AES/CBC/PKCS7Padding"（PKCS7）；
// - AES_MODE.ECB_128_NoPadding = "AES"（Java 默认变换，实际为 AES/ECB/PKCS5Padding）。
import { createCipheriv, publicEncrypt, constants, createHash } from 'node:crypto'

const btoa = (str) => Buffer.from(str, 'binary').toString('base64')
const iv = btoa('0102030405060708')
const presetKey = btoa('0CoJUm6Qyw8W8jud')
const linuxapiKey = btoa('rFgB&h#%2?^eDg:Q')
const eapiKey = btoa('e82ckenh8dichen8')
const publicKey = '-----BEGIN PUBLIC KEY-----\nMIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDgtQn2JZ34ZC28NWYpAUd98iZ37BUrX/aKzmFbt7clFSs6sXqHauqKWqdtLkF2KexO40H1YTX8z2lSgBBOAxLsvaklV8k4cBFK9snQXE9/DDaFt6Rr7iVZMldczhC0JNgTz+SHXT6CBHuX3e9SdB1Ua44oncaTWz7OBGLbCiK45wIDAQAB\n-----END PUBLIC KEY-----'

const aesEncrypt = (b64, mode, keyB64, ivB64) => {
  const data = Buffer.from(b64, 'base64')
  const key = Buffer.from(keyB64, 'base64')
  const cipher = mode === 'cbc'
    ? createCipheriv('aes-128-cbc', key, Buffer.from(ivB64, 'base64'))
    : createCipheriv('aes-128-ecb', key, null)
  return Buffer.concat([cipher.update(data), cipher.final()]).toString('base64')
}

const rsaEncrypt = (buffer) => {
  const padded = Buffer.concat([Buffer.alloc(128 - buffer.length), buffer])
  return publicEncrypt({ key: publicKey, padding: constants.RSA_NO_PADDING }, padded).toString('hex')
}

const weapi = (object, secretKey) => {
  const text = JSON.stringify(object)
  return {
    params: aesEncrypt(btoa(aesEncrypt(Buffer.from(text).toString('base64'), 'cbc', presetKey, iv)), 'cbc', btoa(secretKey), iv),
    encSecKey: rsaEncrypt(Buffer.from(secretKey).reverse()),
  }
}

const linuxapi = (object) => ({
  eparams: Buffer.from(aesEncrypt(Buffer.from(JSON.stringify(object)).toString('base64'), 'ecb', linuxapiKey, ''), 'base64').toString('hex').toUpperCase(),
})

const eapi = (url, object) => {
  const text = JSON.stringify(object)
  const digest = createHash('md5').update(`nobody${url}use${text}md5forencrypt`).digest('hex')
  const data = `${url}-36cd479b6b5-${text}-36cd479b6b5-${digest}`
  return {
    params: Buffer.from(aesEncrypt(Buffer.from(data).toString('base64'), 'ecb', eapiKey, ''), 'base64').toString('hex').toUpperCase(),
  }
}

const secretKey = '0123456789012345'
const detailObject = { id: 33894312, n: 100000, p: 1 }
const emptyObject = {}
const linuxObject = {
  method: 'POST',
  url: 'https://music.163.com/api/v3/playlist/detail',
  params: { id: '3778678', n: 100000, s: 8 },
}
const eapiUrl = '/api/search/song/list/page'
const eapiObject = {
  keyword: '晴天',
  needCorrect: '1',
  channel: 'typing',
  offset: 0,
  scene: 'normal',
  total: true,
  limit: 30,
}

console.log(JSON.stringify({
  secretKey,
  weapiDetail: weapi(detailObject, secretKey),
  weapiEmpty: weapi(emptyObject, secretKey),
  linuxapiPlaylist: linuxapi(linuxObject),
  eapiSearch: eapi(eapiUrl, eapiObject),
}, null, 2))
