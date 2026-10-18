# latest.json

由 `tool/ci/gen_update_manifest.py` 在发布流水线里生成，客户端（`lib/data/update`）按此校验。

```json
{
  "schema": 1,
  "channel": "stable",
  "version": "1.2.3",
  "build": 42,
  "releasedAt": "2026-10-14T00:00:00Z",
  "notes": "…发布说明 markdown…",
  "notesUrl": "https://github.com/StillMisty/molia/releases/tag/v1.2.3",
  "assets": [
    {
      "platform": "android",
      "arch": "arm64",
      "kind": "apk",
      "file": "molia-1.2.3-android-arm64.apk",
      "url": "https://github.com/.../releases/download/v1.2.3/molia-1.2.3-android-arm64.apk",
      "size": 58123456,
      "sha256": "…"
    }
  ]
}
```

客户端约定：

- `channel` 必须与请求渠道一致（防止镜像串渠道）；
- `sha256` 存在就强制校验，不匹配则删除文件并报错；
- `platform` / `arch` 精确匹配优先，同平台任意架构兜底（见 `AppRelease.assetFor`）。
