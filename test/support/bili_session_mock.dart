import 'dart:convert';

import 'package:dio/dio.dart';

import 'mock_dio.dart';

/// B 站测试共用的匿名会话响应（buvid SPI + WBI nav）。
///
/// 各 B 站适配器测试都要让 `BiliApi.session()` 走通；把这两段完全相同的
/// JSON 响应收在这里，业务测试只保留自己的端点。返回 null 表示不是会话请求。
ResponseBody? biliSessionResponse(
  RequestOptions options, {
  void Function()? onNav,
}) {
  switch (options.uri.path) {
    case '/x/frontend/finger/spi':
      return textResponse(
        jsonEncode({
          'code': 0,
          'data': {'b_3': 'buvid3-test', 'b_4': 'buvid4-test'},
        }),
      );
    case '/x/web-interface/nav':
      onNav?.call();
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
    default:
      return null;
  }
}
