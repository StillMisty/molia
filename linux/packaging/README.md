# Linux 桌面集成（打包资产）

发布包 `molia-<版本>-linux-x64.tar.gz` 里的 `share/`、`install.sh`、`uninstall.sh`
由 `release.yml` 的 linux job 从本目录拷进 staging，布局与 XDG 目录一致。

用户解压后：

- 直接 `./molia` 即可用；X11 会话里窗口/任务栏图标由应用自身设置（见下），
  但 dock 与应用菜单的图标要靠桌面条目；
- 想要应用菜单条目 + dock（含 Wayland）图标，跑一次 `./install.sh`：装到
  `${XDG_DATA_HOME:-~/.local/share}`，不需要 root；`./uninstall.sh` 移除。

**为什么必须有 `.desktop`**：Wayland 没有「窗口图标」协议，dock / 应用菜单只能
按 `app_id ↔ .desktop 文件名` 匹配（两者都是 `top.stillmisty.molia`，与
`linux/CMakeLists.txt` 的 `APPLICATION_ID` 一致）；不装就是通用图标。X11 侧另有
`StartupWMClass` 供窗口匹配。应用用同一个 `APPLICATION_ID` 注册
`GApplication` 单实例 / D-Bus 激活；从桌面条目或直接执行二进制重复启动都会把
`activate` 转发给已有实例，并带上 startup notification token（Wayland 聚焦）。
没有 session bus 时回退非唯一模式，由 Dart 文件锁兜底（ADR-0020）。

## `.desktop` 字段与取舍

- `Name=Molia` 全平台统一且**不本地化**：品牌名跟系统语言变化会让用户在菜单里
  找不到同一个应用；解释性文字放 `GenericName`。
- `GenericName` / `GenericName[zh_CN]`：让 GNOME / KDE 的启动器能按「音乐播放器 /
  Music Player」理解应用；只做翻译，不改品牌。
- `Keywords` / `Keywords[zh_CN]`：搜索词（音乐 / 播放器 / 音频 / 播放），值必须以
  分号结尾，否则 `desktop-file-validate` 会报格式错误。
- `X-GNOME-UsesNotifications=true`：GNOME 把应用发出的通知归到 Molia 名下。
- `SingleMainWindow=true`：应用是单实例（ADR-0020），声明后 GNOME 启动第二次时
  聚焦已有窗口而不是暗示要开第二个主窗口。
- `StartupNotify=true`：启动器在进程启动期间显示忙碌反馈（与单实例激活携带的
  startup notification token 一致）。
- **刻意不写** `MimeType` / `Actions` / `DBusActivatable`：当前应用不解析命令行文件
  参数，也没有文件打开动作。声明音频 MIME 会让文件管理器把 Molia 列为「打开方式」，
  用户点开却无法播放。文件关联是独立功能，先做到这两个键就够。
- `Categories` / `StartupWMClass` / `Exec` / `Icon` 的口径不变（见上文）；
  `test/packaging/linux_desktop_test.dart` 钉住以上字段与「没有 MimeType」的契约，
  `desktop-file-validate`（可用时）是最后一道门禁。

## 图标再生成（品牌更新时）

源图 `assets/icons/molia_icon_full_bleed.svg`（2048²，圆角矩形 + mark）。逐尺寸
矢量渲染，小尺寸比缩放清晰：

```bash
for s in 16 24 32 48 64 128 256 512; do
  out="linux/packaging/share/icons/hicolor/${s}x${s}/apps/top.stillmisty.molia.png"
  mkdir -p "$(dirname "$out")"
  rsvg-convert -w "$s" -h "$s" assets/icons/molia_icon_full_bleed.svg -o "$out"
done
rsvg-convert -w 256 -h 256 assets/icons/molia_icon_full_bleed.svg \
  -o assets/icons/app_icon.png
```

- `assets/icons/app_icon.png`（256²）是运行期窗口图标资产：X11 上 `WindowChrome`
  经 window_manager 的 `setIcon` 交给 `gtk_window_set_icon_from_file`；Wayland
  下该调用无害但无效（靠上面的 .desktop）；
- hicolor 目录名必须与图片实际尺寸一致、`.desktop` 必填键与 `Icon` 名必须齐全
  —— `test/packaging/linux_desktop_test.dart` 守住这些契约（含 PNG IHDR 尺寸）；
- Windows 的 `app_icon.ico` 不在这里生成，见根目录 `icons_launcher.yaml`。

## 约定

- `.desktop` 的 `Exec` 在仓库里写相对名 `molia`（仅作模板），`install.sh` 安装时
  改写成便携目录里的绝对路径 —— 应用内更新覆盖同一目录后依然有效；
- 只做用户级安装（`~/.local/share`），不引入 sudo / 系统级路径；
- 卸载只删本应用的 `.desktop` 与图标文件，不动程序文件与用户数据。
