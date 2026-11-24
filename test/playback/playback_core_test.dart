import 'package:flutter_test/flutter_test.dart';

import 'audio_focus_guard_cases.dart' as playback_audio_focus_guard;
import 'auto_source_swap_cases.dart' as playback_auto_source_swap;
import 'fade_envelope_cases.dart' as playback_fade_envelope;
import 'play_order_cases.dart' as playback_play_order;
import 'playback_audio_cases.dart' as playback_playback_audio;
import 'playback_engine_cases.dart' as playback_playback_engine;
import 'playback_queue_cases.dart' as playback_playback_queue;
import 'playback_snapshot_bridge_cases.dart' as playback_snapshot_bridge;
import 'position_channel_cases.dart' as playback_position_channel;
import 'media_session_cases.dart' as playback_media_session;

void main() {
  group('audio focus guard', playback_audio_focus_guard.main);
  group('auto source swap', playback_auto_source_swap.main);
  group('fade envelope', playback_fade_envelope.main);
  group('play order', playback_play_order.main);
  group('playback audio', playback_playback_audio.main);
  group('playback engine', playback_playback_engine.main);
  group('playback queue', playback_playback_queue.main);
  group('snapshot bridge', playback_snapshot_bridge.main);
  group('position channel', playback_position_channel.main);
  group('media session', playback_media_session.main);
}
