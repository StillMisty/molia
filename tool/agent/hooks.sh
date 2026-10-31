#!/usr/bin/env bash
# 启用仓库内 Git hooks（.githooks/pre-commit 自动格式化暂存 Dart 文件）。
#
# 用法: tool/agent/hooks.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

git -C "$PROJECT_DIR" config core.hooksPath .githooks
log "已启用 Git hooks：$PROJECT_DIR/.githooks（仅影响本仓库）"
