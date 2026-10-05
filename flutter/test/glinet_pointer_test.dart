import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/glinet/kvm_pointer.dart';
import 'package:flutter_hbb/glinet/kvm_session_viewport.dart';

void main() {
  testWidgets(
      'touch swipes move without pressing and taps click at the pointer',
      (tester) async {
    final moves = <Offset>[];
    final buttons = <String>[];
    var clicks = 0;
    await tester.pumpWidget(MaterialApp(
        home: Center(
            child: SizedBox(
      width: 400,
      height: 200,
      child: KvmPointer(
          enabled: true,
          onMove: moves.add,
          onButton: (button, down) => buttons.add('$button:$down'),
          onTap: () => clicks++,
          onScroll: (_, __) {},
          onFocus: () {},
          child: const ColoredBox(color: Colors.black)),
    ))));
    final area = tester.getRect(find.byType(KvmPointer));
    final finger =
        await tester.startGesture(area.topLeft + const Offset(20, 20));
    await finger.moveBy(const Offset(80, 20));
    await finger.up();
    expect(moves.last, const Offset(.7, .6));
    expect(buttons, isEmpty);
    expect(clicks, 0);
    await tester.tapAt(area.topLeft + const Offset(300, 150));
    expect(moves.last, const Offset(.7, .6));
    expect(clicks, 1);
  });

  testWidgets('a physical mouse keeps direct pointing and releases on cancel',
      (tester) async {
    final moves = <Offset>[];
    final buttons = <String>[];
    await tester.pumpWidget(MaterialApp(
        home: Center(
            child: SizedBox(
      width: 400,
      height: 200,
      child: KvmPointer(
          enabled: true,
          onMove: moves.add,
          onButton: (button, down) => buttons.add('$button:$down'),
          onTap: () => fail('Mouse must not use touch tap handling'),
          onScroll: (_, __) {},
          onFocus: () {},
          child: const ColoredBox(color: Colors.black)),
    ))));
    final area = tester.getRect(find.byType(KvmPointer));
    final mouse = await tester.startGesture(
        area.topLeft + const Offset(100, 50),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton);
    expect(moves.last, const Offset(.25, .25));
    expect(buttons, ['right:true']);
    await mouse.cancel();
    expect(buttons, ['right:true', 'right:false']);
  });

  testWidgets('landscape video fills the space between safe side controls',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(956, 440);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const video = Key('video');
    await tester.pumpWidget(const MaterialApp(
        home: MediaQuery(
      data: MediaQueryData(
          size: Size(956, 440), padding: EdgeInsets.fromLTRB(62, 0, 62, 21)),
      child: KvmSessionViewport(
          aspectRatio: 16 / 9,
          display: ColoredBox(key: video, color: Colors.blue),
          leading: [
            SizedBox(width: 48, height: 48, child: BackButton())
          ],
          trailing: [
            SizedBox(width: 48, height: 48, child: Icon(Icons.keyboard))
          ]),
    )));
    final rect = tester.getRect(find.byKey(video));
    expect(rect.width, 956 - 124 - 96);
    expect(rect.height, closeTo(rect.width * 9 / 16, .01));
    expect(rect.center, const Offset(478, 220));
    expect(tester.getTopLeft(find.byType(BackButton)), const Offset(62, 0));
    expect(find.byType(AppBar), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
