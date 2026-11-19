# Pigeon 契约（`tool/pigeon/`）

Pigeon 只覆盖**继续走通道**的域，使用 stable 的 channel 模式；**不使用** Pigeon
native interop preview（preview、无 Windows / Linux、官方不建议生产）。选型与
迁移顺序见 `docs/adr/0038-native-interop.md`。

## 约定

- 每个域一份 schema：`tool/pigeon/<域>.dart`（如 `sleep_timer.dart`）；
- 生成物统一 `lib/platform/pigeon/<域>.g.dart`，提交进仓库；
- 命令：`dart run pigeon --input tool/pigeon/<域>.dart`，平台 / 包名参数在
  schema 文件头部固定，避免每条命令各写一份；
- 正在迁 JNI / FFI 的通道不做 Pigeon 迁移，避免同一域两份契约；
- 旧的手写 `MethodChannel` 实现保留到契约测试通过，再删旧路径。

## 阶段 0 状态

本目录目前只有约定，没有 schema，也没有生成物。阶段 5 按域逐个添加；此时
CI 的生成物 drift 任务只运行 `dart run build_runner build`、
`dart run tool/jnigen.dart`、`dart run tool/ffigen_system.dart`。
