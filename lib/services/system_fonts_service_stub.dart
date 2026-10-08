/// Web 等平台：浏览器无法枚举本地字体，统一返回空列表，
/// 调用方仅提供「系统默认」（海报页另有「跟随应用字体」选项）。
class SystemFontsService {
  SystemFontsService._();

  static Future<List<String>> listFamilies() async => const <String>[];

  static List<String> parseAndroidFontConfig(String xml) => const <String>[];

  static List<String> parseFcListOutput(String output) => const <String>[];

  static void debugResetCache() {}
}
