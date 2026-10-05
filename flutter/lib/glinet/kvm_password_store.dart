import 'package:flutter/services.dart';

class KvmPasswordStore {
  static const _channel = MethodChannel('io.dafacility.access/kvm-passwords');

  static Future<String?> read(String account) =>
      _channel.invokeMethod<String>('read', {'account': account});

  static Future<void> write(String account, String password) => _channel
      .invokeMethod<void>('write', {'account': account, 'password': password});

  static Future<void> delete(String account) =>
      _channel.invokeMethod<void>('delete', {'account': account});
}
