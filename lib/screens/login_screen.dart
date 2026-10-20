import 'package:flutter/material.dart';

import '../net/midea_cloud.dart';
import '../session_store.dart';
import '../widgets/gradient_background.dart';
import 'device_list_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _accountCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _loading = false;

  @override
  void dispose() {
    _accountCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _loading = true);

    final cloud = MideaCloud(
      account: _accountCtrl.text.trim(),
      password: _passwordCtrl.text,
    );

    try {
      final ok = await cloud.login();
      if (!ok || !mounted) {
        _showError('登录失败，请检查账号密码');
        return;
      }
      final store = await SessionStore.create();
      await store.save(cloud, _passwordCtrl.text);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const DeviceListScreen()),
      );
    } on CloudException catch (e) {
      _showError('登录失败：${e.message}');
    } catch (e) {
      _showError('网络错误：$e');
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    setState(() => _loading = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GradientBackground(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: MediaQuery.of(context).size.height -
                    MediaQuery.of(context).padding.top -
                    MediaQuery.of(context).padding.bottom -
                    56,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF0071E3),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF0071E3)
                              .withValues(alpha: 0.3),
                          blurRadius: 20,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: const Icon(Icons.ac_unit,
                        color: Colors.white, size: 48),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    '美居遥控器',
                    style: TextStyle(
                      color: Color(0xFF1D1D1F),
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '不打开美居 App，手机直接控制家电',
                    style: TextStyle(
                      color: Color(0xFF86868B),
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 32),
                  WhiteCard(
                    padding: const EdgeInsets.all(22),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        children: [
                          TextFormField(
                            controller: _accountCtrl,
                            keyboardType: TextInputType.phone,
                            maxLength: 20,
                            decoration: const InputDecoration(
                              labelText: '美居账号（手机号）',
                              prefixIcon: Icon(Icons.person_outline),
                              counterText: '',
                              border: OutlineInputBorder(),
                            ),
                            validator: (v) =>
                                (v == null || v.trim().isEmpty) ? '请输入账号' : null,
                          ),
                          const SizedBox(height: 14),
                          TextFormField(
                            controller: _passwordCtrl,
                            obscureText: true,
                            decoration: const InputDecoration(
                              labelText: '美居密码',
                              prefixIcon: Icon(Icons.lock_outline),
                              border: OutlineInputBorder(),
                            ),
                            validator: (v) =>
                                (v == null || v.isEmpty) ? '请输入密码' : null,
                          ),
                          const SizedBox(height: 24),
                          SizedBox(
                            width: double.infinity,
                            height: 54,
                            child: FilledButton(
                              onPressed: _loading ? null : _login,
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFF0071E3),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(27),
                                ),
                                textStyle: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              child: _loading
                                  ? const SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.5,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Text('登 录'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    '账号密码仅用于登录美的官方云服务',
                    style: TextStyle(
                      color: Color(0xFF86868B),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
