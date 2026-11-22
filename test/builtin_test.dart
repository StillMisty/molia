import 'package:flutter_test/flutter_test.dart';

import 'builtin_album_fetch_cases.dart' as builtin_album_fetch;
import 'builtin_album_parse_cases.dart' as builtin_album_parse;
import 'builtin_artist_parse_cases.dart' as builtin_artist_parse;
import 'builtin_channels_cases.dart' as builtin_channels;
import 'builtin_comment_fetch_cases.dart' as builtin_comment_fetch;
import 'builtin_comment_parse_cases.dart' as builtin_comment_parse;
import 'builtin_discover_cache_ratchet_cases.dart'
    as builtin_discover_cache_ratchet;
import 'builtin_lyric_dispatch_cases.dart' as builtin_lyric_dispatch;
import 'builtin_misc_cases.dart' as builtin_misc;
import 'bili_cases.dart' as bili;
import 'lyrics_cases.dart' as lyrics;

void main() {
  group('builtin album fetch', builtin_album_fetch.main);
  group('builtin album parse', builtin_album_parse.main);
  group('builtin artist parse', builtin_artist_parse.main);
  group('builtin channels', builtin_channels.main);
  group('builtin comment fetch', builtin_comment_fetch.main);
  group('builtin comment parse', builtin_comment_parse.main);
  group('builtin discover cache ratchet', builtin_discover_cache_ratchet.main);
  group('builtin lyric dispatch', builtin_lyric_dispatch.main);
  group('builtin misc', builtin_misc.main);
  group('bili', bili.main);
  group('lyrics', lyrics.main);
}
