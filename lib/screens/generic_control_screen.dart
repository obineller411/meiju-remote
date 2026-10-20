import 'package:flutter/material.dart';

import '../models/device_info.dart';
import '../net/midea_cloud.dart';
import '../session_store.dart';
import '../widgets/gradient_background.dart';

/// 通用设备控制页（风扇 / 灯 / 热水器等非空调设备）。
/// 读取设备全部状态字段，修改任意字段后仅下发修改的部分。
class GenericControlScreen extends StatefulWidget {
  final DeviceInfo device;

  const GenericControlScreen({super.key, required this.device});

  @override
  State<GenericControlScreen> createState() => _GenericControlScreenState();
}

class _GenericControlScreenState extends State<GenericControlScreen> {
  late MideaCloud _cloud;
  final Map<String, TextEditingController> _controllers = {};
  final Set<String> _changed = {};

  bool _loading = true;
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _init() async {
    final store = await SessionStore.create();
    _cloud = store.restoreCloud()!;
    await _loadStatus();
  }

  Future<void> _loadStatus() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final status = await _cloud.status(widget.device.code);
      final store = await SessionStore.create();
      await store.updateTokens(_cloud);
      if (!mounted) return;
      _buildRows(status);
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _buildRows(Map<String, dynamic> status) {
    for (final c in _controllers.values) {
      c.dispose();
    }
    _controllers.clear();
    _changed.clear();

    status.forEach((key, value) {
      // 跳过嵌套对象/数组
      if (value is Map || value is List) return;
      _controllers[key] = TextEditingController(text: value.toString());
    });
    setState(() {});
  }

  Future<void> _send() async {
    if (_changed.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有修改任何字段')),
      );
      return;
    }

    final control = <String, Object?>{};
    for (final key in _changed) {
      control[key] = _parseValue(_controllers[key]!.text.trim());
    }

    setState(() => _sending = true);
    try {
      await _cloud.control(widget.device.code, control);
      final store = await SessionStore.create();
      await store.updateTokens(_cloud);
      final fresh = await _cloud.status(widget.device.code);
      if (!mounted) return;
      _buildRows(fresh);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已发送 ${control.length} 项修改'),
          backgroundColor: const Color(0xFF16A34A),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('控制失败：$e'), backgroundColor: Colors.red),
      );
    }
    if (mounted) setState(() => _sending = false);
  }

  /// 字符串 → 布尔/整数/浮点/字符串
  static Object _parseValue(String raw) {
    if (raw.equalsIgnoreCase('true')) return true;
    if (raw.equalsIgnoreCase('false')) return false;
    final i = int.tryParse(raw);
    if (i != null) return i;
    final d = double.tryParse(raw);
    if (d != null) return d;
    return raw;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GradientBackground(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 4, 6, 0),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back,
                          color: Color(0xFF1D1D1F)),
                      onPressed: () => Navigator.pop(context),
                    ),
                    Expanded(
                      child: Column(
                        children: [
                          Text(
                            widget.device.name,
                            style: const TextStyle(
                              color: Color(0xFF1D1D1F),
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Text(
                            '通用控制 · 修改字段后发送',
                            style: TextStyle(
                              color: Color(0xFF86868B),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: _loading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                color: Color(0xFF0071E3),
                              ),
                            )
                          : const Icon(Icons.refresh,
                              color: Color(0xFF1D1D1F)),
                      onPressed: _loading ? null : _loadStatus,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(28),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.cloud_off,
                                      color: Color(0xFF86868B), size: 56),
                                  const SizedBox(height: 14),
                                  Text(
                                    _error!,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                        color: Color(0xFF1D1D1F),
                                        fontSize: 14),
                                  ),
                                  const SizedBox(height: 18),
                                  FilledButton.icon(
                                    onPressed: _loadStatus,
                                    icon: const Icon(Icons.refresh),
                                    label: const Text('重试'),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : _controllers.isEmpty
                            ? Center(
                                child: const Text(
                                  '设备可能离线，无法获取状态',
                                  style: TextStyle(
                                    color: Color(0xFF86868B),
                                    fontSize: 15,
                                  ),
                                ),
                              )
                            : ListView(
                                padding: const EdgeInsets.fromLTRB(
                                    14, 8, 14, 24),
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(16),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius:
                                          BorderRadius.circular(18),
                                      border: Border.all(
                                        color: Colors.black
                                            .withValues(alpha: 0.05),
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black
                                              .withValues(alpha: 0.06),
                                          blurRadius: 24,
                                          offset: const Offset(0, 4),
                                        ),
                                      ],
                                    ),
                                    child: Column(
                                      children: [
                                        for (final key
                                            in _controllers.keys)
                                          _fieldRow(key),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  SizedBox(
                                    height: 52,
                                    child: FilledButton(
                                      onPressed: _sending ? null : _send,
                                      style: FilledButton.styleFrom(
                                        backgroundColor:
                                            const Color(0xFF0071E3),
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(26),
                                        ),
                                        textStyle: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      child: _sending
                                          ? const SizedBox(
                                              width: 22,
                                              height: 22,
                                              child:
                                                  CircularProgressIndicator(
                                                strokeWidth: 2.5,
                                                color: Colors.white,
                                              ),
                                            )
                                          : Text(
                                              '发送修改（${_changed.length}）',
                                            ),
                                    ),
                                  ),
                                ],
                              ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fieldRow(String key) {
    final changed = _changed.contains(key);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            flex: 5,
            child: Text(
              key,
              style: TextStyle(
                fontSize: 13,
                fontWeight: changed ? FontWeight.bold : FontWeight.w500,
                color: changed
                    ? const Color(0xFF0071E3)
                    : const Color(0xFF1D1D1F),
              ),
            ),
          ),
          Expanded(
            flex: 7,
            child: TextField(
              controller: _controllers[key],
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 9),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(
                    color: changed
                        ? const Color(0xFF0071E3)
                        : const Color(0xFFE5E5EA),
                    width: changed ? 1.6 : 1,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(
                    color: Color(0xFF0071E3),
                    width: 1.6,
                  ),
                ),
              ),
              onChanged: (_) {
                if (mounted) {
                  setState(() => _changed.add(key));
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}

extension _StringExt on String {
  bool equalsIgnoreCase(String other) => toLowerCase() == other.toLowerCase();
}
