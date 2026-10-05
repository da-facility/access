import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/glinet/kvm_profile.dart';
import 'package:flutter_hbb/glinet/kvm_password_store.dart';
import 'package:flutter_hbb/glinet/kvm_session_page.dart';

void main() {
  testWidgets('an unavailable screen-awake plugin does not freeze sign-in',
      (tester) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    const rtc = MethodChannel('FlutterWebRTC.Method');
    const texture = MethodChannel('FlutterWebRTC/Texture7');
    const keychain = MethodChannel('io.dafacility.access/kvm-passwords');
    messenger.setMockMethodCallHandler(keychain, (_) async => null);
    const wakelock = 'dev.flutter.pigeon.WakelockPlusApi.toggle';
    messenger.setMockMessageHandler(wakelock, (_) async => null);
    messenger.setMockMethodCallHandler(
        rtc,
        (call) async =>
            call.method == 'createVideoRenderer' ? {'textureId': 7} : null);
    messenger.setMockMethodCallHandler(texture, (_) async => null);
    await tester.pumpWidget(const MaterialApp(
        home: KvmSessionPage(
            profile: KvmProfile(
                id: 'login',
                name: 'Test KVM',
                address: 'https://kvm.example',
                model: 'RMQ1'))));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'test only');
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    // Widget tests reject HTTP with 400. Reaching it proves login proceeded.
    expect(find.text('The KVM returned HTTP 400 for /api/auth/login.'),
        findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    messenger.setMockMethodCallHandler(rtc, null);
    messenger.setMockMethodCallHandler(texture, null);
    messenger.setMockMessageHandler(wakelock, null);
    messenger.setMockMethodCallHandler(keychain, null);
  });
  testWidgets(
      'saved passwords prefill and unchecking remember removes the saved copy',
      (tester) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    const keychain = MethodChannel('io.dafacility.access/kvm-passwords');
    const rtc = MethodChannel('FlutterWebRTC.Method');
    const texture = MethodChannel('FlutterWebRTC/Texture7');
    const profile = KvmProfile(
        id: 'remember',
        name: 'Saved KVM',
        address: 'https://kvm.example',
        model: 'RMQ1');
    final passwords = {profile.credentialKey: 'fixture password'};
    messenger.setMockMethodCallHandler(keychain, (call) async {
      final args = Map<String, dynamic>.from(call.arguments);
      if (call.method == 'delete') passwords.remove(args['account']);
      return call.method == 'read' ? passwords[args['account']] : null;
    });
    messenger.setMockMethodCallHandler(
        rtc,
        (call) async =>
            call.method == 'createVideoRenderer' ? {'textureId': 7} : null);
    messenger.setMockMethodCallHandler(texture, (_) async => null);
    await tester
        .pumpWidget(const MaterialApp(home: KvmSessionPage(profile: profile)));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'fixture password');
    expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isTrue);
    expect(
        tester.widget<TextField>(find.byType(TextField)).obscureText, isTrue);
    await tester.tap(find.text('Remember password'));
    await tester.pumpAndSettle();
    expect(passwords, isEmpty);
    expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester
        .pumpWidget(const MaterialApp(home: KvmSessionPage(profile: profile)));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    messenger.setMockMethodCallHandler(keychain, null);
    messenger.setMockMethodCallHandler(rtc, null);
    messenger.setMockMethodCallHandler(texture, null);
  });

  test('password storage is scoped to the client, origin and username',
      () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('io.dafacility.access/kvm-passwords');
    final passwords = <String, String>{};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args = Map<String, dynamic>.from(call.arguments);
      switch (call.method) {
        case 'write':
          passwords[args['account']] = args['password'];
          return null;
        case 'delete':
          passwords.remove(args['account']);
          return null;
        default:
          return passwords[args['account']];
      }
    });
    const profile = KvmProfile(
        id: 'one', name: 'KVM', address: 'https://one.example', model: 'RMQ1');
    await KvmPasswordStore.write(profile.credentialKey, 'fixture password');
    expect(
        await KvmPasswordStore.read(profile.credentialKey), 'fixture password');
    for (final change in [
      {'id': 'two'},
      {'address': 'https://two.example'},
      {'username': 'other'}
    ]) {
      final other = KvmProfile.fromJson({...profile.toJson(), ...change});
      expect(await KvmPasswordStore.read(other.credentialKey), isNull);
    }
    expect(profile.toJson().values, isNot(contains('fixture password')));
    await KvmPasswordStore.delete(profile.credentialKey);
    expect(await KvmPasswordStore.read(profile.credentialKey), isNull);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
}
