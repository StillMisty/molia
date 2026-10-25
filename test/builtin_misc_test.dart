import 'package:flutter_test/flutter_test.dart';

import 'builtin_cached_retry_cases.dart' as builtin_cached_retry;
import 'builtin_lyric_decode_cases.dart' as builtin_lyric_decode;
import 'builtin_lyric_search_parse_cases.dart' as builtin_lyric_search_parse;
import 'builtin_pic_dispatch_cases.dart' as builtin_pic_dispatch;
import 'builtin_search_parse_cases.dart' as builtin_search_parse;
import 'builtin_search_runner_cases.dart' as builtin_search_runner;
import 'builtin_track_builders_cases.dart' as builtin_track_builders;
import 'builtin_transport_cases.dart' as builtin_transport;

void main() {
  group('builtin cached retry', builtin_cached_retry.main);
  group('builtin lyric decode', builtin_lyric_decode.main);
  group('builtin lyric search parse', builtin_lyric_search_parse.main);
  group('builtin pic dispatch', builtin_pic_dispatch.main);
  group('builtin search parse', builtin_search_parse.main);
  group('builtin search runner', builtin_search_runner.main);
  group('builtin track builders', builtin_track_builders.main);
  group('builtin transport', builtin_transport.main);
}
