import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/glinet/kvm_device.dart';

void main() {
  const video = Size(1920, 1080);
  final iphone = {
    'remote_device_settings': {
      'type': 'iphone_17pro_max_16pro_max',
      'ratio': [2868, 1320]
    },
    'mobile_orientation': 'portrait',
  };

  test('touches on a mirrored iPhone map to its own screen like the web UI',
      () {
    // The phone is centred in the landscape signal and spans its full height.
    final phoneWidth = 1080 * 1320 / 2868 / 1920;
    final left = (1 - phoneWidth) / 2;
    final centre = kvmDevicePosition(const Offset(.5, .5), iphone, video);
    expect(centre.dx, closeTo(.5, 1e-9));
    expect(centre.dy, closeTo(.5, 1e-9));
    final corner = kvmDevicePosition(Offset(left, 0), iphone, video);
    expect(corner.dx, closeTo(0, 1e-9));
    expect(corner.dy, 0);
    final edge =
        kvmDevicePosition(Offset(left + phoneWidth * .25, .8), iphone, video);
    expect(edge.dx, closeTo(.25, 1e-9));
    expect(edge.dy, closeTo(.8, 1e-9));
    // An iPhone in landscape keeps portrait pointer axes.
    final landscape = {...iphone, 'mobile_orientation': 'landscape'};
    // Landscape, the phone spans the full width and is letterboxed.
    final phoneHeight = 1920 * 1320 / 2868 / 1080;
    final rotated = kvmDevicePosition(
        Offset(.5, (1 - phoneHeight) / 2 + phoneHeight * .25),
        landscape,
        video);
    expect(rotated.dx, closeTo(.75, 1e-9));
    expect(rotated.dy, closeTo(.5, 1e-9));
    // Computers keep the whole frame.
    expect(
        kvmDevicePosition(
            const Offset(.1, .2),
            {
              'remote_device_settings': {'type': 'computer_or_other'}
            },
            video),
        const Offset(.1, .2));
  });

  test('the resolution picker recognizes the KVM default and custom EDIDs', () {
    expect(kvmCurrentEdid('RMQ1', '')?.label, '1920x1080/GLKVM/60Hz');
    expect(kvmCurrentEdid('RM4PE', '')?.label, '2560x1440/GLKVM/60Hz');
    final preset = kvmEdidPresets('RMQ1')[1];
    final spaced = preset.hex
        .toUpperCase()
        .replaceAllMapped(RegExp(r'..'), (match) => '${match[0]} ');
    expect(kvmCurrentEdid('RMQ1', spaced), same(preset));
    expect(kvmCurrentEdid('RMQ1', '00ff'), isNull);
  });

  test('the crop shows only the mirrored iPhone screen', () {
    final rect = kvmDeviceRect(iphone, video)!;
    expect(
        rect.width * 1920 / (rect.height * 1080), closeTo(1320 / 2868, 1e-9));
    expect(rect.center.dx, closeTo(.5, 1e-9));
    expect(
        kvmDeviceRect({
          'remote_device_settings': {'type': 'computer_or_other'}
        }, video),
        isNull);
  });

  test('the quality slider steps through widescreen resolutions up to the max',
      () {
    String name(p) => p.label.split('/').first;
    expect(kvmResolutionSteps('RMQ1', iphone: true).map(name), [
      '1280x720',
      '1280x800',
      '1680x1050',
      '1920x1080',
      '2560x1440',
      '2560x1600'
    ]);
    expect(kvmResolutionSteps('RM4PE').map(name).last, '3840x2160');
  });
}
