import 'package:flutter_test/flutter_test.dart';

import 'lyric_line_tracker_cases.dart' as lyric_line_tracker;
import 'lyrics_match_cases.dart' as lyrics_match;
import 'lyrics_model_cases.dart' as lyrics_model;
import 'lyrics_provider_translation_cases.dart' as lyrics_provider_translation;
import 'lyrics_scroll_policy_cases.dart' as lyrics_scroll_policy;
import 'lyrics_service_cases.dart' as lyrics_service;
import 'lyrics_service_native_cases.dart' as lyrics_service_native;

void main() {
  group('lyric line tracker', lyric_line_tracker.main);
  group('lyrics match', lyrics_match.main);
  group('lyrics model', lyrics_model.main);
  group('lyrics provider translation', lyrics_provider_translation.main);
  group('lyrics scroll policy', lyrics_scroll_policy.main);
  group('lyrics service', lyrics_service.main);
  group('lyrics service native', lyrics_service_native.main);
}
