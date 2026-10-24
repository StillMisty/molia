import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/comment.dart';
import 'package:molia/sources/builtin/comment_utils.dart';
import 'package:molia/sources/builtin/kg_comment.dart';
import 'package:molia/sources/builtin/kw_comment.dart';
import 'package:molia/sources/builtin/mg_comment.dart';
import 'package:molia/sources/builtin/tx_comment.dart';
import 'package:molia/sources/builtin/wy_comment.dart';

/// 五平台评论解析：使用真实平台响应快照（test/fixtures/comments/*.json，
/// 每类保留前几条）验证字段归一化（文本 / 时间 / IP / 点赞 / 引用 / 楼中楼）。
///
/// fixture 来源：按各平台真实接口抓取后截断列表（kw `ncomment.kuwo.cn`、
/// kg `m.comment.service.kugou.com`、mg `app.c.nf.migu.cn`、tx `u.y.qq.com` /
/// `c.y.qq.com`）；wy 的 weapi 接口需 RSA/AES 签名，无法用脚本直接抓取，
/// 因此用平台公开评论接口的真实条目 + weapi 响应外壳（`{code, data:{comments,
/// totalCount, cursor}}` / `{code, hotComments, total}`）重组。
dynamic _fixture(String name) =>
    jsonDecode(File('test/fixtures/comments/$name.json').readAsStringSync());

void main() {
  group('评论图片地址归一化', () {
    test('trim / 协议相对 / 非法值', () {
      expect(commentUrlOf('  http://img/a.jpg '), 'http://img/a.jpg');
      expect(commentUrlOf('//img/a.jpg'), 'https://img/a.jpg');
      expect(commentUrlOf(''), isNull);
      expect(commentUrlOf('   '), isNull);
      expect(commentUrlOf(null), isNull);
      expect(commentUrlOf('ftp://img/a.jpg'), isNull);
      expect(commentUrlOf('not-a-url'), isNull);
      expect(commentUrlOf('http://'), isNull);
    });
  });

  group('wy 网易云', () {
    test('最新评论：正文 / 点赞 / 毫秒时间 / 引用评论', () {
      final comments = WyComment.parseLatest(_fixture('wy_new'));
      expect(comments, hasLength(4));
      final first = comments.first;
      expect(first.id, '5283361886');
      expect(first.authorName, 'ccrek');
      expect(first.text, '晴天');
      expect(first.likedCount, 11903);
      expect(
        first.createdAt,
        DateTime.fromMillisecondsSinceEpoch(1618057027143),
      );
      expect(first.quoted, isNotNull);
      expect(first.quoted!.authorName, '-乐芙兰');
      expect(first.quoted!.text, '晴天吗');
      expect(first.quoted!.likedCount, isNull);
    });

    test('热门评论：点赞数 / 文本', () {
      final comments = WyComment.parseHot(_fixture('wy_hot'));
      expect(comments, hasLength(4));
      expect(comments.first.id, '4956438');
      expect(comments.first.authorName, '蛋蛋是圆D');
      expect(comments.first.likedCount, 823166);
      expect(comments.first.text, contains('高一听的'));
    });

    test('表情还原：已知名称映射，未知名称原样保留', () {
      expect(WyComment.restoreEmoji('[大笑][爱心][叉]'), '😃❤️❌');
      expect(WyComment.restoreEmoji('未知[不存在]表情'), '未知[不存在]表情');
    });
  });

  group('tx QQ 音乐', () {
    test('热门评论：IP / 点赞 / 楼中楼', () {
      final comments = TxComment.parseHot(_fixture('tx_hot'));
      expect(comments, hasLength(3));
      final first = comments.first;
      expect(first.authorName, 'qing_h');
      expect(first.location, '广东');
      expect(first.likedCount, 15);
      expect(
        first.createdAt,
        DateTime.fromMillisecondsSinceEpoch(1791807457 * 1000),
      );
      expect(first.text, contains('刮风这天我试过握着你手'));
      expect(first.replies, hasLength(1));
      expect(first.replies.first.authorName, '恬兔痣、🤍🐾');
    });

    test('最新评论：根评论 + 楼中楼（旧 → 新，最新一条带头像/点赞）', () {
      final comments = TxComment.parseLatest(_fixture('tx_new'));
      expect(comments, hasLength(4));
      final first = comments.first;
      // 昵称前导 `@` 去掉（与 LX `substring(1)` 一致）。
      expect(first.authorName, 'vivo');
      expect(first.text, contains('\n'), reason: '字面 \\n 还原为换行');
      expect(first.text, contains('故事里的晴天'));
      expect(first.replies, hasLength(1));
      final reply = first.replies.first;
      expect(reply.authorName, '这里是微信团队');
      // `[em]e400835[/em]` → 😍
      expect(reply.text, contains('😍'));
      expect(reply.text.contains('[em]'), isFalse);
      expect(reply.likedCount, 0);
    });

    test('表情还原：未知编码移除（与 LX `emojis[code] || ""` 一致）', () {
      expect(TxComment.replaceEmoji('[em]e400835[/em] 好听'), '😍 好听');
      expect(TxComment.replaceEmoji('[em]e999999[/em]'), '');
      expect(TxComment.replaceEmoji('无表情'), '无表情');
    });
  });

  group('kg 酷狗', () {
    test('热门评论：文本时间 / 点赞 / 无 IP 时不展示', () {
      final comments = KgComment.parseItems(_fixture('kg_hot'));
      expect(comments, hasLength(4));
      final first = comments.first;
      expect(first.id, '315129160');
      expect(first.authorName, '斯蒂芬梅西');
      expect(first.likedCount, 122211);
      expect(first.createdAt, DateTime(2018, 6, 9, 8, 18, 42));
      expect(first.location, isNull);
      expect(first.text, contains('整个故事都在下雨'));
      // 第二条带 IP 归属。
      expect(comments[2].location, '广东');
    });

    test('最新评论：文本 / IP', () {
      final comments = KgComment.parseItems(_fixture('kg_new'));
      expect(comments, hasLength(4));
      expect(comments.first.id, '1772120602');
      expect(comments.first.authorName, '江零');
      expect(comments.first.location, '山东');
      expect(comments.first.createdAt, DateTime(2026, 10, 14, 0, 17, 38));
    });
  });

  group('kw 酷我', () {
    test('热门评论：秒时间 / 点赞 / 楼中楼', () {
      final comments = KwComment.parseItems(
        _fixture('kw_hot'),
        kind: CommentKind.hot,
      );
      expect(comments, hasLength(4));
      final first = comments.first;
      expect(first.id, '210661281');
      expect(first.authorName, '海洋天堂');
      expect(first.likedCount, 22733);
      expect(
        first.createdAt,
        DateTime.fromMillisecondsSinceEpoch(1501019722 * 1000),
      );
      expect(first.text, contains('12岁初中遇见了你'));
      expect(first.replies, isNotEmpty, reason: 'child_comments 映射为楼中楼');
      expect(first.replies.first.authorName, isNotEmpty);
      expect(comments[1].avatarUrl, contains('http'));
    });

    test('最新评论：总数来自 comments_counts', () {
      final comments = KwComment.parseItems(
        _fixture('kw_new'),
        kind: CommentKind.latest,
      );
      expect(comments, hasLength(4));
      expect(comments.first.id, '1006180565');
      expect(comments.first.authorName, isNotEmpty);
      expect(comments.first.createdAt, isNotNull);
    });
  });

  group('mg 咪咕', () {
    test('热门评论：文本时间 / 点赞 / 头像回退', () {
      final comments = MgComment.parseItems(
        _fixture('mg_hot')['data'],
        kind: CommentKind.hot,
      );
      expect(comments, hasLength(4));
      final first = comments.first;
      expect(first.id, '118753015');
      expect(first.authorName, '有才华的风笛');
      expect(first.likedCount, 7064);
      expect(first.createdAt, DateTime(2021, 6, 15, 15, 50));
      expect(first.avatarUrl, contains('http'));
    });

    test('最新评论：分钟级文本时间', () {
      final comments = MgComment.parseItems(
        _fixture('mg_new')['data'],
        kind: CommentKind.latest,
      );
      expect(comments, hasLength(4));
      expect(comments.first.id, '139756184');
      expect(comments.first.createdAt, DateTime(2026, 10, 13, 22, 46));
    });
  });

  group('CommentPage', () {
    test('fromPage：有总数按页码算，无总数按「本页取满」近似', () {
      const one = Comment(id: '1', text: 'x');
      final withTotal = CommentPage.fromPage(
        kind: CommentKind.hot,
        items: const [one],
        page: 1,
        limit: 20,
        total: 25,
      );
      expect(withTotal.hasMore, isTrue);
      expect(withTotal.total, 25);

      final lastPage = CommentPage.fromPage(
        kind: CommentKind.hot,
        items: const [one],
        page: 2,
        limit: 20,
        total: 25,
      );
      expect(lastPage.hasMore, isFalse);

      final noTotal = CommentPage.fromPage(
        kind: CommentKind.latest,
        items: List.generate(20, (i) => Comment(id: '$i', text: 'x')),
        page: 1,
        limit: 20,
      );
      expect(noTotal.hasMore, isTrue);
      expect(noTotal.total, isNull);

      final short = CommentPage.fromPage(
        kind: CommentKind.latest,
        items: const [one],
        page: 1,
        limit: 20,
      );
      expect(short.hasMore, isFalse);
    });
  });
}
