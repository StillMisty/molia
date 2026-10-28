import 'package:flutter_test/flutter_test.dart';

import 'cache_storage_io_cases.dart' as cache_storage_io;
import 'download_notifications_cases.dart' as download_notifications;
import 'download_queue_cases.dart' as download_queue;
import 'download_settings_cases.dart' as download_settings;
import 'play_statistics_export_cases.dart' as play_statistics_export;

void main() {
  group('cache storage io', cache_storage_io.main);
  group('download notifications', download_notifications.main);
  group('download queue', download_queue.main);
  group('download settings', download_settings.main);
  group('play statistics export', play_statistics_export.main);
}
