/// 渠道 / 能力 / 当前脚本的只读快照（不读取脚本原文）。
library;

import '../../domain/models/source.dart';
import '../../services/diagnostics/diagnostics_bundle.dart';
import '../../sources/source_manager.dart';

DiagnosticsSourcesSnapshot gatherDiagnosticsSources(SourceManager manager) {
  final notes = <String>[];
  if (!manager.initialized) {
    notes.add('Sources are still loading.');
  }
  final entries = [
    for (final channel in manager.channels)
      DiagnosticsSourceEntry(
        key: channel.key,
        displayName: channel.displayName,
        kind: channel.kind.name,
        enabled: channel.enabled,
        discoverable: channel.discoverable,
        capabilities: _capabilities(channel.capabilities),
      ),
  ];
  final script = manager.activeScript;
  final anyListen = manager.anyListenConfig;
  return DiagnosticsSourcesSnapshot(
    entries: entries,
    activeScriptName: script?.name,
    activeScriptVersion: script?.version,
    activeScriptAuthor: script?.author,
    activeScriptHomepageHost: _hostOf(script?.homepage),
    anyListenConfigured: anyListen.isConfigured,
    anyListenEnabled: anyListen.enabled,
    anyListenHost: _hostOf(anyListen.serverUrl),
    notes: notes,
  );
}

List<String> _capabilities(SourceCapabilities capabilities) => [
  if (capabilities.search) 'search',
  if (capabilities.resolveUrl) 'resolve',
  if (capabilities.lyrics) 'lyrics',
  if (capabilities.artwork) 'artwork',
  if (capabilities.comment) 'comments',
  if (capabilities.collection) 'collection',
  if (capabilities.artist) 'artist',
  if (capabilities.lyricSearch) 'lyricSearch',
  if (capabilities.favorite) 'favorite',
  if (capabilities.lyricsTranslation) 'lyricsTranslation',
];

String? _hostOf(String? raw) {
  final value = raw?.trim() ?? '';
  if (value.isEmpty) return null;
  final uri = Uri.tryParse(value);
  final host = uri?.host ?? '';
  return host.isEmpty ? null : host;
}
