import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../models/platform_model.dart';
import 'access_book_api.dart';
import 'kvm_clients_page.dart';
import 'kvm_password_store.dart';
import 'kvm_profile.dart';
import 'kvm_session_page.dart';

/// The existing RustDesk address book owns authentication and peer connections.
class AccessBookLink extends StatefulWidget {
  final String account;
  const AccessBookLink({super.key, required this.account});

  @override
  State<AccessBookLink> createState() => _AccessBookLinkState();
}

class _AccessBookLinkState extends State<AccessBookLink> {
  late final Future<AccessBookApi?> _api = _discover();

  Future<AccessBookApi?> _discover() async {
    final api = AccessBookApi(await bind.mainGetApiServer(), '');
    try {
      final capabilities = await api.request('GET', '/api/access/capabilities');
      return capabilities['kvms'] == true ? api : null;
    } catch (_) {
      // Other RustDesk API servers do not provide the Access extension.
      return null;
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<AccessBookApi?>(
      future: _api,
      builder: (context, snapshot) => snapshot.data == null
          ? const SizedBox.shrink()
          : ListTile(
              leading: const Icon(Icons.developer_board),
              title: const Text('GL.iNet KVMs'),
              subtitle: Text('${widget.account}’s address book'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => AccessBookPage(
                      api: AccessBookApi(snapshot.data!.server,
                          bind.mainGetLocalOption(key: 'access_token')))))));
}

class AccessBookPage extends StatefulWidget {
  final AccessBookApi api;
  const AccessBookPage({super.key, required this.api});

  @override
  State<AccessBookPage> createState() => _AccessBookPageState();
}

class _AccessBookPageState extends State<AccessBookPage> {
  List<KvmProfile> _profiles = [];
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final profiles = await widget.api.load();
      if (mounted) setState(() => _profiles = profiles);
    } catch (error) {
      if (mounted) {
        setState(() {
          _profiles = [];
          _error = error.toString();
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _message(Object error) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _edit([KvmProfile? profile]) async {
    final result = await editKvmProfile(context, profile: profile);
    if (result == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.api.save(result, create: profile == null);
      if (profile != null && profile.credentialKey != result.credentialKey) {
        await KvmPasswordStore.delete(
            widget.api.sessionProfile(profile).credentialKey);
      }
      if (mounted) await _reload();
    } catch (error) {
      _message(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    await KvmProfiles.instance.load();
    if (!mounted) return;
    final local = KvmProfiles.instance.profiles;
    final profile = await showDialog<KvmProfile>(
        context: context,
        builder: (context) => SimpleDialog(
              title: const Text('Copy from this device'),
              children: local.isEmpty
                  ? [
                      const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('No local KVM clients are saved.'))
                    ]
                  : local
                      .map((p) => SimpleDialogOption(
                          onPressed: () => Navigator.pop(context, p),
                          child: Text(p.name)))
                      .toList(),
            ));
    if (profile == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.api.save(
          KvmProfile.fromJson({...profile.toJson(), 'id': const Uuid().v4()}),
          create: true);
      if (mounted) await _reload();
    } catch (error) {
      _message(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(KvmProfile profile) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: Text('Remove ${profile.name}?'),
                content: const Text(
                    'This removes the KVM from your account on all devices.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel')),
                  TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Remove'))
                ]));
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.api.remove(profile);
      await KvmPasswordStore.delete(
          widget.api.sessionProfile(profile).credentialKey);
      if (mounted) await _reload();
    } catch (error) {
      _message(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect(KvmProfile profile) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => KvmSessionPage(
              profile: widget.api.sessionProfile(profile),
              saveTrustedProfile: (trusted) => widget.api.save(
                  KvmProfile.fromJson({...trusted.toJson(), 'id': profile.id}),
                  create: false),
            )));
    if (mounted) await _reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('GL.iNet address book'), actions: [
          IconButton(
              tooltip: 'Refresh',
              onPressed: _busy ? null : _reload,
              icon: const Icon(Icons.refresh)),
          IconButton(
              tooltip: 'Add KVM',
              onPressed: _busy ? null : () => _edit(),
              icon: const Icon(Icons.add)),
        ]),
        body: RefreshIndicator(
            onRefresh: _reload,
            child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  if (_busy) const LinearProgressIndicator(),
                  const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                          'These connections are saved to your account. KVM passwords stay in this device’s Keychain.')),
                  if (_error != null)
                    Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(_error!)),
                  if (!_busy && _error == null && _profiles.isEmpty)
                    const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('No KVMs yet. Add a Comet Q or Comet X.')),
                  for (final profile in _profiles)
                    ListTile(
                      leading: const Icon(Icons.developer_board),
                      title: Text(profile.name),
                      subtitle:
                          Text('${profile.modelName} · ${profile.address}'),
                      onTap: _busy ? null : () => _connect(profile),
                      trailing: PopupMenuButton<String>(
                          enabled: !_busy,
                          onSelected: (action) => action == 'edit'
                              ? _edit(profile)
                              : _remove(profile),
                          itemBuilder: (_) => const [
                                PopupMenuItem(
                                    value: 'edit', child: Text('Edit')),
                                PopupMenuItem(
                                    value: 'remove', child: Text('Remove'))
                              ]),
                    ),
                  Padding(
                      padding: const EdgeInsets.all(16),
                      child: OutlinedButton.icon(
                          onPressed: _busy ? null : _import,
                          icon: const Icon(Icons.copy),
                          label: const Text('Copy a local KVM to my account'))),
                ])),
      );
}
