---
name: Molia 发布流程
description: 发布 Molia 版本时使用：版本号、打 tag、beta 与稳定版渠道、CI 产物与 latest.json。触发词：发布、release、tag、版本号、latest.json、GitHub Release、secrets。
---

# Molia 发布流程

1. 先把 `pubspec.yaml` 的版本改成与 tag 一致的版本号（`tag` 即版本）；
2. 打 tag 并推送，触发 `release.yml`：
   `git tag v1.2.3 && git push origin v1.2.3`（测试版 `v1.2.3-beta.1`，发布为 prerelease）；
3. 流水线：矩阵构建（android / windows / linux / ios）→ 汇总产物 + sha256 + `latest.json`
   → GitHub Release；测试版另滚动 `beta` 标签供客户端取清单；
4. `latest.json` 由 `tool/ci/gen_update_manifest.py` 生成，资产文件名约定见其文件头。

CI 分工：`ci.yml`（PR / main）只跑 `flutter analyze` + `flutter test`；
`integration.yml` 每日 / 手动跑 Linux 端到端；发布 secrets、签名与产物清单见 `docs/release.md`（权威出处）。
