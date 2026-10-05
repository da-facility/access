import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'kvm_password_store.dart';

class KvmProfile {
  final String id;
  final String name;
  final String address;
  final String model;
  final String username;
  final String? certificateSha256;

  const KvmProfile(
      {required this.id,
      required this.name,
      required this.address,
      required this.model,
      this.username = 'admin',
      this.certificateSha256});

  static Uri parseAddress(String input) {
    final text = input.trim();
    final uri = Uri.tryParse(text.contains('://') ? text : 'https://$text');
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.port < 1 ||
        uri.port > 65535) {
      throw const FormatException(
          'Enter an HTTP or HTTPS host, with an optional port.');
    }
    return uri.replace(path: '');
  }

  Uri get uri => parseAddress(address);
  String get credentialKey => jsonEncode([id, uri.origin, username]);
  String get modelName => model == 'RM4PE' ? 'Comet X' : 'Comet Q';

  KvmProfile trust(String fingerprint) => KvmProfile(
      id: id,
      name: name,
      address: address,
      model: model,
      username: username,
      certificateSha256: fingerprint);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'address': address,
        'model': model,
        'username': username,
        'certificateSha256': certificateSha256
      };

  factory KvmProfile.fromJson(Map<String, dynamic> json) {
    final address = parseAddress(json['address'] as String).toString();
    return KvmProfile(
        id: json['id'] as String,
        name: json['name'] as String,
        address: address,
        model: json['model'] as String,
        username: json['username'] as String? ?? 'admin',
        certificateSha256: json['certificateSha256'] as String?);
  }
}

class KvmProfiles extends ChangeNotifier {
  static final instance = KvmProfiles();
  final List<KvmProfile> _profiles = [];
  Future<void>? _loading;
  String? error;
  List<KvmProfile> get profiles => List.unmodifiable(_profiles);

  Future<File> _file() async => File(
      '${(await getApplicationSupportDirectory()).path}/glinet-clients.json');

  Future<void> load() => _loading ??= _load();
  Future<void> _load() async {
    try {
      final file = await _file();
      if (await file.exists()) {
        final data = jsonDecode(await file.readAsString()) as List;
        final loaded = data
            .map((e) => KvmProfile.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        _profiles.addAll(loaded);
      }
    } catch (_) {
      error =
          'Saved KVM clients could not be read. The file has been preserved.';
    }
    notifyListeners();
  }

  Future<void> save(KvmProfile profile) async {
    await load();
    final next = [..._profiles];
    final index = next.indexWhere((e) => e.id == profile.id);
    if (index < 0) {
      next.add(profile);
    } else {
      if (next[index].credentialKey != profile.credentialKey) {
        await KvmPasswordStore.delete(next[index].credentialKey);
      }
      next[index] = profile;
    }
    await _write(next);
  }

  Future<void> remove(KvmProfile profile) async {
    await load();
    await KvmPasswordStore.delete(profile.credentialKey);
    await _write(_profiles.where((e) => e.id != profile.id).toList());
  }

  Future<void> _write(List<KvmProfile> next) async {
    if (error != null) throw StateError(error!);
    final file = await _file();
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.${const Uuid().v4()}.tmp');
    await temp.writeAsString(jsonEncode(next.map((e) => e.toJson()).toList()),
        flush: true);
    await temp.rename(file.path);
    _profiles
      ..clear()
      ..addAll(next);
    notifyListeners();
  }
}
