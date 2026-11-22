import 'package:flutter_test/flutter_test.dart';

import 'media_session_copy_cases.dart' as media_session_copy;
import 'playing_track_cache_writer_cases.dart' as playing_track_cache_writer;
import 'queue_navigation_cases.dart' as queue_navigation;
import 'queue_projection_cases.dart' as queue_projection;
import 'replace_queue_track_cases.dart' as replace_queue_track;

void main() {
  group('media session copy', media_session_copy.main);
  group('playing track cache writer', playing_track_cache_writer.main);
  group('queue navigation', queue_navigation.main);
  group('queue projection', queue_projection.main);
  group('replace queue track', replace_queue_track.main);
}
