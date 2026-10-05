import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'kvm_keys.dart';
import 'kvm_profile.dart';
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
  int? _pointer;
  String? _pointerButton;
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
    _disconnect();
  }

  Future<void> _connect() async {
    if (_connecting || !_initialized || _password.text.isEmpty) return;
    setState(() {
      _connecting = true;
      _error = null;
      _hasFrame = false;
      _status = 'Signing in…';
    });
    await _disconnect();
    if (!mounted) return;
    var transport = KvmTransport(_profile);
    _transport = transport;
    try {
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
      await WakelockPlus.enable();
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
    _pointer = null;
    _modifiers.clear();
    final transport = _transport;
    final video = _video;
    final states = _states;
    _transport = null;
    _video = null;
    _states = null;
    transport?.releaseAll();
    await WakelockPlus.disable();
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
      _pointer = null;
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
    setState(() => _modifiers.clear());
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
    if (mounted) _focus.requestFocus();
  }

  Widget _display() => LayoutBuilder(builder: (context, constraints) {
        final ratio = _renderer.videoWidth > 0 && _renderer.videoHeight > 0
            ? _renderer.videoWidth / _renderer.videoHeight
            : 16 / 9;
        var width = constraints.maxWidth;
        var height = width / ratio;
        if (height > constraints.maxHeight) {
          height = constraints.maxHeight;
          width = height * ratio;
        }
        void move(Offset position) =>
            _transport?.move(position.dx / width, position.dy / height);
        return Center(
            child: SizedBox(
                width: width,
                height: height,
                child: Listener(
                  onPointerDown: (event) {
                    if (!_connected || !_hasFrame || _pointer != null) return;
                    _focus.requestFocus();
                    _pointer = event.pointer;
                    _pointerButton = event.buttons & kSecondaryMouseButton != 0
                        ? 'right'
                        : 'left';
                    move(event.localPosition);
                    _transport?.button(_pointerButton!, true);
                  },
                  onPointerHover: (event) {
                    if (_connected && _hasFrame) move(event.localPosition);
                  },
                  onPointerMove: (event) {
                    if (_pointer == event.pointer) move(event.localPosition);
                  },
                  onPointerUp: (event) {
                    if (_pointer != event.pointer) return;
                    _transport?.button(_pointerButton!, false);
                    _pointer = null;
                  },
                  onPointerCancel: (event) {
                    if (_pointer != event.pointer) return;
                    _transport?.releaseAll();
                    _pointer = null;
                  },
                  onPointerSignal: (event) {
                    if (event is PointerScrollEvent &&
                        _connected &&
                        _hasFrame) {
                      _transport?.wheel(-event.scrollDelta.dx.sign.toInt(),
                          -event.scrollDelta.dy.sign.toInt());
                    }
                  },
                  child: _initialized
                      ? RTCVideoView(_renderer,
                          objectFit: RTCVideoViewObjectFit
                              .RTCVideoViewObjectFitContain)
                      : const SizedBox.shrink(),
                )));
      });

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(_profile.name), actions: [
          if (_connected && _profile.model == 'RM4PE')
            PopupMenuButton<int>(
              tooltip: _activePort == null
                  ? 'Select Comet X port'
                  : 'Port ${_activePort! + 1}',
              enabled: !_switchingPort,
              icon: const Icon(Icons.input),
              onSelected: _switchPort,
              itemBuilder: (_) => [
                for (var port = 0; port < 4; port++)
                  CheckedPopupMenuItem(
                      value: port,
                      checked: _activePort == port,
                      child: Text('Port ${port + 1}'))
              ],
            ),
          if (_connected)
            IconButton(
                tooltip: 'Disconnect',
                icon: const Icon(Icons.close),
                onPressed: () {
                  setState(() {
                    _connected = false;
                    _connecting = false;
                    _hasFrame = false;
                    _status = 'Disconnected';
                  });
                  _disconnect();
                }),
        ]),
        body: SafeArea(
            child: Column(children: [
          if (!_connected && !_connecting)
            Expanded(
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
                  'Touch the video to click or drag. Use the keyboard button to send text. External keyboards and mice are supported.'),
            ]))
          else ...[
            Padding(padding: const EdgeInsets.all(8), child: Text(_status)),
            Expanded(
                child: Focus(
                    focusNode: _focus,
                    onFocusChange: (focused) {
                      if (!focused) {
                        _transport?.releaseAll();
                        _modifiers.clear();
                      }
                    },
                    onKeyEvent: (_, event) {
                      if (!_connected || !_hasFrame) {
                        return KeyEventResult.ignored;
                      }
                      final key = kvmKey(event.physicalKey);
                      if (key == null) return KeyEventResult.ignored;
                      _transport?.key(key, event is! KeyUpEvent);
                      return KeyEventResult.handled;
                    },
                    child: Container(
                        color: Colors.black,
                        child: Stack(children: [
                          Positioned.fill(child: _display()),
                          if (!_hasFrame)
                            const Center(child: CircularProgressIndicator()),
                        ])))),
            if (_connected)
              SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Focus(
                      canRequestFocus: false,
                      descendantsAreFocusable: false,
                      child: Row(children: [
                        IconButton(
                            tooltip: 'Keyboard',
                            onPressed: _hasFrame ? _keyboard : null,
                            icon: const Icon(Icons.keyboard)),
                        TextButton(
                            onPressed: _hasFrame ? () => _click('right') : null,
                            child: const Text('Right click')),
                        for (final entry in {
                          'Esc': 'Escape',
                          'Tab': 'Tab',
                          'Enter': 'Enter',
                          'Del': 'Delete'
                        }.entries)
                          TextButton(
                              onPressed:
                                  _hasFrame ? () => _tapKey(entry.value) : null,
                              child: Text(entry.key)),
                        for (final entry in {
                          'Ctrl': 'ControlLeft',
                          'Alt': 'AltLeft',
                          'Shift': 'ShiftLeft',
                          '⌘': 'MetaLeft'
                        }.entries)
                          Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 3),
                              child: FilterChip(
                                  label: Text(entry.key),
                                  selected: _modifiers.contains(entry.value),
                                  onSelected: _hasFrame
                                      ? (_) => _modifier(entry.value)
                                      : null)),
                        IconButton(
                            tooltip: 'Scroll up',
                            onPressed: _hasFrame
                                ? () => _transport?.wheel(0, 3)
                                : null,
                            icon: const Icon(Icons.keyboard_arrow_up)),
                        IconButton(
                            tooltip: 'Scroll down',
                            onPressed: _hasFrame
                                ? () => _transport?.wheel(0, -3)
                                : null,
                            icon: const Icon(Icons.keyboard_arrow_down)),
                      ]))),
          ],
        ])),
      );
}
