#!/usr/bin/env bash
# Android 调试环境一键搭建（幂等，可重复执行；WSL 与 Linux 通用）
#
# 用法: tool/agent/setup.sh
#
# 做四件事：
#   1. 检查/创建 ~/.androidrc（指定 SDK 路径）
#   2. 确保 emulator 组件与 API 37 系统镜像（ps16k）已安装（约 2GB，仅首次）
#   3. 检查模拟器系统依赖 libxkbfile（缺失时只提示，不在 emulator/lib64 里打补丁）
#   4. 确保 AVD 存在（ps16k 镜像）并写入调试友好的 config（swiftshader/4G/键盘）
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
handle_help "$@"

# AVD 仍用 avdmanager：Android CLI 的 `emulator create` 目前只按设备 profile
# 创建，不能指定 ps16k 系统镜像与下面这些 config.ini 调试项。
AVD_MANAGER="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/avdmanager"

# 系统包管理器提示：按发行版给等价命令，避免只写 Arch 的 pacman。
pkg_hint() {
  if command -v pacman >/dev/null 2>&1; then
    printf 'sudo pacman -S libxkbfile'
  elif command -v apt-get >/dev/null 2>&1; then
    printf 'sudo apt-get install libxkbfile1'
  elif command -v dnf >/dev/null 2>&1; then
    printf 'sudo dnf install libxkbfile'
  else
    printf '用系统包管理器安装 libxkbfile'
  fi
}

command -v "$ANDROID_CLI" >/dev/null ||
  die "未找到 android CLI（$ANDROID_CLI）：Arch 用 paru -S android-cli；其它发行版装官方 android-cli，或设 ANDROID_CLI 指向等价命令"
[[ -x "$AVD_MANAGER" ]] || die "未找到 avdmanager：$AVD_MANAGER（android sdk install cmdline-tools/latest）"

# 1. ~/.androidrc
if [[ ! -f "$HOME/.androidrc" ]] || ! grep -q -- '--sdk=' "$HOME/.androidrc"; then
  printf -- '--sdk=%s\n' "$ANDROID_SDK_ROOT" >> "$HOME/.androidrc"
  log "已写入 ~/.androidrc: --sdk=$ANDROID_SDK_ROOT"
fi

# 2a. emulator 组件
if ! "$ANDROID_CLI" sdk list 2>/dev/null | grep -qE '^\s+emulator\s'; then
  log "安装 emulator 组件"
  "$ANDROID_CLI" sdk install emulator
fi

# 2b. API 37 系统镜像（minSdk=35，API 35+ 镜像均可；默认用 37 覆盖 targetSdk 37 的权限/16KB 行为；
#     用 google_apis 而非 playstore 更轻）。
#     取 ps16k 变体：默认环境就跑在 16 KB 页上，依赖的页对齐问题会当场暴露。
# 包路径两种写法：分号给 avdmanager，斜杠给 sdk list 与 AVD config.ini
SYS_IMAGE="system-images;android-37.0;google_apis_ps16k;x86_64"
SYS_IMAGE_PATH="system-images/android-37.0/google_apis_ps16k/x86_64"
if ! "$ANDROID_CLI" sdk list 2>/dev/null | grep -q "$SYS_IMAGE_PATH"; then
  log "安装 API 37 系统镜像（ps16k，约 2GB）"
  "$ANDROID_CLI" sdk install "$SYS_IMAGE"
fi

# 3. libxkbfile：模拟器 launcher 的 Qt xcb 依赖。只检查并给系统包安装命令，
#    不再把发行版包解压后塞进 emulator/lib64（那种做法会随 emulator 升级丢失，
#    也让问题从系统依赖变成脚本补丁）。
if ! ldconfig -p 2>/dev/null | grep -q 'libxkbfile\.so'; then
  die "系统缺少 libxkbfile：先执行 $(pkg_hint)，然后重跑本脚本"
fi

# 4a. AVD：镜像不一致时重建（AVD 只存调试状态，可弃）
avd_on_16k() {
  local cfg="$HOME/.android/avd/$AVD_NAME.avd/config.ini"
  [[ -f "$cfg" ]] && grep -q "^image.sysdir.1=$SYS_IMAGE_PATH/$" "$cfg"
}
if "$AVD_MANAGER" list avd 2>/dev/null | grep -q "Name: $AVD_NAME" && ! avd_on_16k; then
  log "AVD $AVD_NAME 的镜像不是 ps16k，删除重建"
  "$AVD_MANAGER" delete avd -n "$AVD_NAME" >/dev/null
fi
if ! "$AVD_MANAGER" list avd 2>/dev/null | grep -q "Name: $AVD_NAME"; then
  log "创建 AVD: $AVD_NAME"
  echo no | "$AVD_MANAGER" create avd \
    -n "$AVD_NAME" \
    -k "$SYS_IMAGE" \
    -d medium_phone
fi

# 4b. 纠正老版 avdmanager 可能写错的 target
ini="$HOME/.android/avd/$AVD_NAME.ini"
if [[ -f "$ini" ]] && ! grep -q '^target=android-37.0$' "$ini"; then
  sed -i 's/^target=.*/target=android-37.0/' "$ini"
  log "已修正 AVD target -> android-37.0"
fi

# 4c. 调试友好的 AVD 配置（键存在才改，避免破坏自定义）
cfg="$HOME/.android/avd/$AVD_NAME.avd/config.ini"
if [[ -f "$cfg" ]]; then
  sed -i \
    -e 's/^hw.gpu.enabled=.*/hw.gpu.enabled=yes/' \
    -e 's/^hw.gpu.mode=.*/hw.gpu.mode=swiftshader_indirect/' \
    -e 's/^hw.ramSize=.*/hw.ramSize=4096/' \
    -e 's/^hw.keyboard=.*/hw.keyboard=yes/' \
    -e 's/^hw.audioInput=.*/hw.audioInput=no/' \
    -e 's/^hw.audioOutput=.*/hw.audioOutput=no/' \
    -e 's/^disk.dataPartition.size=.*/disk.dataPartition.size=8G/' \
    -e 's/^vm.heapSize=.*/vm.heapSize=512M/' \
    "$cfg"
fi

log "环境就绪: AVD=$AVD_NAME（cli.dart emu start / app.sh run / shot.sh）"
