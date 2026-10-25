import 'package:flutter_test/flutter_test.dart';

import 'lyric_color_resolver_cases.dart' as lyric_color_resolver;
import 'lyric_timing_policy_cases.dart' as lyric_timing_policy;
import 'lyrics_poster_service_cases.dart' as lyrics_poster_service;
import 'song_match_cases.dart' as song_match;

void main() {
  group('lyric color resolver', lyric_color_resolver.main);
  group('lyric timing policy', lyric_timing_policy.main);
  group('lyrics poster service', lyrics_poster_service.main);
  group('song match', song_match.main);
}
