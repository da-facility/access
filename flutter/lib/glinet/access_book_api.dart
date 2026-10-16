import 'dart:convert';

import 'package:http/http.dart' as http;

import 'kvm_profile.dart';

class AccessBookApi {
  final String server;
  final String token;
  String owner = '';

  AccessBookApi(this.server, this.token);

  Future<dynamic> request(String method, String path, [Object? body]) async {
    final client = http.Client();
    try {
      final base = Uri.parse(server);
      if (!['https', 'http'].contains(base.scheme) || base.host.isEmpty) {
        throw const FormatException(
            'Configure an API server in Settings first.');
      }
      final request = http.Request(method, base.resolve(path))
        ..followRedirects = false
        ..headers.addAll({
          if (token.isNotEmpty) 'Authorization': 'Bearer $token',
          'Content-Type': 'application/json'
        });
      if (body != null) request.body = jsonEncode(body);
      final response = await http.Response.fromStream(
              await client.send(request).timeout(const Duration(seconds: 15)))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 401) {
        throw const FormatException(
            'Your session expired. Log in again in Settings.');
      }
      if (response.statusCode == 404) {
        throw const FormatException(
            'This API server does not support GL.iNet address books.');
      }
      final data = response.body.isEmpty ? null : jsonDecode(response.body);
      if (response.statusCode != 200) {
        throw FormatException(data is Map
            ? data['error']?.toString() ?? 'Request failed.'
            : 'Request failed.');
      }
      return data;
    } finally {
      client.close();
    }
  }

  Future<List<KvmProfile>> load() async {
    final data = await request('GET', '/api/access/kvms');
    owner = data['owner'] as String;
    return (data['items'] as List)
        .map((item) => KvmProfile.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  Future<void> save(KvmProfile profile, {required bool create}) async {
    await request(
        create ? 'POST' : 'PUT', '/api/access/kvms', profile.toJson());
  }

  Future<void> remove(KvmProfile profile) async {
    await request('DELETE', '/api/access/kvms', {'id': profile.id});
  }

  KvmProfile sessionProfile(KvmProfile profile) => KvmProfile.fromJson({
        ...profile.toJson(),
        'id':
            jsonEncode(['access', Uri.parse(server).origin, owner, profile.id]),
      });
}
