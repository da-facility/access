import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'kvm_keys.dart';
import 'kvm_profile.dart';
import 'kvm_pointer.dart';
import 'kvm_session_viewport.dart';
import 'kvm_transport.dart';
import 'kvm_video.dart';

class KvmSessionPage extends StatefulWidget {
  final KvmProfile profile;
  const KvmSessionPage({super.key, required this.profile});
  @override
  State<KvmSessionPage> createState() => _KvmSessionPageState();
}

class _KvmSessionPageState extends State<KvmSessionPage>
    with WidgetsBindingObserver {
  final _renderer = RTCVideoRenderer();
  final _focus = FocusNode();
  final _password = TextEditingController();
  late KvmProfile _profile = widget.profile;
  KvmTransport? _transport;
  KvmVideo? _video;
  StreamSubscription? _states;
  bool _initialized = false;
  bool _connecting = false;
  bool _connected = false;
  bool _hasFrame = false;
  String _status = 'Enter the KVM admin password to connect.';
  String? _error;
  bool _dragging = false;
  final _modifiers = <String>{};
  Timer? _frameTimeout;
  int? _activePort;
  bool _switchingPort = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _renderer.initialize().then((_) {
      if (mounted) setState(() => _initialized = true);
    }).catchError((Object error) {
      _fail('Could not initialize the video display.');
    });
    _renderer.onFirstFrameRendered = () {
      if (mounted) {
        setState(() {
          _hasFrame = true;
          _status = 'Connected';
        });
      }
      _frameTimeout?.cancel();
    };
    _renderer.onResize = () {
      if (mounted) setState(() {});
    };
  }

  void _setStatus(String value) {
    if (mounted) setState(() => _status = value);
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _connecting = false;
      _connected = false;
    });
    _sessionUi(false);
    _disconnect();
  }

  void _sessionUi(bool active) {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
        overlays: active ? [] : SystemUiOverlay.values);
  }

  Future<void> _connect() async {
    if (_connecting || !_initialized || _password.text.isEmpty) return;
    setState(() {
      _connecting = true;
      _error = null;
      _hasFrame = false;
      _status = 'Signing in…';
    });
    _sessionUi(true);
    KvmTransport? transport;
    try {
      await _disconnect();
      if (!mounted) return;
      transport = KvmTransport(_profile);
      _transport = transport;
      try {
        await transport.login(_password.text, onStatus: _setStatus);
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
        await KvmProfiles.instance.save(_profile);
        transport = KvmTransport(_profile);
        _transport = transport;
        await transport.login(_password.text, onStatus: _setStatus);
      }
      if (!mounted || _transport != transport) {
        await transport.close();
        return;
      }
      _password.clear();
      _setStatus('Opening keyboard and mouse…');
      _states =
          transport.states.stream.listen(_onState, onError: (Object error) {
        if (_transport == transport) _fail(error.toString());
      });
      await transport.connectInput();
      if (!mounted || _transport != transport) return;
      _setStatus('Waiting for video…');
      _video = KvmVideo(transport, _renderer, onError: (message) {
        if (_transport == transport) _fail(message);
      });
      await _video!.start();
      if (!mounted || _transport != transport) return;
      setState(() {
        _connecting = false;
        _connected = true;
      });
      await _keepAwake(true);
      _focus.requestFocus();
      if (!_hasFrame) {
        _frameTimeout = Timer(const Duration(seconds: 25), () {
          if (mounted && !_hasFrame) {
            _fail(
                'No video arrived. Check the USB-C or HDMI source and select H.264 WebRTC in the KVM console.');
          }
        });
      }
    } catch (error) {
      if (mounted && _transport == transport) _fail(error.toString());
    }
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
          event['streamer']['source']?['online'] == false) {
        _setStatus('No video signal. Check the KVM source cable.');
      }
    }
  }

  Future<void> _disconnect() async {
    _frameTimeout?.cancel();
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
    if (state == AppLifecycleState.paused && (_connected || _connecting)) {
      _fail('Session paused. Connect again to resume.');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _frameTimeout?.cancel();
    _renderer.onFirstFrameRendered = null;
    _renderer.onResize = null;
    _sessionUi(false);
    _disconnect().whenComplete(() => _renderer.dispose());
    _password.dispose();
    _focus.dispose();
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

  Future<void> _keyboard() async {
    _transport?.releaseAll();
    setState(() {
      _modifiers.clear();
      _dragging = false;
    });
    final text = TextEditingController();
    await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (context) => StatefulBuilder(
            builder: (context, update) => Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16,
                      MediaQuery.of(context).viewInsets.bottom + 20),
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                            controller: text,
                            autofocus: true,
                            autocorrect: false,
                            enableSuggestions: false,
                            minLines: 1,
                            maxLines: 4,
                            decoration: const InputDecoration(
                                labelText: 'Type text on the remote device')),
                        const SizedBox(height: 12),
                        ElevatedButton(
                            onPressed: () async {
                              final value = text.text;
                              if (value.isEmpty) return;
                              try {
                                await _transport?.printText(value);
                                text.clear();
                              } catch (error) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                          content: Text(error.toString())));
                                }
                              }
                            },
                            child: const Text('Send text')),
                        Wrap(alignment: WrapAlignment.center, children: [
                          for (final entry in {
                            'Esc': 'Escape',
                            'Tab': 'Tab',
                            '⌫': 'Backspace',
                            'Enter': 'Enter',
                            '↑': 'ArrowUp',
                            '←': 'ArrowLeft',
                            '↓': 'ArrowDown',
                            '→': 'ArrowRight'
                          }.entries)
                            TextButton(
                                onPressed: () => _tapKey(entry.value),
                                child: Text(entry.key)),
                        ]),
                      ]),
                )));
    text.dispose();
    if (mounted) {
      _sessionUi(true);
      _focus.requestFocus();
    }
  }

  Widget _control(String label, IconData icon, VoidCallback? action,
      {bool selected = false, String? caption}) {
    final color = action == null
        ? Colors.white30
        : selected
            ? Colors.lightBlueAccent
            : Colors.white;
    return SizedBox(
      width: 48,
      height: 48,
      child: caption == null
          ? IconButton(
              tooltip: label,
              onPressed: action,
              color: color,
              disabledColor: Colors.white30,
              icon: Icon(icon, size: 23),
            )
          : Tooltip(
              message: label,
              child: TextButton(
                onPressed: action,
                style: TextButton.styleFrom(
                    foregroundColor: color,
                    disabledForegroundColor: Colors.white30,
                    backgroundColor: selected ? Colors.white12 : null,
                    padding: EdgeInsets.zero),
                child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icon, size: 20, color: color),
                      Text(caption, style: const TextStyle(fontSize: 10)),
                    ]),
              )),
    );
  }

  Widget _session() {
    final ready = _connected && _hasFrame;
    final ratio = _renderer.videoWidth > 0 && _renderer.videoHeight > 0
        ? _renderer.videoWidth / _renderer.videoHeight
        : 16 / 9;
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
        if (!ready) return KeyEventResult.ignored;
        final key = kvmKey(event.physicalKey);
        if (key == null) return KeyEventResult.ignored;
        _transport?.key(key, event is! KeyUpEvent);
        return KeyEventResult.handled;
      },
      child: KvmSessionViewport(
        aspectRatio: ratio,
        leading: [
          _control('Back', Icons.arrow_back, () => Navigator.pop(context)),
          _control('Keyboard', Icons.keyboard, ready ? _keyboard : null),
          _control(
              'Left click', Icons.mouse, ready ? () => _click('left') : null,
              caption: 'Left'),
          _control(
              'Right click', Icons.mouse, ready ? () => _click('right') : null,
              caption: 'Right'),
          _control(
              _dragging ? 'Release drag' : 'Drag',
              Icons.pan_tool_alt,
              ready
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
              icon: const Icon(Icons.input, color: Colors.white),
              onSelected: _switchPort,
              itemBuilder: (_) => [
                for (var port = 0; port < 4; port++)
                  CheckedPopupMenuItem(
                      value: port,
                      checked: _activePort == port,
                      child: Text('Port ${port + 1}')),
              ],
            ),
        ],
        trailing: [
          for (final entry
              in {'Esc': 'Escape', 'Tab': 'Tab', '↵': 'Enter'}.entries)
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
            enabled: ready,
            onFocus: _focus.requestFocus,
            onMove: (position) => _transport?.move(position.dx, position.dy),
            onButton: (button, down) => _transport?.button(button, down),
            onTap: () => _click('left'),
            onScroll: (x, y) => _transport?.wheel(x, y),
            child: _initialized
                ? RTCVideoView(_renderer,
                    objectFit:
                        RTCVideoViewObjectFit.RTCVideoViewObjectFitContain)
                : const SizedBox.shrink(),
          )),
          if (!_hasFrame)
            Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(_status, style: const TextStyle(color: Colors.white)),
            ]))
          else if (_status != 'Connected')
            Align(
                alignment: Alignment.topCenter,
                child: Container(
                    color: Colors.black87,
                    padding: const EdgeInsets.all(8),
                    child: Text(_status,
                        style: const TextStyle(color: Colors.white)))),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: _connected || _connecting ? Colors.black : null,
        appBar: _connected || _connecting
            ? null
            : AppBar(title: Text(_profile.name)),
        body: _connected || _connecting
            ? _session()
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
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration:
                        const InputDecoration(labelText: 'Admin password'),
                    onSubmitted: (_) => _connect()),
                const SizedBox(height: 16),
                ElevatedButton(
                    onPressed: _initialized ? _connect : null,
                    child: const Text('Connect')),
                const SizedBox(height: 16),
                const Text(
                    'Swipe the video to move the pointer. Tap to click at the pointer. Use Drag to hold the left button while moving, then tap Drag again to release. External keyboards and mice are supported.'),
              ])),
      );
}
