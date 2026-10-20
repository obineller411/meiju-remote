import 'dart:convert';
import 'dart:io' show Platform;

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/device_info.dart';
import '../session_store.dart';

/// 定时任务
class TimerTask {
  final int id; // AlarmManager 闹钟 ID
  final int deviceCode;
  final int deviceType;
  final String action; // 'on' / 'off'
  final int triggerAt; // 触发时间（epoch 毫秒）
  final String deviceName;

  const TimerTask({
    required this.id,
    required this.deviceCode,
    required this.deviceType,
    required this.action,
    required this.triggerAt,
    required this.deviceName,
  });

  bool get isCentral => deviceType == 0x21;
  bool get isOn => action == 'on';
  DateTime get time => DateTime.fromMillisecondsSinceEpoch(triggerAt);

  Map<String, dynamic> toJson() => {
        'id': id,
        'deviceCode': deviceCode,
        'deviceType': deviceType,
        'action': action,
        'triggerAt': triggerAt,
        'deviceName': deviceName,
      };

  factory TimerTask.fromJson(Map<String, dynamic> j) => TimerTask(
        id: (j['id'] as num).toInt(),
        deviceCode: (j['deviceCode'] as num).toInt(),
        deviceType: (j['deviceType'] as num).toInt(),
        action: j['action'] as String,
        triggerAt: (j['triggerAt'] as num).toInt(),
        deviceName: (j['deviceName'] ?? '') as String,
      );
}

/// 定时开关机服务：本地精确闹钟到点自动下发云控制指令
class TimerService {
  static const _kStoreKey = 'timer_tasks_v1';
  static const int _maxAlarmId = 0x7fffffff;

  static Future<List<TimerTask>> _readAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kStoreKey);
    if (raw == null || raw.isEmpty) return [];
    final list = jsonDecode(raw) as List;
    return list
        .map((e) => TimerTask.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<void> _writeAll(List<TimerTask> tasks) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kStoreKey,
      jsonEncode(tasks.map((t) => t.toJson()).toList()),
    );
  }

  /// 该设备当前生效的定时任务
  static Future<List<TimerTask>> tasksFor(int deviceCode) async {
    final all = await _readAll();
    return all.where((t) => t.deviceCode == deviceCode).toList();
  }

  /// 安排定时任务（同一设备同一动作只保留最新一条）
  /// 本地闹钟为 Android 专属能力（中央空调无设备侧定时才走这里）
  static Future<TimerTask> schedule({
    required DeviceInfo device,
    required String action, // 'on' / 'off'
    required DateTime when,
  }) async {
    if (!Platform.isAndroid) {
      throw Exception('中央空调本地定时目前仅支持 Android 设备');
    }
    final all = await _readAll();
    // 取消同设备同动作的旧任务
    final old =
        all.where((t) => t.deviceCode == device.code && t.action == action);
    for (final t in old) {
      await AndroidAlarmManager.cancel(t.id);
    }
    all.removeWhere(
        (t) => t.deviceCode == device.code && t.action == action);

    final id = (when.millisecondsSinceEpoch % _maxAlarmId).abs() +
        (action == 'on' ? 1 : 0);
    final task = TimerTask(
      id: id,
      deviceCode: device.code,
      deviceType: device.type,
      action: action,
      triggerAt: when.millisecondsSinceEpoch,
      deviceName: device.name,
    );

    final ok = await AndroidAlarmManager.oneShotAt(
      when,
      id,
      _alarmCallback,
      exact: true,
      wakeup: true,
      rescheduleOnReboot: true,
    );
    if (!ok) throw Exception('系统拒绝了精确闹钟，请检查闹钟权限');
    all.add(task);
    await _writeAll(all);
    return task;
  }

  /// 取消单个任务
  static Future<void> cancel(TimerTask task) async {
    if (Platform.isAndroid) {
      await AndroidAlarmManager.cancel(task.id);
    }
    final all = await _readAll();
    all.removeWhere((t) => t.id == task.id);
    await _writeAll(all);
  }
}

/// 闹钟回调（后台 isolate 入口）
@pragma('vm:entry-point')
Future<void> _alarmCallback(int id) async {
  SharedPreferences? prefs;
  try {
    prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(TimerService._kStoreKey);
    if (raw == null) return;
    final all = (jsonDecode(raw) as List)
        .map((e) => TimerTask.fromJson(e as Map<String, dynamic>))
        .toList();
    final task = all.where((t) => t.id == id).cast<TimerTask?>().firstWhere(
          (t) => t != null,
          orElse: () => null,
        );
    if (task == null) return;

    final store = await SessionStore.create();
    final cloud = store.restoreCloud();
    if (cloud == null) return;

    final device = DeviceInfo(
      code: task.deviceCode,
      name: task.deviceName,
      type: task.deviceType,
      online: true,
      room: '',
      model: '',
      sn8: '',
    );

    if (task.isCentral) {
      // statusCentral 会同时拿到网关子设备属性（nodeid 等）
      final s = await cloud.statusCentral(device);
      String cur(Object? v, String def) {
        final t = v?.toString().trim();
        return (t == null || t.isEmpty) ? def : t;
      }

      String lastMode = cur(s['run_mode'], '2');
      if (lastMode == '0') lastMode = '2';
      await cloud.controlCentral(device, {
        // 开机恢复上次运行模式（关机态记录为 0 时默认制冷），关机发 0
        'run_mode': task.isOn ? lastMode : '0',
        'cooling_temp':
            cur(s['cool_temp_set'] ?? s['temperature'], '26'),
        'heating_temp':
            cur(s['heat_temp_set'] ?? s['temperature'], '26'),
        'fan_speed': cur(s['fan_speed'], '8'),
        'extflag': cur(s['extflag'], '0'),
      });
    } else {
      await cloud.control(task.deviceCode, {
        'power': task.isOn ? 'on' : 'off',
      });
    }
  } catch (_) {
    // 后台静默失败，避免反复唤醒
  } finally {
    // 无论成败都移除任务记录（一次性任务）
    try {
      prefs ??= await SharedPreferences.getInstance();
      final raw = prefs.getString(TimerService._kStoreKey);
      if (raw != null) {
        final all = (jsonDecode(raw) as List)
            .map((e) => TimerTask.fromJson(e as Map<String, dynamic>))
            .toList();
        all.removeWhere((t) => t.id == id);
        await prefs.setString(
          TimerService._kStoreKey,
          jsonEncode(all.map((t) => t.toJson()).toList()),
        );
      }
    } catch (_) {}
  }
}
