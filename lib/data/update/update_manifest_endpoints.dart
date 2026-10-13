/// 各平台默认更新清单地址（按平台条件导入）。
///
/// - 原生端（io）：GitHub Release 资产的稳定/测试清单；
/// - Web：必须走 Pages 同源清单——实测 GitHub Release 资产响应不带
///   `Access-Control-Allow-Origin`，浏览器 fetch 会被 CORS 拦截。
library;

export 'update_manifest_endpoints_stub.dart'
    if (dart.library.io) 'update_manifest_endpoints_io.dart';
