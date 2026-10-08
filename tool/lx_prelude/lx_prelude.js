/*
 * LX Music 自定义源运行时前导脚本（LX Custom Source API v2.0.0，env=mobile）
 *
 * 由 Molia 提供，按 LX Music 公开文档（lxmusic.toside.cn）自行实现，
 * 用于在 QuickJS/JavaScriptCore 中为第三方音源脚本提供 `globalThis.lx` 环境。
 *
 * 与宿主（Dart）的约定：
 *  - JS -> Dart: sendMessage('lx', JSON.stringify({type, data}))  （由 flutter_js 注入 sendMessage）
 *  - Dart -> JS: 通过 evaluate 调用 globalThis.__lxDeliver(msg)
 *  - 同步工具函数: 由 Dart 绑定到 __lxMd5 / __lxAesEncrypt / __lxRsaEncrypt /
 *    __lxRandomBytes / __lxZlibInflate / __lxZlibDeflate
 */
(function () {
  'use strict';

  var __lxInfo = { name: '', description: '', version: '', author: '', homepage: '', rawScript: '' };
  var __lxVersion = '2.0.0';
  var __lxEnv = 'mobile';
  var __lxInited = false;
  var __lxUpdateAlertShown = false;
  var __lxRequestHandler = null;
  var __lxHttpSeq = 0;
  var __lxHttpPending = {};
  var __lxNativeConsole = (typeof console !== 'undefined' && console) ? {
    log: console.log, info: console.info, warn: console.warn, error: console.error, debug: console.debug
  } : null;

  // ---------------------------------------------------------------------------
  // 基础工具
  // ---------------------------------------------------------------------------

  function __lxErrMessage(err) {
    if (err == null) return 'unknown error';
    if (typeof err === 'string') return err;
    if (err.message) return String(err.message);
    try { return String(err); } catch (e) { return 'unknown error'; }
  }

  function __lxStr(value) {
    if (typeof value === 'string') return value;
    try {
      if (typeof value === 'object' && value !== null) return JSON.stringify(value);
      return String(value);
    } catch (e) {
      return String(value);
    }
  }

  function __lxSendNative(type, data) {
    try {
      sendMessage('lx', JSON.stringify({ type: type, data: data === undefined ? null : data }));
    } catch (e) {
      if (__lxNativeConsole && __lxNativeConsole.error) __lxNativeConsole.error('lx bridge error: ' + __lxErrMessage(e));
    }
  }

  // ---------------------------------------------------------------------------
  // console（转发到宿主日志）
  // ---------------------------------------------------------------------------

  if (typeof console === 'undefined') {
    globalThis.console = {};
  }
  (function () {
    var levels = ['log', 'info', 'warn', 'error', 'debug'];
    for (var i = 0; i < levels.length; i++) {
      (function (level) {
        console[level] = function () {
          var parts = [];
          for (var j = 0; j < arguments.length; j++) parts.push(__lxStr(arguments[j]));
          __lxSendNative('log', { level: level === 'debug' ? 'log' : level, message: parts.join(' ') });
        };
      })(levels[i]);
    }
    console.group = function () { console.log.apply(null, arguments); };
    console.groupEnd = function () {};
    console.groupCollapsed = function () { console.log.apply(null, arguments); };
    console.table = function () { console.log.apply(null, arguments); };
    console.trace = function () { console.log.apply(null, arguments); };
    console.dir = function () { console.log.apply(null, arguments); };
  })();

  // ---------------------------------------------------------------------------
  // 定时器（flutter_js 提供 setTimeout；这里补齐 clearTimeout/setInterval）
  // ---------------------------------------------------------------------------

  (function () {
    var nativeSetTimeout = globalThis.setTimeout;
    var seq = 0;
    var cancelled = {};
    if (typeof nativeSetTimeout !== 'function') {
      globalThis.setTimeout = function () { return 0; };
      globalThis.clearTimeout = function () {};
      globalThis.setInterval = function () { return 0; };
      globalThis.clearInterval = function () {};
      return;
    }
    globalThis.setTimeout = function (fn, ms) {
      var id = ++seq;
      nativeSetTimeout(function () {
        if (cancelled[id]) return;
        try {
          if (typeof fn === 'function') fn();
        } catch (e) {
          console.error(__lxErrMessage(e));
        }
      }, typeof ms === 'number' && ms >= 0 ? ms : 0);
      return id;
    };
    globalThis.clearTimeout = function (id) {
      if (id == null) return;
      cancelled[id] = true;
    };
    globalThis.setInterval = function (fn, ms) {
      var flag = { cancelled: false };
      var handle = globalThis.setTimeout(function loop() {
        if (flag.cancelled) return;
        try {
          if (typeof fn === 'function') fn();
        } finally {
          if (!flag.cancelled) globalThis.setTimeout(loop, typeof ms === 'number' && ms >= 0 ? ms : 0);
        }
      }, ms);
      return { __lxIntervalFlag: flag, __lxHandle: handle };
    };
    globalThis.clearInterval = function (h) {
      if (h && typeof h === 'object' && h.__lxIntervalFlag) {
        h.__lxIntervalFlag.cancelled = true;
      } else {
        globalThis.clearTimeout(h);
      }
    };
  })();

  // ---------------------------------------------------------------------------
  // 字处理 / Buffer 兼容层
  // ---------------------------------------------------------------------------

  function __lxUtf8Encode(str) {
    str = String(str);
    var bytes = [];
    for (var i = 0; i < str.length; i++) {
      var c = str.charCodeAt(i);
      if (c < 0x80) {
        bytes.push(c);
      } else if (c < 0x800) {
        bytes.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f));
      } else if (c >= 0xd800 && c <= 0xdbff && i + 1 < str.length) {
        var c2 = str.charCodeAt(++i);
        var cp = 0x10000 + ((c & 0x3ff) << 10) + (c2 & 0x3ff);
        bytes.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
      } else {
        bytes.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
      }
    }
    return new Uint8Array(bytes);
  }

  function __lxUtf8Decode(bytes) {
    var out = '';
    for (var i = 0; i < bytes.length;) {
      var c = bytes[i++];
      if (c < 0x80) {
        out += String.fromCharCode(c);
      } else if (c < 0xe0) {
        out += String.fromCharCode(((c & 0x1f) << 6) | (bytes[i++] & 0x3f));
      } else if (c < 0xf0) {
        out += String.fromCharCode(((c & 0x0f) << 12) | ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f));
      } else {
        var cp = ((c & 0x07) << 18) | ((bytes[i++] & 0x3f) << 12) | ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f);
        cp -= 0x10000;
        out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
      }
    }
    return out;
  }

  var __LX_B64_CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

  function __lxBase64Encode(bytes) {
    var out = '';
    for (var i = 0; i < bytes.length; i += 3) {
      var b0 = bytes[i], b1 = i + 1 < bytes.length ? bytes[i + 1] : 0, b2 = i + 2 < bytes.length ? bytes[i + 2] : 0;
      out += __LX_B64_CHARS[b0 >> 2];
      out += __LX_B64_CHARS[((b0 & 3) << 4) | (b1 >> 4)];
      out += i + 1 < bytes.length ? __LX_B64_CHARS[((b1 & 15) << 2) | (b2 >> 6)] : '=';
      out += i + 2 < bytes.length ? __LX_B64_CHARS[b2 & 63] : '=';
    }
    return out;
  }

  var __LX_B64_LOOKUP = (function () {
    var table = {};
    for (var i = 0; i < __LX_B64_CHARS.length; i++) table[__LX_B64_CHARS[i]] = i;
    table['-'] = 62; table['_'] = 63;
    return table;
  })();

  function __lxBase64Decode(str) {
    str = String(str).replace(/[\r\n\s]/g, '').replace(/-/g, '+').replace(/_/g, '/');
    while (str.length % 4 !== 0) str += '=';
    var out = [];
    for (var i = 0; i < str.length; i += 4) {
      var n = 0, pad = 0;
      for (var j = 0; j < 4; j++) {
        var ch = str[i + j];
        if (ch === '=') { pad++; n <<= 6; continue; }
        var v = __LX_B64_LOOKUP[ch];
        if (v === undefined) return new Uint8Array(0);
        n = (n << 6) | v;
      }
      out.push((n >> 16) & 0xff);
      if (pad < 2) out.push((n >> 8) & 0xff);
      if (pad < 1) out.push(n & 0xff);
    }
    return new Uint8Array(out);
  }

  function __lxHexEncode(bytes) {
    var out = '';
    for (var i = 0; i < bytes.length; i++) {
      out += (bytes[i] < 16 ? '0' : '') + bytes[i].toString(16);
    }
    return out;
  }

  function __lxHexDecode(str) {
    str = String(str);
    var out = [];
    for (var i = 0; i + 1 < str.length; i += 2) out.push(parseInt(str.substr(i, 2), 16));
    return new Uint8Array(out);
  }

  function __lxToBytes(value) {
    if (value == null) return new Uint8Array(0);
    if (value instanceof ArrayBuffer) return new Uint8Array(value);
    if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
    if (Array.isArray(value)) return new Uint8Array(value);
    if (typeof value === 'string') return __lxUtf8Encode(value);
    return new Uint8Array(0);
  }

  function __lxAttachToString(bytes) {
    // 兼容部分脚本直接调用 Buffer#toString(format) 的写法
    try {
      bytes.toString = function (format) { return __lxBufToString(this, format); };
    } catch (e) { /* ignore */ }
    return bytes;
  }

  function __lxBufferFrom(data, encoding) {
    encoding = String(encoding || 'utf8').toLowerCase().replace('-', '');
    var bytes;
    if (typeof data === 'string') {
      if (encoding === 'base64') bytes = __lxBase64Decode(data);
      else if (encoding === 'hex') bytes = __lxHexDecode(data);
      else if (encoding === 'binary' || encoding === 'latin1') {
        bytes = new Uint8Array(data.length);
        for (var i = 0; i < data.length; i++) bytes[i] = data.charCodeAt(i) & 0xff;
      } else bytes = __lxUtf8Encode(data);
    } else {
      bytes = __lxToBytes(data);
    }
    return __lxAttachToString(bytes);
  }

  function __lxBufToString(buf, format) {
    var bytes = __lxToBytes(buf);
    format = String(format || 'utf8').toLowerCase().replace('-', '');
    if (format === 'base64') return __lxBase64Encode(bytes);
    if (format === 'hex') return __lxHexEncode(bytes);
    if (format === 'binary' || format === 'latin1') {
      var out = '';
      for (var i = 0; i < bytes.length; i++) out += String.fromCharCode(bytes[i]);
      return out;
    }
    return __lxUtf8Decode(bytes);
  }

  // 浏览器风格 base64（部分脚本会直接使用）
  if (typeof globalThis.btoa === 'undefined') {
    globalThis.btoa = function (str) {
      var bytes = new Uint8Array(String(str).length);
      for (var i = 0; i < bytes.length; i++) bytes[i] = String(str).charCodeAt(i) & 0xff;
      return __lxBase64Encode(bytes);
    };
  }
  if (typeof globalThis.atob === 'undefined') {
    globalThis.atob = function (str) { return __lxBufToString(__lxBase64Decode(str), 'binary'); };
  }
  if (typeof globalThis.TextEncoder === 'undefined') {
    globalThis.TextEncoder = function () {};
    globalThis.TextEncoder.prototype.encode = function (str) { return __lxUtf8Encode(str); };
  }
  if (typeof globalThis.TextDecoder === 'undefined') {
    globalThis.TextDecoder = function () {};
    globalThis.TextDecoder.prototype.decode = function (bytes) { return __lxUtf8Decode(__lxToBytes(bytes)); };
  }
  if (typeof globalThis.window === 'undefined') globalThis.window = globalThis;
  if (typeof globalThis.self === 'undefined') globalThis.self = globalThis;
  if (typeof globalThis.navigator === 'undefined') {
    globalThis.navigator = { userAgent: 'lx-music-mobile/2.0.0 (Molia)' };
  }

  // ---------------------------------------------------------------------------
  // utils
  // ---------------------------------------------------------------------------

  function __lxNativeOrThrow(name) {
    var fn = globalThis[name];
    if (typeof fn !== 'function') throw new Error('native helper not available: ' + name);
    return fn;
  }

  var __lxUtils = {
    crypto: {
      md5: function (str) {
        return String(__lxNativeOrThrow('__lxMd5')(String(str)));
      },
      aesEncrypt: function (buffer, mode, key, iv) {
        var result = __lxNativeOrThrow('__lxAesEncrypt')(__lxToBytes(buffer), String(mode), key, iv);
        return __lxAttachToString(__lxToBytes(result));
      },
      rsaEncrypt: function (buffer, key) {
        var result = __lxNativeOrThrow('__lxRsaEncrypt')(__lxToBytes(buffer), String(key));
        return __lxAttachToString(__lxToBytes(result));
      },
      randomBytes: function (size) {
        var result = __lxNativeOrThrow('__lxRandomBytes')(size | 0);
        return __lxAttachToString(__lxToBytes(result));
      },
    },
    buffer: {
      from: __lxBufferFrom,
      bufToString: __lxBufToString,
    },
    zlib: {
      inflate: function (buf) {
        return Promise.resolve(__lxAttachToString(__lxToBytes(__lxNativeOrThrow('__lxZlibInflate')(__lxToBytes(buf)))));
      },
      deflate: function (data) {
        return Promise.resolve(__lxAttachToString(__lxToBytes(__lxNativeOrThrow('__lxZlibDeflate')(__lxToBytes(data)))));
      },
    },
  };

  // ---------------------------------------------------------------------------
  // HTTP 桥接
  // ---------------------------------------------------------------------------

  function __lxRequest(url, options, callback) {
    options = options || {};
    var reqId = 'http_' + (++__lxHttpSeq);
    var done = false;
    __lxHttpPending[reqId] = function (err, resp, body) {
      if (done) return;
      done = true;
      delete __lxHttpPending[reqId];
      if (typeof callback === 'function') {
        try {
          callback.call(globalThis, err || null, resp || null, body === undefined ? null : body);
        } catch (e) {
          console.error(__lxErrMessage(e));
        }
      }
    };
    var payload = {
      reqId: reqId,
      url: String(url),
      method: options.method || 'GET',
      headers: options.headers || null,
      timeout: typeof options.timeout === 'number' ? options.timeout : null,
      body: options.body === undefined ? null : options.body,
      form: options.form || null,
      formData: options.formData || null,
      followMax: options.follow_max || null,
    };
    __lxSendNative('http', payload);
    return function cancel() {
      if (done) return;
      done = true;
      delete __lxHttpPending[reqId];
      __lxSendNative('httpCancel', { reqId: reqId });
    };
  }

  // ---------------------------------------------------------------------------
  // 请求事件调度（Dart -> JS）
  // ---------------------------------------------------------------------------

  function __lxRespond(reqId, ok, data, error) {
    __lxSendNative('response', {
      reqId: reqId,
      ok: !!ok,
      data: data === undefined ? null : data,
      error: error == null ? null : String(error),
    });
  }

  function __lxValidateResponse(action, response) {
    if (action === 'musicUrl') {
      if (typeof response !== 'string' || !/^https?:/.test(response)) throw new Error('failed');
      if (response.length > 4096) throw new Error('failed');
      return response;
    }
    if (action === 'pic') {
      if (typeof response !== 'string' || !/^https?:/.test(response)) throw new Error('failed');
      return response;
    }
    if (action === 'lyric') {
      if (typeof response !== 'object' || response === null || typeof response.lyric !== 'string') throw new Error('failed');
      return {
        lyric: response.lyric,
        tlyric: typeof response.tlyric === 'string' ? response.tlyric : null,
        rlyric: typeof response.rlyric === 'string' ? response.rlyric : null,
        lxlyric: typeof response.lxlyric === 'string' ? response.lxlyric : null,
      };
    }
    // search / musicSearch 等扩展 action 直接返回，交给宿主解析
    return response;
  }

  function __lxInvokeRequest(reqId, payload) {
    try {
      payload = payload || {};
      var action = payload.action;
      if (typeof __lxRequestHandler !== 'function') {
        __lxRespond(reqId, false, null, 'Request event is not defined');
        return;
      }
      var result = __lxRequestHandler.call(globalThis, payload);
      Promise.resolve(result).then(function (data) {
        try {
          __lxRespond(reqId, true, __lxValidateResponse(action, data), null);
        } catch (e) {
          __lxRespond(reqId, false, null, __lxErrMessage(e));
        }
      }, function (err) {
        __lxRespond(reqId, false, null, __lxErrMessage(err));
      });
    } catch (e) {
      __lxRespond(reqId, false, null, __lxErrMessage(e));
    }
  }

  // ---------------------------------------------------------------------------
  // 宿主入口
  // ---------------------------------------------------------------------------

  globalThis.__lxSetup = function (info) {
    if (info && typeof info === 'object') {
      __lxInfo = {
        name: info.name || '',
        description: info.description || '',
        version: info.version || '',
        author: info.author || '',
        homepage: info.homepage || '',
        rawScript: info.rawScript || '',
      };
    }
    return true;
  };

  globalThis.__lxDeliver = function (msg) {
    if (!msg || typeof msg !== 'object') return;
    if (msg.type === 'httpResult') {
      var cb = __lxHttpPending[msg.reqId];
      if (!cb) return;
      if (msg.error) {
        cb(new Error(String(msg.error)), null, null);
        return;
      }
      var resp = msg.response || {};
      resp.raw = msg.raw;
      resp.body = msg.body;
      cb(null, resp, msg.body);
      return;
    }
    if (msg.type === 'invoke') {
      __lxInvokeRequest(msg.reqId, msg.payload);
      return;
    }
  };

  var EVENT_NAMES = {
    request: 'request',
    inited: 'inited',
    updateAlert: 'updateAlert',
  };

  globalThis.lx = {
    get version() { return __lxVersion; },
    get env() { return __lxEnv; },
    get currentScriptInfo() {
      return {
        name: __lxInfo.name,
        description: __lxInfo.description,
        version: __lxInfo.version,
        author: __lxInfo.author,
        homepage: __lxInfo.homepage,
        rawScript: __lxInfo.rawScript,
      };
    },
    EVENT_NAMES: EVENT_NAMES,
    on: function (eventName, handler) {
      if (eventName !== EVENT_NAMES.request) {
        return Promise.reject(new Error('The event is not supported: ' + eventName));
      }
      if (typeof handler !== 'function') {
        return Promise.reject(new Error('handler must be a function'));
      }
      __lxRequestHandler = handler;
      return Promise.resolve();
    },
    send: function (eventName, data) {
      if (eventName === EVENT_NAMES.inited) {
        if (__lxInited) return Promise.reject(new Error('Script is inited'));
        __lxInited = true;
        var sources = (data && typeof data === 'object' && data.sources) ? data.sources : {};
        __lxSendNative('inited', { sources: sources });
        return Promise.resolve();
      }
      if (eventName === EVENT_NAMES.updateAlert) {
        if (__lxUpdateAlertShown) return Promise.reject(new Error('The update alert can only be called once.'));
        __lxUpdateAlertShown = true;
        __lxSendNative('updateAlert', {
          log: data && data.log != null ? String(data.log).substring(0, 1024) : '',
          updateUrl: data && typeof data.updateUrl === 'string' && /^https?:/.test(data.updateUrl) ? data.updateUrl.substring(0, 1024) : null,
        });
        return Promise.resolve();
      }
      return Promise.reject(new Error('The event is not supported: ' + eventName));
    },
    request: __lxRequest,
    utils: __lxUtils,
  };
})();
