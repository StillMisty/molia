import 'package:flutter_test/flutter_test.dart';

import 'bili_account_cases.dart' as bili_account;
import 'bili_client_cases.dart' as bili_client;
import 'bili_comment_cases.dart' as bili_comment;
import 'bili_favorites_cases.dart' as bili_favorites;
import 'bili_lyric_cases.dart' as bili_lyric;
import 'bili_misc_cases.dart' as bili_misc;
import 'bili_play_cases.dart' as bili_play;
import 'bili_search_parse_cases.dart' as bili_search_parse;

void main() {
  group('bili account', bili_account.main);
  group('bili client', bili_client.main);
  group('bili comment', bili_comment.main);
  group('bili favorites', bili_favorites.main);
  group('bili lyric', bili_lyric.main);
  group('bili misc', bili_misc.main);
  group('bili play', bili_play.main);
  group('bili search parse', bili_search_parse.main);
}
