import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'net/midea_cloud.dart';

/// 会话持久化：账号、Token、AES 通信密钥
class SessionStore {
  static const _kAccount = 'account';
  static const _kPassword = 'password';
  static const _kToken = 'token';
  static const _kAesKey = 'aes_key';
  static const _kNickname = 'nickname';
  static const _kHomeGroup = 'homegroup_id';
  static const _kStatusPrefix = 'dev_status_';

  final SharedPreferences _prefs;

  SessionStore._(this._prefs);

  static Future<SessionStore> create() async =>
      SessionStore._(await SharedPreferences.getInstance());

  String? get account => _prefs.getString(_kAccount);
  String? get password => _prefs.getString(_kPassword);
  String? get token => _prefs.getString(_kToken);
  String? get aesKey => _prefs.getString(_kAesKey);
  String? get nickname => _prefs.getString(_kNickname);

  bool get isLoggedIn =>
      (token?.isNotEmpty ?? false) && (account?.isNotEmpty ?? false);

  Future<void> save(MideaCloud cloud, String password) async {
    await _prefs.setString(_kAccount, cloud.account);
    await _prefs.setString(_kPassword, password);
    await _prefs.setString(_kToken, cloud.accessToken ?? '');
    await _prefs.setString(_kAesKey, cloud.aesKey ?? '');
    await _prefs.setString(_kNickname, cloud.nickname ?? '');
  }

  Future<void> updateTokens(MideaCloud cloud) async {
    await _prefs.setString(_kToken, cloud.accessToken ?? '');
    await _prefs.setString(_kAesKey, cloud.aesKey ?? '');
    await _prefs.setString(_kNickname, cloud.nickname ?? '');
    if (cloud.lastHomegroupId != null) {
      await _prefs.setString(_kHomeGroup, cloud.lastHomegroupId!);
    }
  }

  Future<void> clear() async {
    await _prefs.remove(_kAccount);
    await _prefs.remove(_kPassword);
    await _prefs.remove(_kToken);
    await _prefs.remove(_kAesKey);
    await _prefs.remove(_kNickname);
    await _prefs.remove(_kHomeGroup);
  }

  /// 缓存设备最近一次状态（进入控制页时秒显，后台再静默刷新）
  Future<void> saveStatus(String deviceKey, Map<String, dynamic> s) async {
    try {
      await _prefs.setString(_kStatusPrefix + deviceKey, jsonEncode(s));
    } catch (_) {}
  }

  Map<String, dynamic>? getStatus(String deviceKey) {
    final raw = _prefs.getString(_kStatusPrefix + deviceKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw);
      return m is Map<String, dynamic> ? m : null;
    } catch (_) {
      return null;
    }
  }

  /// 从存储恢复已登录的云客户端
  MideaCloud? restoreCloud() {
    final acc = account;
    final pwd = password;
    if (acc == null || pwd == null) return null;
    final cloud = MideaCloud(account: acc, password: pwd);
    cloud.accessToken = token;
    cloud.aesKey = aesKey;
    cloud.nickname = nickname;
    cloud.lastHomegroupId = _prefs.getString(_kHomeGroup);
    return cloud;
  }
}
