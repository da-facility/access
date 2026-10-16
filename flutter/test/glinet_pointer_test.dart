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
          zoom: ValueNotifier<double>(1),
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
          zoom: ValueNotifier<double>(1),
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

  testWidgets(
      'video uses the whole screen and only floating controls stay inside safe areas',
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
    expect(rect.height, 440);
    expect(rect.height, closeTo(rect.width * 9 / 16, .01));
    expect(rect.center, const Offset(478, 220));
    expect(find.byType(BackButton), findsNothing);
    final button = tester.getRect(find.byTooltip('Open session controls'));
    expect(button.right, lessThanOrEqualTo(956 - 62));
    expect(button.bottom, lessThanOrEqualTo(440 - 21));
    expect(find.byType(AppBar), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'two-finger drags scroll in all four directions without zoom or clicks',
      (tester) async {
    final zoom = ValueNotifier<double>(1);
    final scrolls = <Offset>[];
    var clicks = 0;
    await tester.pumpWidget(MaterialApp(
        home: Center(
            child: SizedBox(
      width: 400,
      height: 200,
      child: KvmPointer(
          enabled: true,
          zoom: zoom,
          onMove: (_) {},
          onButton: (_, __) {},
          onTap: () => clicks++,
          onScroll: (x, y) => scrolls.add(Offset(x.toDouble(), y.toDouble())),
          onFocus: () {},
          child: const ColoredBox(color: Colors.black)),
    ))));
    final center = tester.getCenter(find.byType(KvmPointer));
    for (final delta in [
      const Offset(48, 0),
      const Offset(-48, 0),
      const Offset(0, 48),
      const Offset(0, -48)
    ]) {
      scrolls.clear();
      final first =
          await tester.startGesture(center - const Offset(60, 0), pointer: 1);
      final second =
          await tester.startGesture(center + const Offset(60, 0), pointer: 2);
      for (var i = 0; i < 4; i++) {
        await first.moveBy(delta / 4);
        await second.moveBy(delta / 4);
        await tester.pump();
      }
      await first.up();
      await second.up();
      await tester.pump();
      final sum = scrolls.fold(Offset.zero, (a, b) => a + b);
      expect(sum.dx.sign, delta.dx.sign);
      expect(sum.dy.sign, delta.dy.sign);
      expect(zoom.value, 1);
      expect(clicks, 0);
    }
  });

  testWidgets(
      'pinch zooms the video, keeps pointer movement scaled, and resets to fit',
      (tester) async {
    final zoom = ValueNotifier<double>(1);
    final moves = <Offset>[];
    const video = Key('zoom-video');
    await tester.pumpWidget(MaterialApp(
        home: Center(
            child: SizedBox(
      width: 400,
      height: 200,
      child: KvmPointer(
          enabled: true,
          zoom: zoom,
          onMove: moves.add,
          onButton: (_, __) {},
          onTap: () => fail('Pinch must not click'),
          onScroll: (_, __) => fail('Pinch must not scroll'),
          onFocus: () {},
          child: const ColoredBox(key: video, color: Colors.black)),
    ))));
    final center = tester.getCenter(find.byType(KvmPointer));
    final first =
        await tester.startGesture(center - const Offset(50, 0), pointer: 1);
    final second =
        await tester.startGesture(center + const Offset(50, 0), pointer: 2);
    for (var i = 0; i < 5; i++) {
      await first.moveBy(const Offset(-10, 0));
      await second.moveBy(const Offset(10, 0));
      await tester.pump();
    }
    await first.up();
    await second.up();
    await tester.pump();
    expect(zoom.value, closeTo(2, .01));
    expect(tester.getSize(find.byKey(video)), const Size(400, 200));
    final box = tester.renderObject<RenderBox>(find.byKey(video));
    expect(
        (box.localToGlobal(const Offset(400, 0)) -
                box.localToGlobal(Offset.zero))
            .dx,
        closeTo(800, .01));
    final finger = await tester.startGesture(center, pointer: 3);
    await finger.moveBy(const Offset(40, 0));
    await finger.up();
    expect(moves.last.dx, closeTo(.55, .001));
    zoom.value = 1;
    await tester.pump();
    expect(box.localToGlobal(Offset.zero),
        tester.getTopLeft(find.byType(KvmPointer)));
    expect(
        (box.localToGlobal(const Offset(400, 0)) -
                box.localToGlobal(Offset.zero))
            .dx,
        400);
  });

  testWidgets('floating menu and its drag never send touches to the remote',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    var remoteTouches = 0;
    var actions = 0;
    for (final size in [const Size(900, 400), const Size(400, 900)]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(MaterialApp(
          home: KvmSessionViewport(
        key: ValueKey(size),
        aspectRatio: size.width / size.height,
        display: Listener(
            onPointerDown: (_) => remoteTouches++,
            behavior: HitTestBehavior.opaque,
            child: const SizedBox.expand()),
        leading: [
          TextButton(onPressed: () => actions++, child: const Text('Portrait'))
        ],
        trailing: const [],
      )));
      await tester.tap(find.byTooltip('Open session controls'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Portrait'));
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(find.text('Session controls'), findsNothing);
      await tester.drag(
          find.byTooltip('Open session controls'), const Offset(-150, -50));
      await tester.pumpAndSettle();
      expect(remoteTouches, 0);
      await tester.tap(find.byTooltip('Open session controls'));
      await tester.pumpAndSettle();
      expect(find.text('Session controls'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Close controls'));
      await tester.pumpAndSettle();
    }
    expect(actions, 2);
  });

  testWidgets(
      'direct touch maps presses and drags through zoom and releases on cancel',
      (tester) async {
    final moves = <Offset>[];
    final buttons = <String>[];
    final zoom = ValueNotifier<double>(2);
    await tester.pumpWidget(MaterialApp(
        home: Center(
            child: SizedBox(
      width: 400,
      height: 200,
      child: KvmPointer(
          enabled: true,
          directTouch: true,
          zoom: zoom,
          onMove: moves.add,
          onButton: (b, d) => buttons.add('$b:$d'),
          onTap: () => fail('Direct input must not send a duplicate click'),
          onScroll: (_, __) {},
          onFocus: () {},
          child: const SizedBox.expand()),
    ))));
    final origin = tester.getTopLeft(find.byType(KvmPointer));
    final finger = await tester.startGesture(origin + const Offset(100, 50));
    expect(moves.last, const Offset(.125, .125));
    expect(buttons, ['left:true']);
    await finger.moveBy(const Offset(80, 20));
    expect(moves.last, const Offset(.225, .175));
    await finger.up();
    expect(buttons, ['left:true', 'left:false']);
    final cancelled =
        await tester.startGesture(origin + const Offset(200, 100));
    await cancelled.cancel();
    expect(buttons, ['left:true', 'left:false', 'left:true', 'left:false']);
  });

  testWidgets('view mode zooms and pans without sending remote input',
      (tester) async {
    final zoom = ValueNotifier<double>(1);
    var remoteEvents = 0;
    await tester.pumpWidget(MaterialApp(
        home: Center(
            child: SizedBox(
      width: 400,
      height: 200,
      child: KvmPointer(
          enabled: true,
          directTouch: true,
          viewOnly: true,
          zoom: zoom,
          onMove: (_) => remoteEvents++,
          onButton: (_, __) => remoteEvents++,
          onTap: () => remoteEvents++,
          onScroll: (_, __) => remoteEvents++,
          onFocus: () {},
          child: const SizedBox.expand()),
    ))));
    final center = tester.getCenter(find.byType(KvmPointer));
    final first =
        await tester.startGesture(center - const Offset(50, 0), pointer: 1);
    final second =
        await tester.startGesture(center + const Offset(50, 0), pointer: 2);
    for (var i = 0; i < 5; i++) {
      await first.moveBy(const Offset(-10, 0));
      await second.moveBy(const Offset(10, 0));
      await tester.pump();
    }
    await first.up();
    await second.up();
    await tester.pump();
    expect(zoom.value, closeTo(2, .01));
    await tester.drag(find.byType(KvmPointer), const Offset(40, 20));
    await tester.pump();
    expect(remoteEvents, 0);
  });
}
