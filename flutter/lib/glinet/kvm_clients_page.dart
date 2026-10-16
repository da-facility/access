import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'kvm_profile.dart';
import 'kvm_session_page.dart';

Future<KvmProfile?> editKvmProfile(BuildContext context,
        {KvmProfile? profile}) =>
    Navigator.of(context).push<KvmProfile>(
        MaterialPageRoute(builder: (_) => _KvmEditor(profile: profile)));

class KvmClientsPage extends StatefulWidget {
  const KvmClientsPage({super.key});
  @override
  State<KvmClientsPage> createState() => _KvmClientsPageState();
}

class _KvmClientsPageState extends State<KvmClientsPage> {
  final store = KvmProfiles.instance;
  @override
  void initState() {
    super.initState();
    store.load();
  }

  Future<void> _edit([KvmProfile? profile]) async {
    final result = await Navigator.of(context).push<KvmProfile>(
        MaterialPageRoute(builder: (_) => _KvmEditor(profile: profile)));
    if (result == null) return;
    try {
      await store.save(result);
    } catch (_) {
      if (mounted) _message('Could not save the KVM client.');
    }
  }

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _delete(KvmProfile profile) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: Text('Remove ${profile.name}?'),
                content:
                    const Text('This removes the saved client from this app.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel')),
                  TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Remove'))
                ]));
    if (confirmed != true) return;
    try {
      await store.remove(profile);
    } catch (_) {
      if (mounted) _message('Could not remove the KVM client.');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('GL.iNet KVM clients'), actions: [
          IconButton(
              tooltip: 'Add KVM',
              onPressed: () => _edit(),
              icon: const Icon(Icons.add))
        ]),
        body: AnimatedBuilder(
            animation: store,
            builder: (context, _) => ListView(children: [
                  const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                          'Add your Comet Q or Comet X using its LAN or Tailscale address. Saved clients appear under Connection.')),
                  if (store.error != null)
                    Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(store.error!)),
                  for (final profile in store.profiles)
                    ListTile(
                        leading: const Icon(Icons.developer_board),
                        title: Text(profile.name),
                        subtitle:
                            Text('${profile.modelName} · ${profile.address}'),
                        onTap: () => _edit(profile),
                        trailing: IconButton(
                            tooltip: 'Remove ${profile.name}',
                            onPressed: () => _delete(profile),
                            icon: const Icon(Icons.delete_outline))),
                  Padding(
                      padding: const EdgeInsets.all(16),
                      child: OutlinedButton.icon(
                          onPressed: store.error == null ? () => _edit() : null,
                          icon: const Icon(Icons.add),
                          label: const Text('Add KVM client'))),
                ])),
      );
}

class KvmConnectionSection extends StatefulWidget {
  const KvmConnectionSection({super.key});
  @override
  State<KvmConnectionSection> createState() => _KvmConnectionSectionState();
}

class _KvmConnectionSectionState extends State<KvmConnectionSection> {
  final store = KvmProfiles.instance;
  @override
  void initState() {
    super.initState();
    store.load();
  }

  void _manage() => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => const KvmClientsPage()));
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: store,
      builder: (context, _) => Card(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ListTile(
                  title: const Text('GL.iNet KVMs'),
                  trailing: IconButton(
                      tooltip: 'Manage KVM clients',
                      onPressed: _manage,
                      icon: const Icon(Icons.settings_outlined))),
              if (store.error != null)
                Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(store.error!)),
              if (store.profiles.isEmpty && store.error == null)
                ListTile(
                    title: const Text('Add a Comet Q or Comet X'),
                    subtitle:
                        const Text('Connect using a LAN or Tailscale address'),
                    leading: const Icon(Icons.add),
                    onTap: _manage),
              for (final profile in store.profiles)
                ListTile(
                    leading: const Icon(Icons.developer_board),
                    title: Text(profile.name),
                    subtitle:
                        Text('${profile.modelName} · ${profile.uri.host}'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => KvmSessionPage(profile: profile)))),
            ]),
          ));
}

class _KvmEditor extends StatefulWidget {
  final KvmProfile? profile;
  const _KvmEditor({this.profile});
  @override
  State<_KvmEditor> createState() => _KvmEditorState();
}

class _KvmEditorState extends State<_KvmEditor> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.profile?.name);
  late final _address = TextEditingController(text: widget.profile?.address);
  late final _username =
      TextEditingController(text: widget.profile?.username ?? 'admin');
  late String _model = widget.profile?.model ?? 'RMQ1';
  bool _resetCertificate = false;
  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _username.dispose();
    super.dispose();
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    final address = KvmProfile.parseAddress(_address.text).toString();
    Navigator.of(context).pop(KvmProfile(
        id: widget.profile?.id ?? const Uuid().v4(),
        name: _name.text.trim(),
        address: address,
        model: _model,
        username: _username.text.trim(),
        certificateSha256:
            !_resetCertificate && address == widget.profile?.address
                ? widget.profile?.certificateSha256
                : null));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
            title: Text(
                widget.profile == null ? 'Add KVM client' : 'Edit KVM client')),
        body: Form(
            key: _form,
            child: ListView(padding: const EdgeInsets.all(16), children: [
              TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(
                      labelText: 'Name', hintText: 'Office Comet Q'),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Enter a name'
                      : null),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                  value: _model,
                  decoration: const InputDecoration(labelText: 'KVM model'),
                  items: const [
                    DropdownMenuItem(
                        value: 'RMQ1', child: Text('Comet Q · GL-RMQ1')),
                    DropdownMenuItem(
                        value: 'RM4PE', child: Text('Comet X · GL-RM4PE'))
                  ],
                  onChanged: (value) => setState(() => _model = value!)),
              const SizedBox(height: 16),
              TextFormField(
                  controller: _address,
                  autocorrect: false,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                      labelText: 'Address',
                      hintText: 'https://glkvm.example.ts.net',
                      helperText:
                          'HTTPS is used when you enter only a hostname.'),
                  validator: (value) {
                    try {
                      KvmProfile.parseAddress(value ?? '');
                      return null;
                    } on FormatException catch (e) {
                      return e.message;
                    }
                  }),
              const SizedBox(height: 16),
              TextFormField(
                  controller: _username,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'Username'),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Enter a username'
                      : null),
              const SizedBox(height: 20),
              const Text(
                  'You will enter the password when connecting. For remote access, enable Tailscale on both your iPhone and the KVM.'),
              if (widget.profile?.certificateSha256 != null)
                CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _resetCertificate,
                    title: const Text('Forget trusted certificate'),
                    onChanged: (value) =>
                        setState(() => _resetCertificate = value!)),
              const SizedBox(height: 24),
              ElevatedButton(onPressed: _save, child: const Text('Save')),
            ])),
      );
}
