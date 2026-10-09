#!/usr/bin/env bash
# WSL 安卓调试环境一键搭建（幂等，可重复执行）
#
# 用法: tool/agent/setup.sh
#
# 做四件事：
#   1. 检查/创建 ~/.androidrc（指定 SDK 路径）
#   2. 确保 emulator 组件与 API 37 系统镜像已安装（约 2GB，仅首次）
#   3. 补齐模拟器系统依赖 libxkbfile（无 root 的临时方案：塞进 emulator/lib64）
#   4. 确保 AVD 存在并写入调试友好的 config（swiftshader/4G/键盘）
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

# Arch 官方镜像的 libxkbfile 包（emulator 的 Qt xcb 依赖；系统装过则跳过）
LIBXKBFILE_URL="${LIBXKBFILE_URL:-https://geo.mirror.pkgbuild.com/extra/os/x86_64/libxkbfile-1.2.0-1-x86_64.pkg.tar.zst}"
AVD_MANAGER="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/avdmanager"

command -v "$ANDROID_CLI" >/dev/null || die "未找到 android CLI（paru -S android-cli）"
command -v curl >/dev/null || die "缺少 curl"
command -v bsdtar >/dev/null || die "缺少 bsdtar（pacman -S libarchive）"

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

# 2b. API 37 系统镜像（项目 minSdk=37，只能用 API 37 镜像；用 google_apis 而非 playstore 更轻）
if ! "$ANDROID_CLI" sdk list 2>/dev/null | grep -q 'system-images/android-37.0/google_apis/x86_64'; then
  log "安装 API 37 系统镜像（约 1.5GB）"
  "$ANDROID_CLI" sdk install "system-images/android-37.0/google_apis/x86_64"
fi

# 3. libxkbfile：系统级安装优先；否则把库文件放进 emulator/lib64（launcher 会把该目录加进
#    qemu 的库搜索路径）。永久修复请执行: sudo pacman -S libxkbfile
if ! ldconfig -p 2>/dev/null | grep -q 'libxkbfile\.so'; then
  if [[ ! -e "$ANDROID_SDK_ROOT/emulator/lib64/libxkbfile.so.1" ]]; then
    log "系统缺少 libxkbfile，临时补丁到 emulator/lib64（建议 sudo pacman -S libxkbfile）"
    mkdir -p "$RUN_DIR"
    pkg="$RUN_DIR/libxkbfile.pkg.tar.zst"
    curl -fsSL "$LIBXKBFILE_URL" -o "$pkg"
    bsdtar -xf "$pkg" -C "$RUN_DIR" usr/lib/
    cp -a "$RUN_DIR"/usr/lib/libxkbfile.so.1* "$ANDROID_SDK_ROOT/emulator/lib64/"
  fi
  log "libxkbfile 补丁就绪"
fi

# 4a. AVD
if ! "$AVD_MANAGER" list avd 2>/dev/null | grep -q "Name: $AVD_NAME"; then
  log "创建 AVD: $AVD_NAME"
  echo no | "$AVD_MANAGER" create avd \
    -n "$AVD_NAME" \
    -k "system-images;android-37.0;google_apis;x86_64" \
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

log "环境就绪: AVD=$AVD_NAME（emu.sh start / app.sh run / shot.sh）"
