#!/usr/bin/env bash
# 为新 worktree 补齐本机构建前置：分支、Android 签名、native assets hooks 缓存。
# 只用于本机/agent，不写任何受版本控制的文件。
#
# 用法:
#   tool/agent/worktree_prepare.sh <worktree-dir> [branch]
#
# 典型流程（从主工作区执行）：
#   tool/agent/worktree_prepare.sh /path/to/molia-wt perf/my-change
#   cd /path/to/molia-wt && flutter analyze --no-pub
#
# 为什么需要：
# - 签名：优先用用户级 ~/.config/molia/android.properties（storeFile 写绝对路径），
#   所有 worktree 共用；没有时才从源工作区复制 android/key.properties / *.jks；
# - .dart_tool/hooks_runner/shared 里是 sqlite3/cnativeapi 的预编译产物，受限
#   网络下重新下载会卡住 Android build hooks；
# - OpenCode 的 worktree_create 默认 detached HEAD，直接提交会丢分支。
#
# Gradle wrapper 已入库，脚本不再复制。脚本幂等；已存在的文件不覆盖。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
handle_help "$@"


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

# Android 签名：优先用户级配置，所有 worktree 共用同一份。
if [[ -f "$HOME/.config/molia/android.properties" ]]; then
  log "使用用户级签名配置：~/.config/molia/android.properties"
else
  # 兼容旧布局：key.properties 里的相对 storeFile 以 app 模块为基准，
  # 因此 key.properties 与 *.jks 必须放在目标 worktree 的 android/ 下。
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
    log "警告：没有用户级签名配置，源工作区也没有 android/key.properties / *.jks；release 构建仍会缺签名"
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
