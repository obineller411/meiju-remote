import 'package:flutter/material.dart';

import '../models/device_info.dart';
import '../net/midea_cloud.dart';
import '../session_store.dart';
import 'ac_control_screen.dart';
import 'generic_control_screen.dart';
import 'login_screen.dart';

class DeviceListScreen extends StatefulWidget {
  const DeviceListScreen({super.key});

  @override
  State<DeviceListScreen> createState() => _DeviceListScreenState();
}

class _DeviceListScreenState extends State<DeviceListScreen> {
  MideaCloud? _cloud;
  List<DeviceInfo> _devices = [];
  bool _loading = true;
  String? _error;

  /// 空调类设备状态缓存：设备码 → 状态
  final Map<int, Map<String, dynamic>> _statusMap = {};

  /// 正在开关操作中的设备码
  final Set<int> _toggling = {};

  @override
  void initState() {
    super.initState();
    _initAndLoad();
  }

  Future<void> _initAndLoad() async {
    final store = await SessionStore.create();
    _cloud = store.restoreCloud();
    if (_cloud == null) {
      await store.clear();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
      return;
    }
    await _loadDevices();
  }

  Future<void> _loadDevices() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final homes = await _cloud!.homes();
      final all = <DeviceInfo>[];
      for (final homeId in homes.keys) {
        all.addAll(await _cloud!.devices(homeId));
      }
      final store = await SessionStore.create();
      await store.updateTokens(_cloud!);
      if (!mounted) return;
      setState(() {
        _devices = all;
        _loading = false;
      });
      _fetchStatuses();
    } catch (e) {
      final store = await SessionStore.create();
      await store.updateTokens(_cloud!);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('确定要退出当前美居账号吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final store = await SessionStore.create();
    await store.clear();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
  }

  void _openDevice(DeviceInfo device) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => device.isAcLike
            ? AcControlScreen(device: device)
            : GenericControlScreen(device: device),
      ),
    );
  }

  /// 拉取所有空调类在线设备的实时状态（用于卡片摘要和快速开关）
  Future<void> _fetchStatuses() async {
    for (final d in _devices.where((d) => d.online && d.isAcLike)) {
      try {
        final s = d.isCentralAc
            ? await _cloud!.statusCentral(d)
            : await _cloud!.status(d.code);
        if (!mounted) return;
        setState(() => _statusMap[d.code] = s);
      } catch (_) {}
    }
  }

  /// 快速开关空调
  Future<void> _togglePower(DeviceInfo d, bool on) async {
    if (_toggling.contains(d.code)) return;
    setState(() => _toggling.add(d.code));
    try {
      if (d.isCentralAc) {
        // 先确保拿到网关子设备属性（nodeid 等）
        await _cloud!.statusCentral(d);
        final s = _statusMap[d.code] ?? const {};
        String cur(Object? v, String def) {
          final t = v?.toString().trim();
          return (t == null || t.isEmpty) ? def : t;
        }

        await _cloud!.controlCentral(d, {
          'run_mode': on ? cur(s['run_mode'], '2') : '0',
          'cooling_temp': cur(s['cool_temp_set'] ?? s['temperature'], '26'),
          'heating_temp': cur(s['heat_temp_set'] ?? s['temperature'], '26'),
          'fan_speed': cur(s['fan_speed'], '8'),
          'extflag': cur(s['extflag'], '0'),
        });
      } else {
        await _cloud!.control(d.code, {'power': on ? 'on' : 'off'});
      }
      // 回读真实状态
      final s = d.isCentralAc
          ? await _cloud!.statusCentral(d)
          : await _cloud!.status(d.code);
      if (mounted) setState(() => _statusMap[d.code] = s);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _toggling.remove(d.code));
    }
  }

  // ---- 状态摘要 ----
  static double? _parseT(Object? v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString().trim());
  }

  static bool _isOnValue(Object? v) {
    if (v == null) return false;
    if (v is bool) return v;
    if (v is num) return v != 0;
    final s = v.toString().toLowerCase();
    return s == 'on' || s == 'true' || s == '1';
  }

  static String _fmtT(double t) =>
      t == t.roundToDouble() ? '${t.toInt()}' : '$t';

  /// 卡片第二行的简要状态文字
  String? _summaryFor(DeviceInfo d) {
    final s = _statusMap[d.code];
    if (s == null) return null;
    if (d.isCentralAc) {
      final rm = (s['run_mode'] ?? '0').toString();
      if (rm == '0') return '已关闭';
      const labels = {'1': '送风', '2': '制冷', '3': '制热', '4': '自动', '5': '除湿'};
      final parts = <String>[labels[rm] ?? '运行中'];
      if (rm != '1') {
        final t = _parseT(
            s['cool_temp_set'] ?? s['heat_temp_set'] ?? s['temperature']);
        if (t != null) parts.add('${_fmtT(t)}°');
      }
      final room = _parseT(s['room_temp']);
      if (room != null) parts.add('室温 ${_fmtT(room)}°');
      return parts.join(' · ');
    }
    if (!_isOnValue(s['power'])) return '已关闭';
    final m = (s['mode'] ?? '').toString().toLowerCase();
    const labels = {
      'auto': '自动', 'cool': '制冷', 'heat': '制热',
      'dry': '除湿', 'fan': '送风', 'eco': '节能',
    };
    final parts = <String>[labels[m] ?? '运行中'];
    if (m != 'fan' && m != 'eco') {
      final tInt = _parseT(s['temperature']);
      final tDec = _parseT(s['small_temperature']) ?? 0.0;
      if (tInt != null) parts.add('${_fmtT(tInt + tDec)}°');
    }
    final room = _parseT(
        s['indoor_temperature'] ?? s['room_temperature'] ?? s['room_temp']);
    if (room != null) parts.add('室温 ${_fmtT(room)}°');
    return parts.join(' · ');
  }

  IconData _iconForType(int type) {
    switch (type) {
      case 0xAC:
      case 0x21: // 中央空调网关
      case 0x44: // 智能温控器
        return Icons.ac_unit;
      case 0xFA:
        return Icons.air;
      case 0x13:
        return Icons.lightbulb_outline;
      case 0x17:
        return Icons.local_laundry_service_outlined;
      default:
        return Icons.devices_other_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final nickname = _cloud?.nickname ?? _cloud?.account ?? '';

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 8, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '我的设备',
                          style: TextStyle(
                            color: Color(0xFF1C1C1E),
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '账号：$nickname',
                          style: const TextStyle(
                            color: Color(0xFF8E8E93),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh,
                        color: Color(0xFF1C1C1E)),
                    onPressed: _loading ? null : _loadDevices,
                  ),
                  IconButton(
                    icon: const Icon(Icons.logout,
                        color: Color(0xFF1C1C1E)),
                    onPressed: _logout,
                  ),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(
                          color: Color(0xFF0071E3)))
                  : _error != null
                      ? _ErrorView(
                          message: _error!,
                          onRetry: _loadDevices,
                        )
                      : _devices.isEmpty
                          ? const Center(
                              child: Text(
                                '没有找到任何设备',
                                style: TextStyle(
                                  color: Color(0xFF8E8E93),
                                  fontSize: 15,
                                ),
                              ),
                            )
                          : RefreshIndicator(
                              color: const Color(0xFF0071E3),
                              onRefresh: _loadDevices,
                              child: ListView.builder(
                                padding: const EdgeInsets.fromLTRB(
                                    14, 4, 14, 24),
                                itemCount: _devices.length,
                                itemBuilder: (context, i) {
                                  final d = _devices[i];
                                  return _DeviceCard(
                                    device: d,
                                    icon: _iconForType(d.type),
                                    summary: _summaryFor(d),
                                    showSwitch: d.online && d.isAcLike,
                                    switchValue:
                                        d.isCentralAc || d.isAirConditioner
                                            ? _powerStateOf(d)
                                            : false,
                                    busy: _toggling.contains(d.code),
                                    onTap: () => _openDevice(d),
                                    onToggle: (v) => _togglePower(d, v),
                                  );
                                },
                              ),
                            ),
            ),
          ],
        ),
      ),
    );
  }
  /// 从缓存状态判断空调是否开机
  bool _powerStateOf(DeviceInfo d) {
    final s = _statusMap[d.code];
    if (s == null) return false;
    if (d.isCentralAc) {
      final rm = (s['run_mode'] ?? '0').toString();
      return rm != '0';
    }
    return _isOnValue(s['power']);
  }
}

class _DeviceCard extends StatelessWidget {
  final DeviceInfo device;
  final IconData icon;
  final VoidCallback onTap;
  final String? summary;
  final bool showSwitch;
  final bool switchValue;
  final bool busy;
  final ValueChanged<bool> onToggle;

  const _DeviceCard({
    required this.device,
    required this.icon,
    required this.onTap,
    required this.onToggle,
    this.summary,
    this.showSwitch = false,
    this.switchValue = false,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final secondLine = summary ??
        [
          if (device.room.isNotEmpty) device.room,
          if (device.model.isNotEmpty) device.model,
        ].join(' · ');

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: const Color(0xFFF5F5F9),
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE3EEFB),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(icon, color: const Color(0xFF0071E3), size: 30),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        device.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        secondLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: summary != null
                              ? FontWeight.w600
                              : FontWeight.normal,
                          color: summary == '已关闭'
                              ? const Color(0xFF94A3B8)
                              : summary != null
                                  ? const Color(0xFF0071E3)
                                  : const Color(0xFF64748B),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: device.online
                                  ? const Color(0xFF16A34A)
                                  : const Color(0xFF94A3B8),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 5),
                          Text(
                            [
                              device.online ? '在线' : '离线',
                              if (summary != null && device.room.isNotEmpty)
                                device.room,
                            ].join(' · '),
                            style: TextStyle(
                              fontSize: 12,
                              color: device.online
                                  ? const Color(0xFF16A34A)
                                  : const Color(0xFF94A3B8),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (showSwitch)
                  busy
                      ? const SizedBox(
                          width: 40,
                          height: 40,
                          child: Padding(
                            padding: EdgeInsets.all(8),
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          ),
                        )
                      : Transform.scale(
                          scale: 1.15,
                          child: Switch(
                            value: switchValue,
                            activeColor: const Color(0xFF0071E3),
                            onChanged: onToggle,
                          ),
                        )
                else
                  Text(
                    device.online ? '在线' : '离线',
                    style: TextStyle(
                      fontSize: 13,
                      color: device.online
                          ? const Color(0xFF16A34A)
                          : const Color(0xFF94A3B8),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, color: Colors.white, size: 56),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
