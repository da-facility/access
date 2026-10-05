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
    expect(tester.getTopLeft(find.byType(BackButton)), const Offset(62, 196));
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

  testWidgets(
      'controls have equal gaps including the edges in both orientations',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    const keys = [
      Key('first-control'),
      Key('second-control'),
      Key('third-control')
    ];
    for (final size in [const Size(900, 400), const Size(400, 900)]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(MaterialApp(
          home: KvmSessionViewport(
        aspectRatio: 16 / 9,
        display: const SizedBox(),
        leading: [
          for (final key in keys) SizedBox(key: key, width: 48, height: 48)
        ],
        trailing: const [],
      )));
      final vertical = size.width > size.height;
      final positions = keys
          .map((key) => tester.getTopLeft(find.byKey(key)))
          .map((point) => vertical ? point.dy : point.dx)
          .toList();
      final extent = vertical ? size.height : size.width;
      final gap = (extent - 3 * 48) / 4;
      expect(positions[0], closeTo(gap, .01));
      expect(positions[1] - positions[0] - 48, closeTo(gap, .01));
      expect(positions[2] - positions[1] - 48, closeTo(gap, .01));
      expect(extent - positions[2] - 48, closeTo(gap, .01));
      expect(tester.takeException(), isNull);
    }
  });
}
