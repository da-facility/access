import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'kvm_transport.dart';

class KvmVideo {
  final KvmTransport transport;
  final RTCVideoRenderer renderer;
  final void Function(String) onError;
  WebSocket? _ws;
  RTCPeerConnection? _peer;
  MediaStream? _stream;
  int? _session;
  int? _handle;
  int _transaction = 0;
  bool _closed = false;
  Timer? _keepalive;
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  final _offer = Completer<Map<String, dynamic>>();

  KvmVideo(this.transport, this.renderer, {required this.onError});

  void _send(Map<String, dynamic> message) {
    if (_closed || _ws?.readyState != WebSocket.open) return;
    _ws!.add(jsonEncode({
      'transaction': 'kvm-${++_transaction}',
      if (_session != null) 'session_id': _session,
      if (_handle != null) 'handle_id': _handle,
      ...message,
    }));
  }

  Future<Map<String, dynamic>> _request(Map<String, dynamic> message) async {
    final id = 'request-${++_transaction}';
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _send({...message, 'transaction': id});
    try {
      return await completer.future.timeout(const Duration(seconds: 15));
    } finally {
      _pending.remove(id);
    }
  }

  Future<void> start() async {
    _ws = await transport.socket('/janus/ws', protocols: ['janus-protocol']);
    _ws!.listen((raw) {
      if (_closed || raw is! String) return;
      try {
        final data = Map<String, dynamic>.from(jsonDecode(raw));
        if (data['janus'] == 'ack') return;
        final pending = _pending[data['transaction']];
        if (data['janus'] == 'error') {
          if (pending != null && !pending.isCompleted) {
            pending.completeError(const KvmException(
                'The KVM video service rejected the request.'));
          } else {
            onError('The KVM video service rejected the request.');
          }
        } else if (pending != null && !pending.isCompleted) {
          pending.complete(data);
        }
        final plugin = data['plugindata']?['data'];
        if (plugin is Map &&
            (plugin['error'] != null || plugin['error_code'] != null)) {
          onError('The KVM video stream is unavailable. Check its video mode.');
        }
        if (data['jsep'] is Map && !_offer.isCompleted) {
          _offer.complete(Map<String, dynamic>.from(data['jsep']));
        }
        if (data['janus'] == 'hangup') {
          onError('The KVM ended the video stream.');
        }
      } catch (_) {
        onError('The KVM sent an invalid video message.');
      }
    }, onError: (Object error) {
      if (!_closed) onError('The KVM video connection failed.');
    }, onDone: () {
      if (!_closed) onError('The KVM video connection closed.');
    });
    final created = await _request({'janus': 'create'});
    _session = created['data']['id'] as int;
    _keepalive = Timer.periodic(
        const Duration(seconds: 25), (_) => _send({'janus': 'keepalive'}));
    final attached =
        await _request({'janus': 'attach', 'plugin': 'janus.plugin.ustreamer'});
    _handle = attached['data']['id'] as int;
    _send({
      'janus': 'message',
      'body': {
        'request': 'watch',
        'params': {
          'orientation': 0,
          'audio': false,
          'mic': false,
          'video_format': 0
        }
      }
    });
    final offer = await _offer.future.timeout(const Duration(seconds: 20));
    if (_closed) return;
    final peer = await createPeerConnection(
        {'iceServers': [], 'sdpSemantics': 'unified-plan'});
    if (_closed) {
      await peer.close();
      await peer.dispose();
      return;
    }
    _peer = peer;
    _peer!.onIceCandidate = (candidate) {
      _send({
        'janus': 'trickle',
        'candidate': candidate.candidate == null || candidate.candidate!.isEmpty
            ? {'completed': true}
            : candidate.toMap()
      });
    };
    _peer!.onConnectionState = (state) {
      if (!_closed &&
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        onError(
            'Video could not reach the KVM. Check that both devices are on the same LAN or Tailscale network.');
      }
    };
    _peer!.onTrack = (event) async {
      if (_closed) return;
      if (event.streams.isNotEmpty) {
        renderer.srcObject = event.streams.first;
      } else {
        final stream = _stream ?? await createLocalMediaStream('glinet-video');
        if (_closed) {
          await stream.dispose();
          return;
        }
        _stream = stream;
        await _stream!.addTrack(event.track);
        renderer.srcObject = _stream;
      }
    };
    await _peer!.setRemoteDescription(
        RTCSessionDescription(offer['sdp'] as String, offer['type'] as String));
    final answer = await _peer!.createAnswer(
        {'offerToReceiveVideo': true, 'offerToReceiveAudio': false});
    await _peer!.setLocalDescription(answer);
    _send({
      'janus': 'message',
      'body': {'request': 'start'},
      'jsep': answer.toMap()
    });
  }

  Future<void> close() async {
    if (_closed) return;
    _send({'janus': 'destroy'});
    _closed = true;
    _keepalive?.cancel();
    renderer.srcObject = null;
    await _peer?.close();
    await _peer?.dispose();
    await _stream?.dispose();
    await _ws?.close();
  }
}
