import 'package:flutter_test/flutter_test.dart';

import 'desktop_audio_output_cases.dart' as playback_desktop_audio_output;
import 'media_session_backend_cases.dart' as playback_media_session_backend;
import 'media_session_pause_session_cases.dart'
    as playback_media_session_pause_session;

void main() {
  group('desktop audio output', playback_desktop_audio_output.main);
  group('media session backend', playback_media_session_backend.main);
  group(
    'media session pause session',
    playback_media_session_pause_session.main,
  );
}
