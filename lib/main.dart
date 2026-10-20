import 'dart:io';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/material.dart';

import 'screens/device_list_screen.dart';
import 'screens/login_screen.dart';
import 'session_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // android_alarm_manager_plus 仅支持 Android，iOS 上调用会抛 MissingPluginException 导致白屏
  if (Platform.isAndroid) {
    await AndroidAlarmManager.initialize();
  }
  runApp(const MeijuApp());
}

class MeijuApp extends StatelessWidget {
  const MeijuApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '空调遥控',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0071E3),
          primary: const Color(0xFF0071E3),
        ),
        useMaterial3: true,
        fontFamily: 'sans-serif',
      ),
      home: const _Bootstrap(),
    );
  }
}

/// 启动路由：有会话进设备列表，否则进登录页
class _Bootstrap extends StatelessWidget {
  const _Bootstrap();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SessionStore>(
      future: SessionStore.create(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final store = snapshot.data!;
        if (store.isLoggedIn) {
          return const DeviceListScreen();
        }
        return const LoginScreen();
      },
    );
  }
}
