import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/http/app_dio.dart';
import 'package:molia/domain/models/comment.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/sources/builtin/builtin_search.dart';
import 'package:molia/sources/builtin/builtin_transport.dart';
import 'package:molia/sources/builtin/comment_source.dart';
import 'package:molia/sources/builtin/comment_utils.dart';
import 'package:molia/sources/builtin/crypto_utils.dart';
import 'package:molia/sources/builtin/kg_comment.dart';
import 'package:molia/sources/builtin/kw_comment.dart';
import 'package:molia/sources/builtin/mg_comment.dart';
import 'package:molia/sources/builtin/tx_comment.dart';
import 'package:molia/sources/builtin/wy_comment.dart';

import 'support/mock_dio.dart';

/// 评论取数链路（请求构造 / 分页游标 / 业务码失败）的离线单测：
/// 用 `MockDioAdapter` 拦在真实 socket 之前，不联网。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BuiltinTransport originalTransport;
  setUpAll(() => originalTransport = BuiltinSearch.transport);
  tearDown(() {
    BuiltinSearch.transport = originalTransport;
    WyComment.cursorStore.clear();
    MgComment.cursorStore.clear();
  });

  /// 注入一个「按请求返回响应」的传输层，返回的 adapter 可断言请求。
  MockDioAdapter install(
    FutureOr<ResponseBody> Function(RequestOptions options) handler,
  ) {
    final adapter = MockDioAdapter(handler);
    BuiltinSearch.transport = BuiltinTransport(dio: createAppDio(adapter: adapter));
    return adapter;
  }

  group('kw 酷我', () {
    test('最新评论：type/start/count 分页 + 总数', () async {
      final adapter = install((options) async {
        return textResponse(jsonEncode({
          'code': '200',
          'comments': [
            {
              'id': '1001',
              'msg': '好听',
              'time': '1700000000',
              'u_name': '听友',
              'u_pic': 'http://img/avatar.jpg',
              'like_num': '3',
            },
          ],
          'comments_counts': 42,
        }));
      });

      final page = await KwComment.fetch(
        '228908',
        kind: CommentKind.latest,
        page: 3,
        limit: 20,
      );

      final query = adapter.lastRequest.uri.queryParameters;
      expect(query['type'], 'get_comment');
      expect(query['sid'], '228908');
      expect(query['start'], '40');
      expect(query['count'], '20');
      expect(page.page, 3);
      expect(page.total, 42);
      expect(page.items.single.id, '1001');
      expect(page.items.single.likedCount, 3);
      expect(page.items.single.avatarUrl, 'http://img/avatar.jpg');
    });

    test('热门评论：type=get_rec_comment + hot_comments_counts', () async {
      final adapter = install((options) async {
        return textResponse(jsonEncode({
          'code': '200',
          'hot_comments': [
            {'id': '9', 'msg': '热评', 'time': '1700000000', 'u_name': 'A'},
          ],
          'hot_comments_counts': 7,
        }));
      });

      final page = await KwComment.fetch('1', kind: CommentKind.hot);
      expect(adapter.lastRequest.uri.queryParameters['type'], 'get_rec_comment');
      expect(page.total, 7);
      expect(page.items.single.text, '热评');
    });

    test('业务码非 200：重试耗尽后归一化为可重试失败', () async {
      final adapter = install((options) async {
        return textResponse(jsonEncode({'code': '403'}));
      });

      await expectLater(
        KwComment.fetch('1', kind: CommentKind.latest),
        throwsA(
          isA<SourceFailure>()
              .having((f) => f.kind, 'kind', FailureKind.unknown)
              .having((f) => f.retryable, 'retryable', isTrue),
        ),
      );
      expect(adapter.requests, hasLength(BuiltinTransport.defaultRetries));
    });
  });

  group('kg 酷狗', () {
    test('最新评论：签名 + extdata/schash + p 页码', () async {
      final adapter = install((options) async {
        return textResponse(jsonEncode({
          'err_code': 0,
          'count': 12,
          'list': [
            {
              'id': 5,
              'content': '酷狗评论',
              'addtime': '2024-01-02 03:04:05',
              'user_name': '听友',
              'location': '广东',
              'like': {'likenum': 8},
            },
          ],
        }));
      });

      final page = await KgComment.fetch('HASH1', kind: CommentKind.latest, page: 2);
      final query = adapter.lastRequest.uri.queryParameters;
      expect(query['p'], '2');
      expect(query['extdata'], 'HASH1');
      expect(query['schash'], 'HASH1');
      expect(query['signature'], hasLength(32));
      expect(
        query['signature'],
        kgSignatureParams(
          'dfid=0&mid=16249512204336365674023395779019'
          '&clienttime=${query['clienttime']}&uuid=0&extdata=HASH1&appid=1005'
          '&code=fc4be23b4e972707f36b8a828a93ba8a&schash=HASH1&clientver=11409'
          '&p=2&clienttoken=&pagesize=20&ver=10&kugouid=0',
        ),
      );
      expect(page.total, 12);
      expect(page.items.single.text, '酷狗评论');
      expect(page.items.single.createdAt, DateTime(2024, 1, 2, 3, 4, 5));
      expect(page.items.single.location, '广东');
    });

    test('err_code 非 0：失败', () async {
      install((options) async {
        return textResponse(jsonEncode({'err_code': 30001, 'list': []}));
      });
      await expectLater(
        KgComment.fetch('HASH', kind: CommentKind.hot),
        throwsA(isA<SourceFailure>()),
      );
    });
  });

  group('mg 咪咕', () {
    test('热门评论：hotCommentStart 偏移 + cfgHotCount', () async {
      final adapter = install((options) async {
        return textResponse(jsonEncode({
          'code': '000000',
          'data': {
            'cfgHotCount': 9,
            'hotComments': [
              {
                'commentId': 'c1',
                'commentInfo': '咪咕热评',
                'commentTime': '2024-05-06 07:08',
                'user': {'nickName': 'A', 'smallIcon': 'http://img/s.jpg'},
                'opNumItem': {'thumbNum': 2},
              },
            ],
          },
        }));
      });

      final page = await MgComment.fetch('600908', kind: CommentKind.hot, page: 2);
      final query = adapter.lastRequest.uri.queryParameters;
      expect(query['queryType'], '2');
      expect(query['hotCommentStart'], '20');
      expect(query['resourceId'], '600908');
      expect(page.total, 9);
      expect(page.items.single.text, '咪咕热评');
      expect(page.items.single.avatarUrl, 'http://img/s.jpg');
    });

    test('最新评论：第 2 页带第 1 页最后一条评论 id（游标）', () async {
      String? lastCommentId;
      final adapter = install((options) async {
        lastCommentId = options.uri.queryParameters['commentId'];
        final id = (lastCommentId ?? '').isEmpty ? 'first' : 'second';
        return textResponse(jsonEncode({
          'code': '000000',
          'data': {
            'commentNums': 30,
            'comments': [
              {'commentId': id, 'commentInfo': 'x', 'commentTime': '2024-05-06 07:08'},
            ],
          },
        }));
      });

      await MgComment.fetch('600908', kind: CommentKind.latest);
      expect(adapter.requests, hasLength(1));
      expect(MgComment.cursorStore.read('600908', 2), 'first');
      expect(lastCommentId, isEmpty, reason: '第一页不带游标');

      await MgComment.fetch('600908', kind: CommentKind.latest, page: 2);
      expect(lastCommentId, 'first', reason: '第 2 页带上一页最后一条评论 id');
    });

    test('最新评论：缺游标时失败（不静默返回首页数据）', () async {
      install((options) async => textResponse(jsonEncode({'code': '000000'})));
      await expectLater(
        MgComment.fetch('600908', kind: CommentKind.latest, page: 2),
        throwsA(isA<SourceFailure>()),
      );
    });
  });

  group('wy 网易云', () {
    test('最新评论：响应游标写入下一页 + 第 2 页请求体与第 1 页不同', () async {
      final adapter = install((options) async {
        return textResponse(jsonEncode({
          'code': 200,
          'data': {
            'comments': [
              {'commentId': 'c1', 'content': '好听', 'time': 1700000000000},
            ],
            'totalCount': 30,
            'cursor': 'CURSOR-1',
          },
        }));
      });

      final first = await WyComment.fetch('186016', kind: CommentKind.latest);
      expect(first.total, 30);
      expect(first.items.single.text, '好听');
      expect(WyComment.cursorStore.read('186016', 2), 'CURSOR-1');
      final firstBody = requestBodyText(adapter.lastRequest);

      await WyComment.fetch('186016', kind: CommentKind.latest, page: 2);
      final secondBody = requestBodyText(adapter.lastRequest);
      expect(secondBody, isNot(firstBody), reason: '第 2 页使用第 1 页返回的游标');
    });

    test('热门评论：热门接口 + total', () async {
      final adapter = install((options) async {
        return textResponse(jsonEncode({
          'code': 200,
          'hotComments': [
            {'commentId': 'h1', 'content': '热评', 'time': 1700000000000},
          ],
          'total': 5,
        }));
      });

      final page = await WyComment.fetch('186016', kind: CommentKind.hot);
      expect(adapter.lastRequest.uri.path, contains('hotcomments'));
      expect(page.total, 5);
      expect(page.items.single.text, '热评');
    });

    test('code 非 200：失败', () async {
      install((options) async => textResponse(jsonEncode({'code': 250})));
      await expectLater(
        WyComment.fetch('1', kind: CommentKind.latest),
        throwsA(isA<SourceFailure>()),
      );
    });
  });

  group('tx QQ 音乐', () {
    test('热门评论：PageNum 偏移 + Total', () async {
      final adapter = install((options) async {
        return textResponse(jsonEncode({
          'code': 0,
          'req': {
            'code': 0,
            'data': {
              'CommentList': {
                'Total': 88,
                'Comments': [
                  {'SeqNo': 's1', 'CmId': 'm1', 'Content': '热评', 'PubTime': 1700000000},
                ],
              },
            },
          },
        }));
      });

      final page = await TxComment.fetch('97773', kind: CommentKind.hot, page: 2);
      final body = jsonDecode(requestBodyText(adapter.lastRequest)) as Map;
      final req = body['req'] as Map;
      expect((req['param'] as Map)['BizId'], '97773');
      expect((req['param'] as Map)['PageNum'], 1);
      expect((req['param'] as Map)['PageSize'], 20);
      expect(page.total, 88);
      expect(page.items.single.text, '热评');
      expect(page.items.single.id, 's1_m1');
    });

    test('最新评论：表单 pagenum 偏移 + commenttotal', () async {
      final adapter = install((options) async {
        return textResponse(jsonEncode({
          'code': 0,
          'comment': {
            'commenttotal': 230665,
            'commentlist': [
              {
                'rootcommentid': 'r1',
                'commentid': 'c1',
                'rootcommentcontent': '根评论\\n第二行',
                'rootcommentnick': '@甲',
                'time': 1700000000,
              },
            ],
          },
        }));
      });

      final page = await TxComment.fetch('97773', kind: CommentKind.latest, page: 3);
      final form = Uri.splitQueryString(requestBodyText(adapter.lastRequest));
      expect(form['topid'], '97773');
      expect(form['pagenum'], '2');
      expect(form['pagesize'], '20');
      expect(form['cmd'], '8');
      expect(page.total, 230665);
      expect(page.items.single.authorName, '甲');
      expect(page.items.single.text, '根评论\n第二行');
    });

    test('req.code 非 0：失败', () async {
      install((options) async {
        return textResponse(jsonEncode({
          'code': 0,
          'req': {'code': 1000, 'data': <String, dynamic>{}},
        }));
      });
      await expectLater(
        TxComment.fetch('1', kind: CommentKind.hot),
        throwsA(isA<SourceFailure>()),
      );
    });
  });

  group('BuiltinComments 调度', () {
    test('未知平台：unsupported', () async {
      await expectLater(
        BuiltinComments.fetch('lx_custom', const {}, kind: CommentKind.hot),
        throwsA(
          isA<SourceFailure>()
              .having((f) => f.kind, 'kind', FailureKind.unsupported),
        ),
      );
    });

    test('缺少平台 ID：可重试失败（不发请求）', () async {
      final adapter = install((options) async {
        fail('不应发起请求');
      });
      await expectLater(
        BuiltinComments.fetch('kw', const {'name': '无 id'}, kind: CommentKind.hot),
        throwsA(
          isA<SourceFailure>()
              .having((f) => f.kind, 'kind', FailureKind.unknown)
              .having((f) => f.retryable, 'retryable', isTrue),
        ),
      );
      expect(adapter.requests, isEmpty);
    });

    test('能力位：仅五平台内置支持', () {
      for (final key in const ['kw', 'kg', 'tx', 'wy', 'mg']) {
        expect(BuiltinComments.isSupported(key), isTrue, reason: key);
      }
      expect(BuiltinComments.isSupported('any_listen'), isFalse);
      expect(BuiltinComments.isSupported('lx_custom'), isFalse);
    });
  });

  group('CommentCursorStore', () {
    test('按曲目 + 页码读写，保留最近两页，容量满丢最早曲目', () {
      final store = CommentCursorStore(maxSessions: 2);
      store.write('a', 2, 'a2');
      store.write('a', 3, 'a3');
      expect(store.read('a', 2), 'a2');
      expect(store.read('a', 3), 'a3');
      store.write('a', 4, 'a4');
      expect(store.read('a', 2), isNull, reason: '只保留最近两页');
      expect(store.read('a', 3), 'a3');
      expect(store.read('a', 4), 'a4');

      store.write('b', 2, 'b2');
      store.write('c', 2, 'c2');
      expect(store.read('a', 4), isNull, reason: '超出 maxSessions 丢最早曲目');
      expect(store.read('c', 2), 'c2');

      store.write('c', 3, '');
      expect(store.read('c', 3), isNull, reason: '空游标不写入');
      store.clear();
      expect(store.read('c', 2), isNull);
    });
  });
}
