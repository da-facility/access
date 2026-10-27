import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../mobile/pages/home_page.dart';
import '../models/platform_model.dart';

/// Shares this iPhone's screen through the ScreenShare broadcast extension.
/// iOS does not let apps control other apps, so sessions are view-only.
class IosSharePage extends StatefulWidget implements PageShape {
  IosSharePage({super.key});

  @override
  final title = 'Share screen';

  @override
  final icon = const Icon(Icons.mobile_screen_share);

  @override
  final appBarActions = <Widget>[];

  @override
  State<IosSharePage> createState() => _IosSharePageState();
}

const _channel = MethodChannel('io.dafacility.access/screen-share');
const _passwordOption = 'access-share-password';
const _serverOptions = [
  'custom-rendezvous-server',
  'relay-server',
  'key',
  'api-server'
];

String _newPassword() {
  const chars = 'abcdefghjkmnpqrstuvwxyz23456789';
  final random = Random.secure();
  return List.generate(8, (_) => chars[random.nextInt(chars.length)]).join();
}

class _IosSharePageState extends State<IosSharePage> {
  String _password = '';
  String? _id;
  bool _sharing = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _password = bind.mainGetLocalOption(key: _passwordOption);
    if (_password.isEmpty) _setPassword(_newPassword());
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _setPassword(String password) {
    setState(() => _password = password);
    bind.mainSetLocalOption(key: _passwordOption, value: password);
  }

  Future<void> _refresh() async {
    try {
      final status = Map<String, dynamic>.from(
          await _channel.invokeMethod<Map>('status') ?? {});
      if (!mounted) return;
      setState(() {
        _id = status['id'] as String?;
        _sharing = status['sharing'] == true;
      });
    } on PlatformException catch (error) {
      debugPrint('Screen share status failed: ${error.message}');
    }
  }

  Future<void> _start() async {
    final options = <String, String>{};
    for (final key in _serverOptions) {
      final value = await bind.mainGetOption(key: key);
      if (value.isNotEmpty) options[key] = value;
    }
    try {
      await _channel.invokeMethod('prepare', {
        'options': options,
        'password': _password,
        'device_name': 'iPhone',
      });
      await _channel.invokeMethod('start');
    } on PlatformException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message ?? error.code)));
      }
    }
  }

  Widget _field(String label, String value, {Widget? action}) => ListTile(
        title: Text(label),
        subtitle: SelectableText(value,
            style: Theme.of(context).textTheme.headlineSmall),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (action != null) action,
          IconButton(
              tooltip: 'Copy',
              icon: const Icon(Icons.copy_outlined),
              onPressed: () => Clipboard.setData(ClipboardData(text: value))),
        ]),
      );

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
              child: Column(children: [
            const ListTile(
                leading: Icon(Icons.visibility_outlined),
                title: Text('View only'),
                subtitle: Text(
                    'The other person sees your screen but cannot control it. iOS does not allow apps to control other apps.')),
            _field('Your ID', _id ?? 'Shown after you start sharing once'),
            _field('Password', _password,
                action: IconButton(
                    tooltip: 'New password',
                    icon: const Icon(Icons.refresh),
                    onPressed:
                        _sharing ? null : () => _setPassword(_newPassword()))),
          ])),
          const SizedBox(height: 16),
          if (_sharing)
            const ListTile(
                leading: Icon(Icons.fiber_manual_record, color: Colors.red),
                title: Text('Sharing your screen'),
                subtitle: Text(
                    'Stop from Control Center or the red indicator at the top of the screen.'))
          else
            FilledButton.icon(
                onPressed: _start,
                icon: const Icon(Icons.mobile_screen_share),
                label: const Text('Start sharing')),
          const SizedBox(height: 12),
          const Text(
              'Give the other person your ID and password. They connect from RustDesk or Access like to any other device.'),
        ],
      );
}
