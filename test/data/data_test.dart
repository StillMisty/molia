import 'package:flutter_test/flutter_test.dart';

import 'app_data_directory_cases.dart' as data_app_data_directory;
import 'device_settings_cases.dart' as data_device_settings;
import 'favorite_fact_cases.dart' as data_favorite_fact;
import 'playback_session_repository_cases.dart'
    as data_playback_session_repository;
import 'public_downloads_path_cases.dart' as data_public_downloads_path;
import 'settings_module_cases.dart' as data_settings_module;
import '../drift/molia/migration_cases.dart' as drift_molia_migration;

void main() {
  group('app data directory', data_app_data_directory.main);
  group('device settings', data_device_settings.main);
  group('favorite fact', data_favorite_fact.main);
  group('playback session repository', data_playback_session_repository.main);
  group('public downloads path', data_public_downloads_path.main);
  group('settings module', data_settings_module.main);
  group('migration', drift_molia_migration.main);
}
