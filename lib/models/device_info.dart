/// 设备信息
class DeviceInfo {
  final int code;
  final String name;
  final int type;
  final bool online;
  final String room;
  final String model;
  final String sn8;

  DeviceInfo({
    required this.code,
    required this.name,
    required this.type,
    required this.online,
    required this.room,
    required this.model,
    required this.sn8,
  });

  /// 是否为空调
  bool get isAirConditioner => type == 0xAC;

  /// 是否为中央空调（T0x21，多联机子设备，走网关透传协议）
  bool get isCentralAc => type == 0x21;

  /// 空调类设备：空调 / 中央空调网关 / 智能温控器，均可使用空调控制界面
  bool get isAcLike =>
      type == 0xAC || type == 0x21 || type == 0x44;
}
