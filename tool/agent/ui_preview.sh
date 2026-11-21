#!/usr/bin/env bash
# 无设备 UI 预览：渲染真实壳层 / 设置弹层的 360 与 640 宽 PNG，供 agent 直接 read
#
# 用法:
#   tool/agent/ui_preview.sh [flutter test 额外参数]
#
# 说明:
# - 用 widget test 装配真实壳层（假仓库 / 假音源，不写本机资料库），不依赖
#   模拟器或显示服务；输出目录默认 $RUN_DIR/ui-preview，可用 UI_PREVIEW_DIR 覆盖；
# - 预览文件是 test/preview/ui_preview.dart（不叫 *_test.dart，默认全量测试不会
#   写截图）；本脚本显式指定路径运行；
# - 共享工具栏 / 选择器 / 弹层改动先看这组图，再按 AGENTS.md 的 360/640 口径提交。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
handle_help "$@"

out="${UI_PREVIEW_DIR:-$RUN_DIR/ui-preview}"
mkdir -p "$out"

(
  cd "$PROJECT_DIR"
  UI_PREVIEW_DIR="$out" flutter test test/preview/ui_preview.dart --no-pub "$@"
)

log "UI 预览完成：$out"
find "$out" -maxdepth 1 -name '*.png' -print | sort
