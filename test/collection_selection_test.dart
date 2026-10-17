import 'package:flutter_test/flutter_test.dart';
import 'package:molia/widgets/collection_selection.dart';

/// 合集多选状态机：修饰键语义（锚点 / 区间）、提取与全选三态的行为钉死。
void main() {
  late CollectionSelection selection;

  setUp(() {
    selection = CollectionSelection();
  });

  tearDown(() => selection.dispose());

  test('Ctrl 点击切换并移动锚点；连续 Shift 只调整区间端点', () {
    expect(
      selection.applyModifiers(1, itemCount: 5, ctrl: true, shift: false),
      isTrue,
    );
    expect(selection.selectedIndices, {1});

    // Shift 到 3：区间 [1,3]。
    expect(
      selection.applyModifiers(3, itemCount: 5, ctrl: false, shift: true),
      isTrue,
    );
    expect(selection.selectedIndices, {1, 2, 3});

    // 连续 Shift 到 2：锚点仍是 1，区间缩回 [1,2]。
    expect(
      selection.applyModifiers(2, itemCount: 5, ctrl: false, shift: true),
      isTrue,
    );
    expect(selection.selectedIndices, {1, 2});

    // 普通点击移动锚点到 4（返回 false = 未接管）；Shift 到 1 → [1,4]。
    expect(
      selection.applyModifiers(4, itemCount: 5, ctrl: false, shift: false),
      isFalse,
    );
    expect(
      selection.applyModifiers(1, itemCount: 5, ctrl: false, shift: true),
      isTrue,
    );
    expect(selection.selectedIndices, {1, 2, 3, 4});
  });

  test('Shift 反向区间与锚点越界退化为单选', () {
    // 无锚点：Shift 退化为单选当前行并落锚。
    expect(
      selection.applyModifiers(3, itemCount: 5, ctrl: false, shift: true),
      isTrue,
    );
    expect(selection.selectedIndices, {3});

    // 锚点 3，Shift 到 1：反向区间 [1,3]。
    expect(
      selection.applyModifiers(1, itemCount: 5, ctrl: false, shift: true),
      isTrue,
    );
    expect(selection.selectedIndices, {1, 2, 3});

    // 锚点 3 越界（列表变短到 2）：退化为单选当前行。
    expect(
      selection.applyModifiers(0, itemCount: 2, ctrl: false, shift: true),
      isTrue,
    );
    expect(selection.selectedIndices, {0});
  });

  test('全选三态与 selectAll', () {
    expect(selection.allSelectedFor(3), isFalse);
    selection.select(0);
    expect(selection.allSelectedFor(3), isNull);
    selection.selectAll(3);
    expect(selection.selectedIndices, {0, 1, 2});
    expect(selection.selectedCount, 3);
    expect(selection.allSelectedFor(3), isTrue);
    expect(selection.allSelectedFor(0), isFalse);
  });

  test('selectedFrom 按行下标提取，越界忽略', () {
    selection.select(0);
    selection.select(2);
    expect(selection.selectedFrom(['a', 'b', 'c']), ['a', 'c']);
    expect(selection.selectedFrom(['a']), ['a']);
    expect(selection.selectedFrom(const <String>[]), isEmpty);
  });

  test('clear 清空选择与锚点；clearAnchor 只失效锚点', () {
    selection.select(4);
    selection.applyModifiers(3, itemCount: 5, ctrl: false, shift: false);

    selection.clearAnchor();
    // 锚点已失效：Shift 从当前行起算（否则会是 [0,3]）。
    selection.applyModifiers(0, itemCount: 5, ctrl: false, shift: true);
    expect(selection.selectedIndices, {0});

    selection.clear();
    expect(selection.isSelecting, isFalse);
    expect(selection.selectedCount, 0);
    // 锚点也清了：Shift 从当前行起算。
    selection.applyModifiers(2, itemCount: 5, ctrl: false, shift: true);
    expect(selection.selectedIndices, {2});
  });
}
