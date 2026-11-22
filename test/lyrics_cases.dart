import 'package:flutter_test/flutter_test.dart';

import 'lyrics_core_cases.dart' as lyrics_core;
import 'lyrics_provider_cases.dart' as lyrics_provider;
import 'lyrics_source_search_session_cases.dart'
    as lyrics_source_search_session;

void main() {
  group('lyrics core', lyrics_core.main);
  group('lyrics provider', lyrics_provider.main);
  group('lyrics source search session', lyrics_source_search_session.main);
}
