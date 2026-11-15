#!/usr/bin/env python3
"""带「直链过期」行为的 mock 音频服务（`seed.sh --fault expire` 专用）。

`python3 -m http.server` 是无状态的，做不到「同一条链接若干秒后 403」。
这里只加这一条行为：`/audio.wav?token=<n>` 在 token 首次被请求后的
`--expire-after` 秒内正常返回，之后一律 403，用于验证：

- 取链缓存里的旧链接失效后，播放失败恢复会不会重新取链；
- 播放器（ExoPlayer / libmpv）收到 403 时的错误归类与提示。

其它路径仍按静态文件语义提供（mock.js / cover-*.png），与静态服务一致；
目录默认就是 seed.sh 生成的 `$RUN_DIR/seed-web`。

用法：
  python3 tool/agent/mock_source_server.py --port 8765 --directory DIR \
      --expire-after 20
"""

import argparse
import functools
import http.server
import threading
import time
import urllib.parse


class ExpiringHandler(http.server.SimpleHTTPRequestHandler):
    # 类属性由 main() 在启动前写入：handler 由 http.server 实例化，没法直接传参。
    expire_after = 20.0
    issued_at: dict[str, float] = {}
    lock = threading.Lock()

    def do_GET(self):  # noqa: N802（http.server 的命名约定）
        self._serve(with_body=True)

    def do_HEAD(self):  # noqa: N802
        self._serve(with_body=False)

    def _serve(self, *, with_body: bool) -> None:
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path.endswith("/audio.wav"):
            token = urllib.parse.parse_qs(parsed.query).get("token", [""])[0]
            if token and self._expired(token):
                self.send_error(403, "Link expired")
                return
        if with_body:
            super().do_GET()
        else:
            super().do_HEAD()

    def _expired(self, token: str) -> bool:
        now = time.monotonic()
        with self.lock:
            first = self.issued_at.setdefault(token, now)
        return now - first > self.expire_after

    def log_message(self, fmt, *args):
        # 过期判定要看得到「哪条 token 什么时候被判 403」；日志进 seed-http.log。
        super().log_message(fmt, *args)


def main() -> None:
    parser = argparse.ArgumentParser(description="mock 音频服务（带直链过期）")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--directory", required=True)
    parser.add_argument("--expire-after", type=float, default=20.0)
    args = parser.parse_args()

    ExpiringHandler.expire_after = args.expire_after
    handler = functools.partial(ExpiringHandler, directory=args.directory)
    # 只监听回环：Linux 直连 127.0.0.1，Android 走 `adb reverse` 到宿主机回环。
    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), handler)
    print(
        f"mock source server on 127.0.0.1:{args.port} "
        f"(directory={args.directory}, expire_after={args.expire_after}s)",
        flush=True,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
