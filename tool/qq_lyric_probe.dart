import 'dart:io';

import 'package:molia/models/lyric_line.dart';
import 'package:molia/services/lyrics/qq_provider.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'Usage: dart run tool/qq_lyric_probe.dart "Song Title" ["Artist Name"]',
    );
    exitCode = 64;
    return;
  }

  final title = args[0];
  final artist = args.length > 1 ? args[1] : '';
  final provider = QQProvider();

  stdout.writeln('Searching QQ Music for: $title — $artist');
  final match = await provider.search(title, artist);
  if (match == null) {
    stdout.writeln('No QQ Music match found.');
    return;
  }

  stdout.writeln(
    'Match found: ${match.title} — ${match.artist} (songId: ${match.songId})',
  );

  final payload = await provider.fetchLyricPayload(match.songId);
  if (payload == null || !payload.hasAnyContent) {
    stdout.writeln('Lyric payload was empty.');
    return;
  }

  final normalizedLyric =
      payload.lyric != null ? provider.normalizeLyric(payload.lyric!) : '';

  // 与运行时同一套时间契约（lib/models/lyric_line.dart）。
  final hasTimestamps = hasLyricTimestamps(normalizedLyric);
  final contentLines = normalizedLyric
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  final timestampedLines =
      contentLines.where(hasLyricTimestamps).take(3).toList();
  final plainLines = contentLines
      .where((line) => !hasLyricTimestamps(line))
      .take(3)
      .toList();

  stdout.writeln('Primary lyric length: ${normalizedLyric.length} characters.');
  stdout.writeln(
    'Total content lines: ${contentLines.length}, '
    'timestamped lines: ${contentLines.where(hasLyricTimestamps).length}.',
  );
  stdout.writeln('Contains LRC timestamps: ${hasTimestamps ? 'YES' : 'NO'}');

  if (timestampedLines.isNotEmpty) {
    stdout.writeln('\nSample timestamped lines:');
    for (final line in timestampedLines) {
      stdout.writeln('  $line');
    }
  }

  if (plainLines.isNotEmpty) {
    stdout.writeln('\nSample plain lines:');
    for (final line in plainLines) {
      stdout.writeln('  $line');
    }
  }

  if (payload.romanizedLyric != null &&
      payload.romanizedLyric!.trim().isNotEmpty) {
    stdout.writeln(
      'Romanized lyric present (${payload.romanizedLyric!.length} chars).',
    );
  }
}
