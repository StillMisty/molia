# Last.fm 应用密钥

Last.fm 的 API key / shared secret 按桌面 scrobbler 的惯例内置在构建里，
但**不提交进仓库**。发布构建从 GitHub Actions secrets 注入：

| Secret | 用途 |
| --- | --- |
| `MOLIA_LASTFM_API_KEY` | Last.fm API key |
| `MOLIA_LASTFM_API_SECRET` | 请求签名用 shared secret |

`.github/workflows/release.yml` 的 Android / Windows / Linux / iOS / macOS
构建都会把它们作为 `--dart-define` 传入；secret 未配置时为空字符串，应用
照常构建，但设置页的 Last.fm 连接入口会明确显示「这个版本没有内置
Last.fm 应用密钥」。

本地验证：

```bash
flutter run \
  --dart-define=MOLIA_LASTFM_API_KEY=... \
  --dart-define=MOLIA_LASTFM_API_SECRET=...
```

共享密钥无法在分发型客户端里真正保密；保护模型是每用户会话密钥 + TLS。
不要把密钥写进日志、错误文案或 UI。
