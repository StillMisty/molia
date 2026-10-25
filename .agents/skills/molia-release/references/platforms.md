# 各平台产物与更新限制

- **Android**：应用内更新走系统安装器（`REQUEST_INSTALL_PACKAGES` + FileProvider，
  `cacheDir/updates`）；首次需用户在系统里允许「安装未知应用」。
- **Linux**：发布包**不含 libmpv**，运行需系统安装（发行版包名如 `mpv` / `libmpv2`）；
  托盘图标依赖系统 libX11 / libXi（桌面发行版默认都有）与 StatusNotifier 宿主
  （GNOME 需 AppIndicator 扩展，缺失时自动降级为无托盘）；应用内更新只支持可写的
  便携目录，系统包管理器安装会降级为手动下载。桌面集成（应用菜单条目 + dock 图标）
  是可选一步：解压后 `./install.sh` 装到 `~/.local/share`（`uninstall.sh` 移除）；
  Wayland 下不装就是通用图标（没有窗口图标协议），X11 下窗口图标由应用自身设置
  （`WindowChrome` 的 setIcon）。
- **Windows 安装版**：`setup.exe`（Inno Setup，脚本 `windows/installer/molia.iss`，
  按用户装到 `%LOCALAPPDATA%\Programs\Molia`，无需管理员）；应用内更新会静默运行新版本
  安装器（`/SILENT /NORESTART /CLOSEAPPLICATIONS`），安装器的 `[Run]` 段在完成后自动拉起应用。
- **Windows 便携版**：解压 zip 到任意可写目录运行；应用内更新是「解压覆盖 + 重启」，
  目录不可写时降级为手动下载。
- **iOS**：无应用内更新（App Store 规则），产物仅供侧载验证。
- **macOS**：无应用内更新（GitHub 分发 + ad-hoc 签名，自动替换 `.app` 会与 Gatekeeper
  冲突）；产物是 `molia-<版本>-macos-<arch>-unsigned.zip`（文件名带 `unsigned`，不进
  `latest.json`），首次打开需在「系统设置 › 隐私与安全性」放行。播放走 just_audio
  原生 AVPlayer，不需要 libmpv；托盘 = 菜单栏图标，关闭窗口默认隐藏到菜单栏。
