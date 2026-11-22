import 'package:flutter_test/flutter_test.dart';

import 'comments_cases.dart' as comments;
import 'database_schema_cases.dart' as database_schema;
import 'download_record_store_cases.dart' as download_record_store;
import 'poster_style_settings_cases.dart' as poster_style_settings;
import 'wy_crypto_cases.dart' as wy_crypto;
import 'theme/theme_cases.dart' as theme_theme;

void main() {
  group('comments', comments.main);
  group('database schema', database_schema.main);
  group('download record store', download_record_store.main);
  group('poster style settings', poster_style_settings.main);
  group('wy crypto', wy_crypto.main);
  group('theme', theme_theme.main);
}
