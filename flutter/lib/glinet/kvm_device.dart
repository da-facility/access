import 'dart:ui';

import 'kvm_edid_presets.dart';
import 'kvm_transport.dart';

/// Remote device presets and their KVM settings, matching the GL.iNet web UI.
/// The web UI stores these choices on the KVM, so both clients share them.
enum KvmDeviceFamily { computer, apple, android }

class KvmDevicePreset {
  final String key;
  final String label;
  final KvmDeviceFamily family;

  /// Native screen size as [long side, short side], or null when the picture
  /// fills the video frame.
  final List<int>? ratio;
  const KvmDevicePreset(this.key, this.label, this.family, [this.ratio]);

  bool get custom => key == otherApple || key == otherAndroid;

  /// Mouse output for this client. Android uses the web UI's compatibility
  /// (touch) mode because this client only sends absolute positions.
  String get mouseOutput => switch (family) {
        KvmDeviceFamily.computer => 'usb',
        KvmDeviceFamily.apple => 'usb_hybrid',
        KvmDeviceFamily.android => 'usb_touch',
      };
}

const otherApple = 'other_apple_model';
const otherAndroid = 'other_android_model';
const _iphones = [
  'iphone_17_17pro_16pro',
  'iphone_17pro_max_16pro_max',
  'iphone_16_15_15pro'
];

const kvmDevicePresets = [
  KvmDevicePreset(
      'computer_or_other', 'Computer/Other', KvmDeviceFamily.computer),
  KvmDevicePreset('iphone_17_17pro_16pro', 'iPhone 17 / 17 Pro / 16 Pro',
      KvmDeviceFamily.apple, [2622, 1206]),
  KvmDevicePreset('iphone_17pro_max_16pro_max',
      'iPhone 17 Pro Max / 16 Pro Max', KvmDeviceFamily.apple, [2868, 1320]),
  KvmDevicePreset('iphone_16_15_15pro', 'iPhone 16 / 15 / 15 Pro',
      KvmDeviceFamily.apple, [2556, 1179]),
  KvmDevicePreset('ipad_pro_screen_11', 'iPad Pro M4/M5 · 11 inch',
      KvmDeviceFamily.apple, [2420, 1668]),
  KvmDevicePreset('ipad_pro_screen_13', 'iPad Pro M4/M5 · 13 inch',
      KvmDeviceFamily.apple, [2752, 2064]),
  KvmDevicePreset('ipad_air_screen_11', 'iPad Air M3/M4 · 11 inch',
      KvmDeviceFamily.apple, [2360, 1640]),
  KvmDevicePreset('ipad_air_screen_13', 'iPad Air M3/M4 · 13 inch',
      KvmDeviceFamily.apple, [2732, 2048]),
  KvmDevicePreset(otherApple, 'Other Apple model', KvmDeviceFamily.apple),
  KvmDevicePreset('samsung_s26_s25_ultra', 'Samsung S26/S25 Ultra',
      KvmDeviceFamily.android, [3120, 1440]),
  KvmDevicePreset('samsung_s26_s25', 'Samsung S26/S25', KvmDeviceFamily.android,
      [2340, 1080]),
  KvmDevicePreset('galaxy_tab_s11', 'Galaxy Tab S11', KvmDeviceFamily.android,
      [2560, 1600]),
  KvmDevicePreset(otherAndroid, 'Other Android model', KvmDeviceFamily.android),
];

KvmDevicePreset kvmDevicePreset(Map<String, dynamic> config) {
  final type = (config['remote_device_settings'] as Map?)?['type'];
  return kvmDevicePresets.firstWhere((preset) => preset.key == type,
      orElse: () => kvmDevicePresets.first);
}

List<int>? _size(Object? value) => value is List &&
        value.length == 2 &&
        value.every((side) => side is num && side > 0)
    ? [for (final side in value) (side as num).toInt()]
    : null;

/// The custom screen size saved for an "Other model" entry.
List<int>? kvmCustomSize(Map<String, dynamic> config, String key) =>
    _size(config[key == otherApple
        ? 'custom_apple_resolution'
        : 'custom_android_resolution']);

bool kvmPortrait(Map<String, dynamic> config) =>
    (config['mobile_orientation'] as String? ?? 'portrait')
        .startsWith('portrait');

/// The remote device's screen inside the video frame, in normalized frame
/// coordinates. A phone mirrors its screen centred inside the landscape video
/// signal; null when the picture fills the frame.
Rect? kvmDeviceRect(Map<String, dynamic>? config, Size video) {
  if (config == null || video.isEmpty) return null;
  final preset = kvmDevicePreset(config);
  final ratio = preset.custom
      ? kvmCustomSize(config, preset.key)
      : _size((config['remote_device_settings'] as Map?)?['ratio']);
  if (ratio == null) return null;
  final portrait = kvmPortrait(config);
  final width = (portrait ? ratio[1] : ratio[0]).toDouble();
  final height = (portrait ? ratio[0] : ratio[1]).toDouble();
  final fit = width / height / (video.width / video.height);
  return fit <= 1
      ? Rect.fromLTWH((1 - fit) / 2, 0, fit, 1)
      : Rect.fromLTWH(0, (1 - 1 / fit) / 2, 1, 1 / fit);
}

/// Maps a position on the video frame to the remote device's absolute pointer
/// space, as the web player does. The pointer spans only the phone screen.
Offset kvmDevicePosition(
    Offset position, Map<String, dynamic>? config, Size video) {
  final rect = kvmDeviceRect(config, video);
  if (rect == null) return position;
  final preset = kvmDevicePreset(config!);
  final portrait = kvmPortrait(config);
  final iphone = _iphones.contains(preset.key) ||
      (preset.key == otherApple &&
          config['custom_apple_device_type'] == 'iphone');
  final x = ((position.dx - rect.left) / rect.width).clamp(0.0, 1.0);
  final y = ((position.dy - rect.top) / rect.height).clamp(0.0, 1.0);
  // An iPhone held in landscape still reports its pointer in portrait axes.
  if (iphone && !portrait) return Offset(1 - y, x);
  if (preset.family == KvmDeviceFamily.android) {
    final aspect = rect.height * video.height / (rect.width * video.width);
    return portrait ? Offset(x / aspect, y) : Offset(x, y * aspect);
  }
  return Offset(x, y);
}

List<KvmEdidPreset> kvmEdidPresets(String model) =>
    model == 'RM4PE' ? kvmEdidPresetsOther : kvmEdidPresetsQ1;

String _normalizeHex(String hex) =>
    hex.replaceAll(RegExp(r'\s+'), '').toLowerCase();

/// The preset matching the KVM's current EDID. An empty EDID means the
/// factory default, which is the first preset; null means a custom EDID.
KvmEdidPreset? kvmCurrentEdid(String model, String edid) {
  final presets = kvmEdidPresets(model);
  if (edid.trim().isEmpty) return presets.first;
  final current = _normalizeHex(edid);
  for (final preset in presets) {
    if (preset.hex == current) return preset;
  }
  return null;
}

final _resolution = RegExp(r'^(\d+)x(\d+)/');

/// Widescreen (16:9 and 16:10) EDID presets ordered from lowest to highest
/// resolution, one per resolution, for the quality slider. [iphone] drops the
/// modes the web UI marks as unsupported for iPhones.
List<KvmEdidPreset> kvmResolutionSteps(String model, {bool iphone = false}) {
  final steps = <String, (int, KvmEdidPreset)>{};
  for (final preset in kvmEdidPresets(model)) {
    final match = _resolution.firstMatch(preset.label);
    if (match == null) continue;
    final width = int.parse(match[1]!), height = int.parse(match[2]!);
    final aspect = width / height;
    if ((aspect - 16 / 9).abs() > .01 && (aspect - 16 / 10).abs() > .01) {
      continue;
    }
    if (iphone && (match[0] == '1440x900/' || match[0] == '1920x1200/')) {
      continue;
    }
    steps.putIfAbsent('${width}x$height', () => (width * height, preset));
  }
  final sorted = steps.values.toList()..sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final step in sorted) step.$2];
}

/// The KVM's mouse outputs, as the web UI's mouse mode setting names them.
const kvmMouseOutputs = {
  'usb_hybrid': (
    'Hybrid',
    'GL default for iPhone/iPad. Pointer and buttons come from two separate mice, so the iPhone cannot drag.'
  ),
  'usb': (
    'Absolute, one mouse',
    'Behaves like a normal PC mouse: pointer and buttons from one mouse.'
  ),
  'usb_rel': (
    'Relative, one mouse',
    'One mouse that moves by distance, like a trackpad. Touchpad mode works best.'
  ),
  'usb_touch': ('Touchscreen', 'Android compatibility mode.'),
};

class KvmDeviceSettings {
  final KvmTransport transport;
  KvmDeviceSettings(this.transport);

  Future<Map<String, dynamic>> config() async => Map<String, dynamic>.from(
      (await transport.request('GET', '/api/system/get_config'))['config'] ??
          {});

  /// The web UI saves its whole settings object, so merge into a fresh copy.
  Future<Map<String, dynamic>> update(Map<String, dynamic> changes) async {
    final merged = {...await config(), ...changes};
    await transport.request('POST', '/api/system/set_config', json: merged);
    return merged;
  }

  Future<String> edid() async =>
      (await transport.request('GET', '/api/upgrade/get_edid'))['edid']
          as String? ??
      '';

  Future<void> setEdid(String hex) =>
      transport.request('POST', '/api/upgrade/edid', form: {'edid': hex});

  Future<Map<String, dynamic>> streamer() =>
      transport.request('GET', '/api/streamer');

  /// H.264 bitrate in kbps, as the web UI's streamer settings set it.
  Future<void> setBitrate(int kbps) =>
      transport.request('POST', '/api/streamer/set_params',
          query: {'h264_bitrate': '$kbps'});

  Future<Map<String, dynamic>> mouseOutputs() async =>
      Map<String, dynamic>.from(((await transport.request(
              'GET', '/api/hid'))['mouse'] as Map?)?['outputs'] as Map? ??
          {});

  /// Returns false when the KVM cannot switch to this output without a reboot.
  Future<bool> setMouseOutput(String output) async {
    final hid = await transport.request('GET', '/api/hid');
    final outputs = (hid['mouse'] as Map?)?['outputs'] as Map?;
    if (outputs?['active'] == output) return true;
    if (!((outputs?['available'] as List?)?.contains(output) ?? false)) {
      return false;
    }
    await transport.request('POST', '/api/hid/set_params',
        query: {'mouse_output': output});
    return true;
  }

  Future<Map<String, dynamic>> setDevice(KvmDevicePreset preset,
      {List<int>? customSize, String? appleType}) {
    final ratio = customSize ?? preset.ratio;
    return update({
      'remote_device_settings': {
        'type': preset.key,
        if (ratio != null) 'ratio': ratio,
        if (preset.key == otherApple) 'customAppleDeviceType': appleType,
      },
      if (customSize != null && preset.key == otherApple) ...{
        'custom_apple_resolution': customSize,
        'custom_apple_device_type': appleType,
      },
      if (customSize != null && preset.key == otherAndroid)
        'custom_android_resolution': customSize,
      'mouse_mode': switch (preset.family) {
        KvmDeviceFamily.computer => 'absolute',
        KvmDeviceFamily.apple => 'hybrid',
        KvmDeviceFamily.android => 'touch',
      },
      'is_absolute_mouse': preset.family != KvmDeviceFamily.apple,
    });
  }
}
