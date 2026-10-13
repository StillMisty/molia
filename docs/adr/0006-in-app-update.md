# ADR-0006：应用内更新（GitHub Release 清单 + 平台安装策略）

- 状态：已采纳
- 日期：2026-10-14
- 相关：`lib/data/update/**`、`lib/services/update/**`、`lib/providers/update_provider.dart`、
  `lib/pages/update_settings_page.dart`、`lib/main.dart`、
  `android/app/src/main/kotlin/top/stillmisty/molia/MainActivity.kt`、
  `windows/installer/molia.iss`、
  `.github/workflows/release.yml`、`tool/ci/gen_update_manifest.py`、
  `docs/release.md`

## 背景

应用此前没有任何更新通道：用户只能自己盯 GitHub Release 手动下载覆盖。
多端（Android / Windows / Linux / Web）分发方式各不相同，需要一套
「检查 → 下载 → 安装」的通用机制，同时不引入第三方更新 SDK（仓库惯例：
关键链路自持，如同步 / 音源引擎 / 预lude）。

约束与事实：

- 仓库有 GitHub Actions 免费额度（公开库），Release 资产走 CDN；
  GitHub API 匿名限流 60 次/小时/IP，不适合作为版本检查入口；
- Android 覆盖安装要求签名一致 + versionCode 单调递增；
- Linux/Windows 是便携解压式分发，没有安装器/服务；
- Web 部署在 Pages，浏览器沙箱不允许应用内安装；
- iOS 只能走 App Store；
- `dart:io` 不得出现在 Web 会编译到的文件里（`docs/pitfalls.md` #30 同源问题）。

## 决策

1. **版本源 = Release 资产 `latest.json`**（不是 GitHub API）：
   稳定版取 `releases/latest/download/latest.json`（GitHub 的 latest 天然
   排除 prerelease），测试版取滚动标签 `releases/download/beta/latest.json`；
   Web 端由 Pages 同源提供。清单由 `tool/ci/gen_update_manifest.py` 在发布
   流水线中生成，与产物同批上传。
2. **渠道分稳定/测试**：tag `vX.Y.Z` 为稳定版、`vX.Y.Z-beta.N` 为测试版
   （prerelease）；客户端默认稳定版，设置页可切换。清单里的 `channel`
   必须与请求渠道一致，否则拒绝（防止镜像/配置串渠道）。
3. **版本判定用 semver + 构建号**：`compareAppVersions` 按 semver 比较
   （预发布 < 正式版），版本号相同再比 `build`（= CI run number，单调递增，
   同时是 Android versionCode）。当前版本读 `package_info_plus`。
4. **完整性用 sha256**：清单每个产物带 sha256，下载侧流式校验，不匹配删除
   文件并报错。信任模型 = HTTPS + GitHub 资产 + 清单内哈希，不做额外签名；
   自定义镜像属于用户显式降级信任（设置项文案已提示）。
5. **平台安装策略收在条件导入后面**：
   - Android：MethodChannel（`top.stillmisty.molia/updater`）交给系统安装器，
     FileProvider 暴露 `cacheDir/updates`；未授权「安装未知应用」时返回
     待授权状态并给系统设置深链；应用继续运行（系统安装器接管）。
   - Windows 安装版：静默运行新版 `setup.exe`（Inno Setup，`windows/installer/molia.iss`，
     按用户装到 `%LOCALAPPDATA%\Programs\Molia`），安装完成由安装器 `[Run]`
     段自动拉起应用；安装版判定 = 应用目录存在 Inno 的 `unins000.exe`。
   - Windows 便携版 / Linux：解压到临时目录后写「等主进程退出 → 覆盖安装目录 →
     重启」的助手脚本（`/bin/sh` / `cmd`），detached 启动后应用退出。
     安装目录不可写（包管理器安装等）降级为 `notWritable`，UI 引导手动下载。
   - 产物类别按安装形态选择：`UpdateInstaller.preferredArchiveKind()`
     返回 `exe`（安装版）/ `zip`（便携）/ `tar.gz` / `apk`，服务层据此从同一份
     清单里挑产物，缺失时回退该平台任意产物。
   - Web：不支持安装，`reloadPage()` 刷新页面。
   - iOS：返回不支持，UI 提示走 App Store。
   `dart:io` 只出现在 `update_installer_io.dart` / `update_downloader_io.dart`，
   其余文件经 `update_installer.dart` / `update_downloader.dart` 条件导出引用
   （与 `services/window/` 同一模式），保证 Web 可编译。
6. **UI 状态机在 provider**：`UpdateProvider` 持 `UpdateStatus` 阶段
   （idle/checking/upToDate/available/downloading/downloaded/installing/error），
   下载进度走独立 `ValueListenable`（不进 notifyListeners，仓库约定）；
   错误归类为 `UpdateFailureKind` 映射 l10n 文案，不展示原始异常。
7. **自动检查默认关闭、每天最多一次**：更新属于低频且桌面端会替换文件，
   默认静默反而有打扰/风险；开启后启动静默检查，失败不进入错误态。
   偏好（渠道 / 自动检查 / 清单地址覆盖 / 镜像前缀）是设备本地项，
   不登记进 `SettingsRegistry`。

## 取舍

- **Windows 双形态**：安装版（Inno Setup）负责「双击即装、可卸载、静默升级」，
  便携 zip 保留给免安装用户；不做 MSIX（需要代码签名证书，成本高）。
- **不做**增量更新 / 差分包（下载体积可接受，复杂度不值）；
- **不做**后台静默安装（桌面替换脚本会退出进程，必须由用户触发）；
- **不做**自建更新服务（GitHub Release 足够且零运维）；
- **不做**清单签名（sha256 + HTTPS 已覆盖传输损坏与 URL 劫持；密钥托管
  成本高于当前收益，需要时可加 minisign）。
- 目录残留：桌面覆盖是「同名替换」，旧版本多余文件会留下（不影响运行）；
  需要时可升级为镜像式清理。

## 影响

- `android/app/src/main/AndroidManifest.xml` 增加 `REQUEST_INSTALL_PACKAGES`
  与 FileProvider；`MainActivity` 增加更新通道。
- 新增依赖只有 `package_info_plus`（读当前版本）。
- 发布流程新增 tag 约定与 secrets 配置，见 `docs/release.md`。
- 设置首屏「通用与数据」新增「关于与更新」入口。
