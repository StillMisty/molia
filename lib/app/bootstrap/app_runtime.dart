/// 启动阶段产物的可变注册表：只解决“容器必须先于功能栈、而核心栈又由
/// 组合根构造”的顺序问题。
///
/// 取值方一律通过 `appRuntimeProvider` + 泛型键读取；键是显式类型参数
/// （接口实现按窄接口登记，例如 `DownloadMaintenance`），不做运行时类型推断。
/// 迁移完成后（各栈内聚进 provider）本文件应删除。
library;

class AppRuntime {
  final Map<Type, Object> _values = {};

  /// 登记实例；同一类型重复登记视为组合根接线错误。
  void put<T>(T value) {
    final previous = _values[T];
    if (previous != null && !identical(previous, value)) {
      throw StateError('AppRuntime 已有 $T 的不同实例');
    }
    _values[T] = value as Object;
  }

  /// 读取可空依赖（测试未注入时等价于旧 provider 树里的“未注册”）。
  T? maybe<T>() => _values[T] as T?;

  /// 读取必需依赖（缺失说明组合根漏接线）。
  T require<T>() {
    final value = maybe<T>();
    if (value == null) {
      throw StateError('AppRuntime 缺少 $T：组合根未登记或测试未 override');
    }
    return value;
  }
}
