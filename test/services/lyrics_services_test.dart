import 'package:flutter_test/flutter_test.dart';

import 'desktop_lyrics_output_cases.dart' as services_desktop_lyrics_output;
import 'lyric_color_resolver_cases.dart' as services_lyric_color_resolver;
import 'lyric_timing_policy_cases.dart' as services_lyric_timing_policy;
import 'lyrics_cache_cases.dart' as services_lyrics_cache;
import 'lyrics_display_provider_cases.dart' as services_lyrics_display_provider;
import 'lyrics_poster_service_cases.dart' as services_lyrics_poster_service;
import 'media_lyric_composer_cases.dart' as services_media_lyric_composer;
import 'song_match_cases.dart' as services_song_match;

void main() {
  group('desktop lyrics output', services_desktop_lyrics_output.main);
  group('lyric color resolver', services_lyric_color_resolver.main);
  group('lyric timing policy', services_lyric_timing_policy.main);
  group('lyrics cache', services_lyrics_cache.main);
  group('lyrics display provider', services_lyrics_display_provider.main);
  group('lyrics poster service', services_lyrics_poster_service.main);
  group('media lyric composer', services_media_lyric_composer.main);
  group('song match', services_song_match.main);
}
