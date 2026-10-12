import 'package:flutter_test/flutter_test.dart';
import 'package:molia/utils/html_unescape/html_unescape.dart';

/// 收编的 html_unescape（见 lib/utils/html_unescape/）行为锁定：
/// 命名实体 / 数字引用 / 非实体文本透传 / 混合串。
void main() {
  final unescape = HtmlUnescape();

  group('命名实体', () {
    test('常见实体', () {
      expect(unescape.convert('&amp;'), '&');
      expect(unescape.convert('&lt;'), '<');
      expect(unescape.convert('&gt;'), '>');
      expect(unescape.convert('&quot;'), '"');
      expect(unescape.convert('&apos;'), "'");
    });

    test('使用全量字符表的生僻实体', () {
      expect(unescape.convert('&copy;'), '©');
      expect(unescape.convert('&reg;'), '®');
      expect(unescape.convert('&nbsp;'), '\u00a0');
      expect(unescape.convert('&hellip;'), '…');
      expect(unescape.convert('&mdash;'), '—');
      expect(unescape.convert('&pm;'), '±');
    });
  });

  group('数字引用', () {
    test('十进制', () {
      expect(unescape.convert('&#39;'), "'");
      expect(unescape.convert('&#233;'), 'é');
      expect(unescape.convert('&#22909;'), '好');
    });

    test('十六进制（大小写均可）', () {
      expect(unescape.convert('&#xE9;'), 'é');
      expect(unescape.convert('&#xe9;'), 'é');
      expect(unescape.convert('&#x2764;'), '❤');
    });
  });

  group('透传与边界', () {
    test('不含实体的文本原样返回', () {
      expect(unescape.convert('plain text'), 'plain text');
      expect(unescape.convert(''), '');
    });

    test('裸 & / 未知实体 / 缺分号数字引用原样透传', () {
      expect(unescape.convert('Tom & Jerry'), 'Tom & Jerry');
      expect(unescape.convert('AT&T'), 'AT&T');
      expect(unescape.convert('&unknown;'), '&unknown;');
      expect(unescape.convert('&#xE9'), '&#xE9');
    });

    test('HTML5 遗留的无分号实体会被解析', () {
      // 无分号遗留写法同样在全量表中，属上游既有行为。
      expect(unescape.convert('&amp'), '&');
      expect(unescape.convert('&copy'), '©');
      expect(unescape.convert('&quot'), '"');
    });
  });

  test('混合串', () {
    expect(
      unescape.convert('A &amp; B &copy; 2026 &#x2764; &apos;ok&apos;'),
      "A & B © 2026 ❤ 'ok'",
    );
    expect(
      unescape.convert('&lt;b&gt;加粗&lt;/b&gt; &hellip; Tom & Jerry'),
      '<b>加粗</b> … Tom & Jerry',
    );
  });
}
