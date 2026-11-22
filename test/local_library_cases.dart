import 'package:flutter_test/flutter_test.dart';

import 'local_cache_index_store_cases.dart' as local_cache_index_store;
import 'local_identity_cases.dart' as local_identity;
import 'local_library_provider_cases.dart' as local_library_provider;
import 'local_library_ui_cases.dart' as local_library_ui;
import 'local_songs_collection_cases.dart' as local_songs_collection;
import 'raw_models_cases.dart' as raw_models;

void main() {
  group('local cache index store', local_cache_index_store.main);
  group('local identity', local_identity.main);
  group('local library provider', local_library_provider.main);
  group('local library ui', local_library_ui.main);
  group('local songs collection', local_songs_collection.main);
  group('raw models', raw_models.main);
}
