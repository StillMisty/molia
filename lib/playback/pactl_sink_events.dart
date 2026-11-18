/// `pactl subscribe` 事件行的纯解析器（ADR-0036）。
///
/// 为什么单独成模块：PulseAudio / PipeWire 是否安装、是否有声音服务器、Flatpak
/// 沙箱是否放行 `pactl` 都不可控；解析本身不依赖任何进程或平台，测试直接在
/// CI 上跑事件行即可覆盖边界（损坏行、CRLF、超大 id、无关对象类型）。
library;

/// `pactl subscribe` 事件类型。
enum PactlEventKind {
  added,
  changed,
  removed,

  /// 未知事件名（上游新增 / 拼写异常）：调用方按「不是输出丢失」忽略。
  unknown,
}

/// 一条 `pactl subscribe` 事件。
///
/// 例：`Event 'remove' on sink #42` → kind=removed、facility=sink、id=42。
/// `Event 'change' on server` → facility=server、id=null。
class PactlEvent {
  const PactlEvent({required this.kind, required this.facility, this.id});

  final PactlEventKind kind;

  /// 事件对象类型：`sink` / `source` / `sink-input` / `source-output` /
  /// `server` / `client` / `card` / `module` 等。
  final String facility;

  /// 对象数字 id；server 级事件为 null。
  final int? id;

  /// 被移除的播放输出（默认 sink）。
  bool get isSinkRemoved =>
      kind == PactlEventKind.removed && facility == 'sink';

  @override
  String toString() => 'PactlEvent(${kind.name}, $facility, #$id)';
}

final RegExp _eventPattern = RegExp(
  r"^Event\s+'([^']+)'\s+on\s+([A-Za-z0-9_-]+)(?:\s+#(\d+))?$",
);

/// 解析一行 `pactl subscribe` 输出；无法识别时返回 null，绝不抛异常。
///
/// 接受行尾 CR（child process 的行切分在不同平台可能保留 `\r`）与前后空白；
/// id 溢出（超出 Dart int 范围）按不可识别处理，避免把损坏行当成默认 sink
/// 消失。
PactlEvent? parsePactlEvent(String line) {
  final match = _eventPattern.firstMatch(line.trim());
  if (match == null) return null;
  final kind = switch (match.group(1)) {
    'new' => PactlEventKind.added,
    'change' => PactlEventKind.changed,
    'remove' => PactlEventKind.removed,
    _ => PactlEventKind.unknown,
  };
  final rawId = match.group(3);
  final id = rawId == null ? null : int.tryParse(rawId);
  if (rawId != null && id == null) return null;
  return PactlEvent(kind: kind, facility: match.group(2)!, id: id);
}
