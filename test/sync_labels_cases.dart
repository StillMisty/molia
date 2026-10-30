import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:molia/domain/ports/sync_transport.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/pages/sync_dialogs.dart';
import 'package:molia/pages/sync_labels.dart';
import 'package:molia/providers/sync_nearby_availability.dart';

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
    // 迭代 SyncIssueCode.all：新增原因码忘记补文案时这里会红。
    for (final locale in const [Locale('zh'), Locale('en')]) {
      final l10n = lookupAppLocalizations(locale);
      for (final code in SyncIssueCode.all) {
        final text = syncIssueText(l10n, SyncIssue(code: code));
        expect(text, isNotEmpty, reason: '$locale/$code');
        if (code != SyncIssueCode.unknown) {
          expect(text, isNot(l10n.syncIssueUnknown), reason: '$locale/$code');
        }
      }
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
    // 探测端口不可用：与广播失败同组，给手动地址 / WebDAV / 重试三条出路。
    expect(
      syncIssueActions(
          const SyncIssue(code: SyncIssueCode.probePortUnavailable)),
      containsAll([
        SyncIssueAction.addManualPeer,
        SyncIssueAction.useWebdav,
        SyncIssueAction.retry,
      ]),
    );
    // 未配置 WebDAV：主推荐是「去配置」（末位 = filled），重试只作次要出口。
    expect(
      syncIssueActions(const SyncIssue(code: SyncIssueCode.notConfigured)).last,
      SyncIssueAction.configureWebdav,
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

    // 传输缺失（args 可能不带该参数）按局域网处理：至少给出手动地址这条路。
    expect(
      syncIssueActions(
          const SyncIssue(code: SyncIssueCode.allPeersUnreachable)),
      contains(SyncIssueAction.addManualPeer),
    );
  });

  test('附近设备可用性：优先级与每种状态都有专属文案', () {
    SyncNearbyAvailability resolve({
      bool lanEnabled = true,
      bool permissionDenied = false,
      bool transportRunning = true,
      bool transportUnavailable = false,
      bool discoveryAvailable = true,
      bool pairingAvailable = true,
      bool onCellular = false,
      bool powerSaveActive = false,
    }) =>
        resolveSyncNearbyAvailability(
          lanEnabled: lanEnabled,
          permissionDenied: permissionDenied,
          transportRunning: transportRunning,
          transportUnavailable: transportUnavailable,
          discoveryAvailable: discoveryAvailable,
          pairingAvailable: pairingAvailable,
          onCellular: onCellular,
          powerSaveActive: powerSaveActive,
        );

    // 本机未就绪 > 策略暂停 > 能力降级 > 可用。
    expect(
      resolve(permissionDenied: true, lanEnabled: false),
      SyncNearbyAvailability.permissionDenied,
    );
    expect(resolve(lanEnabled: false), SyncNearbyAvailability.lanOff);
    expect(
      resolve(transportRunning: false),
      SyncNearbyAvailability.transportUnavailable,
    );
    expect(
      resolve(transportUnavailable: true),
      SyncNearbyAvailability.transportUnavailable,
    );
    expect(resolve(onCellular: true), SyncNearbyAvailability.cellular);
    expect(
      resolve(onCellular: true, powerSaveActive: true),
      SyncNearbyAvailability.cellular,
      reason: '移动数据比省电更具体：先提示切 Wi-Fi',
    );
    expect(
      resolve(powerSaveActive: true),
      SyncNearbyAvailability.powerSave,
    );
    expect(
      resolve(discoveryAvailable: false, pairingAvailable: false),
      SyncNearbyAvailability.discoveryUnavailable,
    );
    expect(
      resolve(pairingAvailable: false),
      SyncNearbyAvailability.pairingUnavailable,
    );
    expect(resolve(), SyncNearbyAvailability.available);

    // 除 available 外每种状态都有非空标题 / 副标题，且标题互不重复。
    final titles = <String>{};
    for (final locale in const [Locale('zh'), Locale('en')]) {
      final l10n = lookupAppLocalizations(locale);
      for (final availability in SyncNearbyAvailability.values) {
        final copy = syncNearbyAvailabilityCopy(l10n, availability);
        if (availability == SyncNearbyAvailability.available) {
          expect(copy, isNull);
          continue;
        }
        expect(copy, isNotNull, reason: '$locale/$availability');
        expect(copy!.title, isNotEmpty, reason: '$locale/$availability');
        expect(copy.subtitle, isNotEmpty, reason: '$locale/$availability');
      }
      final localeTitles = {
        for (final availability in SyncNearbyAvailability.values)
          if (availability != SyncNearbyAvailability.available)
            syncNearbyAvailabilityCopy(l10n, availability)!.title,
      };
      expect(localeTitles, hasLength(SyncNearbyAvailability.values.length - 1));
      titles.addAll(localeTitles);
    }
    expect(titles, hasLength((SyncNearbyAvailability.values.length - 1) * 2));
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
