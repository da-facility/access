import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/glinet/kvm_profile.dart';
import 'package:flutter_hbb/glinet/kvm_session_page.dart';

void main() {
  testWidgets('an unavailable screen-awake plugin does not freeze sign-in',
      (tester) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    const rtc = MethodChannel('FlutterWebRTC.Method');
    const texture = MethodChannel('FlutterWebRTC/Texture7');
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
  });
}
