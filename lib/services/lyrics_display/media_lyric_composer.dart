import 'package:flutter/foundation.dart';

import 'lyrics_display_settings.dart';
import 'lyrics_output.dart';

/// 媒体元数据覆盖：只包含需要改写的字段（null = 保持原始元数据）。
@immutable
class LyricMetadataOverride {
  final String? title;
  final String? artist;
  final String? album;
  final String? displaySubtitle;

  const LyricMetadataOverride({
    this.title,
    this.artist,
    this.album,
    this.displaySubtitle,
  });

  bool get isEmpty =>
      title == null && artist == null && album == null && displaySubtitle == null;

  @override
  bool operator ==(Object other) =>
      other is LyricMetadataOverride &&
      other.title == title &&
      other.artist == artist &&
      other.album == album &&
      other.displaySubtitle == displaySubtitle;

  @override
  int get hashCode => Object.hash(title, artist, album, displaySubtitle);
}

/// 媒体会话元数据歌词合成（纯函数，便于单测）。
///
/// 通知/锁屏 profile 先应用、蓝牙 profile 后应用：同字段冲突时蓝牙优先；
/// 任一 profile 未启用 / 被 A2DP 门控拦下 / 文本为空时不写该字段。
class MediaLyricComposer {
  const MediaLyricComposer();

  LyricMetadataOverride? compose({
    required LyricsPresentation presentation,
    required LyricsDisplaySettings settings,
    required bool a2dpConnected,
  }) {
    final fields = <LyricsMetadataTarget, String>{};

    void applyProfile({
      required bool enabled,
      required LyricsMetadataTarget target,
      required LyricsMetadataFormat format,
      required bool includeTranslation,
      required LyricsPauseBehavior pauseBehavior,
      required bool bluetooth,
    }) {
      if (!enabled) return;
      if (bluetooth && settings.bluetoothOnlyWhenA2dp && !a2dpConnected) return;
      final text = _textOf(
        presentation,
        format: format,
        includeTranslation: includeTranslation,
        pauseBehavior: pauseBehavior,
      );
      if (text == null || text.isEmpty) {
        fields.remove(target);
      } else {
        fields[target] = text;
      }
    }

    applyProfile(
      enabled: settings.notificationEnabled,
      target: settings.notificationTarget,
      format: settings.notificationFormat,
      includeTranslation: settings.notificationIncludeTranslation,
      pauseBehavior: settings.notificationPauseBehavior,
      bluetooth: false,
    );
    applyProfile(
      enabled: settings.bluetoothEnabled,
      target: settings.bluetoothTarget,
      format: settings.bluetoothFormat,
      includeTranslation: settings.bluetoothIncludeTranslation,
      pauseBehavior: settings.bluetoothPauseBehavior,
      bluetooth: true,
    );

    if (fields.isEmpty) return null;
    return LyricMetadataOverride(
      title: fields[LyricsMetadataTarget.title],
      artist: fields[LyricsMetadataTarget.artist],
      album: fields[LyricsMetadataTarget.album],
      displaySubtitle: fields[LyricsMetadataTarget.subtitle],
    );
  }

  String? _textOf(
    LyricsPresentation presentation, {
    required LyricsMetadataFormat format,
    required bool includeTranslation,
    required LyricsPauseBehavior pauseBehavior,
  }) {
    if (!presentation.hasLyrics) return null;
    if (!presentation.isPlaying) {
      switch (pauseBehavior) {
        case LyricsPauseBehavior.clear:
          return null;
        case LyricsPauseBehavior.title:
          return presentation.title.isEmpty ? null : presentation.title;
        case LyricsPauseBehavior.keep:
          break;
      }
    }
    var text = presentation.line;
    if (text.isEmpty) return null; // 前奏 / 间奏：保持原始元数据
    if (includeTranslation && presentation.extended.isNotEmpty) {
      text = '$text / ${presentation.extended.join(' / ')}';
    }
    switch (format) {
      case LyricsMetadataFormat.lyric:
        return text;
      case LyricsMetadataFormat.lyricTitle:
        return presentation.title.isEmpty ? text : '$text · ${presentation.title}';
      case LyricsMetadataFormat.titleLyric:
        return presentation.title.isEmpty ? text : '${presentation.title} · $text';
    }
  }
}
