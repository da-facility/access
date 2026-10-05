import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/glinet/kvm_keys.dart';
import 'package:flutter_hbb/glinet/kvm_profile.dart';
import 'package:flutter_hbb/glinet/kvm_transport.dart';

void main() {
  test(
      'saved clients accept LAN and Tailscale origins and reject embedded credentials',
      () {
    expect(KvmProfile.parseAddress(' glkvm.example.ts.net ').toString(),
        'https://glkvm.example.ts.net');
    expect(KvmProfile.parseAddress('https://[fd7a:115c:a1e0::1]:8443/').port,
        8443);
    expect(KvmProfile.parseAddress('http://192.168.1.2').scheme, 'http');
    for (final address in [
      '',
      'https://user:secret@host',
      'ftp://host',
      'https://host/api',
      'https://host?token=secret',
      'https://host#fragment'
    ]) {
      expect(() => KvmProfile.parseAddress(address), throwsFormatException,
          reason: address);
    }
    const profile = KvmProfile(
        id: 'q',
        name: 'Desk',
        address: 'https://glkvm.example.ts.net',
        model: 'RMQ1');
    expect(KvmProfile.fromJson(profile.toJson()).modelName, 'Comet Q');
    expect(profile.toJson().keys, isNot(contains('password')));
  });

  test('physical keys and absolute pointer positions use GLKVM input codes',
      () {
    expect(kvmKey(PhysicalKeyboardKey.keyA), 'KeyA');
    expect(kvmKey(PhysicalKeyboardKey.digit0), 'Digit0');
    expect(kvmKey(PhysicalKeyboardKey.controlLeft), 'ControlLeft');
    expect(kvmKey(PhysicalKeyboardKey.arrowDown), 'ArrowDown');
    expect(kvmKey(PhysicalKeyboardKey.f12), 'F12');
    expect(KvmTransport.coordinate(-1), -32768);
    expect(KvmTransport.coordinate(0.5), 0);
    expect(KvmTransport.coordinate(2), 32767);
  });

  test(
      'login cookie reaches input socket, typing, and held keys release on close',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = <Map<String, dynamic>>[];
    final released = Completer<void>();
    String? typed;
    final errors = <Object>[];
    final subscription = server.listen((req) async {
      try {
        if (req.uri.path == '/api/auth/login') {
          final form = Uri.splitQueryString(await utf8.decodeStream(req));
          expect(form['user'], 'admin');
          expect(form['passwd'], 'test only');
          req.response.write(jsonEncode({
            'ok': true,
            'result': {'token': 'test-token'}
          }));
          await req.response.close();
        } else {
          expect(req.headers.value('cookie'), 'auth_token=test-token');
          if (req.uri.path == '/api/ws') {
            final socket = await WebSocketTransformer.upgrade(req);
            socket.listen((message) {
              received.add(
                  Map<String, dynamic>.from(jsonDecode(message as String)));
            }, onDone: () {
              if (!released.isCompleted) released.complete();
            });
          } else {
            if (req.uri.path == '/api/hid/print') {
              typed = await utf8.decodeStream(req);
            }
            req.response.write(jsonEncode({'ok': true, 'result': {}}));
            await req.response.close();
          }
        }
      } catch (error) {
        errors.add(error);
      }
    });
    final transport = KvmTransport(KvmProfile(
        id: 'test',
        name: 'Test',
        address: 'http://127.0.0.1:${server.port}',
        model: 'RMQ1'));
    try {
      await transport.login('test only');
      await transport.connectInput();
      transport.move(0, 1);
      transport.button('left', true);
      transport.key('ControlLeft', true);
      await transport.printText('Hello & world');
      await transport.close();
      await released.future.timeout(const Duration(seconds: 2));
      expect(errors, isEmpty);
      expect(typed, 'Hello & world');
      expect(received, [
        {
          'event_type': 'mouse_move',
          'event': {
            'to': {'x': -32768, 'y': 32767}
          }
        },
        {
          'event_type': 'mouse_button',
          'event': {'button': 'left', 'state': true}
        },
        {
          'event_type': 'key',
          'event': {'key': 'ControlLeft', 'state': true}
        },
        {
          'event_type': 'key',
          'event': {'key': 'ControlLeft', 'state': false}
        },
        {
          'event_type': 'mouse_button',
          'event': {'button': 'left', 'state': false}
        },
      ]);
    } finally {
      await transport.close();
      await subscription.cancel();
      await server.close(force: true);
    }
  });
}
