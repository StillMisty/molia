import 'package:flutter_test/flutter_test.dart';

import 'artwork_resolver_cases.dart' as artwork_resolver;
import 'audio_cache_source_cases.dart' as audio_cache_source;
import 'audio_focus_policy_cases.dart' as audio_focus_policy;
import 'audio_output_policy_cases.dart' as audio_output_policy;
import 'local_playback_shutdown_cases.dart' as local_playback_shutdown;
import 'playback_power_policy_cases.dart' as playback_power_policy;

void main() {
  group('artwork resolver', artwork_resolver.main);
  group('audio cache source', audio_cache_source.main);
  group('audio focus policy', audio_focus_policy.main);
  group('audio output policy', audio_output_policy.main);
  group('local playback shutdown', local_playback_shutdown.main);
  group('playback power policy', playback_power_policy.main);
}
