import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'kvm_profile.dart';

class KvmCertificateException implements Exception {
  final String fingerprint;
  const KvmCertificateException(this.fingerprint);
  @override
  String toString() => 'The KVM uses an untrusted TLS certificate.';
}

class KvmException implements Exception {
  final String message;
  const KvmException(this.message);
  @override
  String toString() => message;
}

class KvmTransport {
  final KvmProfile profile;
  late final HttpClient _http;
  String? _untrustedCertificate;
  String? _token;
  WebSocket? _input;
  Timer? _heartbeat;
  DateTime _lastPong = DateTime.now();
  bool _closed = false;
  final _keys = <String>{};
  final _buttons = <String>{};
  final states = StreamController<Map<String, dynamic>>.broadcast();

  KvmTransport(this.profile) {
    _http = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    _http.badCertificateCallback = (cert, host, port) {
      final digest = sha256.convert(cert.der).toString();
      _untrustedCertificate = digest;
      return host == profile.uri.host &&
          port == profile.uri.port &&
          profile.certificateSha256 == digest;
    };
  }

  Uri endpoint(String path, [Map<String, String>? query]) =>
      profile.uri.replace(path: path, queryParameters: query);

  Future<Map<String, dynamic>> request(String method, String path,
      {Map<String, String>? form,
      Map<String, String>? query,
      String? text}) async {
    if (_closed) throw const KvmException('The KVM connection is closed.');
    try {
      final req = await _http
          .openUrl(method, endpoint(path, query))
          .timeout(const Duration(seconds: 15));
      req.followRedirects = false;
      if (_token != null) req.headers.set('Cookie', 'auth_token=$_token');
      req.headers.set('User-Agent', 'RustDesk-GLKVM-iOS');
      if (form != null) {
        req.headers.contentType = ContentType(
            'application', 'x-www-form-urlencoded',
            charset: 'utf-8');
        req.write(Uri(queryParameters: form).query);
      } else if (text != null) {
        req.headers.contentType = ContentType.text;
        req.write(text);
      }
      final res = await req.close().timeout(const Duration(seconds: 15));
      final body =
          await utf8.decodeStream(res).timeout(const Duration(seconds: 15));
      if (res.statusCode == 401 || res.statusCode == 403) {
        throw const KvmException(
            'Login was rejected or expired. Check the password and device approval.');
      }
      if (res.statusCode == 429) {
        throw const KvmException(
            'The KVM has temporarily limited login attempts. Wait before retrying.');
      }
      if (res.statusCode >= 300 && res.statusCode < 400) {
        throw const KvmException(
            'The KVM redirects this address. Use its HTTPS address in Settings.');
      }
      if (res.statusCode != 200) {
        throw KvmException(
            'The KVM returned HTTP ${res.statusCode} for $path.');
      }
      final data = jsonDecode(body) as Map<String, dynamic>;
      if (data['ok'] == false) {
        throw const KvmException('The KVM could not complete this request.');
      }
      return Map<String, dynamic>.from(data['result'] ?? {});
    } on HandshakeException {
      if (_untrustedCertificate != null) {
        throw KvmCertificateException(_untrustedCertificate!);
      }
      rethrow;
    }
  }

  Future<void> login(String password, {void Function(String)? onStatus}) async {
    var result = await request('POST', '/api/auth/login',
        form: {'user': profile.username, 'passwd': password, 'expire': '0'});
    if (result['two_step_required'] == true) {
      onStatus?.call('Approve this login on the Comet Q touchscreen.');
      final temporary = result['two_step_token'] as String;
      final deadline = DateTime.now().add(Duration(
          seconds: (result['expires_in'] as int? ?? 60).clamp(1, 120)));
      while (!_closed && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(seconds: 2));
        result = await request('POST', '/api/auth/two_step_complete',
            form: {'two_step_token': temporary});
        if (result['status'] != 'pending') break;
      }
      if (result['token'] == null) {
        throw const KvmException(
            'Device approval timed out. Connect again to retry.');
      }
    }
    _token = result['token'] as String?;
    await request('GET', '/api/auth/check');
  }

  Future<WebSocket> socket(String path, {List<String>? protocols}) async {
    if (_closed) throw const KvmException('The KVM connection is closed.');
    final uri = endpoint(path)
        .replace(scheme: profile.uri.scheme == 'https' ? 'wss' : 'ws');
    final ws = await WebSocket.connect(uri.toString(),
            customClient: _http,
            headers: _token == null ? null : {'Cookie': 'auth_token=$_token'},
            protocols: protocols)
        .timeout(const Duration(seconds: 15));
    if (_closed) {
      await ws.close();
      throw const KvmException('The KVM connection is closed.');
    }
    return ws;
  }

  Future<void> connectInput() async {
    _input = await socket('/api/ws');
    _lastPong = DateTime.now();
    _input!.listen((raw) {
      if (raw is! String || _closed) return;
      try {
        final event = Map<String, dynamic>.from(jsonDecode(raw));
        if (event['event_type'] == 'pong') _lastPong = DateTime.now();
        if (event['event_type'] == 'kickout') {
          states.addError(const KvmException(
              'The KVM ended this session. Connect again to retry.'));
          return;
        }
        states.add(event);
      } catch (_) {
        states.addError(
            const KvmException('The KVM sent an invalid status message.'));
      }
    }, onError: (Object error) {
      if (!_closed) {
        states.addError(const KvmException('The KVM input connection failed.'));
      }
    }, onDone: () {
      _heartbeat?.cancel();
      if (!_closed) {
        states.addError(const KvmException('The KVM input connection closed.'));
      }
    });
    _heartbeat = Timer.periodic(const Duration(seconds: 2), (_) {
      if (DateTime.now().difference(_lastPong).inSeconds > 12) {
        _heartbeat?.cancel();
        if (!_closed) {
          states.addError(const KvmException('The KVM stopped responding.'));
        }
      } else {
        send('ping', {});
      }
    });
  }

  void send(String type, Map<String, dynamic> event) {
    if (!_closed && _input?.readyState == WebSocket.open) {
      _input!.add(jsonEncode({'event_type': type, 'event': event}));
    }
  }

  static int coordinate(double fraction) =>
      ((fraction.clamp(0.0, 1.0) * 65535).round() - 32768).clamp(-32768, 32767);
  void move(double x, double y) => send('mouse_move', {
        'to': {'x': coordinate(x), 'y': coordinate(y)}
      });
  void button(String button, bool down) {
    if (down) {
      _buttons.add(button);
    } else {
      _buttons.remove(button);
    }
    send('mouse_button', {'button': button, 'state': down});
  }

  void key(String key, bool down) {
    if (down) {
      _keys.add(key);
    } else {
      _keys.remove(key);
    }
    send('key', {'key': key, 'state': down});
  }

  void wheel(int x, int y) => send('mouse_wheel', {
        'delta': {'x': x.clamp(-127, 127), 'y': y.clamp(-127, 127)}
      });
  void releaseAll() {
    for (final keyName in _keys.toList()) {
      key(keyName, false);
    }
    for (final name in _buttons.toList()) {
      button(name, false);
    }
  }

  Future<void> printText(String text) async {
    if (text.isEmpty) return;
    await request('POST', '/api/hid/print', text: text, query: {'limit': '0'});
  }

  Future<void> close() async {
    if (_closed) return;
    releaseAll();
    _closed = true;
    _heartbeat?.cancel();
    await _input?.close();
    _http.close(force: true);
    await states.close();
    _token = null;
  }
}
