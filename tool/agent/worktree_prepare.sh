#!/usr/bin/env bash
# 为新 worktree 补齐本机构建前置：分支、Android 签名、Gradle wrapper、
# native assets hooks 缓存。只用于本机/agent，不写任何受版本控制的文件。
#
# 用法:
#   tool/agent/worktree_prepare.sh <worktree-dir> [branch]
#
# 典型流程（从主工作区执行）：
#   tool/agent/worktree_prepare.sh /path/to/molia-wt perf/my-change
#   cd /path/to/molia-wt && flutter analyze --no-pub
#
# 为什么需要：
# - android/key.properties 与 *.jks 被 .gitignore 排除，新 worktree 的 release
#   构建会缺签名；
# - android/gradle/wrapper 也被排除，Flutter 可能生成与 AGP 不匹配的 wrapper；
# - .dart_tool/hooks_runner/shared 里是 sqlite3/cnativeapi 的预编译产物，受限
#   网络下重新下载会卡住 Android build hooks；
# - OpenCode 的 worktree_create 默认 detached HEAD，直接提交会丢分支。
#
# 脚本幂等；已存在的文件不覆盖。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

usage() {
  sed -n '/^# 用法:/,/^# 为什么需要:/p' "$0" |
    sed -e 's/^# \{0,1\}//' -e '$d' >&2
  exit 2
}

[[ $# -ge 1 ]] || usage
target_arg="$1"
branch="${2:-}"

target="$(realpath -m "$target_arg")"
[[ "$target" != "$PROJECT_DIR" ]] ||
  die "目标就是当前工作区；从主工作区运行并指定另一个 worktree"

# 主工作区 = git worktree list 的第一项；从其它 worktree 运行时也能找到
# 签名与 hooks 缓存。若第一项没有签名，再退回脚本所在工作区。
source_dir="$PROJECT_DIR"
if [[ ! -f "$source_dir/android/key.properties" ]]; then
  primary="$(git -C "$PROJECT_DIR" worktree list --porcelain |
    awk 'NR==1 { sub(/^worktree /, ""); print; exit }')"
  [[ -n "$primary" && -d "$primary" ]] && source_dir="$primary"
fi

if [[ ! -e "$target" ]]; then
  branch="${branch:-perf/$(basename "$target")}"
  log "创建 worktree：$target（分支 $branch）"
  git -C "$PROJECT_DIR" worktree add -b "$branch" "$target" HEAD >/dev/null
elif [[ -d "$target/.git" || -f "$target/.git" ]]; then
  if ! git -C "$target" symbolic-ref -q HEAD >/dev/null; then
    branch="${branch:-perf/$(basename "$target")}"
    if git -C "$target" show-ref --verify --quiet "refs/heads/$branch"; then
      log "worktree 为 detached HEAD，切到已有分支：$branch"
      git -C "$target" checkout "$branch" >/dev/null
    else
      log "worktree 为 detached HEAD，创建分支：$branch"
      git -C "$target" checkout -b "$branch" >/dev/null
    fi
  elif [[ -n "$branch" && "$(git -C "$target" branch --show-current)" != "$branch" ]]; then
    die "worktree 已在分支 $(git -C "$target" branch --show-current)，拒绝切到 $branch"
  fi
else
  die "目标存在但不是 git worktree：$target"
fi

# Android 签名：key.properties 里的 storeFile 通常相对 android/，连 .jks 一起复制。
copied_signing=0
if [[ -f "$source_dir/android/key.properties" ]]; then
  cp -a "$source_dir/android/key.properties" "$target/android/"
  copied_signing=1
fi
for keystore in "$source_dir"/android/*.jks; do
  [[ -f "$keystore" ]] || continue
  cp -a "$keystore" "$target/android/"
  copied_signing=1
done
(( copied_signing )) ||
  log "警告：源工作区没有 android/key.properties 或 *.jks；release 构建仍会缺签名"

# Gradle wrapper（工作流要求 Gradle 9.9.0；不要让它按 SDK 模板生成旧版本）。
if [[ -d "$source_dir/android/gradle" && ! -d "$target/android/gradle" ]]; then
  cp -a "$source_dir/android/gradle" "$target/android/"
  log "已复制 android/gradle wrapper"
fi

# native assets hooks 缓存：sqlite3/cnativeapi 的预编译产物。只复制 shared，
# 不复制整个 .dart_tool（体积大且含本 worktree 专属状态）。
if [[ -d "$source_dir/.dart_tool/hooks_runner/shared" &&
      ! -d "$target/.dart_tool/hooks_runner/shared" ]]; then
  mkdir -p "$target/.dart_tool/hooks_runner"
  cp -a "$source_dir/.dart_tool/hooks_runner/shared" \
    "$target/.dart_tool/hooks_runner/"
  log "已复制 native assets hooks 缓存（shared）"
fi

if [[ ! -f "$target/.dart_tool/package_config.json" ]]; then
  log "首次 pub get：$target"
  ( cd "$target" && flutter pub get >/dev/null )
fi

log "worktree 就绪：$target（分支 $(git -C "$target" branch --show-current)）"
