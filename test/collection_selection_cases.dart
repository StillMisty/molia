import 'package:flutter_test/flutter_test.dart';
import 'package:molia/utils/collection_selection.dart';

/// 合集多选状态机：按行 key 的选择、修饰键语义（锚点 / 区间）、提取与
/// 全选三态的行为钉死。
void main() {
  late CollectionSelection selection;

  setUp(() {
    selection = CollectionSelection();
  });

  tearDown(() => selection.dispose());

  List<String> visible([List<String>? keys]) =>
      keys ?? const ['a', 'b', 'c', 'd', 'e'];

  test('Ctrl 点击切换并移动锚点；连续 Shift 只调整区间端点', () {
    expect(
      selection.applyModifiers(
        'b',
        visibleKeys: visible(),
        ctrl: true,
        shift: false,
      ),
      isTrue,
    );
    expect(selection.selectedKeys, {'b'});

    // Shift 到 d：区间 [b,d]。
    expect(
      selection.applyModifiers(
        'd',
        visibleKeys: visible(),
        ctrl: false,
        shift: true,
      ),
      isTrue,
    );
    expect(selection.selectedKeys, {'b', 'c', 'd'});

    // 连续 Shift 到 c：锚点仍是 b，区间缩回 [b,c]。
    expect(
      selection.applyModifiers(
        'c',
        visibleKeys: visible(),
        ctrl: false,
        shift: true,
      ),
      isTrue,
    );
    expect(selection.selectedKeys, {'b', 'c'});

    // 普通点击移动锚点到 e（返回 false = 未接管）；Shift 到 b → [b,e]。
    expect(
      selection.applyModifiers(
        'e',
        visibleKeys: visible(),
        ctrl: false,
        shift: false,
      ),
      isFalse,
    );
    expect(
      selection.applyModifiers(
        'b',
        visibleKeys: visible(),
        ctrl: false,
        shift: true,
      ),
      isTrue,
    );
    expect(selection.selectedKeys, {'b', 'c', 'd', 'e'});
  });

  test('Shift 反向区间与锚点已不在可见行时退化为单选', () {
    // 无锚点：Shift 退化为单选当前行并落锚。
    expect(
      selection.applyModifiers(
        'd',
        visibleKeys: visible(),
        ctrl: false,
        shift: true,
      ),
      isTrue,
    );
    expect(selection.selectedKeys, {'d'});

    // 锚点 d，Shift 到 b：反向区间 [b,d]。
    expect(
      selection.applyModifiers(
        'b',
        visibleKeys: visible(),
        ctrl: false,
        shift: true,
      ),
      isTrue,
    );
    expect(selection.selectedKeys, {'b', 'c', 'd'});

    // 锚点 d 已不在可见行（列表变短到 a/b）：退化为单选当前行。
    expect(
      selection.applyModifiers(
        'a',
        visibleKeys: visible(['a', 'b']),
        ctrl: false,
        shift: true,
      ),
      isTrue,
    );
    expect(selection.selectedKeys, {'a'});
  });

  test('全选三态与 selectAll', () {
    expect(selection.allSelectedFor(visible()), isFalse);
    selection.select('a');
    expect(selection.allSelectedFor(visible()), isNull);
    selection.selectAll(visible());
    expect(selection.selectedKeys, {'a', 'b', 'c', 'd', 'e'});
    expect(selection.selectedCount, 5);
    expect(selection.allSelectedFor(visible()), isTrue);
    expect(selection.allSelectedFor(const <String>[]), isFalse);
  });

  test('selectedFrom 按可见顺序提取，未可见 / 不存在的 key 忽略', () {
    selection.select('a');
    selection.select('c');
    expect(
      selection.selectedFrom(['a', 'b', 'c'], keyOf: (row) => row),
      ['a', 'c'],
    );
    expect(
      selection.selectedFrom(['c', 'a'], keyOf: (row) => row),
      ['c', 'a'],
      reason: '提取顺序跟可见行，不跟选择顺序',
    );
    expect(selection.selectedFrom(['a'], keyOf: (row) => row), ['a']);
    expect(
      selection.selectedFrom(const <String>[], keyOf: (row) => row),
      isEmpty,
    );
  });

  test('retainKeys：选择跟随行 key 存活，插入不漂移、删除即失效', () {
    selection.selectAll(['a', 'b']);

    // 历史前插新行：a / b 仍指向原来那两行，新行不会被误选。
    selection.retainKeys(['new', 'a', 'b']);
    expect(selection.selectedKeys, {'a', 'b'});
    expect(
      selection.selectedFrom(['new', 'a', 'b'], keyOf: (row) => row),
      ['a', 'b'],
    );

    // 删除 b：选择集收缩到仍存在的行。
    selection.retainKeys(['new', 'a']);
    expect(selection.selectedKeys, {'a'});
    expect(selection.selectedCount, 1);
  });

  test('clear 清空选择与锚点；clearAnchor 只失效锚点', () {
    selection.select('e');
    selection.applyModifiers(
      'd',
      visibleKeys: visible(),
      ctrl: false,
      shift: false,
    );

    selection.clearAnchor();
    // 锚点已失效：Shift 从当前行起算（否则会是 [a,d]）。
    selection.applyModifiers(
      'a',
      visibleKeys: visible(),
      ctrl: false,
      shift: true,
    );
    expect(selection.selectedKeys, {'a'});

    selection.clear();
    expect(selection.isSelecting, isFalse);
    expect(selection.selectedCount, 0);
    // 锚点也清了：Shift 从当前行起算。
    selection.applyModifiers(
      'c',
      visibleKeys: visible(),
      ctrl: false,
      shift: true,
    );
    expect(selection.selectedKeys, {'c'});
  });
}
