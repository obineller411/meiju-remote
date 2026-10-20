import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/device_info.dart';
import '../net/midea_cloud.dart';
import '../services/timer_service.dart';
import '../session_store.dart';
import '../widgets/gradient_background.dart' show WhiteCard;

/// 中央空调（T0x21）模式标签，对应 run_mode: 4自动 2制冷 3制热 5除湿 1送风
const _centralModeLabels = ['自动', '制冷', '制热', '除湿', '送风'];
const _centralRunModes = ['4', '2', '3', '5', '1'];

/// T0xAC 模式标签（0自动 1制冷 2制热 3除湿 4送风）
const _modeLabels = ['自动', '制冷', '制热', '除湿', '送风'];
const _modeStrings = ['auto', 'cool', 'heat', 'dry', 'fan_only'];

/// 风速：普通空调协议值=百分比，1=静音(官方显示1%)…100=全速，102=自动，支持两位数无级调速
const _windLabels = ['静音 1%', '20%', '40%', '60%', '80%', '100%', '自动'];
const _windValues = [1, 20, 40, 60, 80, 100, 102];

/// Apple 设计色（参考 apple-ui-design 技能）
const Color kIOSBG = Color(0xFFF5F5F7);
const Color kIOSAccent = Color(0xFF0071E3);
const Color kIOSLabel = Color(0xFF1D1D1F);
const Color kIOSSecondary = Color(0xFF86868B);
const Color kIOSFill = Color(0xFFE5E5EA);

class AcControlScreen extends StatefulWidget {
  final DeviceInfo device;

  const AcControlScreen({super.key, required this.device});

  @override
  State<AcControlScreen> createState() => _AcControlScreenState();
}

class _AcControlScreenState extends State<AcControlScreen> {
  late MideaCloud _cloud;
  bool _loading = true;
  bool _sending = false;

  bool _powerOn = false;
  double _setTemp = 26;
  double? _roomTemp;
  int _mode = 1;
  int _fanSpeed = 102;
  bool _swingV = false;
  bool _swingH = false;
  final Map<String, bool> _functions = {};

  /// 状态回写期间避免本地选择态被旧状态覆盖
  bool _applying = false;

  /// 最近一次设备真实状态，用于判断控制值类型（字符串枚举 or 数字）
  Map<String, dynamic> _lastStatus = {};

  /// 中央空调本地闹钟定时
  List<TimerTask> _timers = [];
  Timer? _countdownTimer;

  /// 普通空调设备侧定时目标时刻
  DateTime? _devTimerOnAt;
  DateTime? _devTimerOffAt;

  /// 定时滑块拖动预览（分钟）
  double? _previewOnMin;
  double? _previewOffMin;

  @override
  void initState() {
    super.initState();
    _init();
    _loadTimers();
    _countdownTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadTimers() async {
    final list = await TimerService.tasksFor(widget.device.code);
    if (mounted) setState(() => _timers = list);
  }

  // ============================================================
  // 定时
  // ============================================================
  Future<void> _setTimer(String action, DateTime when) async {
    final minutes = when.difference(DateTime.now()).inMinutes;
    if (minutes < 1) return;
    try {
      if (_isCentral) {
        await TimerService.schedule(
          device: widget.device,
          action: action,
          when: when,
        );
        await _loadTimers();
      } else {
        await _send({
          'power_${action}_timer': 'on',
          'power_${action}_time_value': minutes,
        });
        setState(() {
          if (action == 'on') {
            _devTimerOnAt = when;
          } else {
            _devTimerOffAt = when;
          }
        });
      }
      if (!mounted) return;
      _toast('${action == 'off' ? '定时关机' : '定时开机'} ${_fmtClock(when)}'
          '${_isCentral ? ' · 手机到点执行' : ' · 设备端执行'}');
    } catch (e) {
      if (mounted) {
        _toast('设置失败：$e', error: true);
      }
    }
  }

  static const List<({String label, int minutes})> _quickTimers = [
    (label: '30分', minutes: 30),
    (label: '1小时', minutes: 60),
    (label: '2小时', minutes: 120),
    (label: '4小时', minutes: 240),
    (label: '8小时', minutes: 480),
  ];

  Future<void> _quickTimer(String action, int minutes) =>
      _setTimer(action, DateTime.now().add(Duration(minutes: minutes)));

  Future<void> _customTimer(String action) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
      helpText: action == 'off' ? '定时关机时间' : '定时开机时间',
    );
    if (picked == null) return;
    final now = DateTime.now();
    var when =
        DateTime(now.year, now.month, now.day, picked.hour, picked.minute);
    if (!when.isAfter(now)) when = when.add(const Duration(days: 1));
    await _setTimer(action, when);
  }

  Future<void> _cancelTimer(String action) async {
    try {
      if (_isCentral) {
        for (final t in _timers.where((t) => t.action == action).toList()) {
          await TimerService.cancel(t);
        }
        await _loadTimers();
      } else {
        await _send({'power_${action}_timer': 'off'});
        setState(() {
          if (action == 'on') {
            _devTimerOnAt = null;
          } else {
            _devTimerOffAt = null;
          }
        });
      }
    } catch (e) {
      _toast('取消失败：$e', error: true);
    }
  }

  /// 定时滑块当前分钟数（0 = 未开启）
  double _timerMinutes(String action) {
    final preview = action == 'on' ? _previewOnMin : _previewOffMin;
    if (preview != null) return preview;
    DateTime? at;
    if (_isCentral) {
      for (final t in _timers) {
        if (t.action == action) at = t.time;
      }
    } else {
      at = action == 'on' ? _devTimerOnAt : _devTimerOffAt;
    }
    if (at == null) return 0;
    final m = at.difference(DateTime.now()).inMinutes;
    if (m <= 0) return 0;
    return m.clamp(0, 480).toDouble();
  }

  DateTime? _timerAt(String action) {
    if (_isCentral) {
      for (final t in _timers) {
        if (t.action == action) return t.time;
      }
      return null;
    }
    return action == 'on' ? _devTimerOnAt : _devTimerOffAt;
  }

  void _toast(String msg, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: error ? CupertinoColors.systemRed : Colors.black87,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  static String _fmtClock(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  static String _fmtMinutes(double m) {
    final v = m.round();
    if (v <= 0) return '未开启';
    final h = v ~/ 60;
    final mm = v % 60;
    if (h == 0) return '$mm 分钟';
    if (mm == 0) return '$h 小时';
    return '$h小时$mm分';
  }

  String get _statusKey =>
      (_isCentral ? 'c_' : 'a_') + widget.device.code.toString();

  Future<void> _init() async {
    final store = await SessionStore.create();
    _cloud = store.restoreCloud()!;
    // 先用上次缓存的状态秒亮按钮，再后台静默拉取最新状态
    final cached = store.getStatus(_statusKey);
    if (cached != null) {
      _applyStatus(cached);
      if (mounted) setState(() => _loading = false);
    }
    await _loadStatus();
  }

  bool _refreshing = false;

  Future<void> _loadStatus({bool manual = false}) async {
    if (manual) {
      if (_refreshing) return;
      _refreshing = true;
      if (mounted) setState(() {});
    }
    BuildContext? hudCtx;
    if (manual && mounted) {
      unawaited(showDialog(
        context: context,
        barrierDismissible: false,
        barrierColor: Colors.black26,
        builder: (c) {
          hudCtx = c;
          return PopScope(
            canPop: false,
            child: Center(
              child: Material(
                type: MaterialType.transparency,
                child: Container(
                  width: 132,
                  height: 132,
                  decoration: BoxDecoration(
                    color: const Color(0xCC1C1C1E),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      CupertinoActivityIndicator(
                          color: Colors.white, radius: 16),
                      SizedBox(height: 14),
                      Text('正在同步…',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w500)),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ));
    }
    var ok = false;
    try {
      Map<String, dynamic> status = const {};
      // 云端偶发先回空包（设备应答有延迟），短间隔重试最多 3 次
      for (var attempt = 0; attempt < 3; attempt++) {
        status = _isCentral
            ? await _cloud.statusCentral(widget.device)
            : await _cloud.status(widget.device.code);
        if (_statusMeaningful(status)) break;
        if (attempt < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 700));
        }
      }
      final store = await SessionStore.create();
      await store.updateTokens(_cloud);
      if (!mounted) return;
      if (_statusMeaningful(status)) {
        await store.saveStatus(_statusKey, status);
        _applyStatus(status);
        ok = true;
      }
      _loading = false;
    } catch (e) {
      if (!mounted) return;
      _loading = false;
      if (manual) _toast('获取状态失败：$e', error: true);
    } finally {
      _refreshing = false;
      if (hudCtx != null && hudCtx!.mounted) {
        Navigator.of(hudCtx!, rootNavigator: true).pop();
      }
      if (mounted) setState(() {});
      // 成功后短暂轻提示，确认刷新完成
      if (ok && manual && mounted) _toast('状态已同步');
    }
  }

  // ============================================================
  // 状态解析
  // ============================================================
  static bool _isOn(Object? v) {
    if (v == null) return false;
    if (v is bool) return v;
    if (v is num) return v.toInt() == 1;
    final s = v.toString().toLowerCase();
    return const ['on', '1', 'true', 'running', 'active', 'enabled']
        .contains(s);
  }

  /// 非零即开（screen_display 开=100、buzzer 可能为 1/100 或 on）
  static bool _isOnWide(Object? v) {
    if (v == null) return false;
    if (v is bool) return v;
    if (v is num) return v != 0;
    final s = v.toString().toLowerCase();
    return const ['on', '1', 'true', 'running', 'active', 'enabled']
        .contains(s);
  }

  static int? _parseInt(Object? v) {
    if (v == null) return null;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString().trim()) ??
        double.tryParse(v.toString().trim())?.toInt();
  }

  static double? _parseDouble(Object? v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString().trim());
  }

  static int _parseMode(Object? v) {
    if (v is num) return v.toInt().clamp(0, 5);
    final s = v?.toString().toLowerCase() ?? '';
    if (s.contains('cool')) return 1;
    if (s.contains('heat')) return 2;
    if (s.contains('dry')) return 3;
    if (s.contains('fan')) return 4;
    if (s.contains('eco') || s.contains('energy') || s.contains('save')) {
      return 5;
    }
    return 0;
  }

  static int _parseFan(Object? v) {
    if (v is num) return v.toInt();
    final s = v?.toString().toLowerCase() ?? '';
    if (s.contains('silent') || s.contains('mute') || s.contains('quiet')) {
      return 1;
    }
    if (s.contains('full')) return 100;
    if (s.contains('auto')) return 102;
    if (s.contains('low')) return 40;
    if (s.contains('mid')) return 60;
    if (s.contains('high') || s.contains('strong')) return 80;
    return 102;
  }

  // ============================================================
  // 控制值自适应
  // ============================================================
  bool _stringMode() => _isStringField(_lastStatus, ['mode', 'run_mode']);

  Object _powerValue(bool on) =>
      _isStringField(_lastStatus, ['power', 'powerStatus'])
          ? (on ? 'on' : 'off')
          : (on ? 1 : 0);

  Object _modeValue(int m) => _stringMode() ? _modeStrings[m] : m;

  static bool _isStringField(Map<String, dynamic> s, List<String> keys) {
    for (final k in keys) {
      final v = s[k];
      if (v is String && v.trim().isNotEmpty) return true;
    }
    return false;
  }

  Object _flagValue(List<String> keys, bool on) =>
      _isStringField(_lastStatus, keys) ? (on ? 'on' : 'off') : (on ? 1 : 0);

  List<String> _flagKeys(String key) {
    switch (key) {
      case 'screen_display':
        return ['screen_display', 'screenDisplay', 'display'];
      case 'sleep':
        return ['comfort_sleep', 'sleep', 'sleep_mode'];
      case 'aux_heat':
        return ['aux_heat', 'ptc'];
      case 'turbo':
        return ['strong_wind', 'turbo'];
      case 'swing_vertical':
        return ['wind_swing_ud', 'swing_vertical', 'vertical_swing'];
      case 'swing_horizontal':
        return ['wind_swing_lr', 'swing_horizontal', 'horizontal_swing'];
      default:
        return [key];
    }
  }

  String _fanKey() {
    for (final k in ['wind_speed', 'fan_speed', 'fanSpeed', 'windSpeed']) {
      if (_lastStatus.containsKey(k)) return k;
    }
    return 'wind_speed';
  }

  // ============================================================
  // 中央空调（T0x21）分支
  // ============================================================
  bool get _isCentral => widget.device.isCentralAc;

  bool get _isFanMode => _mode == 4;

  bool get _tempEnabled => _powerOn && !_isFanMode;

  List<String> get _modeLabelList =>
      _isCentral ? _centralModeLabels : _modeLabels;

  Map<String, Object?> _centralBase() {
    final s = _lastStatus;
    String cur(Object? v, String def) {
      final t = v?.toString().trim();
      return (t == null || t.isEmpty) ? def : t;
    }

    return {
      'run_mode': cur(s['run_mode'], _powerOn ? '2' : '0'),
      'cooling_temp':
          cur(s['cool_temp_set'] ?? s['temperature'], _fmtPlain(_setTemp)),
      'heating_temp':
          cur(s['heat_temp_set'] ?? s['temperature'], _fmtPlain(_setTemp)),
      'fan_speed': cur(s['fan_speed'], '8'),
      'extflag': cur(s['extflag'], '0'),
    };
  }

  String _centralLastRunMode() {
    final rm = _lastStatus['run_mode']?.toString() ?? '';
    return (rm.isNotEmpty && rm != '0') ? rm : '2';
  }

  String _centralExtSwing(bool on) {
    final cur = _lastStatus['extflag']?.toString() ?? '0';
    if (on) return cur == '2' ? '6' : '4';
    return cur == '6' ? '2' : '0';
  }

  String _centralExtAux(bool on) {
    final cur = _lastStatus['extflag']?.toString() ?? '0';
    if (on) return cur == '4' ? '6' : '2';
    return cur == '6' ? '4' : '0';
  }

  static String _fmtTemp(double t) =>
      t == t.roundToDouble() ? '${t.toInt()}' : '$t';

  static String _fmtPlain(double t) =>
      t == t.roundToDouble() ? '${t.toInt()}' : '$t';

  void _sendTemp(double t) {
    if (_isCentral) {
      final o = <String, String>{'cooling_temp': _fmtPlain(t)};
      final idx = _mode.clamp(0, _centralRunModes.length - 1);
      final rm = _centralRunModes[idx];
      if (rm == '3' || rm == '4') o['heating_temp'] = _fmtPlain(t);
      _sendCentral(o);
    } else {
      _send({
        'temperature': t.floor(),
        'small_temperature': t % 1 == 0 ? 0.0 : 0.5,
      });
    }
  }

  void _applyStatus(Map<String, dynamic> s) {
    _lastStatus = s;

    if (widget.device.isCentralAc) {
      final rm = (s['run_mode'] ?? '0').toString();
      _powerOn = rm != '0';
      _mode = const {'4': 0, '2': 1, '3': 2, '5': 3, '1': 4}[rm] ?? 0;
      final fs = (s['fan_speed'] ?? '8').toString();
      _fanSpeed = int.tryParse(fs) ?? 8;
      Object? anyOf(List<String> keys) {
        for (final k in keys) {
          if (s.containsKey(k)) return s[k];
        }
        return null;
      }

      _setTemp = _parseDouble(
            anyOf(['cool_temp_set', 'heat_temp_set', 'temperature']),
          ) ??
          _setTemp;
      _roomTemp = _parseDouble(anyOf(['room_temp']));
      final ext = (s['extflag'] ?? '0').toString();
      _swingV = ext == '4' || ext == '6';
      _swingH = false;
      _functions['aux_heat'] = ext == '2' || ext == '6';

      // 不在此处锁 _applying：调用方随后都会 setState，直接允许选中渲染
      return;
    }

    // ---- T0xAC 普通空调 ----
    Object? anyOf(List<String> keys) {
      for (final k in keys) {
        if (s.containsKey(k)) return s[k];
      }
      return null;
    }

    _powerOn = _isOn(anyOf(['power', 'powerStatus', 'status']));
    _mode = _parseMode(anyOf(['mode', 'run_mode']));

    final tInt = _parseInt(anyOf(['temperature', 'set_temp', 'target_temp']));
    final small = _parseDouble(
        anyOf(['small_temperature', 'smallTemperature', 'half_degree']));
    if (tInt != null) {
      _setTemp = tInt.toDouble() + (small ?? 0);
    }
    _roomTemp = _parseDouble(
        anyOf(['room_temperature', 'room_temp', 'indoor_temperature']));
    final fanRaw = anyOf(['wind_speed', 'fan_speed', 'fanSpeed', 'windSpeed']);
    if (fanRaw is num) {
      _fanSpeed = fanRaw.toInt();
    } else {
      _fanSpeed = _parseFan(fanRaw);
    }
    _swingV = _isOn(anyOf([
      'wind_swing_ud',
      'swing_vertical',
      'vertical_swing',
    ]));
    _swingH = _isOn(anyOf([
      'wind_swing_lr',
      'swing_horizontal',
      'horizontal_swing',
    ]));
    _functions['eco'] = _isOn(anyOf(['eco']));
    _functions['sleep'] =
        _isOn(anyOf(['comfort_sleep', 'sleep', 'sleep_mode']));
    _functions['turbo'] = _isOn(anyOf(['strong_wind', 'turbo']));
    _functions['aux_heat'] = _isOn(anyOf(['aux_heat', 'ptc']));
    _functions['dry'] = _isOn(anyOf(['dry']));
    _functions['screen_display'] = _isOnWide(anyOf(
        ['screen_display_now', 'screen_display', 'screenDisplay', 'display']));
    _functions['beep'] = _isOnWide(anyOf(['buzzer', 'beep']));

    final now = DateTime.now();
    final onMin = _parseInt(anyOf(['power_on_time_value']));
    _devTimerOnAt =
        _isOn(anyOf(['power_on_timer'])) && onMin != null && onMin > 0
            ? now.add(Duration(minutes: onMin))
            : null;
    final offMin = _parseInt(anyOf(['power_off_time_value']));
    _devTimerOffAt =
        _isOn(anyOf(['power_off_timer'])) && offMin != null && offMin > 0
            ? now.add(Duration(minutes: offMin))
            : null;
  }

  /// 状态是否包含有效字段（云端偶尔先返回空包，避免缓存被覆盖、按钮不亮）
  bool _statusMeaningful(Map<String, dynamic> s) {
    if (s.isEmpty) return false;
    const keys = [
      'power', 'powerStatus', 'status', 'mode', 'run_mode',
      'wind_speed', 'fan_speed', 'temperature',
    ];
    return keys.any((k) => s[k] != null);
  }

  // ============================================================
  // 控制
  // ============================================================
  Future<void> _send(Map<String, Object?> params) =>
      _runControl(() => _cloud.control(widget.device.code, params));

  Future<void> _sendCentral(Map<String, String> overrides) {
    final event = _centralBase()..addAll(overrides);
    return _runControl(() => _cloud.controlCentral(widget.device, event));
  }

  Future<void> _runControl(
      Future<Map<String, dynamic>> Function() action) async {
    setState(() => _sending = true);
    try {
      final resp = await action();
      final store = await SessionStore.create();
      await store.updateTokens(_cloud);
      final newStatus = resp['current_status'] as Map<String, dynamic>?;
      if (newStatus != null) {
        _applyStatus(newStatus);
      }
    } catch (e) {
      if (!mounted) return;
      _toast('控制失败：$e', error: true);
      _loadStatus();
    }
    if (mounted) setState(() => _sending = false);
  }

  // ============================================================
  // UI
  // ============================================================
  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: kIOSBG,
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _buildNavBar(),
              const SizedBox(height: 18),
              _buildHeroCard(),
              const SizedBox(height: 14),
              _sectionLabel('运行模式'),
              const SizedBox(height: 8),
              _buildModeCard(),
              const SizedBox(height: 14),
              _sectionLabel('风速'),
              const SizedBox(height: 8),
              _buildFanCard(),
              const SizedBox(height: 14),
              _sectionLabel('摆风'),
              const SizedBox(height: 8),
              _buildSwingCard(),
              const SizedBox(height: 14),
              _sectionLabel('定时'),
              const SizedBox(height: 8),
              _buildTimerCard(),
              const SizedBox(height: 14),
              _sectionLabel('更多功能'),
              const SizedBox(height: 8),
              _buildFunctionsCard(),
            ],
          ),
        ),
      ),
    );
  }

  // ---- 顶部导航（iOS 大标题）----
  Widget _buildNavBar() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _circleIconBtn(CupertinoIcons.chevron_back, () {
          Navigator.pop(context);
        }),
        const Spacer(),
        _circleIconBtn(
          _refreshing || _sending ? null : CupertinoIcons.arrow_clockwise,
          () => _loadStatus(manual: true),
          child: _refreshing || _sending
              ? const Padding(
                  padding: EdgeInsets.all(10),
                  child: CupertinoActivityIndicator(),
                )
              : null,
        ),
      ],
    );
  }

  Widget _circleIconBtn(IconData? icon, VoidCallback? onTap,
      {Widget? child}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: child ??
            Icon(icon, size: 20, color: kIOSLabel.withValues(alpha: 0.8)),
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(left: 6),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: kIOSLabel,
            letterSpacing: 0.2,
          ),
        ),
      );

  /// 温度 ±0.5 步进（16-30℃）
  void _adjustTemp(double delta) {
    // 先放大 2 倍取整再缩回，保证精确落在 x.0/x.5
    var t = ((_setTemp + delta) * 2).round() / 2;
    if (t < 16) t = 16;
    if (t > 30) t = 30;
    if (t == _setTemp) return;
    setState(() => _setTemp = t);
    _sendTemp(t);
  }

  Widget _heroTempBtn(IconData icon, bool enabled, VoidCallback onTap) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: kIOSFill.withValues(alpha: enabled ? 1 : 0.5),
          border: Border.all(
            color: Colors.black.withValues(alpha: 0.05),
          ),
        ),
        child: Icon(icon,
            size: 20,
            color: enabled
                ? kIOSLabel
                : kIOSSecondary.withValues(alpha: 0.4)),
      ),
    );
  }

  // ---- 主视觉卡（Apple 白卡风格）----
  Widget _buildHeroCard() {
    final on = _powerOn;

    final modeText = !on
        ? '已关机'
        : _modeLabelList[_mode.clamp(0, _modeLabelList.length - 1)];

    return Container(
      padding: const EdgeInsets.fromLTRB(22, 22, 18, 18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.black.withValues(alpha: 0.05)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 24,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.device.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: kIOSLabel,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: on
                                ? const Color(0xFF34C759)
                                : kIOSSecondary.withValues(alpha: 0.5),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '$modeText  ·  ${_fanLabel(_fanSpeed)}',
                          style: const TextStyle(
                            color: kIOSSecondary,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: _sending
                    ? null
                    : () => _isCentral
                        ? _sendCentral({
                            'run_mode':
                                on ? '0' : _centralLastRunMode(),
                          })
                        : _send({'power': _powerValue(!on)}),
                child: Container(
                  width: 66,
                  height: 66,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: on ? kIOSAccent : kIOSFill,
                    boxShadow: on
                        ? [
                            BoxShadow(
                              color: kIOSAccent.withValues(alpha: 0.3),
                              blurRadius: 16,
                              offset: const Offset(0, 6),
                            ),
                          ]
                        : null,
                  ),
                  child: _sending
                      ? Padding(
                          padding: const EdgeInsets.all(20),
                          child: CircularProgressIndicator(
                            color: on ? Colors.white : kIOSAccent,
                            strokeWidth: 2.5,
                          ),
                        )
                      : Icon(
                          Icons.power_settings_new,
                          color: on
                              ? Colors.white
                              : kIOSLabel.withValues(alpha: 0.55),
                          size: 32,
                        ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                _tempEnabled ? _fmtTemp(_setTemp) : '--',
                style: const TextStyle(
                  color: kIOSLabel,
                  fontSize: 72,
                  fontWeight: FontWeight.w800,
                  height: 1.0,
                  letterSpacing: -2,
                ),
              ),
              const Text(
                '°',
                style: TextStyle(
                  color: kIOSLabel,
                  fontSize: 36,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  _roomTemp != null
                      ? '室温 ${_fmtTemp(_roomTemp!)}°'
                      : '室温 --°',
                  style: const TextStyle(
                    color: kIOSSecondary,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Builder(builder: (_) {
            final canAdj = _tempEnabled && !_sending;
            return Row(
              children: [
                _heroTempBtn(CupertinoIcons.minus,
                    canAdj && _setTemp > 16, () => _adjustTemp(-0.5)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    children: [
                      _iosSlider(
                        value: _setTemp.clamp(16.0, 30.0),
                        min: 16,
                        max: 30,
                        divisions: 28,
                        enabled: canAdj,
                        onChanged: (v) =>
                            setState(() => _setTemp = v),
                        onChangeEnd: _sendTemp,
                      ),
                      const SizedBox(height: 4),
                      const Row(
                        mainAxisAlignment:
                            MainAxisAlignment.spaceBetween,
                        children: [
                          Text('16°',
                              style: TextStyle(
                                  color: kIOSSecondary, fontSize: 12)),
                          Text('30°',
                              style: TextStyle(
                                  color: kIOSSecondary, fontSize: 12)),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                _heroTempBtn(CupertinoIcons.plus,
                    canAdj && _setTemp < 30, () => _adjustTemp(0.5)),
              ],
            );
          }),
        ],
      ),
    );
  }

  /// 严格 3 列栅格，保证不同行数下列也对齐
  Widget _pillGrid(List<Widget> pills) {
    const cols = 3;
    final rows = <Widget>[];
    for (var i = 0; i < pills.length; i += cols) {
      final cells = <Widget>[];
      for (var j = 0; j < cols; j++) {
        final idx = i + j;
        cells.add(Expanded(
          child: idx < pills.length ? pills[idx] : const SizedBox.shrink(),
        ));
        if (j < cols - 1) cells.add(const SizedBox(width: 10));
      }
      rows.add(Row(children: cells));
      if (i + cols < pills.length) rows.add(const SizedBox(height: 10));
    }
    return Column(children: rows);
  }

  Widget _cardLoading() => const Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Center(
          child: CupertinoActivityIndicator(color: kIOSSecondary),
        ),
      );

  // ---- 模式 ----
  Widget _buildModeCard() {
    final labels = _modeLabelList;
    final icons = const [
      CupertinoIcons.wand_stars,
      CupertinoIcons.snow,
      CupertinoIcons.sun_max,
      CupertinoIcons.drop,
      CupertinoIcons.wind,
    ];

    return _card(
      enabled: _powerOn,
      child: _loading
          ? _cardLoading()
          : _pillGrid(
              List.generate(labels.length, (i) {
                final selected = _mode == i && !_applying;
                return _pillButton(
                  icon: icons[i],
                  label: labels[i],
                  selected: selected,
                  onTap: (_powerOn && !_sending)
                      ? () {
                          _mode = i;
                          setState(() {});
                          if (_isCentral) {
                            _sendCentral({'run_mode': _centralRunModes[i]});
                          } else {
                            _send({'mode': _modeValue(i)});
                          }
                        }
                      : null,
                );
              }),
            ),
    );
  }

  // ---- 风速 ----
  /// 普通空调 7 个快捷档（1-100% 无级 + 自动）
  static const List<IconData> _windIcons = [
    CupertinoIcons.speaker_slash_fill,
    CupertinoIcons.speaker_1_fill,
    CupertinoIcons.speaker_1_fill,
    CupertinoIcons.speaker_2_fill,
    CupertinoIcons.speaker_3_fill,
    Icons.waves,
    CupertinoIcons.arrow_2_circlepath,
  ];

  String _fanLabel(int v) {
    if (_isCentral) {
      if (v == 0) return '静音';
      if (v == 8) return '自动';
      return '${(v / 8 * 100).round()}%';
    }
    if (v == 102) return '自动';
    return '$v%';
  }

  /// 中央空调 6 档快捷值（与普通空调 6 按钮对齐）
  static const List<int> _centralFanPills = [0, 2, 4, 6, 7, 8];
  static const List<String> _centralFanPillLabels = [
    '静音', '25%', '50%', '75%', '100%', '自动',
  ];

  Widget _buildFanCard() {
    return _card(
      enabled: _powerOn,
      child: Column(
        children: [
          if (_loading)
            _cardLoading()
          else
            _pillGrid(
              List.generate(_isCentral ? 6 : 7, (i) {
                final bool selected;
                final int outValue;
                if (_isCentral) {
                  outValue = _centralFanPills[i];
                  selected = _fanSpeed == outValue && !_applying;
                } else {
                  outValue = _windValues[i];
                  selected = _fanSpeed == outValue && !_applying;
                }
                return _pillButton(
                  icon: _windIcons[i],
                  label:
                      _isCentral ? _centralFanPillLabels[i] : _windLabels[i],
                  selected: selected,
                  onTap: (_powerOn && !_sending)
                      ? () {
                          _fanSpeed = outValue;
                          setState(() {});
                          if (_isCentral) {
                            _sendCentral({'fan_speed': '$outValue'});
                          } else {
                            _send({_fanKey(): outValue});
                          }
                        }
                      : null,
                );
              }),
            ),
          const SizedBox(height: 14),
          if (!_loading)
            Row(
              children: [
                Icon(
                  _isCentral
                      ? CupertinoIcons.speaker_slash_fill
                      : CupertinoIcons.wind,
                  size: 18,
                  color: kIOSSecondary,
                ),
              Expanded(
                child: _isCentral
                    ? _iosSlider(
                        value: _fanSpeed.clamp(0, 8).toDouble(),
                        min: 0,
                        max: 8,
                        divisions: 8,
                        enabled: _powerOn && !_sending,
                        label: _fanLabel(_fanSpeed),
                        onChanged: (v) =>
                            setState(() => _fanSpeed = v.toInt()),
                        onChangeEnd: (v) {
                          _fanSpeed = v.toInt();
                          _sendCentral({'fan_speed': '${v.toInt()}'});
                        },
                      )
                    : Builder(builder: (_) {
                        // 自动档(102)下滑块停在 1%，拖动即进入无级百分比
                        final isAuto = _fanSpeed == 102;
                        final pos =
                            isAuto ? 1.0 : _fanSpeed.clamp(1, 100).toDouble();
                        return _iosSlider(
                          value: pos,
                          min: 1,
                          max: 100,
                          divisions: 99,
                          enabled: _powerOn && !_sending,
                          label: isAuto ? '自动' : '${pos.round()}%',
                          onChanged: (v) =>
                              setState(() => _fanSpeed = v.toInt()),
                          onChangeEnd: (v) {
                            _fanSpeed = v.toInt();
                            _send({_fanKey(): _fanSpeed});
                          },
                        );
                      }),
              ),
              SizedBox(
                width: 60,
                child: Text(
                  _fanLabel(_fanSpeed),
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: kIOSAccent,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---- 摆风 ----
  Widget _buildSwingCard() {
    return _card(
      enabled: _powerOn,
      child: Row(
        children: [
          Expanded(
            child: _pillButton(
              icon: CupertinoIcons.arrow_up_arrow_down,
              label: '上下摆风',
              selected: _swingV,
              onTap: (_powerOn && !_sending)
                  ? () => _isCentral
                      ? _sendCentral({'extflag': _centralExtSwing(!_swingV)})
                      : _send({
                          'swing_vertical': _flagValue(
                              _flagKeys('swing_vertical'), !_swingV),
                        })
                  : null,
            ),
          ),
          if (!_isCentral) ...[
            const SizedBox(width: 10),
            Expanded(
              child: _pillButton(
                icon: CupertinoIcons.arrow_left_right,
                label: '左右摆风',
                selected: _swingH,
                onTap: (_powerOn && !_sending)
                    ? () => _send({
                          'swing_horizontal': _flagValue(
                              _flagKeys('swing_horizontal'), !_swingH),
                        })
                    : null,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ---- 定时 ----
  Widget _buildTimerCard() {
    return _card(
      enabled: widget.device.online,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _timerRow(
            action: 'off',
            icon: CupertinoIcons.power,
            title: '定时关机',
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Divider(height: 1, color: Colors.black.withValues(alpha: 0.06)),
          ),
          _timerRow(
            action: 'on',
            icon: CupertinoIcons.power,
            title: '定时开机',
          ),
          const SizedBox(height: 4),
          Text(
            _isCentral ? '手机到点自动执行，需手机联网并允许闹钟权限' : '定时保存在空调上，手机关机也生效',
            style: const TextStyle(fontSize: 12, color: kIOSSecondary),
          ),
        ],
      ),
    );
  }

  Widget _timerRow({
    required String action,
    required IconData icon,
    required String title,
  }) {
    final mins = _timerMinutes(action);
    final at = _timerAt(action);
    final active = mins > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 19, color: active ? kIOSAccent : kIOSSecondary),
            const SizedBox(width: 8),
            Text(
              title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: kIOSLabel,
              ),
            ),
            const Spacer(),
            Text(
              _fmtMinutes(mins),
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: active ? kIOSAccent : kIOSSecondary,
              ),
            ),
            const SizedBox(width: 4),
            GestureDetector(
              onTap: () => _customTimer(action),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(CupertinoIcons.clock,
                    size: 19, color: kIOSAccent),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // 快捷时长按钮
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (final q in _quickTimers)
              _quickChip(
                label: q.label,
                selected:
                    !active ? false : mins.round() == q.minutes,
                onTap: widget.device.online && !_sending
                    ? () => _quickTimer(action, q.minutes)
                    : null,
              ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _iosSlider(
                value: mins,
                min: 0,
                max: 480,
                divisions: 32,
                enabled: widget.device.online && !_sending,
                onChanged: (v) {
                  final snapped = (v / 15).round() * 15.0;
                  setState(() {
                    if (action == 'on') {
                      _previewOnMin = snapped;
                    } else {
                      _previewOffMin = snapped;
                    }
                  });
                },
                onChangeEnd: (v) {
                  final snapped = (v / 15).round() * 15;
                  setState(() {
                    if (action == 'on') {
                      _previewOnMin = null;
                    } else {
                      _previewOffMin = null;
                    }
                  });
                  if (snapped <= 0) {
                    if (active) _cancelTimer(action);
                  } else {
                    _setTimer(
                        action, DateTime.now().add(Duration(minutes: snapped.round())));
                  }
                },
              ),
            ),
            if (at != null && active) ...[
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => _cancelTimer(action),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: kIOSAccent.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _fmtClock(at),
                        style: const TextStyle(
                          color: kIOSAccent,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(Icons.close,
                          size: 15, color: kIOSAccent),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  // ---- 更多功能 ----
  Widget _buildFunctionsCard() {
    if (_isCentral) {
      return _card(
        enabled: _powerOn,
        child: _functionRow(
          icon: CupertinoIcons.flame,
          label: '电辅热',
          value: _functions['aux_heat'] ?? false,
          onChanged: (v) {
            _functions['aux_heat'] = v;
            setState(() {});
            _sendCentral({'extflag': _centralExtAux(v)});
          },
        ),
      );
    }
    return _card(
      enabled: _powerOn,
      child: Column(
        children: [
          _functionRow(
            icon: CupertinoIcons.moon_stars_fill,
            label: '睡眠模式',
            value: _functions['sleep'] ?? false,
            onChanged: (v) {
              _functions['sleep'] = v;
              setState(() {});
              _send({'sleep': _flagValue(_flagKeys('sleep'), v)});
            },
          ),
          _functionRow(
            icon: CupertinoIcons.flame,
            label: '电辅热',
            value: _functions['aux_heat'] ?? false,
            onChanged: (v) {
              _functions['aux_heat'] = v;
              setState(() {});
              _send({'aux_heat': _flagValue(_flagKeys('aux_heat'), v)});
            },
          ),
          _functionRow(
            icon: CupertinoIcons.drop_fill,
            label: '干燥防霉',
            value: _functions['dry'] ?? false,
            onChanged: (v) {
              _functions['dry'] = v;
              setState(() {});
              _send({'dry': _flagValue(_flagKeys('dry'), v)});
            },
          ),
          _functionRow(
            icon: CupertinoIcons.tv_fill,
            label: '屏幕显示',
            value: _functions['screen_display'] ?? false,
            showDivider: false,
            onChanged: (v) {
              _functions['screen_display'] = v;
              setState(() {});
              // 写 screen_display：字符串物模型发 on/off，数值发 100/0
              final cur = _lastStatus['screen_display_now'] ??
                  _lastStatus['screen_display'];
              _send({
                'screen_display':
                    cur is String ? (v ? 'on' : 'off') : (v ? 100 : 0),
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _functionRow({
    required IconData icon,
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
    bool showDivider = true,
  }) {
    return Opacity(
      opacity: _powerOn && !_sending ? 1 : 0.5,
      child: Column(
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: kIOSAccent),
              const SizedBox(width: 12),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 16,
                  color: kIOSLabel,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(),
              CupertinoSwitch(
                value: value,
                activeTrackColor: kIOSAccent,
                onChanged: (_powerOn && !_sending) ? onChanged : null,
              ),
            ],
          ),
          if (showDivider)
            Padding(
              padding: const EdgeInsets.only(left: 32),
              child: Divider(
                  height: 16, color: Colors.black.withValues(alpha: 0.06)),
            ),
        ],
      ),
    );
  }

  // ============================================================
  // 通用组件
  // ============================================================
  Widget _card({required Widget child, required bool enabled}) {
    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: WhiteCard(
        padding: const EdgeInsets.all(16),
        child: child,
      ),
    );
  }

  /// 定时快捷小按钮
  Widget _quickChip({
    required String label,
    required bool selected,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 34,
        width: 58,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? kIOSAccent.withValues(alpha: 0.12)
              : const Color(0xFFF2F2F7),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? kIOSAccent : Colors.transparent,
            width: 1.4,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: selected ? kIOSAccent : kIOSSecondary,
          ),
        ),
      ),
    );
  }

  /// iOS 风药丸按钮（图标+文字，填满父级宽度）
  Widget _pillButton({
    required IconData icon,
    required String label,
    required bool selected,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: selected ? kIOSAccent : kIOSFill,
          borderRadius: BorderRadius.circular(23),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: kIOSAccent.withValues(alpha: 0.25),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 17,
                  color:
                      selected ? Colors.white : kIOSLabel.withValues(alpha: 0.75)),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: selected ? Colors.white : kIOSLabel,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 粗滑块（iOS 音量条风格：粗轨道 + 白色大滑块钮）
  Widget _iosSlider({
    required double value,
    required double min,
    required double max,
    int? divisions,
    required bool enabled,
    required ValueChanged<double> onChanged,
    ValueChanged<double>? onChangeEnd,
    String? label,
    bool onHero = false,
  }) {
    final v = value.clamp(min, max);
    return SliderTheme(
      data: SliderThemeData(
        trackHeight: 12,
        activeTrackColor: onHero ? Colors.white : kIOSAccent,
        inactiveTrackColor:
            onHero ? Colors.white24 : Colors.black.withValues(alpha: 0.08),
        thumbColor: Colors.white,
        overlayColor:
            (onHero ? Colors.white : kIOSAccent).withValues(alpha: 0.18),
        thumbShape: RoundSliderThumbShape(
          enabledThumbRadius: onHero ? 15 : 14,
          elevation: 3,
          pressedElevation: 6,
        ),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 24),
        trackShape: _RoundedTrackShape(),
        activeTickMarkColor: onHero ? Colors.white70 : Colors.white70,
        inactiveTickMarkColor:
            onHero ? Colors.white30 : Colors.black.withValues(alpha: 0.12),
      ),
      child: Slider(
        value: v,
        min: min,
        max: max,
        divisions: divisions,
        label: label,
        onChanged: enabled ? onChanged : null,
        onChangeEnd: enabled ? onChangeEnd : null,
      ),
    );
  }
}

/// 全圆角粗轨道
class _RoundedTrackShape extends RoundedRectSliderTrackShape {
  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 0,
  }) {
    final trackHeight = sliderTheme.trackHeight ?? 12;
    final trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final r = Radius.circular(trackHeight / 2);

    final inactive = RRect.fromRectAndRadius(trackRect, r);
    context.canvas.drawRRect(
      inactive,
      Paint()..color = sliderTheme.inactiveTrackColor ?? const Color(0x14000000),
    );

    if (thumbCenter.dx <= trackRect.left) return;
    final activeRect = Rect.fromLTRB(
      trackRect.left,
      trackRect.top,
      thumbCenter.dx,
      trackRect.bottom,
    );
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(activeRect, r),
      Paint()..color = sliderTheme.activeTrackColor ?? kIOSAccent,
    );
  }
}
