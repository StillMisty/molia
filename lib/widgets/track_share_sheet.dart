/// 来源行弹层：曲目身份相关的复制 / 分享动作。
///
/// 四项动作（按可得性显隐 / 禁用）：
/// - 复制曲目 ID（`{sourceKey}:{id}`）；
/// - 分享平台页面（内置平台（六个音乐平台 + B 站）可构造 URL，脚本源 / 本地曲目没有）；
/// - 打开平台页面（系统浏览器 / 外部应用）；
/// - 分享歌曲文件（已下载直接分享；未下载则先下载再分享）。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../domain/models/download.dart';
import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../services/notification_service.dart';
import '../services/download/download_intent.dart';
import '../services/download/download_records.dart';
import '../utils/download_failure_label.dart';
import '../utils/responsive.dart';
import 'detail_page/detail_page_chrome.dart';
import 'download_data_saver_guard.dart';
import 'simple_modal_body.dart';

/// 打开来源行弹层（歌曲信息页「来源」行唯一入口）。
Future<void> showTrackShareSheet(BuildContext context, {required Track track}) {
  return ResponsiveNavigation.showSimpleModal<void>(
    context: context,
    title: AppLocalizations.of(context)!.trackInfoSource,
    child: _TrackShareSheet(track: track, pageContext: context),
  );
}

class _TrackShareSheet extends StatelessWidget {
  const _TrackShareSheet({required this.track, required this.pageContext});

  final Track track;

  /// 外层页面 context：弹层关闭后下载动作仍要用它取 l10n / provider / 提示，
  /// 不能继续持有已销毁的弹层 context。
  final BuildContext pageContext;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final notifications = context.read<NotificationService?>();
    final records = context.read<DownloadRecords?>();
    final launcher = context.read<DownloadLauncher?>();
    final pageUrl = track.platformPageUrl;
    final record = records?.recordForTrack(track);
    final trackIdLabel = track.id.uri.isEmpty
        ? l10n.trackInfoSourceUnknownId
        : track.id.uri;

    void message(String text) {
      if (notifications != null) {
        notifications.showSnackBar(text);
      } else {
        M3ESnackbar.show(pageContext, message: text);
      }
    }

    return SimpleModalBody(
      header: DetailPageTrackHeader(
        track: track,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      ),
      children: [
        M3EListItem(
          leading: const Icon(Icons.tag_rounded),
          headline: l10n.trackInfoTrackId,
          supportingText: trackIdLabel,
          onTap: () {
            unawaited(Clipboard.setData(ClipboardData(text: track.id.uri)));
            message(l10n.trackInfoIdCopied);
            Navigator.of(context).pop();
          },
        ),
        M3EListItem(
          leading: const Icon(Icons.link_rounded),
          headline: l10n.sharePlatformPage,
          supportingText: pageUrl == null ? l10n.platformPageUnavailable : null,
          enabled: pageUrl != null,
          onTap: pageUrl == null
              ? null
              : () {
                  Navigator.of(context).pop();
                  unawaited(_shareText(context, pageUrl, message));
                },
        ),
        M3EListItem(
          leading: const Icon(Icons.open_in_new_rounded),
          headline: l10n.openPlatformPage,
          enabled: pageUrl != null,
          onTap: pageUrl == null
              ? null
              : () {
                  Navigator.of(context).pop();
                  unawaited(
                    launchUrl(
                      Uri.parse(pageUrl),
                      mode: LaunchMode.externalApplication,
                    ),
                  );
                },
        ),
        M3EListItem(
          leading: const Icon(Icons.ios_share_rounded),
          headline: record != null
              ? l10n.shareTrackFile
              : l10n.downloadAndShare,
          onTap: () {
            Navigator.of(context).pop();
            unawaited(
              _shareTrackFile(
                pageContext,
                record: record,
                records: records,
                launcher: launcher,
                message: message,
              ),
            );
          },
        ),
      ],
    );
  }

  Future<void> _shareText(
    BuildContext context,
    String text,
    void Function(String) message,
  ) async {
    try {
      await SharePlus.instance.share(ShareParams(text: text));
    } catch (_) {
      if (context.mounted) message(AppLocalizations.of(context)!.exportFailed);
    }
  }

  /// 分享歌曲文件：已有下载记录直接分享；未下载先按偏好音质下载再分享。
  Future<void> _shareTrackFile(
    BuildContext context, {
    required DownloadedTrack? record,
    required DownloadRecords? records,
    required DownloadLauncher? launcher,
    required void Function(String) message,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    var target = record;
    if (target == null) {
      if (launcher == null) {
        message(l10n.downloadUnsupported);
        return;
      }
      // 省流生效先确认；弹层已被关闭，确认框挂 root navigator 并挂在外层
      // 页面上，不依赖已销毁的 sheet context。
      if (!await confirmDownloadOnDataSaver(context)) return;
      if (!context.mounted) return;
      final DownloadStartResult result;
      try {
        result = await launcher.start(track);
      } catch (error) {
        final failure = downloadFailureMessage(l10n, error);
        if (failure != null) message(failure);
        return;
      }
      switch (result) {
        case DownloadAlreadyDownloaded(:final record):
          // 弹层打开后、点按前已由别的入口下完：直接分享现成文件。
          target = record;
        case DownloadUnsupported(:final reason):
          message(downloadFailureLabel(l10n, reason));
          return;
        case DownloadStarted(:final task):
          message(l10n.shareDownloading);
          try {
            await task.done;
          } catch (error) {
            final failure = downloadFailureMessage(l10n, error);
            if (failure != null) message(failure);
            return;
          }
          target = records?.recordForTrack(track);
        case DownloadAlreadyActive(:final task):
          // 已有任务：等它结束再分享，不重复入队。
          message(l10n.shareDownloading);
          try {
            await task.done;
          } catch (error) {
            final failure = downloadFailureMessage(l10n, error);
            if (failure != null) message(failure);
            return;
          }
          target = records?.recordForTrack(track);
      }
      if (target == null) {
        message(l10n.downloadFailed(''));
        return;
      }
    }
    try {
      final path = target.filePath;
      if (path == null || path.isEmpty) {
        message(l10n.downloadFileMissing);
        return;
      }
      await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
    } catch (_) {
      message(l10n.exportFailed);
    }
  }
}
