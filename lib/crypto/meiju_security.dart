import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

/// 美的美居云 API 加密安全模块（对应 Python security.py）
class MeijuSecurity {
  static const String appKey = '46579c15';
  static const String loginKey = 'ad0ee21d48a64bf49f4fb583ab76e799';
  static const String iotKey = 'prod_secret123@muc';
  static const String hmacKey = 'PROD_VnoClJI9aikS8dyy';

  /// 登录返回通信密钥所用的固定 AES 密钥（hex 字符串的 ASCII 字节）
  static const String fixedKey = '96c7acdfdb8af79a';
  static const String appId = '900';

  /// 请求签名：HMAC-SHA256(hmac_key, iot_key + body + random)
  static String sign(String body, String random) {
    final bytes = utf8.encode('$iotKey$body$random');
    return Hmac(sha256, utf8.encode(hmacKey)).convert(bytes).toString();
  }

  /// 登录密码加密：SHA256(loginId + SHA256(password) + login_key)
  static String loginPassword(String loginId, String password) {
    final pwdHash = sha256.convert(utf8.encode(password)).toString();
    return sha256.convert(utf8.encode('$loginId$pwdHash$loginKey')).toString();
  }

  /// iampwd：MD5(MD5(password))
  static String iamPassword(String password) {
    final first = md5.convert(utf8.encode(password)).toString();
    return md5.convert(utf8.encode(first)).toString();
  }

  /// 设备ID：MD5("Hello, {username}!") 的前16位
  static String deviceId(String username) =>
      md5.convert(utf8.encode('Hello, $username!')).toString().substring(0, 16);

  /// 用固定密钥 AES/ECB 解密登录返回的通信密钥
  static String decryptSessionKey(String hex) =>
      _aesEcb(asciiBytes(fixedKey), hexDecode(hex), false);

  /// 用会话密钥 AES/ECB 解密 hex 数据
  static String aesDecrypt(String hexData, String asciiKey) =>
      _aesEcb(asciiBytes(asciiKey), hexDecode(hexData), false);

  /// 用会话密钥 AES/ECB 加密明文，返回 hex（中央空调网关 order 字段）
  static String aesEncryptHex(String plain, String asciiKey) {
    final cipher = ECBBlockCipher(AESEngine())
      ..init(true, KeyParameter(asciiBytes(asciiKey)));
    final padded = _pkcs7Pad(Uint8List.fromList(utf8.encode(plain)));
    final out = Uint8List(padded.length);
    var offset = 0;
    while (offset < padded.length) {
      offset += cipher.processBlock(padded, offset, out, offset);
    }
    return out.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static Uint8List asciiBytes(String s) =>
      Uint8List.fromList(s.codeUnits);

  static String _aesEcb(
      Uint8List key, Uint8List data, bool encrypt) {
    final cipher = ECBBlockCipher(AESEngine())
      ..init(encrypt, KeyParameter(key));

    final input = encrypt ? _pkcs7Pad(data) : data;
    final out = Uint8List(input.length);
    var offset = 0;
    while (offset < input.length) {
      offset += cipher.processBlock(input, offset, out, offset);
    }
    final result = encrypt ? out : _pkcs7Unpad(out);
    return utf8.decode(result);
  }

  static Uint8List _pkcs7Pad(Uint8List data) {
    const blockSize = 16;
    final padLen = blockSize - (data.length % blockSize);
    final out = Uint8List(data.length + padLen);
    out.setRange(0, data.length, data);
    out.fillRange(data.length, out.length, padLen);
    return out;
  }

  static Uint8List _pkcs7Unpad(Uint8List data) {
    if (data.isEmpty) return data;
    final padLen = data.last;
    if (padLen < 1 || padLen > 16 || padLen > data.length) {
      return data;
    }
    for (var i = data.length - padLen; i < data.length; i++) {
      if (data[i] != padLen) return data;
    }
    return data.sublist(0, data.length - padLen);
  }

  static Uint8List hexDecode(String s) {
    final clean = s.trim();
    if (clean.length % 2 != 0) {
      throw ArgumentError('非法的十六进制字符串');
    }
    final out = Uint8List(clean.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}
