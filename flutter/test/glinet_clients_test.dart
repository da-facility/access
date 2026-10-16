import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/glinet/kvm_clients_page.dart';
import 'package:flutter_hbb/glinet/kvm_profile.dart';

void main() {
  testWidgets('a client saved in settings appears in Connection and on disk',
      (tester) async {
    final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('glinet-client-test')))!;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => directory.path);
    try {
      await tester.runAsync(() => KvmProfiles.instance.load());
      expect(KvmProfiles.instance.error, isNull);
      await tester.pumpWidget(const MaterialApp(home: KvmClientsPage()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add KVM client'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a name'), findsOneWidget);
      await tester.enterText(
          find.byType(TextFormField).at(0), 'Office Comet Q');
      await tester.enterText(
          find.byType(TextFormField).at(1), 'glkvm.example.ts.net');
      final saved = Completer<void>();
      void onSave() {
        if (!saved.isCompleted) saved.complete();
      }

      KvmProfiles.instance.addListener(onSave);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      for (var attempt = 0; attempt < 20 && !saved.isCompleted; attempt++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      expect(saved.isCompleted, isTrue);
      KvmProfiles.instance.removeListener(onSave);
      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: KvmConnectionSection())));
      await tester.pumpAndSettle();
      expect(find.text('Office Comet Q'), findsOneWidget);
      expect(find.text('Comet Q · glkvm.example.ts.net'), findsOneWidget);
      final reloaded = KvmProfiles();
      await tester.runAsync(reloaded.load);
      expect(reloaded.profiles.single.name, 'Office Comet Q');
      expect(reloaded.profiles.single.address, 'https://glkvm.example.ts.net');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await tester.runAsync(() => directory.delete(recursive: true));
    }
  });
}
