import 'dart:math';

/// 同步口令的生成与归一化（纯 Dart：Web 构建也能编译；加密实现见 sync_crypto）。
///
/// 口令即信任根：能解密快照的设备视为已授权（ADR-0003）。
abstract final class SyncPassphrase {
  /// 展示字母表：去掉 I/O/0/1 等易混字符。
  static const String alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  /// 生成 8 组 × 4 字符（约 160 bit 熵），展示为 `XXXX-XXXX-...`。
  static String generate([Random? random]) {
    final source = random ?? Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < 32; i++) {
      if (i > 0 && i % 4 == 0) buffer.write('-');
      buffer.write(alphabet[source.nextInt(alphabet.length)]);
    }
    return buffer.toString();
  }

  /// 归一化用户输入：大写、去分隔符与空白，仅保留字母表字符。
  static String normalize(String raw) {
    final upper = raw.toUpperCase();
    final buffer = StringBuffer();
    for (final rune in upper.runes) {
      final char = String.fromCharCode(rune);
      if (alphabet.contains(char)) buffer.write(char);
    }
    return buffer.toString();
  }

  /// 用户输入是否与当前口令一致（归一化后比较）。
  static bool matches(String raw, String passphrase) =>
      normalize(raw) == normalize(passphrase);
}
