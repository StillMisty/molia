import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/ports/sync_transport.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/sync_dialogs.dart';
import 'package:molia/pages/sync_labels.dart';

/// 失败原因码 → 文案 / 动作映射的回归。
///
/// 关键契约：UI 只展示 [SyncIssueCode] 映射出的本地化文案；
/// [SyncIssue.detail]（原始 `$e`）永远不出现在展示文本里。
Map<String, dynamic> _arb(String name) =>
    jsonDecode(File('lib/l10n/$name').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  test('zh：原因码映射到中文文案，参数生效', () {
    final zh = lookupAppLocalizations(const Locale('zh'));
    expect(
      syncIssueText(zh, const SyncIssue(code: SyncIssueCode.noPassphrase)),
      zh.syncIssueNoPassphrase,
    );
    expect(
      syncIssueText(
        zh,
        const SyncIssue(
          code: SyncIssueCode.applyFailed,
          args: {'count': 3},
        ),
      ),
      contains('3'),
    );
    // 对端标识缺失时用兜底文案，不出现空串 / null。
    final peerText =
        syncIssueText(zh, const SyncIssue(code: SyncIssueCode.peerReadFailed));
    expect(peerText, contains(zh.syncPeerUnknown));
    expect(peerText, isNot(contains('null')));
  });

  test('en：同一原因码映射到英文文案；detail 不参与展示', () {
    final en = lookupAppLocalizations(const Locale('en'));
    expect(
      syncIssueText(en, const SyncIssue(code: SyncIssueCode.noPassphrase)),
      en.syncIssueNoPassphrase,
    );
    final unknown = syncIssueText(
      en,
      const SyncIssue(code: 'not_a_code', detail: 'Bad state: raw \$e'),
    );
    expect(unknown, en.syncIssueUnknown);
    expect(unknown, isNot(contains('Bad state')));
  });

  test('每个原因码都有专属文案（不是 unknown 兜底）', () {
    final zh = lookupAppLocalizations(const Locale('zh'));
    const codes = [
      SyncIssueCode.notConfigured,
      SyncIssueCode.startFailed,
      SyncIssueCode.permissionDenied,
      SyncIssueCode.noPassphrase,
      SyncIssueCode.allPeersUnreachable,
      SyncIssueCode.pullFailed,
      SyncIssueCode.pushFailed,
      SyncIssueCode.applyFailed,
      SyncIssueCode.peerReadFailed,
      SyncIssueCode.peerDecryptFailed,
      SyncIssueCode.peerPushFailed,
      SyncIssueCode.broadcastUnavailable,
      SyncIssueCode.discoverySilent,
      SyncIssueCode.webdavDirFailed,
      SyncIssueCode.webdavListFailed,
      SyncIssueCode.webdavReadFailed,
      SyncIssueCode.webdavDecryptFailed,
      SyncIssueCode.webdavUploadFailed,
    ];
    for (final code in codes) {
      final text = syncIssueText(zh, SyncIssue(code: code));
      expect(text, isNotEmpty, reason: code);
      expect(text, isNot(zh.syncIssueUnknown), reason: code);
    }
  });

  test('失败原因 → 下一步动作：不留死胡同', () {
    expect(
      syncIssueActions(const SyncIssue(code: SyncIssueCode.permissionDenied)),
      contains(SyncIssueAction.useWebdav),
    );
    // 未设口令：主推荐是「配置口令」，重试必败所以不出现。
    expect(
      syncIssueActions(const SyncIssue(code: SyncIssueCode.noPassphrase)),
      [SyncIssueAction.configurePassphrase],
    );
    expect(
      syncIssueActions(const SyncIssue(code: SyncIssueCode.discoverySilent)),
      contains(SyncIssueAction.addManualPeer),
    );
    // 未知原因至少给「重试」。
    expect(
      syncIssueActions(const SyncIssue(code: 'not_a_code')),
      contains(SyncIssueAction.retry),
    );
    expect(syncIssueActions(null), contains(SyncIssueAction.retry));
  });

  test('全不可达按传输分流：WebDAV 不给手动地址，局域网给', () {
    final webdav = syncIssueActions(const SyncIssue(
      code: SyncIssueCode.allPeersUnreachable,
      args: {'transport': SyncTransportKind.webdav},
    ));
    expect(webdav, contains(SyncIssueAction.configureWebdav));
    expect(webdav, isNot(contains(SyncIssueAction.addManualPeer)));

    final lan = syncIssueActions(const SyncIssue(
      code: SyncIssueCode.allPeersUnreachable,
      args: {'transport': SyncTransportKind.lan},
    ));
    expect(lan, contains(SyncIssueAction.addManualPeer));

    // 传输缺失（旧日志条目）按局域网处理：至少给出手动地址这条路。
    expect(
      syncIssueActions(
          const SyncIssue(code: SyncIssueCode.allPeersUnreachable)),
      contains(SyncIssueAction.addManualPeer),
    );
  });

  test('syncIssue* / syncAction* 键在 zh 中齐全（en 为模板）', () {
    final en = _arb('app_en.arb');
    final zh = _arb('app_zh.arb');
    final keys = en.keys
        .where((key) =>
            !key.startsWith('@') &&
            (key.startsWith('syncIssue') || key.startsWith('syncAction')))
        .toList();
    expect(keys, isNotEmpty);
    for (final key in keys) {
      expect(zh[key], isA<String>(), reason: key);
      expect(zh[key], isNotEmpty, reason: key);
    }
  });
}
