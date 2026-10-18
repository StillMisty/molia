# ADR-0011：品牌名全平台统一 Molia（去掉「茉咏」）

- 状态：已采纳
- 日期：2026-10-19
- 相关：`lib/l10n/app_zh.arb`（`appName`）、`lib/services/app_branding_service.dart`、
  `android/app/src/main/res/values-zh-rCN/strings.xml`、
  `ios/Runner/zh-Hans.lproj/InfoPlist.strings`、
  `linux/packaging/share/applications/top.stillmisty.molia.desktop`、
  `windows/runner/Runner.rc`、`windows/installer/molia.iss`、
  `test/packaging/linux_desktop_test.dart`、ADR-0012、`docs/pitfalls.md` #58 / #59

## 背景

此前品牌名随界面语言分叉：英文 `Molia`、中文「茉咏」（l10n `appName`、Android/iOS
应用名、Linux `.desktop` 的 `Name[zh_CN]`，以及 Windows 的 exe 元数据与安装器
快捷方式名「Molia 茉咏」）。这套分叉在 Windows 上暴露了两个具体问题：

- 任务栏按钮右键菜单 / 悬浮预览头部的名字取自 shell 的**应用身份**（安装器
  快捷方式名 + AUMID 注册），显示为「Molia 茉咏」，与界面内品牌名（跟随语言）
  不是同一套文案；
- 改名类升级不会自动清理旧快捷方式名，开始菜单 / 桌面会残留
  「Molia 茉咏.lnk」，指向同一个 exe 出现两个入口。

## 决策

1. **品牌名统一为 `Molia`**，五平台一致：l10n `appName`（en / zh 同值）、
   Android `app_name`、iOS `CFBundleDisplayName` / `CFBundleName`、Linux
   `.desktop`（删掉 `Name[zh_CN]`）、Windows exe 元数据（`ProductName` /
   `FileDescription`）、安装器 `AppName`。
2. **「茉咏」只保留在升级路径上**：安装器 `[InstallDelete]` 删除旧的
   `Molia 茉咏.lnk`（开始菜单 + 桌面）。用户数据（`%APPDATA%\top.stillmisty\molia`
   与曲库）不动。
3. 设置页的「自定义应用名」能力不变：空白输入回退默认名 `Molia`，语义与
   `AppBrandingService` 的本地化默认名机制同构（默认值不再随语言变化，
   但仍走 l10n，保留将来再本地化的入口）。

## 后果

- 用户可见名字五平台一致：标题栏、海报水印、托盘 tooltip、任务栏右键菜单、
  开始菜单、应用列表 / 卸载项都显示 `Molia`；
- 中文界面不再有独立品牌名——这是本次的产品决定：一个名字比两个名字更好维护，
  也避免 shell 侧身份文案与应用内文案打架；
- 老版本升级不会出现两个开始菜单入口（`[InstallDelete]` 兜住）；Linux
  `.desktop` 少了 `Name[zh_CN]`，中文环境下 Name 回退到 `Molia`（`Name[zh_CN]`
  存在时桌面菜单会显示中文名，去掉即统一）。

## 验证

- `flutter analyze --no-pub`：0 error / 0 warning；
- `flutter test --no-pub`：全绿，含 `test/packaging/linux_desktop_test.dart`
  新增的「不再有本地化名字」断言；
- `tool/agent/test.sh linux`：端到端（托盘 / 窗口用例）不受改名影响；
- Windows 试构建（CI `windows-dev`，见 ADR-0012）：安装后开始菜单只有 `Molia`、
  应用列表显示「Molia <版本>」、旧「Molia 茉咏.lnk」被清掉（真机复核项）。
