#!/usr/bin/env bash
# Linux release bundle 卫生检查：拒绝 debug 残留 / 非 release 引擎。
#
# 用法:
#   tool/agent/check_linux_bundle.sh [bundle 目录]
#
# 默认检查 build/linux/x64/release/bundle。CI release、perf.sh size、startup.sh
# 共用同一判据；日常 `flutter build linux --release` 后也可手动跑。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

bundle="${1:-$LINUX_RELEASE_BUNDLE}"
linux_assert_release_bundle "$bundle"

log "bundle 校验通过：$bundle"
printf '  bundle: %s\n' "$(du -sh "$bundle" | cut -f1)"
printf '  libapp.so: %s\n' "$(stat -c%s "$bundle/lib/libapp.so")"
printf '  engine: %s\n' "$(stat -c%s "$bundle/lib/libflutter_linux_gtk.so")"
