/// 设备 id 的短展示（名册 / 日志 / 错误文案共用）。
///
/// 统一取**末位**字符：同一设备在名册、日志与错误文案里显示同一个编号；
/// 完整 id 只在详情与诊断信息里出现。
String shortDeviceId(String deviceId, {int length = 6}) {
  if (deviceId.length <= length) return deviceId;
  return deviceId.substring(deviceId.length - length);
}
