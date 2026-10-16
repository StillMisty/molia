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
`StartupWMClass` 供窗口匹配。

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
