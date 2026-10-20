/// 与 Python json.dumps 字节级兼容的 JSON 序列化器。
///
/// 美的云签名对请求体原文计算 HMAC，Python 默认特征：
///  - 分隔符 ", " 和 ": "（带空格）
///  - ensure_ascii：非 ASCII 转义为 \uXXXX
///  - 保持 Map 插入顺序（Dart Map 默认为 LinkedHashMap）
class PyJson {
  static String encode(Object? value) {
    final sb = StringBuffer();
    _encode(sb, value);
    return sb.toString();
  }

  static void _encode(StringBuffer sb, Object? v) {
    if (v == null) {
      sb.write('null');
    } else if (v is bool) {
      sb.write(v ? 'true' : 'false');
    } else if (v is num) {
      sb.write(v.toString());
    } else if (v is String) {
      _encodeString(sb, v);
    } else if (v is Map) {
      sb.write('{');
      var first = true;
      v.forEach((k, vv) {
        if (!first) sb.write(', ');
        first = false;
        _encodeString(sb, k.toString());
        sb.write(': ');
        _encode(sb, vv);
      });
      sb.write('}');
    } else if (v is Iterable) {
      sb.write('[');
      var first = true;
      for (final vv in v) {
        if (!first) sb.write(', ');
        first = false;
        _encode(sb, vv);
      }
      sb.write(']');
    } else {
      throw ArgumentError('不支持序列化的类型: ${v.runtimeType}');
    }
  }

  static void _encodeString(StringBuffer sb, String s) {
    sb.write('"');
    for (final c in s.codeUnits) {
      switch (c) {
        case 0x22:
          sb.write(r'\"');
          break;
        case 0x5C:
          sb.write(r'\\');
          break;
        case 0x0A:
          sb.write(r'\n');
          break;
        case 0x0D:
          sb.write(r'\r');
          break;
        case 0x09:
          sb.write(r'\t');
          break;
        case 0x08:
          sb.write(r'\b');
          break;
        case 0x0C:
          sb.write(r'\f');
          break;
        default:
          if (c < 0x20 || c >= 0x7F) {
            sb.write('\\u');
            sb.write(c.toRadixString(16).padLeft(4, '0'));
          } else {
            sb.writeCharCode(c);
          }
      }
    }
    sb.write('"');
  }
}

/// 保持插入顺序的 JSON 对象构造工具
Map<String, Object?> pyObj([List<Pair>? pairs]) {
  final m = <String, Object?>{};
  if (pairs != null) {
    for (final p in pairs) {
      m[p.key] = p.value;
    }
  }
  return m;
}

class Pair {
  final String key;
  final Object? value;
  Pair(this.key, this.value);
}
