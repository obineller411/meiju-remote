import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../crypto/meiju_security.dart';
import '../models/device_info.dart';
import 'py_json.dart';

/// 美的云 API 错误
class CloudException implements Exception {
  final int code;
  @override
  final String message;

  CloudException(this.code, this.message);

  @override
  String toString() => '[$code] $message';
}

/// 美的美居云客户端（对应 Python midea_client.MideaClient）
class MideaCloud {
  final String account;
  final String password;

  String? accessToken;
  String? aesKey;
  String? nickname;

  /// 最近使用的家庭 ID（中央空调网关控制需要）
  String? lastHomegroupId;

  /// 中央空调子设备属性：设备码 → {nodeid, masterId, modelid, idType}
  final Map<int, Map<String, String>> _centralAttrs = {};

  MideaCloud({required this.account, required this.password});

  String get deviceId => MeijuSecurity.deviceId(account);

  static const String _baseUrl =
      'https://mp-prod.smartmidea.net/mas/v5/app/proxy?alias=';

  // ============================================================
  // 通用请求（签名 + 自动重登）
  // ============================================================
  Future<Map<String, dynamic>> _apiRequest(
    String endpoint,
    Map<String, Object?> payload, {
    bool retried = false,
  }) async {
    payload.putIfAbsent('reqId', () => _randomReqId());
    payload.putIfAbsent('stamp', () => _stamp());

    final random =
        (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    final body = PyJson.encode(payload);
    final sign = MeijuSecurity.sign(body, random);

    final resp = await http
        .post(
          Uri.parse(_baseUrl + endpoint),
          headers: {
            'content-type': 'application/json; charset=utf-8',
            'secretVersion': '1',
            'sign': sign,
            'random': random,
            if (accessToken != null) 'accesstoken': accessToken!,
          },
          body: body,
        )
        .timeout(const Duration(seconds: 12));

    final Map<String, dynamic> response =
        jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final code = _asInt(response['code'], fallback: -1);

    if (code == 0) {
      return (response['data'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    }

    // Token 失效：自动重新登录并重试一次
    final loginEndpoint =
        endpoint.contains('/user/login') || endpoint.contains('/unitcenter/router/');
    if (!retried && !loginEndpoint && _isTokenInvalid(response)) {
      accessToken = null;
      if (await login()) {
        return _apiRequest(endpoint, payload, retried: true);
      }
    }

    final msg = (response['msg']?.toString() ??
            response['message']?.toString() ??
            '未知错误')
        .toString();
    throw CloudException(code, msg);
  }

  bool _isTokenInvalid(Map<String, dynamic> response) {
    final code = _asInt(response['code'], fallback: -1);
    final msg =
        ('${response['msg'] ?? ''}${response['message'] ?? ''}').toLowerCase();
    return code == 40002 ||
        code == 7400 ||
        msg.contains('user token not exist') ||
        msg.contains('token校验不通过');
  }

  // ============================================================
  // 登录
  // ============================================================
  Future<bool> login() async {
    final loginIdResp = await _apiRequest(
      '/v1/user/login/id/get',
      pyObj([Pair('loginAccount', account), Pair('type', '1')]),
    );
    final loginId = loginIdResp['loginId']?.toString();
    if (loginId == null || loginId.isEmpty) return false;

    final stamp = _stamp();
    final resp = await _apiRequest(
      '/mj/user/login',
      pyObj([
        Pair(
          'iotData',
          pyObj([
            Pair('clientType', 1),
            Pair('deviceId', deviceId),
            Pair('iampwd', MeijuSecurity.iamPassword(password)),
            Pair('iotAppId', MeijuSecurity.appId),
            Pair('loginAccount', account),
            Pair('password', MeijuSecurity.loginPassword(loginId, password)),
            Pair('reqId', _randomReqId()),
            Pair('stamp', stamp),
          ]),
        ),
        Pair(
          'data',
          pyObj([
            Pair('appKey', MeijuSecurity.appKey),
            Pair('deviceId', deviceId),
            Pair('platform', 2),
          ]),
        ),
        Pair('timestamp', stamp),
        Pair('stamp', stamp),
      ]),
    );

    final mdata = resp['mdata'] as Map<String, dynamic>?;
    if (mdata == null) return false;
    accessToken = mdata['accessToken']?.toString();
    if (accessToken == null || accessToken!.isEmpty) return false;

    // 解密 AES 通信密钥
    aesKey = MeijuSecurity.decryptSessionKey(resp['key'] as String);

    final userInfo = resp['userInfo'] as Map<String, dynamic>?;
    if (userInfo != null && userInfo['nickName'] != null) {
      final name = userInfo['nickName'].toString();
      if (name.isNotEmpty) nickname = name;
    }
    return true;
  }

  // ============================================================
  // 家庭 / 设备
  // ============================================================
  Future<Map<int, String>> homes() async {
    final resp = await _apiRequest('/v1/homegroup/list/get', pyObj());
    final out = <int, String>{};
    final list = resp['homeList'] as List?;
    if (list == null) return out;
    for (final home in list) {
      final h = home as Map<String, dynamic>;
      out[_asInt(h['homegroupId'])] = h['name']?.toString() ?? '';
    }
    return out;
  }

  Future<List<DeviceInfo>> devices(int homeId) async {
    lastHomegroupId = homeId.toString();
    final resp = await _apiRequest(
      '/v1/appliance/home/list/get',
      pyObj([Pair('homegroupId', homeId)]),
    );
    final out = <DeviceInfo>[];
    final homeList = resp['homeList'] as List?;
    if (homeList == null) return out;

    for (final h in homeList) {
      final home = h as Map<String, dynamic>;
      final roomList = home['roomList'] as List?;
      if (roomList == null) continue;
      for (final r in roomList) {
        final room = r as Map<String, dynamic>;
        final roomName = room['name']?.toString() ?? '';
        final applianceList = room['applianceList'] as List?;
        if (applianceList == null) continue;
        for (final a in applianceList) {
          final appliance = a as Map<String, dynamic>;
          // type 可能带 0x 前缀（如 "0xAC"），Python int(x,16) 接受前缀而 Dart 不接受
          final typeHex =
              appliance['type']?.toString().trim().replaceFirst(
                    RegExp('^0x', caseSensitive: false),
                    '',
                  ) ??
                  '';
          final type = int.tryParse(typeHex, radix: 16) ?? 0;

          final snHex = appliance['sn']?.toString();
          if (snHex != null && snHex.isNotEmpty && aesKey != null) {
            try {
              MeijuSecurity.aesDecrypt(snHex, aesKey!);
            } catch (_) {
              // 忽略 SN 解密失败
            }
          }

          out.add(DeviceInfo(
            code: _asInt(appliance['applianceCode']),
            name: appliance['name']?.toString() ?? '未命名设备',
            type: type,
            online: appliance['onlineStatus']?.toString() == '1',
            room: roomName,
            model: (appliance['productModel']?.toString() ??
                    appliance['sn8']?.toString() ??
                    '')
                .toString(),
            sn8: appliance['sn8']?.toString() ?? '00000000',
          ));
        }
      }
    }
    return out;
  }

  // ============================================================
  // 状态 / 控制
  // ============================================================
  Future<Map<String, dynamic>> status(int applianceCode) async {
    return _apiRequest(
      '/mjl/v1/device/status/lua/get',
      pyObj([
        Pair('applianceCode', applianceCode.toString()),
        Pair('command', pyObj([Pair('query', pyObj())])),
      ]),
    );
  }

  Future<Map<String, dynamic>> control(
      int applianceCode, Map<String, Object?> params) async {
    return _apiRequest(
      '/mjl/v1/device/lua/control',
      pyObj([
        Pair('applianceCode', applianceCode.toString()),
        Pair('command', pyObj([Pair('control', params)])),
      ]),
    );
  }

  // ============================================================
  // 中央空调（T0x21 子设备）：聚合器状态 + 网关透传控制
  // 移植自 midea_auto_cloud get_central_ac_status / send_central_ac_control
  // ============================================================

  /// 中央空调状态：POST /api/v1/aggregator/appliances
  /// 同时提取 nodeid/masterId/modelid/idType 供控制使用
  Future<Map<String, dynamic>> statusCentral(DeviceInfo device) async {
    final resp = await _apiRequest(
      '/api/v1/aggregator/appliances',
      pyObj([
        Pair('entities', ['endlist', 'tips']),
        Pair('appliances', [
          pyObj([
            Pair('id', device.code.toString()),
            Pair('type', '0x21'),
          ]),
        ]),
      ]),
    );

    final result = <String, dynamic>{};
    final list = resp['appliances'] as List?;
    if (list == null) return result;
    for (final item in list) {
      final ap = item as Map<String, dynamic>;
      final attr =
          (ap['extraData'] as Map<String, dynamic>?)?['attr'] as Map?;
      if (attr == null) continue;

      // 保存控制所需的网关/子设备属性
      final attrs = <String, String>{};
      for (final k in ['nodeid', 'masterId', 'modelid', 'idType']) {
        final v = attr[k];
        if (v != null) attrs[k] = v.toString();
      }
      if (attrs.isNotEmpty) _centralAttrs[device.code] = attrs;

      // 状态字段在 state.condition_attribute 下
      final state = attr['state'] as Map?;
      final cond = state?['condition_attribute'];
      if (cond is Map) {
        cond.forEach((k, v) => result[k.toString()] = v);
      }
      break;
    }
    return result;
  }

  /// 中央空调控制：POST /v1/gateway/transport/send（AES 加密 order）
  Future<Map<String, dynamic>> controlCentral(
      DeviceInfo device, Map<String, Object?> event) async {
    final attrs = _centralAttrs[device.code];
    final nodeid = attrs?['nodeid'];
    final masterId = attrs?['masterId'];
    final modelid = attrs?['modelid'];
    final idType = attrs?['idType'];
    if (nodeid == null ||
        masterId == null ||
        modelid == null ||
        idType == null) {
      throw Exception('缺少中央空调子设备属性，请下拉刷新状态后重试');
    }

    final request = pyObj([
      Pair('applianceCode', masterId),
      Pair('modelId', modelid),
      Pair('topic', '/subdevice/multicontrol'),
      Pair('command', pyObj([
        Pair('nodeid', nodeid),
        Pair('acattri_ctrl', pyObj([
          Pair('nodeid', nodeid),
          Pair('modelid', modelid),
          Pair('type', _asInt(idType)),
          Pair(
              'aclist_data',
              nodeid.length >= 2
                  ? nodeid.substring(nodeid.length - 2)
                  : nodeid),
          Pair('event', event),
        ])),
      ])),
      Pair('msgId', _randomReqId()),
    ]);

    final plain = PyJson.encode(request);
    final order = MeijuSecurity.aesEncryptHex(plain, aesKey!);

    return _apiRequest(
      '/v1/gateway/transport/send',
      pyObj([
        Pair('applianceCode', masterId),
        Pair('order', order),
        Pair('homegroupId', lastHomegroupId ?? ''),
      ]),
    );
  }

  // ============================================================
  // 工具
  // ============================================================
  /// 云端 ID 字段可能返回字符串或数字，统一解析为 int
  static int _asInt(Object? v, {int fallback = 0}) {
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString().trim() ?? '') ?? fallback;
  }

  String _stamp() {
    final d = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}${two(d.month)}${two(d.day)}'
        '${two(d.hour)}${two(d.minute)}${two(d.second)}';
  }

  String _randomReqId() {
    final random = Random.secure();
    return List.generate(32, (_) => random.nextInt(16).toRadixString(16)).join();
  }
}
