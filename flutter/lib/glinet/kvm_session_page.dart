import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'kvm_device.dart';
import 'kvm_edid_presets.dart';
import 'kvm_keyboard_bar.dart';
import 'kvm_keys.dart';
import 'kvm_profile.dart';
import 'kvm_password_store.dart';
import 'kvm_pointer.dart';
import 'kvm_session_viewport.dart';
import 'kvm_transport.dart';
import 'kvm_video.dart';

class KvmSessionPage extends StatefulWidget {
  final KvmProfile profile;
  final Future<void> Function(KvmProfile)? saveTrustedProfile;
  const KvmSessionPage(
      {super.key, required this.profile, this.saveTrustedProfile});
  @override
  State<KvmSessionPage> createState() => _KvmSessionPageState();
}

class _KvmSessionPageState extends State<KvmSessionPage>
    with WidgetsBindingObserver {
  final _renderer = RTCVideoRenderer();
  final _focus = FocusNode();
  final _zoom = ValueNotifier<double>(1);
  final _password = TextEditingController();
  late KvmProfile _profile = widget.profile;
  KvmTransport? _transport;
  KvmVideo? _video;
  StreamSubscription? _states;
  bool _initialized = false;
  bool _credentialsLoaded = false;
  bool _rememberPassword = false;
  bool _updatingPassword = false;
  bool _connecting = false;
  bool _connected = false;
  bool _hasFrame = false;
  String _status = 'Enter the KVM admin password to connect.';
  String? _error;
  bool _dragging = false;
  bool _controlsOpen = false;
  bool _directTouch = true;
  bool _viewOnly = false;
  bool _backgrounded = false;
  final _modifiers = <String>{};
  bool _keyboardOpen = false;
  final _viewport = GlobalKey<KvmSessionViewportState>();
  final _typeFocus = FocusNode();
  Timer? _frameTimeout;
  Timer? _videoRetry;
  int _videoAttempt = 0;
  bool _noSignal = false;
  Map<String, dynamic>? _deviceConfig;
  String? _edid;
  Map<String, dynamic>? _streamer;
  bool _cropToDevice = true;
  String? _mouseOutput;
  List<String> _mouseOutputsAvailable = const [];
  Offset? _lastRelative;
  Offset _relativeRemainder = Offset.zero;
  bool _applyingSetting = false;
  int? _activePort;
  bool _switchingPort = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _zoom.addListener(_refreshZoom);
    _loadPassword();
    _renderer.initialize().then((_) {
      if (mounted) setState(() => _initialized = true);
    }).catchError((Object error) {
      _fail('Could not initialize the video display.');
    });
    _renderer.onFirstFrameRendered = () {
      if (mounted) {
        setState(() {
          _hasFrame = true;
          if (!_noSignal) _status = 'Connected';
        });
      }
      _frameTimeout?.cancel();
    };
    _renderer.onResize = () {
      if (mounted) setState(() {});
    };
  }

  Future<void> _loadPassword() async {
    try {
      final saved = await KvmPasswordStore.read(_profile.credentialKey);
      if (!mounted) return;
      _password.text = saved ?? '';
      _rememberPassword = saved != null;
    } catch (_) {
      if (mounted) {
        _error =
            'Could not read the saved password. You can enter it manually.';
      }
    } finally {
      if (mounted) setState(() => _credentialsLoaded = true);
    }
  }

  Future<void> _remember(bool remember) async {
    setState(() => _updatingPassword = true);
    try {
      if (!remember) await KvmPasswordStore.delete(_profile.credentialKey);
      if (mounted) setState(() => _rememberPassword = remember);
    } catch (_) {
      if (mounted) {
        setState(
            () => _error = 'Could not remove the saved password. Try again.');
      }
    } finally {
      if (mounted) setState(() => _updatingPassword = false);
    }
  }

  void _refreshZoom() {
    if (mounted) setState(() {});
  }

  void _setStatus(String value) {
    if (mounted) setState(() => _status = value);
  }

  void _fail(String message) {
    if (!mounted) return;
    if (_backgrounded && _connected) {
      _connecting = false;
      _status = 'Reconnecting when you return…';
      return;
    }
    setState(() {
      _error = message;
      _connecting = false;
      _connected = false;
    });
    _sessionUi(false);
    _disconnect();
  }

  void _sessionUi(bool active) {
    // Sticky: an edge swipe that reveals the system bars hides them again.
    SystemChrome.setEnabledSystemUIMode(
        active ? SystemUiMode.immersiveSticky : SystemUiMode.manual,
        overlays: active ? [] : SystemUiOverlay.values);
    if (!active) SystemChrome.setPreferredOrientations([]);
  }

  void _releaseInput() {
    _transport?.releaseAll();
    _dragging = false;
    _modifiers.clear();
  }

  void _inputMode({required bool direct, bool viewOnly = false}) {
    setState(() {
      _releaseInput();
      _directTouch = direct;
      _viewOnly = viewOnly;
    });
  }

  Future<void> _rotateViewer() async {
    _releaseInput();
    final portrait = MediaQuery.of(context).orientation == Orientation.portrait;
    _zoom.value = 1;
    await SystemChrome.setPreferredOrientations(portrait
        ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
        : [DeviceOrientation.portraitUp]);
    if (mounted) setState(() {});
  }

  Future<void> _connect({KvmTransport? session}) async {
    if (_connecting ||
        !_initialized ||
        !_credentialsLoaded ||
        _updatingPassword ||
        (session == null && _password.text.isEmpty)) return;
    setState(() {
      _connecting = true;
      if (session == null) _controlsOpen = false;
      _error = null;
      _hasFrame = false;
      _noSignal = false;
      _status = session == null ? 'Signing in…' : 'Resuming connection…';
    });
    _sessionUi(true);
    KvmTransport? transport;
    try {
      await _disconnect();
      if (!mounted) return;
      transport = session ?? KvmTransport(_profile);
      _transport = transport;
      try {
        if (session == null) {
          await transport.login(_password.text, onStatus: _setStatus);
        } else {
          await transport.checkSession();
        }
      } on KvmCertificateException catch (certificate) {
        await transport.close();
        if (!mounted) return;
        final trust = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                    title: const Text('Trust this KVM certificate?'),
                    content: SingleChildScrollView(
                        child: SelectableText(
                            '${_profile.uri.host} uses a certificate that iOS does not trust. Verify its SHA-256 fingerprint before connecting.\n\n${certificate.fingerprint}')),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel')),
                      TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Trust this device'))
                    ]));
        if (trust != true || !mounted) {
          throw const KvmException('Certificate was not trusted.');
        }
        _profile = _profile.trust(certificate.fingerprint);
        if (widget.saveTrustedProfile != null) {
          await widget.saveTrustedProfile!(_profile);
        } else {
          await KvmProfiles.instance.save(_profile);
        }
        transport = KvmTransport(_profile);
        _transport = transport;
        await transport.login(_password.text, onStatus: _setStatus);
      }
      if (!mounted || _transport != transport) {
        await transport.close();
        return;
      }
      if (_rememberPassword && session == null) {
        await KvmPasswordStore.write(_profile.credentialKey, _password.text);
        if (!mounted || _transport != transport) return;
      } else if (!_rememberPassword) {
        _password.clear();
      }
      _setStatus('Opening keyboard and mouse…');
      _states =
          transport.states.stream.listen(_onState, onError: (Object error) {
        if (_transport == transport) _fail(error.toString());
      });
      await transport.connectInput();
      if (!mounted || _transport != transport) return;
      // Input works without video, so a sleeping source can be woken by touch.
      setState(() {
        _connecting = false;
        _connected = true;
        _status = 'Waiting for video…';
      });
      await _keepAwake(true);
      _focus.requestFocus();
      _frameTimeout = Timer(const Duration(seconds: 10), () {
        if (mounted && !_hasFrame && _transport == transport) {
          _setStatus(
              'No video yet. If the source screen is off, tap the screen or use Wake device. Otherwise check the USB-C or HDMI source and select H.264 WebRTC in the KVM console.');
        }
      });
      _loadDeviceSettings(transport);
      await _startVideo(transport);
    } catch (error) {
      if (mounted && _transport == transport) _fail(error.toString());
    }
  }

  Future<void> _startVideo(KvmTransport transport) async {
    _videoRetry?.cancel();
    final previous = _video;
    _video = null;
    await previous?.close();
    if (!mounted || _transport != transport) return;
    final attempt = ++_videoAttempt;
    final video = KvmVideo(transport, _renderer,
        onError: (message) => _videoLost(transport, attempt, message));
    _video = video;
    try {
      await video.start();
    } catch (error) {
      _videoLost(transport, attempt, error.toString());
    }
  }

  /// Video failures retry only the stream; keyboard and mouse stay connected.
  void _videoLost(KvmTransport transport, int attempt, String message) {
    if (!mounted ||
        _transport != transport ||
        attempt != _videoAttempt ||
        _videoRetry?.isActive == true) return;
    _setStatus('$message Retrying video. Touch and keys still work.');
    _videoRetry = Timer(const Duration(seconds: 3), () {
      if (mounted && _transport == transport && !_backgrounded) {
        _startVideo(transport);
      }
    });
  }

  /// Apple devices wake with the same pointer routine as the KVM web UI.
  Future<void> _wake() async {
    final transport = _transport;
    if (transport == null) return;
    final config = _deviceConfig;
    if (config != null &&
        kvmDevicePreset(config).family == KvmDeviceFamily.apple) {
      transport.move(.5, .5);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      transport.button('middle', true);
      await Future<void>.delayed(const Duration(seconds: 1));
      transport.button('middle', false);
    } else {
      transport.move(.5, .5);
    }
    // A sleeping iPhone ignores the pointer routine but wakes on a key press.
    _tapKey('ShiftLeft');
  }

  Future<void> _loadMouseOutput(KvmTransport transport) async {
    try {
      final outputs = await KvmDeviceSettings(transport).mouseOutputs();
      if (mounted && _transport == transport) {
        setState(() {
          _mouseOutput = outputs['active'] as String?;
          _mouseOutputsAvailable = [
            for (final output in outputs['available'] as List? ?? const [])
              if (kvmMouseOutputs.containsKey(output)) output as String
          ];
        });
      }
    } catch (error) {
      debugPrint('GLKVM could not read the mouse mode: $error');
    }
  }

  Future<void> _pickMouseOutput() async {
    final current = _mouseOutput;
    final output = await _sheet<String>(
        'Mouse mode',
        (context) => [
              for (final output in _mouseOutputsAvailable)
                ListTile(
                    title: Text(kvmMouseOutputs[output]!.$1),
                    subtitle: Text(kvmMouseOutputs[output]!.$2),
                    trailing:
                        output == current ? const Icon(Icons.check) : null,
                    onTap: () => Navigator.pop(context, output)),
            ]);
    if (output == null || output == current || !mounted) return;
    await _applySetting((settings) async {
      if (!await settings.setMouseOutput(output)) {
        throw const KvmException('The KVM cannot switch to this mouse mode.');
      }
      final transport = _transport;
      if (transport != null) await _loadMouseOutput(transport);
    }, 'Mouse mode set to ${kvmMouseOutputs[output]!.$1}.');
  }

  /// The relative output moves by distance, so send the change in position.
  void _moveRelative(Offset position, Size video) {
    final last = _lastRelative;
    _lastRelative = position;
    if (last == null) return;
    final scale = video.isEmpty ? const Size(1920, 1080) : video;
    final delta = Offset((position.dx - last.dx) * scale.width,
            (position.dy - last.dy) * scale.height) +
        _relativeRemainder;
    final dx = delta.dx.truncate(), dy = delta.dy.truncate();
    _relativeRemainder = delta - Offset(dx.toDouble(), dy.toDouble());
    _transport?.moveBy(dx, dy);
  }

  Future<void> _loadDeviceSettings(KvmTransport transport) async {
    final settings = KvmDeviceSettings(transport);
    try {
      final config = await settings.config();
      if (mounted && _transport == transport) {
        setState(() => _deviceConfig = config);
      }
    } catch (error) {
      debugPrint('GLKVM could not read device settings: $error');
    }
    try {
      final edid = await settings.edid();
      if (mounted && _transport == transport) setState(() => _edid = edid);
    } catch (error) {
      debugPrint('GLKVM could not read the EDID: $error');
    }
    await _loadMouseOutput(transport);
    try {
      final streamer = await settings.streamer();
      if (mounted && _transport == transport) {
        setState(() => _streamer = streamer);
      }
    } catch (error) {
      debugPrint('GLKVM could not read the streamer settings: $error');
    }
  }

  void _notify(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _applySetting(
      Future<void> Function(KvmDeviceSettings) action, String done) async {
    final transport = _transport;
    if (transport == null || _applyingSetting) return;
    _releaseInput();
    setState(() => _applyingSetting = true);
    try {
      await action(KvmDeviceSettings(transport));
      _notify(done);
    } catch (error) {
      _notify(error.toString());
    } finally {
      if (mounted) setState(() => _applyingSetting = false);
    }
  }

  Future<T?> _sheet<T>(
      String title, List<Widget> Function(BuildContext) items) async {
    _releaseInput();
    final result = await showModalBottomSheet<T>(
        context: context,
        isScrollControlled: true,
        builder: (context) => SafeArea(
            child: ConstrainedBox(
                constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * .8),
                child: ListView(shrinkWrap: true, children: [
                  ListTile(
                      title: Text(title,
                          style: Theme.of(context).textTheme.titleMedium)),
                  ...items(context),
                ]))));
    if (mounted) {
      _sessionUi(true);
      (_keyboardOpen ? _typeFocus : _focus).requestFocus();
    }
    return result;
  }

  Future<void> _pickDevice() async {
    final config = _deviceConfig;
    if (config == null) return;
    final current = kvmDevicePreset(config);
    final preset = await _sheet<KvmDevicePreset>('Remote device', (context) {
      final items = <Widget>[];
      KvmDeviceFamily? family;
      for (final preset in kvmDevicePresets) {
        if (preset.family != family) {
          family = preset.family;
          items.add(Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                  switch (family) {
                    KvmDeviceFamily.computer => 'Computer',
                    KvmDeviceFamily.apple => 'iPhone/iPad',
                    KvmDeviceFamily.android => 'Android phone/tablet',
                  },
                  style: Theme.of(context).textTheme.labelLarge)));
        }
        items.add(ListTile(
            title: Text(preset.label),
            subtitle: preset.custom
                ? Text(_sizeLabel(kvmCustomSize(config, preset.key)) ??
                    'Enter the screen resolution')
                : null,
            trailing:
                preset.key == current.key ? const Icon(Icons.check) : null,
            onTap: () => Navigator.pop(context, preset)));
      }
      return items;
    });
    if (preset == null || !mounted) return;
    List<int>? customSize;
    String? appleType;
    if (preset.custom) {
      final custom = await _customDevice(preset, config);
      if (custom == null) return;
      (customSize, appleType) = custom;
    }
    await _applySetting((settings) async {
      final updated = await settings.setDevice(preset,
          customSize: customSize, appleType: appleType);
      if (mounted) setState(() => _deviceConfig = updated);
      if (!await settings.setMouseOutput(preset.mouseOutput)) {
        throw const KvmException(
            'Device saved. Switching its mouse mode needs a KVM restart; change the mouse mode in the KVM web UI.');
      }
      final transport = _transport;
      if (transport != null) await _loadMouseOutput(transport);
    }, 'Remote device set to ${preset.label}.');
  }

  String? _sizeLabel(List<int>? size) =>
      size == null ? null : '${size[0]} × ${size[1]}';

  Future<(List<int>, String?)?> _customDevice(
      KvmDevicePreset preset, Map<String, dynamic> config) async {
    final saved = kvmCustomSize(config, preset.key);
    final height = TextEditingController(text: saved?[0].toString() ?? '');
    final width = TextEditingController(text: saved?[1].toString() ?? '');
    var appleType = config['custom_apple_device_type'] as String? ?? 'iphone';
    final result = await showDialog<(List<int>, String?)>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
                  title: const Text('Custom device model'),
                  content: SingleChildScrollView(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Text(
                        'Enter the screen resolution of the controlled device, for example iPhone 17: 2622 × 1206, Samsung S26: 2340 × 1080. The device must support video output over USB-C.'),
                    if (preset.key == otherApple)
                      DropdownButtonFormField<String>(
                          value: appleType,
                          decoration:
                              const InputDecoration(labelText: 'Device type'),
                          items: const [
                            DropdownMenuItem(
                                value: 'iphone', child: Text('iPhone')),
                            DropdownMenuItem(
                                value: 'ipad', child: Text('iPad')),
                          ],
                          onChanged: (value) =>
                              update(() => appleType = value ?? appleType)),
                    TextField(
                        controller: height,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                            labelText: 'Resolution (height)')),
                    TextField(
                        controller: width,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                            labelText: 'Resolution (width)')),
                  ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel')),
                    TextButton(
                        onPressed: () {
                          final h = int.tryParse(height.text.trim());
                          final w = int.tryParse(width.text.trim());
                          if (h == null || w == null || h < 1 || w < 1) return;
                          Navigator.pop(context, (
                            [h, w],
                            preset.key == otherApple ? appleType : null
                          ));
                        },
                        child: const Text('Save')),
                  ],
                )));
    height.dispose();
    width.dispose();
    return result;
  }

  Future<void> _pickResolution() async {
    final edid = _edid;
    if (edid == null) return;
    final current = kvmCurrentEdid(_profile.model, edid);
    final iphone = _iphone;
    final choice = await _sheet<Object>(
        'Resolution (EDID)',
        (context) => [
              const ListTile(
                  dense: true,
                  subtitle: Text(
                      'If the picture does not update after changing the EDID, restart or reconnect the controlled device.')),
              for (final preset in kvmEdidPresets(_profile.model))
                ListTile(
                    title: Text(preset.label),
                    subtitle: iphone &&
                            (preset.label.startsWith('1440x900') ||
                                preset.label.startsWith('1920x1200'))
                        ? const Text('Not supported for iPhone')
                        : null,
                    trailing: identical(preset, current)
                        ? const Icon(Icons.check)
                        : null,
                    onTap: () => Navigator.pop(context, preset)),
              ListTile(
                  title: const Text('Custom EDID'),
                  trailing: current == null ? const Icon(Icons.check) : null,
                  onTap: () => Navigator.pop(context, 'custom')),
            ]);
    if (choice == null || !mounted) return;
    String? hex;
    if (choice is KvmEdidPreset) {
      hex = choice.hex;
    } else {
      hex = await _customEdid(current == null ? edid : '');
    }
    if (hex == null || hex.isEmpty) return;
    await _applySetting((settings) async {
      await settings.setEdid(hex!);
      final updated = await settings.edid();
      if (mounted) setState(() => _edid = updated);
    }, 'EDID applied.');
  }

  bool get _iphone {
    final config = _deviceConfig;
    return config != null &&
        kvmDevicePreset(config).family == KvmDeviceFamily.apple &&
        !kvmDevicePreset(config).key.startsWith('ipad');
  }

  int? get _bitrate => (_streamer?['params'] as Map?)?['h264_bitrate'] as int?;

  String _resolutionCaption() {
    final edid = _edid;
    if (edid == null) return 'Quality';
    final label = kvmCurrentEdid(_profile.model, edid)?.label;
    final height = label == null
        ? 'Custom'
        : '${RegExp(r'x(\d+)/').firstMatch(label)?[1] ?? label}p';
    final bitrate = _bitrate;
    return bitrate == null
        ? height
        : '$height · ${(bitrate / 1000).toStringAsFixed(bitrate % 1000 == 0 ? 0 : 1)} Mb';
  }

  /// Resolution and H.264 bitrate sliders. A higher resolution gives a phone,
  /// which mirrors into a strip of the frame, more pixels.
  Future<void> _pickQuality() async {
    final edid = _edid;
    if (edid == null) return;
    final steps = kvmResolutionSteps(_profile.model, iphone: _iphone);
    final current = kvmCurrentEdid(_profile.model, edid);
    var resolution = steps.indexWhere((step) => step.hex == current?.hex);
    final limit = ((_streamer?['limits'] as Map?)?['h264_bitrate'] as Map?);
    final maxMbps = ((limit?['max'] as int? ?? 20000) / 1000).floor();
    var mbps = ((_bitrate ?? 2000) / 1000).clamp(1, maxMbps).toDouble();
    final more = await _sheet<bool>(
        'Video quality',
        (context) => [
              StatefulBuilder(
                  builder: (context, update) =>
                      Column(mainAxisSize: MainAxisSize.min, children: [
                        ListTile(
                            title: const Text('Resolution'),
                            trailing: Text(resolution < 0
                                ? (current?.label.split('/').first ?? 'Custom')
                                : steps[resolution].label.split('/').first)),
                        if (steps.length > 1)
                          Slider(
                              value: resolution < 0 ? 0 : resolution.toDouble(),
                              max: steps.length - 1.0,
                              divisions: steps.length - 1,
                              label: resolution < 0
                                  ? null
                                  : steps[resolution].label.split('/').first,
                              onChanged: (value) =>
                                  update(() => resolution = value.round()),
                              onChangeEnd: (value) {
                                final step = steps[value.round()];
                                if (step.hex == current?.hex) return;
                                _applySetting((settings) async {
                                  await settings.setEdid(step.hex);
                                  final updated = await settings.edid();
                                  if (mounted) setState(() => _edid = updated);
                                }, 'Resolution set to ${step.label.split('/').first}. If the picture does not change, reconnect the controlled device.');
                              }),
                        if (_bitrate != null) ...[
                          ListTile(
                              title: const Text('Bitrate'),
                              trailing: Text('${mbps.round()} Mbps')),
                          Slider(
                              value: mbps,
                              min: 1,
                              max: maxMbps.toDouble(),
                              divisions: maxMbps > 1 ? maxMbps - 1 : null,
                              label: '${mbps.round()} Mbps',
                              onChanged: (value) =>
                                  update(() => mbps = value.roundToDouble()),
                              onChangeEnd: (value) {
                                final kbps = value.round() * 1000;
                                _applySetting((settings) async {
                                  await settings.setBitrate(kbps);
                                  final streamer = await settings.streamer();
                                  if (mounted) {
                                    setState(() => _streamer = streamer);
                                  }
                                }, 'Bitrate set to ${value.round()} Mbps.');
                              }),
                        ],
                        ListTile(
                            title: const Text('All resolutions (EDID)…'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.pop(context, true)),
                      ])),
            ]);
    if (more == true && mounted) await _pickResolution();
  }

  Future<String?> _customEdid(String initial) async {
    final text = TextEditingController(text: initial);
    final result = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Custom EDID'),
              content: TextField(
                  controller: text,
                  minLines: 4,
                  maxLines: 10,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  decoration: const InputDecoration(
                      hintText: '128 or 256 bytes of EDID in hexadecimal')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel')),
                TextButton(
                    onPressed: () => Navigator.pop(context, text.text.trim()),
                    child: const Text('Apply')),
              ],
            ));
    text.dispose();
    return result;
  }

  Future<void> _toggleOrientation() async {
    final config = _deviceConfig;
    if (config == null) return;
    final next = kvmPortrait(config) ? 'landscape' : 'portrait';
    await _applySetting((settings) async {
      final updated = await settings.update({'mobile_orientation': next});
      if (mounted) setState(() => _deviceConfig = updated);
    },
        next == 'portrait'
            ? 'Remote device orientation set to portrait.'
            : 'Remote device orientation set to landscape. Enable rotation lock on an iPhone or iPad.');
  }

  Future<void> _keepAwake(bool enabled) async {
    try {
      await WakelockPlus.toggle(enable: enabled);
    } catch (error) {
      // Screen-awake support must not prevent login or connection cleanup.
      debugPrint('GLKVM could not change screen-awake state: $error');
    }
  }

  void _onState(Map<String, dynamic> message) {
    if (message['event_type'] == 'switch' && mounted) {
      final summary = message['event']?['summary'];
      if (summary is Map && summary['active_port'] is int) {
        setState(() => _activePort = summary['active_port'] as int);
      }
    }
    if (message['event_type'] == 'streamer') {
      final event = message['event'];
      if (event is Map &&
          event['streamer'] is Map &&
          event['streamer']['source']?['online'] is bool) {
        final online = event['streamer']['source']['online'] as bool;
        if (!online && !_noSignal) {
          _noSignal = true;
          _setStatus(
              'No video signal. The source may be asleep; tap the screen or use Wake device.');
        } else if (online && _noSignal) {
          _noSignal = false;
          _setStatus(_hasFrame ? 'Connected' : 'Waiting for video…');
        }
      }
    }
  }

  Future<void> _disconnect() async {
    _frameTimeout?.cancel();
    _videoRetry?.cancel();
    _dragging = false;
    _modifiers.clear();
    final transport = _transport;
    final video = _video;
    final states = _states;
    _transport = null;
    _video = null;
    _states = null;
    transport?.releaseAll();
    await _keepAwake(false);
    await states?.cancel();
    await video?.close();
    await transport?.close();
  }

  Future<void> _switchPort(int port) async {
    final transport = _transport;
    if (transport == null || _switchingPort) return;
    transport.releaseAll();
    setState(() {
      _switchingPort = true;
      _modifiers.clear();
      _dragging = false;
    });
    try {
      await transport.request('POST', '/api/switch/set_active',
          query: {'port': '1.${port + 1}'});
      final state = await transport.request('GET', '/api/switch');
      if (mounted && _transport == transport) {
        _onState({'event_type': 'switch', 'event': state});
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _switchingPort = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _transport?.releaseAll();
      _dragging = false;
      _modifiers.clear();
    }
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _backgrounded = true;
    } else if (state == AppLifecycleState.resumed) {
      final reconnect = _backgrounded && _connected && !_connecting;
      _backgrounded = false;
      if (reconnect) _connect(session: _transport?.resumeSession());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _frameTimeout?.cancel();
    _videoRetry?.cancel();
    _renderer.onFirstFrameRendered = null;
    _renderer.onResize = null;
    _sessionUi(false);
    _disconnect().whenComplete(() => _renderer.dispose());
    _password.dispose();
    _focus.dispose();
    _typeFocus.dispose();
    _zoom.dispose();
    super.dispose();
  }

  void _tapKey(String key) {
    _transport?.key(key, true);
    _transport?.key(key, false);
  }

  void _click(String button) {
    if (_dragging) {
      _transport?.button('left', false);
      setState(() => _dragging = false);
      if (button == 'left') return;
    }
    _transport?.button(button, true);
    _transport?.button(button, false);
  }

  void _modifier(String key) {
    final down = !_modifiers.contains(key);
    setState(() {
      if (down) {
        _modifiers.add(key);
      } else {
        _modifiers.remove(key);
      }
    });
    _transport?.key(key, down);
  }

  void _keyboard() {
    setState(() => _keyboardOpen = !_keyboardOpen);
    if (!_keyboardOpen) _focus.requestFocus();
  }

  /// Modifiers from the keyboard bar apply to the next key only.
  void _releaseModifiers() {
    if (_modifiers.isEmpty) return;
    for (final key in _modifiers) {
      _transport?.key(key, false);
    }
    setState(_modifiers.clear);
  }

  /// Presses [keys] together, like a keyboard shortcut.
  void _shortcut(List<String> keys) {
    for (final key in keys) {
      _transport?.key(key, true);
    }
    for (final key in keys.reversed) {
      _transport?.key(key, false);
    }
  }

  /// Wakes a locked phone, opens its passcode screen and shows a local
  /// keypad: iOS hides its own keypad from the mirrored picture.
  Future<void> _unlock() async {
    _tapKey('ShiftLeft');
    await Future<void>.delayed(const Duration(milliseconds: 700));
    _tapKey('Enter');
    if (!mounted) return;
    var typed = 0;
    await showModalBottomSheet<void>(
        context: context,
        builder: (context) => StatefulBuilder(builder: (context, update) {
              Widget key(String label, VoidCallback onPressed,
                      {IconData? icon}) =>
                  Expanded(
                      child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: SizedBox(
                              height: 56,
                              child: OutlinedButton(
                                  onPressed: onPressed,
                                  child: icon == null
                                      ? Text(label,
                                          style: const TextStyle(fontSize: 24))
                                      : Icon(icon, semanticLabel: label)))));
              Widget digit(int value) => key('$value', () {
                    _tapKey('Digit$value');
                    update(() => typed++);
                  });
              return SafeArea(
                  child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        const Text(
                            'Each digit is typed on the device as you tap it. The phone does not show its own keypad in the mirrored picture.',
                            textAlign: TextAlign.center),
                        const SizedBox(height: 8),
                        Text(typed == 0 ? ' ' : '•' * typed,
                            style: const TextStyle(
                                fontSize: 24, letterSpacing: 6)),
                        for (final row in const [
                          [1, 2, 3],
                          [4, 5, 6],
                          [7, 8, 9]
                        ])
                          Row(children: [
                            for (final value in row) digit(value)
                          ]),
                        Row(children: [
                          key('Show passcode screen', () {
                            _tapKey('ShiftLeft');
                            _tapKey('Enter');
                            update(() => typed = 0);
                          }, icon: Icons.refresh),
                          digit(0),
                          key('Delete', () {
                            _tapKey('Backspace');
                            update(() => typed = math.max(0, typed - 1));
                          }, icon: Icons.backspace_outlined),
                        ]),
                        Row(children: [
                          key('Enter', () {
                            _tapKey('Enter');
                            update(() => typed = 0);
                          }, icon: Icons.keyboard_return),
                        ]),
                      ])));
            }));
    if (mounted) _focus.requestFocus();
  }

  void _typeKey(String key) {
    _tapKey(key);
    _releaseModifiers();
  }

  void _typeChar(String char) {
    final key = kvmCharKey(char);
    if (key == null) {
      _transport?.printText(char).catchError((Object error) {
        _notify(error.toString());
      });
      return;
    }
    final shift = key.$2 && !_modifiers.contains('ShiftLeft');
    if (shift) _transport?.key('ShiftLeft', true);
    _tapKey(key.$1);
    if (shift) _transport?.key('ShiftLeft', false);
    _releaseModifiers();
  }

  Widget _control(String label, IconData icon, VoidCallback? action,
      {bool selected = false, String? caption}) {
    final color = action == null
        ? Colors.white30
        : selected
            ? Colors.lightBlueAccent
            : Colors.white;
    return SizedBox(
      width: 88,
      height: 64,
      child: Tooltip(
          message: label,
          child: TextButton(
            onPressed: action,
            style: TextButton.styleFrom(
                foregroundColor: color,
                disabledForegroundColor: Colors.white30,
                backgroundColor: selected ? Colors.white12 : null,
                padding: EdgeInsets.zero),
            child:
                Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, size: 20, color: color),
              Text(caption ?? label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12)),
            ]),
          )),
    );
  }

  /// Shows only [crop] of [video], scaled to fill the available space.
  Widget _cropped(Widget video, Rect? crop) {
    if (crop == null) return video;
    return ClipRect(child: LayoutBuilder(builder: (context, box) {
      final width = box.maxWidth / crop.width;
      final height = box.maxHeight / crop.height;
      return Stack(children: [
        Positioned(
            left: -crop.left * width,
            top: -crop.top * height,
            width: width,
            height: height,
            child: video),
      ]);
    }));
  }

  Widget _session() {
    // Input does not depend on video, so a sleeping source can still be woken.
    final ready = _connected;
    final video =
        Size(_renderer.videoWidth.toDouble(), _renderer.videoHeight.toDouble());
    final deviceRect = kvmDeviceRect(_deviceConfig, video);
    final crop = _cropToDevice ? deviceRect : null;
    final frameRatio = video.isEmpty ? 16 / 9 : video.width / video.height;
    final ratio =
        crop == null ? frameRatio : frameRatio * crop.width / crop.height;
    return Focus(
      focusNode: _focus,
      onFocusChange: (focused) {
        if (!focused) {
          _transport?.releaseAll();
          if (mounted) {
            setState(() {
              _modifiers.clear();
              _dragging = false;
            });
          }
        }
      },
      onKeyEvent: (_, event) {
        if (!ready || _controlsOpen || _viewOnly) return KeyEventResult.ignored;
        final key = kvmKey(event.physicalKey);
        if (key == null) return KeyEventResult.ignored;
        _transport?.key(key, event is! KeyUpEvent);
        return KeyEventResult.handled;
      },
      child: KvmSessionViewport(
        key: _viewport,
        aspectRatio: ratio,
        actions: [
          KvmEdgeAction('Keyboard', Icons.keyboard, ready ? _keyboard : null,
              selected: _keyboardOpen),
          KvmEdgeAction('Home', Icons.home_outlined,
              ready ? () => _shortcut(['MetaLeft', 'KeyH']) : null),
          KvmEdgeAction('App switcher', Icons.view_carousel_outlined,
              ready ? () => _shortcut(['MetaLeft', 'Tab']) : null),
          KvmEdgeAction('Spotlight', Icons.search,
              ready ? () => _shortcut(['MetaLeft', 'Space']) : null),
          KvmEdgeAction('Unlock', Icons.lock_open, ready ? _unlock : null),
          KvmEdgeAction('Disconnect', Icons.close, () => Navigator.pop(context),
              destructive: true),
        ],
        onMenuChanged: (open) => setState(() {
          if (open) _releaseInput();
          _controlsOpen = open;
          if (!open) (_keyboardOpen ? _typeFocus : _focus).requestFocus();
        }),
        leading: [
          _control(
              'Direct touch', Icons.touch_app, () => _inputMode(direct: true),
              selected: _directTouch && !_viewOnly),
          _control('Touchpad', Icons.mouse, () => _inputMode(direct: false),
              selected: !_directTouch && !_viewOnly),
          _control('Zoom & pan', Icons.pinch,
              () => _inputMode(direct: true, viewOnly: true),
              selected: _viewOnly),
          _control(
              MediaQuery.of(context).orientation == Orientation.portrait
                  ? 'Landscape'
                  : 'Portrait',
              Icons.screen_rotation,
              _rotateViewer),
          _control(
              'Reset zoom to 100%', Icons.zoom_out_map, () => _zoom.value = 1,
              caption: '${(_zoom.value * 100).round()}%'),
          if (_profile.model != 'RM4PE')
            _control('Remote device', Icons.devices,
                _deviceConfig != null && !_applyingSetting ? _pickDevice : null,
                caption: 'Device'),
          if (_profile.model != 'RM4PE' &&
              _deviceConfig != null &&
              kvmDevicePreset(_deviceConfig!).family !=
                  KvmDeviceFamily.computer)
            _control('Remote device orientation', Icons.stay_current_portrait,
                _applyingSetting ? null : _toggleOrientation,
                caption:
                    kvmPortrait(_deviceConfig!) ? 'Portrait' : 'Landscape'),
          _control('Video quality', Icons.hd,
              _edid != null && !_applyingSetting ? _pickQuality : null,
              caption: _resolutionCaption()),
          if (deviceRect != null)
            _control(
                _cropToDevice ? 'Show full frame' : 'Crop to device screen',
                Icons.crop,
                () => setState(() {
                      _cropToDevice = !_cropToDevice;
                      _zoom.value = 1;
                    }),
                selected: _cropToDevice,
                caption: 'Crop'),
          if (_mouseOutputsAvailable.length > 1)
            _control('Mouse mode', Icons.mouse_outlined,
                _applyingSetting ? null : _pickMouseOutput,
                caption: _mouseOutput == null
                    ? 'Mouse'
                    : kvmMouseOutputs[_mouseOutput]?.$1.split(',').first ??
                        'Mouse'),
          _control('Keyboard', Icons.keyboard, ready ? _keyboard : null,
              selected: _keyboardOpen),
          _control(
              'Left click', Icons.mouse, ready ? () => _click('left') : null,
              caption: 'Left'),
          _control(
              'Right click', Icons.mouse, ready ? () => _click('right') : null,
              caption: 'Right'),
          _control(
              _dragging ? 'Release drag' : 'Drag',
              Icons.pan_tool_alt,
              ready && !_directTouch && !_viewOnly
                  ? () {
                      setState(() => _dragging = !_dragging);
                      _transport?.button('left', _dragging);
                    }
                  : null,
              selected: _dragging,
              caption: 'Drag'),
          _control('Scroll up', Icons.keyboard_arrow_up,
              ready ? () => _transport?.wheel(0, 3) : null),
          _control('Scroll down', Icons.keyboard_arrow_down,
              ready ? () => _transport?.wheel(0, -3) : null),
          if (_profile.model == 'RM4PE')
            PopupMenuButton<int>(
              tooltip: 'Select Comet X port',
              enabled: ready && !_switchingPort,
              child: SizedBox(
                  width: 88,
                  height: 64,
                  child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.input, color: Colors.white),
                        Text(
                            _activePort == null
                                ? 'Select port'
                                : 'Port ${_activePort! + 1}',
                            style: const TextStyle(color: Colors.white)),
                      ])),
              onSelected: _switchPort,
              itemBuilder: (_) => [
                for (var port = 0; port < 4; port++)
                  CheckedPopupMenuItem(
                      value: port,
                      checked: _activePort == port,
                      child: Text('Port ${port + 1}')),
              ],
            ),
          _control('Disconnect', Icons.link_off, () => Navigator.pop(context)),
        ],
        trailing: [
          for (final entry in {
            'Esc': 'Escape',
            'Tab': 'Tab',
            'Enter': 'Enter',
            'Delete': 'Backspace'
          }.entries)
            SizedBox(
                width: 48,
                height: 48,
                child: TextButton(
                    onPressed: ready ? () => _tapKey(entry.value) : null,
                    style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                        disabledForegroundColor: Colors.white30,
                        padding: EdgeInsets.zero),
                    child: Text(entry.key))),
          for (final entry in {
            'Ctrl': 'ControlLeft',
            'Alt': 'AltLeft',
            'Shift': 'ShiftLeft',
            '⌘': 'MetaLeft'
          }.entries)
            SizedBox(
                width: 48,
                height: 48,
                child: TextButton(
                    onPressed: ready ? () => _modifier(entry.value) : null,
                    style: TextButton.styleFrom(
                        foregroundColor: _modifiers.contains(entry.value)
                            ? Colors.lightBlueAccent
                            : Colors.white,
                        disabledForegroundColor: Colors.white30,
                        backgroundColor: _modifiers.contains(entry.value)
                            ? Colors.white12
                            : null,
                        padding: EdgeInsets.zero),
                    child: Text(entry.key))),
        ],
        display: Stack(children: [
          Positioned.fill(
              child: KvmPointer(
            enabled: ready && !_controlsOpen,
            directTouch: _directTouch,
            viewOnly: _viewOnly,
            zoom: _zoom,
            onFocus: () => (_keyboardOpen ? _typeFocus : _focus).requestFocus(),
            onMove: (position) {
              final framePosition = crop == null
                  ? position
                  : Offset(crop.left + position.dx * crop.width,
                      crop.top + position.dy * crop.height);
              if (_mouseOutput == 'usb_rel') {
                _moveRelative(framePosition, video);
                return;
              }
              final mapped =
                  kvmDevicePosition(framePosition, _deviceConfig, video);
              _transport?.move(mapped.dx, mapped.dy);
            },
            onButton: (button, down) => _transport?.button(button, down),
            onTap: () => _click('left'),
            onMultitouch: () {
              if (_dragging) _click('left');
            },
            onScroll: (x, y) => _transport?.wheel(x, y),
            child: _initialized
                ? _cropped(
                    RTCVideoView(_renderer,
                        objectFit:
                            RTCVideoViewObjectFit.RTCVideoViewObjectFitContain),
                    crop)
                : const SizedBox.shrink(),
          )),
          if (!_hasFrame || _noSignal)
            Center(
                child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (!_connected) ...[
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                ],
                IgnorePointer(
                    child: Text(_status,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white))),
                if (_connected) ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                      onPressed: _wake,
                      icon: const Icon(Icons.power_settings_new),
                      label: const Text('Wake device')),
                ],
              ]),
            ))
          else if (_status != 'Connected')
            IgnorePointer(
                child: Align(
                    alignment: Alignment.topCenter,
                    child: Container(
                        color: Colors.black87,
                        padding: const EdgeInsets.all(8),
                        child: Text(_status,
                            style: const TextStyle(color: Colors.white))))),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !(_connected || _connecting),
      // Back gestures come from the screen edges, like the shortcut arc.
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _viewport.currentState?.toggleActions();
      },
      child: Scaffold(
        backgroundColor: _connected || _connecting ? Colors.black : null,
        appBar: _connected || _connecting
            ? null
            : AppBar(title: Text(_profile.name)),
        body: _connected || _connecting
            ? Column(children: [
                Expanded(child: _session()),
                if (_keyboardOpen && _connected)
                  KvmKeyboardBar(
                      focus: _typeFocus,
                      modifiers: _modifiers,
                      onType: _typeChar,
                      onKey: _typeKey,
                      onModifier: _modifier,
                      onSendText: (text) async => _transport?.printText(text),
                      onClose: _keyboard),
              ])
            : SafeArea(
                child: ListView(padding: const EdgeInsets.all(20), children: [
                Text('${_profile.modelName} · ${_profile.address}',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 16),
                if (_error != null)
                  Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(_error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error))),
                Text(_status),
                const SizedBox(height: 16),
                TextField(
                    controller: _password,
                    enabled: _credentialsLoaded,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration:
                        const InputDecoration(labelText: 'Admin password'),
                    onSubmitted: (_) => _connect()),
                const SizedBox(height: 16),
                CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('Remember password'),
                    value: _rememberPassword,
                    onChanged: _credentialsLoaded && !_updatingPassword
                        ? (value) => _remember(value ?? false)
                        : null),
                ElevatedButton(
                    onPressed:
                        _initialized && _credentialsLoaded && !_updatingPassword
                            ? _connect
                            : null,
                    child: const Text('Connect')),
                const SizedBox(height: 16),
                const Text(
                    'Touch the remote screen to click or drag at that position. Swipe in from either screen edge for shortcuts and the session controls: keyboard, Home, unlock, touchpad, or Zoom & pan. Touchpad supports two-finger scrolling and pinch zoom. KVM input is mouse and keyboard, not native iPhone multitouch.'),
              ])),
      ));
}
