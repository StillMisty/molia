import 'package:flutter_test/flutter_test.dart';

import 'desktop_quit_commit_cases.dart' as desktop_quit_commit;
import 'frame_stats_cases.dart' as frame_stats;
import 'incoming_pairing_queue_cases.dart' as incoming_pairing_queue;
import 'lyrics_session_wiring_cases.dart' as lyrics_session_wiring;
import 'perf_app_harness_cases.dart' as perf_app_harness;
import 'tray_dormant_gate_cases.dart' as tray_dormant_gate;

void main() {
  group('desktop quit commit', desktop_quit_commit.main);
  group('frame stats', frame_stats.main);
  group('incoming pairing queue', incoming_pairing_queue.main);
  group('lyrics session wiring', lyrics_session_wiring.main);
  group('perf app harness', perf_app_harness.main);
  group('tray dormant gate', tray_dormant_gate.main);
}
