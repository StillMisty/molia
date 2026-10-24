import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/http/app_dio.dart';
import 'package:molia/domain/models/comment.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/sources/builtin/bili_api.dart';
import 'package:molia/sources/builtin/bili_comment.dart';
import 'package:molia/sources/builtin/builtin_search.dart';
import 'package:molia/sources/builtin/builtin_transport.dart';
import 'package:molia/sources/builtin/comment_source.dart';

import 'support/mock_dio.dart';

/// B 站评论：热门/最新 mode、游标翻页、嵌套回复、IP 归属地与业务码失败。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BuiltinTransport originalTransport;
  late String fixtureText;

  setUpAll(() => originalTransport = BuiltinSearch.transport);

  setUp(() {
    BiliApi.reset();
    BiliComment.resetForTest();
    fixtureText = File('test/fixtures/bili_comment.json').readAsStringSync();
  });

  tearDown(() {
    BuiltinSearch.transport = originalTransport;
    BiliComment.resetForTest();
  });

  /// 注入评论响应；buvid / WBI 会话请求由这里统一兜底。
  MockDioAdapter install(
    FutureOr<ResponseBody> Function(RequestOptions options) onReply,
  ) {
    final adapter = MockDioAdapter((options) async {
      switch (options.uri.path) {
        case '/x/frontend/finger/spi':
          return textResponse(
            jsonEncode({
              'code': 0,
              'data': {'b_3': 'buvid3-test', 'b_4': 'buvid4-test'},
            }),
          );
        case '/x/web-interface/nav':
          return textResponse(
            jsonEncode({
              'code': -101,
              'data': {
                'wbi_img': {
                  'img_url': 'https://i0.hdslb.com/bfs/wbi/'
                      '7cd084941338484aae1ad9425b84077c.png',
                  'sub_url': 'https://i0.hdslb.com/bfs/wbi/'
                      '4932caff0ff746eab6f01bf08b70ac45.png',
                },
              },
            }),
          );
        case '/x/v2/reply/main':
          return onReply(options);
        default:
          return textResponse('{}', statusCode: 500);
      }
    });
    BuiltinSearch.transport =
        BuiltinTransport(dio: createAppDio(adapter: adapter));
    return adapter;
  }

  test('热门第 1 页：mode=3、无 pagination_str、游标/总数/嵌套回复', () async {
    final adapter = install((options) async => textResponse(fixtureText));

    final page = await BiliComment.fetch('987654', kind: CommentKind.hot);

    final query = adapter.lastRequest.uri.queryParameters;
    expect(query['type'], '1');
    expect(query['oid'], '987654');
    expect(query['mode'], '3');
    expect(query.containsKey('pagination_str'), isFalse, reason: '第一页不带游标');
    expect(query.containsKey('limit'), isFalse, reason: '接口固定 20/页');
    expect(adapter.lastRequest.headers['Referer'], 'https://www.bilibili.com/');
    // 评论接口不能带 buvid Cookie：带 Cookie 时平台只回 3 条热评并置
    // is_end=true（实测），匿名请求才是完整的 20 条/页。
    expect(adapter.lastRequest.headers.containsKey('Cookie'), isFalse);
    expect(
      adapter.requests.map((request) => request.uri.path).toSet(),
      {'/x/v2/reply/main'},
      reason: '评论接口不需要 WBI / buvid，不应先拉会话',
    );

    expect(page.kind, CommentKind.hot);
    expect(page.page, 1);
    expect(page.limit, 20);
    expect(page.total, 42);
    expect(page.hasMore, isTrue);

    final first = page.items.single;
    expect(first.id, '111');
    expect(first.authorName, '甲');
    expect(first.avatarUrl, 'https://i0.hdslb.com/bfs/face/a.jpg');
    expect(first.text, '好听 & 好看 [doge]', reason: 'HTML 转义解码、保留 B 站表情文本');
    expect(first.likedCount, 12);
    expect(first.location, '广东');
    expect(
      first.createdAt,
      DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000),
    );

    expect(first.replies, hasLength(1));
    final reply = first.replies.single;
    expect(reply.id, '112');
    expect(reply.authorName, '乙');
    expect(reply.location, '上海');
    expect(reply.replies, isEmpty, reason: '楼中楼只解析一层，避免无限递归');

    expect(BiliComment.cursorStore.read('bili:987654:hot', 2), 'CURSOR-1');
  });

  test('最新第 2 页：mode=2，带上一页 next_offset 作为 pagination_str', () async {
    final pagination = <String?>[];
    final adapter = install((options) async {
      final value = options.uri.queryParameters['pagination_str'];
      pagination.add(value);
      if (value == null) return textResponse(fixtureText);
      return textResponse(
        jsonEncode({
          'code': 0,
          'data': {
            'cursor': {'all_count': 42, 'is_end': true},
            'replies': [
              {
                'rpid': 222,
                'like': 0,
                'ctime': 1700000200,
                'member': {'uname': '第二页'},
                'content': {'message': '第二页评论'},
              },
            ],
          },
        }),
      );
    });

    final first = await BiliComment.fetch('987654', kind: CommentKind.latest);
    expect(first.page, 1);
    expect(first.hasMore, isTrue);
    expect(adapter.lastRequest.uri.queryParameters['mode'], '2');

    final second = await BiliComment.fetch(
      '987654',
      kind: CommentKind.latest,
      page: 2,
    );

    expect(pagination, hasLength(2));
    expect(pagination.first, isNull, reason: '第一页不带游标');
    expect(
      jsonDecode(pagination.last!)['offset'],
      'CURSOR-1',
      reason: '第 2 页使用第 1 页返回的 next_offset',
    );
    expect(adapter.lastRequest.uri.queryParameters['mode'], '2');
    expect(second.page, 2);
    expect(second.total, 42);
    expect(second.hasMore, isFalse, reason: 'is_end=true 即末页');
    expect(second.items.single.text, '第二页评论');
  });

  test('第 2 页缺少游标：退回首页参数（不带 pagination_str），不抛错', () async {
    final adapter = install((options) async => textResponse(fixtureText));

    final page = await BiliComment.fetch(
      '987654',
      kind: CommentKind.hot,
      page: 2,
    );

    expect(
      adapter.lastRequest.uri.queryParameters.containsKey('pagination_str'),
      isFalse,
      reason: '跳页/状态丢失时从首页重取，重复项由上层去重',
    );
    expect(page.page, 2);
    expect(page.items, isNotEmpty);
  });

  test('replies 为空时回退 hots', () async {
    install((options) async {
      return textResponse(
        jsonEncode({
          'code': 0,
          'data': {
            'cursor': {'all_count': 1, 'is_end': true},
            'replies': [],
            'hots': [
              {
                'rpid': 5,
                'content': {'message': '热评'},
                'member': {'uname': 'A'},
              },
            ],
          },
        }),
      );
    });

    final page = await BiliComment.fetch('1', kind: CommentKind.hot);
    expect(page.items.single.text, '热评');
    expect(page.hasMore, isFalse);
    expect(page.total, 1);
  });

  test('成功响应缺少 cursor / is_end：默认无下一页，避免分页死循环', () async {
    install((options) async {
      return textResponse(
        jsonEncode({
          'code': 0,
          'data': {
            'replies': [
              {
                'rpid': 6,
                'content': {'message': '没有游标'},
                'member': {'uname': 'A'},
              },
            ],
          },
        }),
      );
    });

    final page = await BiliComment.fetch('1', kind: CommentKind.hot);
    expect(page.items.single.text, '没有游标');
    expect(page.hasMore, isFalse);
    expect(BiliComment.cursorStore.read('bili:1:hot', 2), isNull);
  });

  test('code 12002 → SourceFailure(unknown, retryable)', () async {
    install((options) async {
      return textResponse(jsonEncode({'code': 12002, 'message': '禁止'}));
    });

    await expectLater(
      BiliComment.fetch('987654', kind: CommentKind.hot),
      throwsA(
        isA<SourceFailure>()
            .having((f) => f.kind, 'kind', FailureKind.unknown)
            .having((f) => f.retryable, 'retryable', isTrue),
      ),
    );
  });

  test('code -404 → SourceFailure(notFound, 不可重试)', () async {
    install((options) async {
      return textResponse(jsonEncode({'code': -404, 'message': '无'}));
    });

    await expectLater(
      BiliComment.fetch('987654', kind: CommentKind.latest),
      throwsA(
        isA<SourceFailure>()
            .having((f) => f.kind, 'kind', FailureKind.notFound)
            .having((f) => f.retryable, 'retryable', isFalse),
      ),
    );
  });

  test('BuiltinComments 调度：bili 从 raw 的 aid 取评论', () async {
    install((options) async => textResponse(fixtureText));

    final page = await BuiltinComments.fetch(
      'bili',
      const {'bvid': 'BV1xx411c7mD', 'aid': 987654},
      kind: CommentKind.hot,
    );
    expect(page.items.single.id, '111');
  });
}
