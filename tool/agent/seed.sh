#!/usr/bin/env bash
# 数据注入：收藏 / 最近播放 / 恢复会话 / mock 音源（UI 与播放验证用）
#
# 用法:
#   tool/agent/seed.sh android <command> [args]
#   tool/agent/seed.sh linux   <command> [args]
#
# 命令:
#   status               打印三份数据的路径与摘要（不写入）
#   favorites [N]        注入 __favorites__ + N 首固定样例（默认 3，含超长标题）
#   history [N]          注入最近播放 N 条（默认 5，最近在上）
#   session              写恢复会话（3 首 mock 曲目，下标 1，进度 20s）
#   mock-source [--port P]  生成 mock LX 脚本 + WAV，起宿主机 http 服务，
#                           并把脚本直接写进 lx_sources.json 并置 activeId
#                           （绕开应用内 Import from URL；默认端口 8765）
#   lang <zh|en|system>  切换应用语言（截图对照用；system = 跟随系统）
#   clear                清除注入的收藏 / 历史 / 会话（音源脚本保留）
#   restore              用最近一次备份恢复被本脚本写过的文件
#
# 说明:
# - 依赖：bash + python3 + adb（android）/ 本机文件（linux）；
# - 任何写入前把原文件备份到 $RUN_DIR/seed-backup/<时间戳>/；
# - DB 注入要求数据库已存在（应用至少启动过一次生成库）；写库前会清掉
#   `-wal` / `-shm` 旁挂文件，否则残留 WAL 会在应用下次打开时重放旧页面、
#   盖掉刚注入的数据；
# - Android 写入前自动 force-stop 应用（SharedPreferences 有内存缓存，
#   运行中写入会被覆盖）；Linux 请先退出正在运行的应用；
# - Android 上的 mock 音频 URL 用 127.0.0.1:<port> + `adb reverse`（模拟器→
#   宿主机 NAT 的 10.0.2.2 在应用进程内实测会超时），Linux 直接用 127.0.0.1;
# - DB 路径：Android /data/data/$APP_ID/app_flutter/molia_database_v2.sqlite，
#   Linux 优先 $HOME/Documents（xdg 文档目录），缺省回退
#   ~/.local/share/$APP_ID/molia_database_v2.sqlite。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

RUN_DIR="${RUN_DIR:-/tmp/opencode/molia}"
SEED_WEB_DIR="$RUN_DIR/seed-web"
SEED_BACKUP_DIR="$RUN_DIR/seed-backup"
SEED_PID_FILE="$RUN_DIR/seed-http.pid"
SEED_PORT_DEFAULT=8765
MOCK_SOURCE_KEY="mock"
MOCK_SOURCE_NAME="Mock 测试音源"
MOCK_SOURCE_ID="seed-mock-source"
# Drift 库走 getApplicationSupportDirectory()（Android 上即 files/）；
# app_flutter/ 是 documents 目录，应用不会把库写在那里。
ANDROID_DB_PATH="/data/data/$APP_ID/files/molia_database_v2.sqlite"
ANDROID_PREFS_PATH="/data/data/$APP_ID/shared_prefs/FlutterSharedPreferences.xml"
ANDROID_SCRIPTS_PATH="/data/data/$APP_ID/files/lx_sources.json"
ANDROID_TMP="/data/local/tmp/molia-seed"

usage() {
  sed -n '/^# 用法:/,/^# 说明:/p' "$0" | sed -e 's/^# \{0,1\}//' -e '$d' >&2
  exit 2
}

[[ $# -ge 2 ]] || usage
platform="$1"; shift
cmd="$1"; shift

case "$platform" in
  android) ;;
  linux) ;;
  *) usage ;;
esac

case "$cmd" in
  status|favorites|history|session|mock-source|lang|clear|restore) ;;
  *) usage ;;
esac

mkdir -p "$SEED_BACKUP_DIR"

# ---------- 平台文件定位 ----------

linux_documents_db() {
  local dir
  dir="$(xdg-user-dir DOCUMENTS 2>/dev/null || true)"
  [[ -n "$dir" && -f "$dir/molia_database_v2.sqlite" ]] && { echo "$dir/molia_database_v2.sqlite"; return 0; }
  return 1
}

# Linux 数据文件路径（DB 三段回退：xdg 文档 → 旧 .db → support 目录）。
linux_db_path() {
  local support="$HOME/.local/share/$APP_ID"
  if linux_documents_db >/dev/null; then linux_documents_db; return; fi
  if [[ -f "$support/molia_database_v2.sqlite" ]]; then echo "$support/molia_database_v2.sqlite"; return; fi
  echo "$support/molia_database_v2.sqlite"
}
linux_prefs_path() { echo "$HOME/.local/share/$APP_ID/shared_preferences.json"; }
linux_scripts_path() { echo "$HOME/.local/share/$APP_ID/lx_sources.json"; }

require_device() {
  [[ "$platform" == android ]] || return 0
  ensure_adb
  wait_for_device 60
  "$ADB" -s "$DEVICE_ID" shell pm path "$APP_ID" >/dev/null 2>&1 \
    || die "设备上没有安装 $APP_ID（先 tool/agent/app.sh run 或装包）"
}

force_stop_app() {
  [[ "$platform" == android ]] || return 0
  "$ADB" -s "$DEVICE_ID" shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
}

# ---------- 通用读写（Android 经 adb，Linux 直接改本机文件） ----------

# 设备 adb 是否为 root（模拟器默认是；真机 / 非 root 走 run-as）。
# 为什么需要：release 包不是 debuggable，run-as 会被系统拒绝，
# `seed.sh android mock-source` 在 release 产物上就无法写入音源 / 偏好。
adb_is_root() {
  [[ "$platform" == android ]] || return 1
  [[ "$("$ADB" -s "$DEVICE_ID" shell id -u 2>/dev/null | tr -d '\r')" == "0" ]]
}

# seed_pull <远端路径> <local 路径>：文件不存在时返回 1。
# Linux 下远端即本机路径，顺便完成「备份 = 复制到 local」。
seed_pull() {
  local remote="$1" local="$2"
  if [[ "$platform" == android ]]; then
    if adb_is_root; then
      "$ADB" -s "$DEVICE_ID" shell "test -f '$remote'" >/dev/null 2>&1 || return 1
      "$ADB" -s "$DEVICE_ID" exec-out "cat '$remote'" >"$local" || return 1
    else
      "$ADB" -s "$DEVICE_ID" shell "run-as $APP_ID test -f '$remote'" >/dev/null 2>&1 || return 1
      "$ADB" -s "$DEVICE_ID" exec-out "run-as $APP_ID cat '$remote'" >"$local" || return 1
    fi
  else
    [[ -f "$remote" ]] || return 1
    if [[ "$remote" != "$local" ]]; then
      cp "$remote" "$local"
    fi
  fi
  return 0
}

# seed_push <local 路径> <android 路径>：经 /data/local/tmp 落盘。
# root 设备直接 cp + chown（release 包也能注入）；否则 run-as（debug 包）。
seed_push() {
  local local="$1" remote="$2"
  if [[ "$platform" == android ]]; then
    "$ADB" -s "$DEVICE_ID" shell "mkdir -p '$ANDROID_TMP'" >/dev/null
    "$ADB" -s "$DEVICE_ID" push "$local" "$ANDROID_TMP/upload" >/dev/null
    if adb_is_root; then
      local owner
      owner="$("$ADB" -s "$DEVICE_ID" shell "stat -c '%u:%g' '$(dirname "$remote")'" | tr -d '\r')"
      # 目录属主 = 应用 uid；拿不到就只 cp（个别 toybox 无 stat -c）。
      if [[ -n "$owner" ]]; then
        "$ADB" -s "$DEVICE_ID" shell "cp '$ANDROID_TMP/upload' '$remote' \
          && chown '$owner' '$remote' && rm -f '$ANDROID_TMP/upload'" >/dev/null
      else
        "$ADB" -s "$DEVICE_ID" shell "cp '$ANDROID_TMP/upload' '$remote' \
          && rm -f '$ANDROID_TMP/upload'" >/dev/null
      fi
    else
      "$ADB" -s "$DEVICE_ID" shell "run-as $APP_ID cp '$ANDROID_TMP/upload' '$remote' \
        && rm -f '$ANDROID_TMP/upload'" >/dev/null
    fi
  else
    cp "$local" "$remote"
  fi
}

# backup_file <备份目录> <远端路径> <备份文件名>：把原文件拷入备份目录并回显
# 备份路径；原文件不存在时回显空串。
#
# 已存在同名备份时不覆盖（首次写入前快照 = 该文件的「注入前」状态，
# 多次注入后 restore 回到第一次注入前）。
backup_file() {
  local backup_dir="$1" remote="$2" name="$3"
  local tmp="$backup_dir/$name"
  if [[ -f "$tmp" ]]; then
    echo "$tmp"
    return 0
  fi
  if seed_pull "$remote" "$tmp"; then
    echo "$tmp"
  else
    echo ""
  fi
}

# ---------- 注入内容 ----------

# 固定样例曲目（JSON：sourceKey/songId/title/artist/album/durationMs），
# 其中第一首超长标题用于列表行宽验证。
seed_tracks_json() {
  local n="$1"
  python3 - "$n" "$MOCK_SOURCE_KEY" <<'PY'
import json, sys
n = int(sys.argv[1])
source = sys.argv[2]
base = [
    {
        "songId": "seed-1",
        "title": "夜曲（超长标题测试歌曲名称长度是否会占满整个列表行宽度并省略）",
        "artist": "周杰伦",
        "album": "十一月的萧邦",
        "durationMs": 250000,
    },
    {"songId": "seed-2", "title": "晴天", "artist": "周杰伦", "album": "叶惠美", "durationMs": 269000},
    {"songId": "seed-3", "title": "七里香", "artist": "周杰伦", "album": "七里香", "durationMs": 299000},
]
tracks = []
for i in range(n):
    item = dict(base[i % len(base)])
    if i >= len(base):
        item["songId"] = f"seed-{i + 1}"
        item["title"] = f"{item['title']}（样例 {i + 1}）"
    item["sourceKey"] = source
    tracks.append(item)
print(json.dumps(tracks, ensure_ascii=False))
PY
}

# ---------- DB 注入 ----------

# 删除数据库的 WAL / SHM 旁挂文件。
#
# 脚本推 / 拉的是单文件副本：残留 WAL 里可能还留着旧页面，应用下次打开时
# 会把它重放到刚推入的文件上，注入数据被静默盖掉（实测收藏全部丢失）。
# 注入前后各收一次，保证读到的与写入的都是自洽的单文件库。
seed_drop_sqlite_sidecars() {
  local remote="$1"
  if [[ "$platform" == android ]]; then
    "$ADB" -s "$DEVICE_ID" shell \
      "run-as $APP_ID rm -f '$remote-wal' '$remote-shm'" >/dev/null 2>&1 || true
  else
    rm -f "$remote-wal" "$remote-shm"
  fi
}

seed_db() {
  local mode="$1" count="$2"
  local remote tmp backup
  if [[ "$platform" == android ]]; then
    remote="$ANDROID_DB_PATH"
  else
    remote="$(linux_db_path)"
  fi
  seed_drop_sqlite_sidecars "$remote"
  mkdir -p "$SEED_BACKUP_DIR/latest"
  backup="$(backup_file "$SEED_BACKUP_DIR/latest" "$remote" "molia_database_v2.sqlite")"
  [[ -n "$backup" ]] && log "已备份数据库 → $backup"
  # 工作副本 = 当前文件（可能已被上一次注入改过）。库由应用首启建出：
  # 缺库时不再自建表——脚本维护的 DDL 会随 schema 演进失配（v5 起
  # playlist 版本列取代了 updatedAt/updatedBy），且只会造出缺表缺列的
  # 半成品库（drift 以 user_version 判定版本，不会走 onCreate 补表）。
  tmp="$SEED_BACKUP_DIR/work.sqlite"
  if ! seed_pull "$remote" "$tmp"; then
    if [[ "$mode" == "clear" ]]; then
      log "未找到现有数据库（$remote）：无需清除"
      return 0
    fi
    die "未找到现有数据库（$remote）：先启动一次应用生成库，再执行注入"
  fi

  local tracks
  tracks="$(seed_tracks_json "$count")"
  python3 - "$tmp" "$mode" "$tracks" <<'PY'
import json, sqlite3, sys, time
path, mode, tracks_json = sys.argv[1], sys.argv[2], sys.argv[3]
tracks = json.loads(tracks_json)
now = int(time.time() * 1000)
conn = sqlite3.connect(path)
cur = conn.cursor()

# 列集与 drift schema v5 对齐：版本列（versionPhysical/versionCounter/deviceId）
# 走表默认值，这里不写，与本地写引擎落下的行形状一致。
if mode == "favorites":
    row = cur.execute(
        "SELECT id FROM playlists WHERE name = '__favorites__' ORDER BY id LIMIT 1"
    ).fetchone()
    if row is None:
        cur.execute(
            "INSERT INTO playlists (name, createdAt) VALUES ('__favorites__', ?)",
            (now,),
        )
        pid = cur.lastrowid
    else:
        pid = row[0]
    cur.execute("DELETE FROM playlist_tracks WHERE playlistId = ?", (pid,))
    for i, t in enumerate(tracks):
        cur.execute(
            "INSERT INTO playlist_tracks (playlistId, sourceKey, songId, title, "
            "artist, album, coverUrl, durationMs, raw, addedAt, sortOrder) "
            "VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            (
                pid, t["sourceKey"], t["songId"], t["title"], t["artist"],
                t["album"], None, t["durationMs"],
                json.dumps({"songId": t["songId"]}, ensure_ascii=False),
                now + i, i,
            ),
        )
elif mode == "history":
    for i, t in enumerate(tracks):
        cur.execute(
            "INSERT INTO play_history (sourceKey, songId, title, artist, album, "
            "coverUrl, durationMs, raw, playedAt) VALUES (?,?,?,?,?,?,?,?,?) "
            "ON CONFLICT(sourceKey, songId) DO UPDATE SET title=excluded.title, "
            "artist=excluded.artist, album=excluded.album, "
            "durationMs=excluded.durationMs, raw=excluded.raw, "
            "playedAt=excluded.playedAt",
            (
                t["sourceKey"], t["songId"], t["title"], t["artist"], t["album"],
                None, t["durationMs"],
                json.dumps({"songId": t["songId"]}, ensure_ascii=False),
                now - (len(tracks) - 1 - i) * 60_000,
            ),
        )
elif mode == "clear":
    cur.execute("DELETE FROM playlist_tracks WHERE playlistId IN "
                "(SELECT id FROM playlists WHERE name = '__favorites__')")
    cur.execute("DELETE FROM play_history")

conn.commit()
print(f"written mode={mode} tracks={len(tracks)}")
conn.close()
PY

  seed_push "$tmp" "$remote"
  # 推入的是自洽单文件：再清一次旁挂文件，防止旧 WAL 在应用下次打开时重放。
  seed_drop_sqlite_sidecars "$remote"
  log "已写入数据库 → $remote"
}

# ---------- 恢复会话 ----------

seed_session() {
  local backup_dir="$SEED_BACKUP_DIR/latest"
  mkdir -p "$backup_dir"
  local prefs_remote prefs_local
  if [[ "$platform" == android ]]; then
    prefs_remote="$ANDROID_PREFS_PATH"
    prefs_local="$backup_dir/FlutterSharedPreferences.xml"
  else
    prefs_remote="$(linux_prefs_path)"
    prefs_local="$backup_dir/shared_preferences.json"
  fi
  local backup
  backup="$(backup_file "$backup_dir" "$prefs_remote" "$(basename "$prefs_local")")"
  if [[ -z "$backup" ]]; then
    die "未找到 $(basename "$prefs_local")（先启动一次应用生成偏好文件）"
  fi
  log "已备份偏好 → $backup"
  # 工作副本 = 当前文件（保留其它已有键；备份保持「注入前」状态）。
  local work="$backup_dir/work-$(basename "$prefs_local")"
  seed_pull "$prefs_remote" "$work" || cp "$backup" "$work"

  python3 - "$work" "$platform" "$MOCK_SOURCE_KEY" <<'PY'
import json, sys, time, xml.etree.ElementTree as ET

path, platform, source = sys.argv[1], sys.argv[2], sys.argv[3]
KEY = "flutter.playback_session_v1"
now = int(time.time() * 1000)


def track(i, title, duration):
    return {
        "sourceKey": source,
        "id": f"seed-{i}",
        "title": title,
        "artists": [{"name": "周杰伦"}],
        "album": "十一月的萧邦",
        "durationMs": duration,
        "origin": "lx",
        "qualities": [],
        "payload": {"songId": f"seed-{i}"},
    }


session = {
    "v": 1,
    "index": 1,
    "positionMs": 20000,
    "mode": "sequential",
    "context": None,
    "tracks": [
        track(1, "夜曲（超长标题测试歌曲名称长度是否会占满整个列表行宽度并省略）", 250000),
        track(2, "晴天", 269000),
        track(3, "七里香", 299000),
    ],
    "savedAt": now,
}
raw = json.dumps(session, ensure_ascii=False)

if platform == "linux":
    data = json.load(open(path, encoding="utf-8"))
    data[KEY] = raw
    json.dump(data, open(path, "w", encoding="utf-8"), ensure_ascii=False)
else:
    tree = ET.parse(path)
    root = tree.getroot()
    for node in root.findall("string"):
        if node.get("name") == KEY:
            node.text = raw
            break
    else:
        node = ET.SubElement(root, "string", {"name": KEY})
        node.text = raw
    tree.write(path, encoding="utf-8", xml_declaration=True)
print("session written")
PY

  seed_push "$work" "$prefs_remote"
  log "已写入恢复会话（3 首 / 下标 1 / 进度 20s）→ $prefs_remote"
}

# 清除恢复会话（clear 命令用；偏好文件不存在时静默跳过）。
seed_session_clear() {
  local prefs_remote prefs_local
  if [[ "$platform" == android ]]; then
    prefs_remote="$ANDROID_PREFS_PATH"
  else
    prefs_remote="$(linux_prefs_path)"
  fi
  mkdir -p "$SEED_BACKUP_DIR/latest"
  prefs_local="$SEED_BACKUP_DIR/latest/work-$(basename "$prefs_remote")"
  seed_pull "$prefs_remote" "$prefs_local" || return 0
  python3 - "$prefs_local" "$platform" <<'PY'
import json, sys, xml.etree.ElementTree as ET
path, platform = sys.argv[1], sys.argv[2]
KEY = "flutter.playback_session_v1"
if platform == "linux":
    data = json.load(open(path, encoding="utf-8"))
    data.pop(KEY, None)
    json.dump(data, open(path, "w", encoding="utf-8"), ensure_ascii=False)
else:
    tree = ET.parse(path)
    root = tree.getroot()
    for node in list(root.findall("string")):
        if node.get("name") == KEY:
            root.remove(node)
    tree.write(path, encoding="utf-8", xml_declaration=True)
print("session cleared")
PY
  seed_push "$prefs_local" "$prefs_remote"
  log "已清除恢复会话 → $prefs_remote"
}

# ---------- mock 音源 ----------

mock_script() {
  local base_url="$1"
  cat <<EOF
/**
 * @name $MOCK_SOURCE_NAME
 * @description seed.sh 生成的本地联调音源（musicUrl 指向宿主机 http 服务）
 * @version 1.0.0
 * @author seed.sh
 */

const { EVENT_NAMES, on, send } = globalThis.lx

on(EVENT_NAMES.request, function (payload) {
  const action = payload.action
  if (action === 'musicUrl') {
    return Promise.resolve('$base_url/audio.wav')
  }
  if (action === 'search') {
    return Promise.resolve({
      isEnd: true,
      list: [
        { id: 'seed-1', name: '夜曲（超长标题测试歌曲名称长度是否会占满整个列表行宽度并省略）', singer: '周杰伦', albumName: '十一月的萧邦', source: '$MOCK_SOURCE_KEY', interval: '04:10' },
        { id: 'seed-2', name: '晴天', singer: '周杰伦', albumName: '叶惠美', source: '$MOCK_SOURCE_KEY', interval: '04:29' },
        { id: 'seed-3', name: '七里香', singer: '周杰伦', albumName: '七里香', source: '$MOCK_SOURCE_KEY', interval: '04:59' }
      ]
    })
  }
  if (action === 'lyric') {
    return Promise.resolve({
      lyric: '[00:00.00]第一行歌词\n[00:04.00]这一行歌词特别长特别长特别长特别长特别长特别长特别长特别长用来测试桌面歌词横向滚动\n[00:08.00]第三行歌词',
      tlyric: '[00:00.00]translation one\n[00:04.00]translation two long long long long long long long long long long long',
      rlyric: null,
      // 逐字时间轴：文本拼接与主行一致，供桌面歌词逐字渐染的视觉验证。
      // 词轴必须落在行内（末词结束 < 下一行 8s），否则切行时滚动还没走完，
      // 会误判成长行滚动被截断。
      lxlyric: '[00:00.00]<0,500>第一行<500,500>歌词\n[00:04.00]<0,500>这一行歌词<500,380>特别长<880,380>特别长<1260,380>特别长<1640,380>特别长<2020,380>特别长<2400,380>特别长<2780,380>特别长<3160,380>特别长<3540,360>用来测试桌面歌词横向滚动\n[00:08.00]<0,500>第三<500,500>行歌词'
    })
  }
  return Promise.reject(new Error('action not support: ' + action))
})

send(EVENT_NAMES.inited, {
  sources: {
    $MOCK_SOURCE_KEY: {
      name: 'Mock 测试源',
      type: 'music',
      actions: ['search', 'musicUrl', 'lyric'],
      qualitys: ['128k', '320k']
    }
  }
})
EOF
}

seed_mock_source() {
  local port="$SEED_PORT_DEFAULT"
  while (($#)); do
    case "$1" in
      --port) port="$2"; shift ;;
      *) usage ;;
    esac
    shift
  done

  # 音频素材：优先复用上次会话留下的 WAV，否则现场生成。
  mkdir -p "$SEED_WEB_DIR"
  if [[ -f "$RUN_DIR/web/audio.wav" ]]; then
    cp "$RUN_DIR/web/audio.wav" "$SEED_WEB_DIR/audio.wav"
  elif [[ ! -f "$SEED_WEB_DIR/audio.wav" ]]; then
    python3 - "$SEED_WEB_DIR/audio.wav" <<'PY'
import math, struct, sys, wave
path = sys.argv[1]
rate = 44100
seconds = 30
with wave.open(path, "w") as f:
    f.setnchannels(1)
    f.setsampwidth(2)
    f.setframerate(rate)
    frames = bytearray()
    for i in range(rate * seconds):
        value = int(12000 * math.sin(2 * math.pi * 440 * i / rate))
        frames += struct.pack("<h", value)
    f.writeframes(bytes(frames))
PY
  fi

  local base_url
  if [[ "$platform" == android ]]; then
    # 用 adb reverse 把设备上的 127.0.0.1:<port> 转发到宿主机：
    # 实测本环境里 10.0.2.2（模拟器→宿主 NAT）在应用进程内连接会卡死
    # （ExoPlayer 读响应头超时），adb reverse 走 adb 通道稳定可用。
    ensure_adb
    "$ADB" -s "$DEVICE_ID" reverse "tcp:$port" "tcp:$port" >/dev/null
    log "已建立 adb reverse tcp:$port → 宿主机 tcp:$port"
    base_url="http://127.0.0.1:$port"
  else
    base_url="http://127.0.0.1:$port"
  fi
  mock_script "$base_url" >"$SEED_WEB_DIR/mock.js"

  # 起宿主机 http 服务（已在监听则复用）。
  if ! (echo >"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
    log "启动宿主机 http 服务：$SEED_WEB_DIR（端口 $port）"
    nohup python3 -m http.server "$port" --directory "$SEED_WEB_DIR" \
      >"$RUN_DIR/seed-http.log" 2>&1 &
    echo $! >"$SEED_PID_FILE"
    sleep 1
  else
    log "端口 $port 已有服务在监听，复用"
  fi

  # 写 lx_sources.json（备份 → 生成 → 推送）。
  local scripts_remote
  if [[ "$platform" == android ]]; then scripts_remote="$ANDROID_SCRIPTS_PATH"; else scripts_remote="$(linux_scripts_path)"; fi
  mkdir -p "$SEED_BACKUP_DIR/latest"
  local backup tmp
  backup="$(backup_file "$SEED_BACKUP_DIR/latest" "$scripts_remote" "lx_sources.json")"
  [[ -n "$backup" ]] && log "已备份音源文件 → $backup"
  tmp="$SEED_BACKUP_DIR/work-lx_sources.json"
  if ! seed_pull "$scripts_remote" "$tmp"; then
    echo '{"activeId":null,"scripts":[]}' >"$tmp"
  fi
  python3 - "$tmp" "$SEED_WEB_DIR/mock.js" "$MOCK_SOURCE_ID" "$MOCK_SOURCE_KEY" \
    "$MOCK_SOURCE_NAME" <<'PY'
import json, sys, time
path, script_path, script_id, source_key, source_name = sys.argv[1:6]
data = json.load(open(path, encoding="utf-8"))
script = open(script_path, encoding="utf-8").read()
entry = {
    "id": script_id,
    "name": source_name,
    "description": "seed.sh 生成的本地联调音源",
    "version": "1.0.0",
    "author": "seed.sh",
    "homepage": "",
    "script": script,
    "importedAt": int(time.time() * 1000),
    "updateUrl": None,
    "sources": {
        source_key: {
            "name": "Mock 测试源",
            "actions": ["search", "musicUrl", "lyric"],
            "qualitys": ["128k", "320k"],
        }
    },
}
scripts = [s for s in data.get("scripts", []) if s.get("id") != script_id]
scripts.append(entry)
data["scripts"] = scripts
data["activeId"] = script_id
json.dump(data, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print("script written")
PY
  seed_push "$tmp" "$scripts_remote"
  log "已写入并激活 mock 音源 → $scripts_remote"
  log "音频地址：$base_url/audio.wav（服务目录 $SEED_WEB_DIR）"
}

# 切换应用语言（写入 flutter.selected_language；system = 删除该键）。
seed_language() {
  local code="$1"
  local backup_dir="$SEED_BACKUP_DIR/latest"
  mkdir -p "$backup_dir"
  local prefs_remote prefs_local
  if [[ "$platform" == android ]]; then
    prefs_remote="$ANDROID_PREFS_PATH"
  else
    prefs_remote="$(linux_prefs_path)"
  fi
  backup_file "$backup_dir" "$prefs_remote" "$(basename "$prefs_remote")" >/dev/null
  prefs_local="$backup_dir/work-$(basename "$prefs_remote")"
  seed_pull "$prefs_remote" "$prefs_local" || die "未找到偏好文件（先启动一次应用）"
  python3 - "$prefs_local" "$platform" "$code" <<'PY'
import json, sys, xml.etree.ElementTree as ET
path, platform, code = sys.argv[1], sys.argv[2], sys.argv[3]
KEY = "flutter.selected_language"
value = None if code == "system" else code
if platform == "linux":
    data = json.load(open(path, encoding="utf-8"))
    if value is None:
        data.pop(KEY, None)
    else:
        data[KEY] = value
    json.dump(data, open(path, "w", encoding="utf-8"), ensure_ascii=False)
else:
    tree = ET.parse(path)
    root = tree.getroot()
    found = False
    for node in list(root.findall("string")):
        if node.get("name") == KEY:
            if value is None:
                root.remove(node)
            else:
                node.text = value
            found = True
    if not found and value is not None:
        node = ET.SubElement(root, "string", {"name": KEY})
        node.text = value
    tree.write(path, encoding="utf-8", xml_declaration=True)
print("language written:", code)
PY
  seed_push "$prefs_local" "$prefs_remote"
  log "已设置应用语言为 $code → $prefs_remote"
}

# ---------- status / restore ----------

seed_status() {
  local db prefs scripts
  if [[ "$platform" == android ]]; then
    db="$ANDROID_DB_PATH"; prefs="$ANDROID_PREFS_PATH"; scripts="$ANDROID_SCRIPTS_PATH"
  else
    db="$(linux_db_path)"; prefs="$(linux_prefs_path)"; scripts="$(linux_scripts_path)"
  fi
  echo "平台: $platform（设备: ${DEVICE_ID}）"
  for f in "$db" "$prefs" "$scripts"; do
    if seed_pull "$f" "$RUN_DIR/seed-status.tmp"; then
      printf '存在: %s (%s bytes)\n' "$f" "$(wc -c <"$RUN_DIR/seed-status.tmp" | tr -d ' ')"
    else
      printf '缺失: %s\n' "$f"
    fi
  done
  rm -f "$RUN_DIR/seed-status.tmp"
  if [[ -f "$SEED_PID_FILE" ]]; then
    echo "mock http 服务 PID: $(cat "$SEED_PID_FILE")（日志 $RUN_DIR/seed-http.log）"
  fi
}

seed_restore() {
  [[ -d "$SEED_BACKUP_DIR/latest" ]] || die "没有备份（$SEED_BACKUP_DIR/latest）"
  local found=0
  for f in "$SEED_BACKUP_DIR/latest"/*; do
    [[ -f "$f" ]] || continue
    case "$(basename "$f")" in
      work-*|empty.sqlite) continue ;;
    esac
    found=1
    local name remote
    name="$(basename "$f")"
    case "$name" in
      molia_database_v2.sqlite)
        [[ "$platform" == android ]] && remote="$ANDROID_DB_PATH" || remote="$(linux_db_path)" ;;
      FlutterSharedPreferences.xml)
        remote="$ANDROID_PREFS_PATH" ;;
      shared_preferences.json)
        remote="$(linux_prefs_path)" ;;
      lx_sources.json)
        [[ "$platform" == android ]] && remote="$ANDROID_SCRIPTS_PATH" || remote="$(linux_scripts_path)" ;;
      *) continue ;;
    esac
    force_stop_app
    seed_push "$f" "$remote"
    log "已恢复 $remote ← $f"
  done
  (( found )) || die "备份目录里没有可恢复的文件"
}

# ---------- 入口 ----------

case "$cmd" in
  status)
    if [[ "$platform" == android ]]; then
      require_device
    fi
    seed_status
    ;;
  favorites)
    require_device
    force_stop_app
    seed_db favorites "${1:-3}"
    ;;
  history)
    require_device
    force_stop_app
    seed_db history "${1:-5}"
    ;;
  session)
    require_device
    force_stop_app
    seed_session
    ;;
  mock-source)
    require_device
    force_stop_app
    seed_mock_source "$@"
    ;;
  lang)
    [[ $# -ge 1 ]] || usage
    require_device
    force_stop_app
    seed_language "$1"
    ;;
  clear)
    require_device
    force_stop_app
    seed_db clear 0
    seed_session_clear
    ;;
  restore)
    require_device
    seed_restore
    ;;
esac
