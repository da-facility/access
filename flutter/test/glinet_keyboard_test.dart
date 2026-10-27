import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/glinet/kvm_keyboard_bar.dart';
import 'package:flutter_hbb/glinet/kvm_keys.dart';

void main() {
  testWidgets('keys are sent as they are typed, including backspace',
      (tester) async {
    final typed = <String>[];
    final keys = <String>[];
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: KvmKeyboardBar(
                focus: focus,
                modifiers: const {},
                onType: typed.add,
                onKey: keys.add,
                onModifier: (_) {},
                onSendText: (_) async {},
                onClose: () {}))));
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    const sentinel = '​​​​​​​​';
    tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: '${sentinel}Hi!',
        selection: TextSelection.collapsed(offset: sentinel.length + 3)));
    await tester.pump();
    expect(typed, ['H', 'i', '!']);
    tester.testTextInput.updateEditingValue(TextEditingValue(
        text: sentinel.substring(1),
        selection: const TextSelection.collapsed(offset: sentinel.length - 1)));
    await tester.pump();
    expect(keys, ['Backspace']);
  });

  test('typed characters map to US keyboard keys', () {
    expect(kvmCharKey('a'), ('KeyA', false));
    expect(kvmCharKey('A'), ('KeyA', true));
    expect(kvmCharKey('7'), ('Digit7', false));
    expect(kvmCharKey('&'), ('Digit7', true));
    expect(kvmCharKey('?'), ('Slash', true));
    expect(kvmCharKey('\n'), ('Enter', false));
    expect(kvmCharKey('ž'), isNull);
  });
}
