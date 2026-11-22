import 'package:flutter_test/flutter_test.dart';

import 'any_listen_manager_cases.dart' as any_listen_manager;
import 'any_listen_source_cases.dart' as any_listen_source;
import 'channel_selection_cases.dart' as channel_selection;
import 'qq_provider_retry_cases.dart' as qq_provider_retry;
import 'qs_channel_cases.dart' as qs_channel;
import 'source_preferences_cases.dart' as source_preferences;
import 'source_profiles_cases.dart' as source_profiles;
import 'source_quality_cases.dart' as source_quality;
import 'source_routing_cases.dart' as source_routing;
import 'source_swap_provider_cases.dart' as source_swap_provider;
import 'sources_provider_cases.dart' as sources_provider;
import 'sources_search_l10n_cases.dart' as sources_search_l10n;

void main() {
  group('any listen manager', any_listen_manager.main);
  group('any listen source', any_listen_source.main);
  group('channel selection', channel_selection.main);
  group('qq provider retry', qq_provider_retry.main);
  group('qs channel', qs_channel.main);
  group('source preferences', source_preferences.main);
  group('source profiles', source_profiles.main);
  group('source quality', source_quality.main);
  group('source routing', source_routing.main);
  group('source swap provider', source_swap_provider.main);
  group('sources provider', sources_provider.main);
  group('sources search l10n', sources_search_l10n.main);
}
