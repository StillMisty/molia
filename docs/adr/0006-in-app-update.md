# ADR-0006：应用内更新（GitHub Release 清单 + 平台安装策略）

- 状态：已采纳
- 日期：2026-10-14
- 相关：`lib/data/update/**`、`lib/services/update/**`、`lib/providers/update_provider.dart`、
  `lib/pages/update_settings_page.dart`、`lib/main.dart`、
  `android/app/src/main/kotlin/top/stillmisty/molia/MainActivity.kt`、
  `windows/installer/molia.iss`、
  `.github/workflows/release.yml`、`tool/ci/gen_update_manifest.py`、
  `.agents/skills/molia-release/SKILL.md`

## 背景

应用此前没有任何更新通道：用户只能自己盯 GitHub Release 手动下载覆盖。
Android / Windows / Linux / iOS / macOS 的分发形态各不相同，需要一套
「检查 → 下载 → 安装」的通用机制，同时不引入第三方更新 SDK（仓库惯例：
关键链路自持，如同步 / 音源引擎 / 预lude）。

约束与事实：

- 仓库有 GitHub Actions 免费额度（公开库），Release 资产走 CDN；
  GitHub API 匿名限流 60 次/小时/IP，不适合作为版本检查入口；
- Android 覆盖安装要求签名一致 + versionCode 单调递增；
- Windows 同时有 Inno Setup 安装版与便携 zip，Linux 是便携 tar.gz，
  都没有可依赖的系统级更新服务；
- iOS 只能走 App Store；macOS 是 GitHub + ad-hoc 签名分发，自动替换 `.app`
  会与 Gatekeeper 冲突；
- `dart:io` 只允许出现在 `*_io.dart` 实现文件里，领域模型与 provider 保持纯 Dart。

## 决策

1. **版本源 = Release 资产 `latest.json`**（不是 GitHub API）：
   稳定版取 `releases/latest/download/latest.json`（GitHub 的 latest 天然
   排除 prerelease），测试版取滚动标签 `releases/download/beta/latest.json`。
   清单由 `tool/ci/gen_update_manifest.py` 在发布流水线中生成，与产物同批上传。
2. **渠道分稳定/测试**：tag `vX.Y.Z` 为稳定版、`vX.Y.Z-beta.N` 为测试版
   （prerelease）；客户端默认稳定版，设置页可切换。清单里的 `channel`
   必须与请求渠道一致，否则拒绝（防止镜像/配置串渠道）。
   beta 的滚动 release 采用「原地覆盖 `latest.json` 资产（`gh release upload
   --clobber`）」，不删除重建 release——删除到重建之间客户端固定地址会 404。
3. **版本判定用 semver + 构建号**：`compareAppVersions` 按 semver 比较
   （预发布 < 正式版），版本号相同再比 `build`（= CI run number，单调递增，
   同时是 Android versionCode）。当前版本读 `package_info_plus`。
4. **下载韧性 + sha256 完整性**：
   - 产物下载到临时目录 `updates/`，半成品是 `<target>.<sha8>.part`；
     同目录只保留当前 part，旧 part / 旧完整包下载前清理。
   - part 非空时发 `Range: bytes=<size>-` 续传；206 校验 `Content-Range`
     起点并追加；200 表示服务端忽略 Range，截断 part 重下；416 删 part
     后重试整包。
   - 网络失败 / 5xx / 流中断最多尝试 3 次（含首次，退避 1s / 2s）；4xx
     直接失败。请求 `connectTimeout` 15s、`receiveTimeout` 30s。
   - 进度总量优先取 `Content-Range` 的 total，其次清单 `size`，再次
     `partSize + Content-Length`；未知时保持 -1。
   - 完成后用流式 `sha256` 校验完整文件；没有 sha 时用清单 `size` 兜底
     校验长度。校验失败 / 长度不符删除 part。
   - 用户取消删除 part 并原样抛 `DioException`，由 provider 区分取消。
5. **平台安装策略**：
   - Android：MethodChannel（`top.stillmisty.molia/updater`）交给系统安装器，
     FileProvider 暴露 `cacheDir/updates`；未授权「安装未知应用」时返回
     待授权状态并给系统设置深链；应用继续运行（系统安装器接管）。
   - Windows 安装版：静默运行新版 `setup.exe`（Inno Setup，`windows/installer/molia.iss`，
     按用户装到 `%LOCALAPPDATA%\Programs\Molia`），安装完成由安装器 `[Run]`
     段自动拉起应用；安装版判定 = 应用目录存在 Inno 的 `unins000.exe`。
   - Windows 便携版 / Linux：解压到临时目录后写助手脚本（Linux `/bin/sh`、
     Windows PowerShell），detached 启动后应用退出。脚本等待主进程退出最多
     120s，超时放弃替换（不硬拷贝）；随后备份安装目录到同级
     `<installDir>.molia-backup`，覆盖 payload，校验可执行文件存在；备份或
     payload 校验失败时直接重启旧应用、不碰安装目录，覆盖失败则删除半更新
     目录并恢复备份/重启旧应用，成功删除备份与临时 payload。
     日志写应用支持目录的 `updates/install.log`（失败回退系统临时目录）。
     安装目录不可写（包管理器安装等）降级为 `notWritable`，UI 引导手动下载。
   - 产物类别按安装形态选择：`UpdateInstaller.preferredArchiveKind()`
     返回 `exe`（安装版）/ `zip`（便携）/ `tar.gz` / `apk`，服务层用同一份
     选择结果驱动发布卡片大小展示与下载，缺失时回退该平台任意产物。
   - iOS / macOS：不做应用内安装。iOS 提示走 App Store；macOS 提示从发布页
     手动下载（与 Gatekeeper 的自动替换限制一致）。
   - `dart:io` 只出现在 `update_installer_io.dart` / `update_downloader_io.dart`，
     其余文件经 `update_installer.dart` / `update_downloader.dart` 导出引用。
6. **UI 状态机与安装回执在 provider**：`UpdateProvider` 持 `UpdateStatus`
   阶段（idle/checking/upToDate/available/downloading/downloaded/installing/error），
   下载进度走独立 `ValueListenable`（不进 notifyListeners，仓库约定）；
   错误归类为 `UpdateFailureKind` 映射 l10n 文案，不展示原始异常。
   已下载安装包与「哪个发布」绑定：检查结果换版本 / 切换渠道 / 改清单地址或
   镜像前缀即作废，避免把旧包当新包安装；在途检查用代际计数丢弃旧结果。
   交给安装器前持久化 pending 版本/构建号，下次启动对比当前版本给出
   succeeded / incomplete 回执并清除 pending；Android 安装器取消返回时
   （`handleAppResumed`）清除 pending。手动检查清除回执，静默启动检查保留。
7. **自动检查只在启动时一次，默认关闭**：开启后在启动后静默检查，按
   `lastCheckedAt + 24h` 节流；不做常驻 Timer、不做回前台检查，失败不进入
   错误态。偏好（渠道 / 自动检查 / 清单地址覆盖 / 镜像前缀）是设备本地项，
   不登记进 `SettingsRegistry`。
8. **Android 更新下载通知**：复用下载任务的 dataSync 前台服务端口，使用独立的
   `molia_updates` 通知渠道；下载前 best-effort 请求通知权限，拒绝或通道异常
   不阻断下载（仅可能影响后台保活/通知展示）。

## 取舍

- **Windows 双形态**：安装版（Inno Setup）负责「双击即装、可卸载、静默升级」，
  便携 zip 保留给免安装用户；不做 MSIX（需要代码签名证书，成本高）。
- **不做**增量更新 / 差分包（下载体积可接受，复杂度不值）；
- **不做**后台静默安装（桌面替换脚本会退出进程，必须由用户触发）；
- **不做**自建更新服务（GitHub Release 足够且零运维）；
- **不做**清单签名（sha256 + HTTPS 已覆盖传输损坏与 URL 劫持；密钥托管
  成本高于当前收益，需要时可加 minisign）。
- 目录残留：桌面覆盖是「同名替换」，旧版本多余文件会留下（不影响运行）；
  需要时可升级为镜像式清理。替换前的同级备份用于失败回滚，成功后删除。

## 影响

- `android/app/src/main/AndroidManifest.xml` 增加 `REQUEST_INSTALL_PACKAGES`
  与 FileProvider；`MainActivity` 增加更新通道与更新通知渠道。
- 新增依赖只有 `package_info_plus`（读当前版本）；`path_provider` 已在仓库内，
  用于临时下载目录与安装日志目录。
- 发布流程新增 tag 约定与 secrets 配置，beta 滚动 release 原地更新
  `latest.json`，见 `.agents/skills/molia-release/SKILL.md`。
- 设置首屏「通用与数据」新增「关于与更新」入口。
