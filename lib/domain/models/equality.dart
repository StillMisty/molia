/// 领域模型的集合深比较工具（纯 Dart，不依赖 Flutter）。
///
/// 模型手写 `==` / `hashCode` 时统一复用这里的实现：
/// - `Map` / `List` / `Set` 按值递归比较，其余对象按 `==`；
/// - 先做 `identical` 短路，兼容 `payload` 原样透传（同一引用）的热路径。
library;

bool deepEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key)) return false;
      if (!deepEquals(entry.value, b[entry.key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Set && b is Set) {
    if (a.length != b.length) return false;
    for (final item in a) {
      if (!b.any((other) => deepEquals(other, item))) return false;
    }
    return true;
  }
  return a == b;
}

int deepHash(Object? value) {
  if (value is Map) {
    return Object.hashAllUnordered(value.entries
        .map((e) => Object.hash(deepHash(e.key), deepHash(e.value))));
  }
  if (value is List) {
    return Object.hashAll(value.map(deepHash));
  }
  if (value is Set) {
    return Object.hashAllUnordered(value.map(deepHash));
  }
  return value.hashCode;
}
