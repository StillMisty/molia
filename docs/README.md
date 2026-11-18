# 文档地图与单一来源约定

> 改文档前先查这张表：**一类事实只在一个地方维护**，其它文档只给指针。
> `AGENTS.md` 是入口；本文件回答「该看哪份、谁说了算」。

## 事实 → 权威文档

| 事实 / 主题 | 权威位置（唯一维护） | 说明 |
| --- | --- | --- |
| 工具链版本（Flutter / Dart / JDK / Gradle / AGP / Kotlin / SDK / NDK） | `AGENTS.md` §工具链 | 其它文档与 `molia-*` 技能不复列；`dart run tool/agent/cli.dart docs check` 校验 |
| 开发 / 编译 / 发布流程（顺序、门禁、偏离登记） | `docs/dev_workflow.md` | 流程入口；命令细节以脚本用法为准 |
| 本地开发环境、模拟器、seed、集成测试入口 | `docs/dev_environment.md` | 工具版本仍回 `AGENTS.md` |
| 架构与分层（as-built） | `docs/architecture.md` | 分层约束由 `test/architecture/` 强制执行 |
| 模块布局 / 文件体积守卫 | `docs/adr/0034-module-layout-and-file-size-guardrails.md` | domain/models 唯一模型位置、lib/utils 纯工具、800 行棘轮、pages/widgets 禁止 data import |
| 平台音频会话 / Android 混播焦点 | `docs/adr/0035-platform-audio-session-lifecycle.md` | 唯一激活 / 释放所有者、20 秒暂停宽限、iOS 启动释放、duck 音量 |
| 桌面输出丢失 / Windows 身份 / macOS 播放菜单 / Linux 桌面入口 | `docs/adr/0036-desktop-media-integration.md` | 一个端口、只暂停消失的旧输出、三端检测与平台通道、刻意不声明文件关联 |
| 曲间无缝（gapless） | `docs/adr/0037-gapless-playback.md` | 已决定暂不实现；若推进先做本地文件 / 完成缓存的窄路径 |
| Linux 桌面入口打包资产 | `linux/packaging/README.md` | 每个 `.desktop` 字段的理由与图标再生成 |
| 领域术语与模块职责 | `GLOSSARY.md` | 新术语落地时登记 |
| 已知坑（编号被源码引用） | `docs/pitfalls.md` | 编号不可重排，新增追加到末尾 |
| LX 音源、引擎、验证清单 | `docs/lx_sources.md` | 引擎 / 音源改动先看这里 |
| 歌词显示（含 Android 悬浮歌词） | `docs/lyrics_display.md` | 规格 + §12 as-built 映射 |
| 启动基线与测量方法 | `docs/performance.md` | 当前基线；历史轮次指向归档 |
| 全链路体检归档 | `docs/performance-audit.md` | 只追加带日期的轮次 |
| 桌面托盘内存 | `docs/memory.md` | 可复现数字 + 为什么这样改 |
| 移动端后台功耗 | `docs/mobile-power.md` | 后台继续 / 停掉哪些工作 |
| media_kit 原生库取舍 | `docs/media_kit_native_libs.md` | 含当时环境的测量快照 |
| 注释规范 | `docs/comment_style.md` | 噪音注释判定与清理 |
| 文案规范 | `docs/copy_style.md` | 黑话对照与长度约定 |
| 发布流程 / secrets / 产物清单 | `.agents/skills/molia-release/SKILL.md` | 版本号先改 `AGENTS.md` |
| 各版本发布公告 / 应用内更新说明 | `docs/releases/` | `<tag>.md` 是 Release 正文，`<tag>.summary.txt` 是 `latest.json` 的 notes |
| 包体积 / 内存 / worktree / seed 工具 | `.agents/skills/molia-perf-tooling/SKILL.md` | 详细口径与踩坑 |
| 设备调试（模拟器 / 热重载 / 截图） | `.agents/skills/molia-device-debug/SKILL.md` | 环境细节指向 `docs/dev_environment.md` |
| Issue、标签、领域文档约定 | `docs/agents/` | GitHub issues 为规格来源 |
| 决策记录（ADR） | `docs/adr/` | 只追加，不重写历史 |
| 投屏 / Android Auto 范围 | `docs/adr/0025-cast-and-auto-out-of-scope.md` | 生产入口保持缺席 |
| 收藏页密度 / 封面口径 | `docs/adr/0028-favorites-convergence.md` | 单一入口、桌面宽屏表格行、书脊、动图封面 |
| 凭据存储 | `docs/adr/0029-credentials-in-local-database.md` | 本机明文 SQLite，不依赖钥匙串 |
| Windows 贴靠布局 / 虚拟桌面 / 窗口位置分组 | `docs/adr/0032-windows-snap-and-virtual-desktops.md` | 最大化键上报、按桌面分组几何 |
| 界面截图 | `docs/images/` | 只被 `README.md` 引用 |

## 维护规则

1. **单一来源**：同一事实只在一个权威位置维护；需要复述时改成指针。工具链版本、性能基线、发布 secrets 是最容易漂移的三类。
2. **当前 vs 归档**：`performance.md` / `memory.md` 是当前口径；带日期的体检、测量快照只追加，不把旧数字改成新数字。新轮次先更新当前文档，再归档。
3. **孤儿文档**：新增 `docs/*.md` 必须在本表登记，或删除。没有入链的文档等于不存在。
4. **用户可见功能**：新功能落地时同步补 `GLOSSARY.md` 术语与 `docs/architecture.md` 条目；评审把「缺条目」视为未完成。
5. **ADR**：编号从 0001 起连续；已采纳的 ADR 只改「状态 / 相关链接」，不改历史决策正文。
6. **检查**：改完跑 `dart run tool/agent/cli.dart docs check`（CI 与 pre-commit 都会跑）。它校验路径 / 链接 / § 章节号 / 孤儿文档 / ADR 编号，以及工具链版本一致性。
