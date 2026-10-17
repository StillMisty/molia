---
name: Molia 测试价值门槛
description: 新增、修改或精简 Molia 测试（test/**、integration_test/**）时使用：什么必须测、什么不写、删测试与文件合并的标准，以及迭代时按范围跑测试。触发词：写测试、加测试、删测试、测试太慢、测试价值、mock、fixture。
---

# Molia 测试价值门槛

## 必须测

领域不变量（`SourceTrack.raw` / `Track.payload` 原样回传、错误统一为 `SourceFailure`、幂等）、
边界与错误分支、真实回归（修过的 bug 钉死）、架构强制（`test/architecture/`）。

## 不写

- 复述实现的断言；下层已专测的重复覆盖——同一行为只测一处，例如缓存语义只在
  `test/catalog/request_cache_test.dart`；
- 纯冒烟 / 布局（「不溢出」「可渲染」每页至多留一条代表）；
- 锁死动画时长与像素中间帧的实现细节（优先断言端点 + 不变量）；
- 占位功能的完整错误矩阵（真实协议接入时在替换层补回，先留 TODO）。

## 删除与合并

1. 先确认行为已有替代覆盖，写明「由谁覆盖」；
2. 与功能改动分开提交：`chore(test): ...`，提交信息带替代覆盖；
3. 小而散的测试文件（< ~120 行）并入同模块文件：`flutter test` 的装载开销与文件数成正比
   （每文件约 2s，与文件大小无关）。

## 迭代与验证

- 迭代中只跑改动范围：`flutter test --no-pub test/catalog`；
- 提交前跑全量 `flutter test --no-pub` + `flutter analyze --no-pub`（0 error / 0 warning）。
