import 'package:flutter_test/flutter_test.dart';

import 'pigeon/download_notifications_adapter_cases.dart'
    as platform_pigeon_download_notifications_adapter;
import 'pigeon/downloads_publisher_adapter_cases.dart'
    as platform_pigeon_downloads_publisher_adapter;
import 'pigeon/saf_adapter_cases.dart' as platform_pigeon_saf_adapter;
import '../data/saf/pigeon_saf_bridge_cases.dart' as data_saf_pigeon_saf_bridge;

void main() {
  group(
    'download notifications adapter',
    platform_pigeon_download_notifications_adapter.main,
  );
  group(
    'downloads publisher adapter',
    platform_pigeon_downloads_publisher_adapter.main,
  );
  group('saf adapter', platform_pigeon_saf_adapter.main);
  group('pigeon saf bridge', data_saf_pigeon_saf_bridge.main);
}
