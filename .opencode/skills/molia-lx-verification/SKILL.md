---
name: Molia 音源与引擎验证
description: 改动 Molia 的 LX 引擎、prelude、内置平台音源 / 歌词 / 解析或相关测试时使用：生成物流程、Node 沙箱校验、fixture 重抓与完整验证清单。触发词：音源、引擎、prelude、quickjs、LX 脚本、取链、歌词解析、fixture。
---

# 音源与引擎验证

改 `tool/lx_prelude/` 后（`assets/lx/lx_prelude.js` 是 terser 产物，勿手改）：

```bash
node tool/build_lx_prelude.mjs          # 源码 → 产物
node tool/build_lx_prelude.mjs --check  # 校验产物与源码同步
node tool/lx_prelude_harness.mjs        # Node 沙箱全链路，应输出 PROTOCOL OK
```

重抓平台真实响应（依赖外网，网络不可控时不要跑）：

```bash
node tool/gen_search_fixtures.mjs
node tool/gen_album_fixtures.mjs
node tool/gen_artist_fixtures.mjs
node tool/gen_lyric_search_fixtures.mjs
```

## 完整验证清单

1. `flutter analyze --no-pub` 0 error / 0 warning；
2. `flutter test --no-pub`（重点：`lx_core` / `lx_supervisor` / `lx_script_update` /
   `builtin_*_parse` / `builtin_lyric_decode` / `source_manager_builtin_lyric` / `layering`）；
3. `node tool/lx_prelude_harness.mjs` → `PROTOCOL OK`；
4. `tool/agent/test.sh linux`（真实导入 → 搜索 → 取链 → 歌词；不含播放，无头环境不装 libmpv）；
5. `tool/agent/test.sh android`（模拟器同一套用例，跑完自动卸载）；
6. 真机/模拟器手验：设置 → 音源管理 → 导入社区脚本（或在线更新）→ 搜索 → 播放。

平台接口说明、加密与签名细节、已知限制见 `docs/lx_sources.md`（权威出处）。
