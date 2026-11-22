import 'package:flutter_test/flutter_test.dart';

import 'library_browse_cases.dart' as library_browse;
import 'library_collections_cases.dart' as library_collections;
import 'library_provider_cases.dart' as library_provider;
import 'library_read_model_cases.dart' as library_read_model;
import 'library_repository_cases.dart' as library_repository;
import 'library_write_engine_cases.dart' as library_write_engine;
import 'local_library_cases.dart' as local_library;

void main() {
  group('library browse', library_browse.main);
  group('library collections', library_collections.main);
  group('library provider', library_provider.main);
  group('library read model', library_read_model.main);
  group('library repository', library_repository.main);
  group('library write engine', library_write_engine.main);
  group('local library', local_library.main);
}
