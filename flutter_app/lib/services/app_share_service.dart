import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';

import 'api_keys.dart';
import 'user_identity_service.dart';
import '../l10n/app_localizations.dart';

enum AppShareStatus { ready, preparing, linkReady, guestConnected, transferring, finished, disconnected, failed }
enum AppShareErrorCode { unavailable, tunnel, transfer }

/// Offers this device's installed APK over an ephemeral Cloudflare websocket
/// tunnel. The APK remains a File on the host; no APK bytes are uploaded or
/// persisted by Cloudflare.
class AppShareService extends ChangeNotifier {
  static const _channel = MethodChannel('com.snail.app_share/method');
  static const _ttl = Duration(minutes: 15);

  IOWebSocketChannel? _tunnel;
  StreamSubscription? _tunnelSubscription;
  Timer? _expiryTimer;
  File? _apk;
  String? _token;
  String? _url;
  String? _version;
  int? _apkBytes;
  DateTime? _expiresAt;
  int _downloads = 0;
  int _transferredBytes = 0;
  bool _isPreparing = false;
  bool _isTransferring = false;
  DateTime? _transferStartedAt;
  AppShareStatus _status = AppShareStatus.ready;
  String? _error;
  AppShareErrorCode? _errorCode;

  bool get isSharing => _tunnel != null && _url != null;
  String? get url => _url;
  String? get version => _version;
  int? get apkBytes => _apkBytes;
  DateTime? get expiresAt => _expiresAt;
  int get downloads => _downloads;
  int get transferredBytes => _transferredBytes;
  bool get isPreparing => _isPreparing;
  bool get isTransferring => _isTransferring;
  AppShareStatus get status => _status;
  String? get error => _error;
  AppShareErrorCode? get errorCode => _errorCode;
  String localizedError(AppLocalizations l10n) => switch (_errorCode) {
        AppShareErrorCode.tunnel => l10n.appShareTunnel,
        AppShareErrorCode.transfer => l10n.appShareTransfer,
        AppShareErrorCode.unavailable => l10n.appShareUnavailable,
        null => l10n.appShareUnavailable,
      };
  double get progress => _apkBytes == null || _apkBytes == 0
      ? 0
      : (_transferredBytes / _apkBytes!).clamp(0, 1);
  double get bytesPerSecond {
    final started = _transferStartedAt;
    if (started == null || _transferredBytes == 0) return 0;
    final seconds = DateTime.now().difference(started).inMilliseconds / 1000;
    return seconds <= 0 ? 0 : _transferredBytes / seconds;
  }

  Future<void> start() async {
    if (isSharing || _isPreparing) return;
    _error = null;
    _errorCode = null;
    _isPreparing = true;
    _status = AppShareStatus.preparing;
    notifyListeners();
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>('apkInfo');
      final path = raw?['path'];
      if (path is! String || path.isEmpty) {
        throw StateError('app_share_apk_unavailable');
      }
      final apk = File(path);
      if (!await apk.exists()) throw StateError('app_share_apk_unreadable');
      _apk = apk;
      _version = raw?['version'] as String? ?? 'unknown';
      _apkBytes = await apk.length();
      _token = _newToken();
      final identity = UserIdentityService();
      await identity.init();
      final headers = <String, String>{'Content-Type': 'application/json'};
      final userId = identity.identity?.userId;
      if (userId != null) headers['X-Snail-Identity'] = userId;
      if (ApiKeys.devApiKey.isNotEmpty) headers['X-API-Key'] = ApiKeys.devApiKey;
      final requestBody = jsonEncode({'version': _version, 'bytes': _apkBytes});
      final publicKey = identity.publicKey;
      if (publicKey != null && publicKey.isNotEmpty) {
        final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
        final signature = await identity.signDevicePayload(
            'POST\n/api/app-share/${_token!}\n$requestBody\n$timestamp');
        if (signature != null && signature.isNotEmpty) {
          headers['X-Snail-Public-Key'] = publicKey;
          headers['X-Snail-Signature'] = signature;
          headers['X-Snail-Timestamp'] = timestamp;
        }
      }
      final response = await http.post(
        Uri.parse('${ApiKeys.workerUrl}/api/app-share/${_token!}'),
        headers: headers,
        body: requestBody,
      );
      if (response.statusCode != 201) throw StateError('app_share_create_failed_${response.statusCode}');
      final result = jsonDecode(response.body) as Map<String, dynamic>;
      _url = result['url'] as String? ?? '${ApiKeys.appShareUrl}/${_token!}';
      _expiresAt = DateTime.fromMillisecondsSinceEpoch((result['expiresAt'] as num?)?.toInt() ?? DateTime.now().add(_ttl).millisecondsSinceEpoch);
      _status = AppShareStatus.linkReady;
      await _connectHostTunnel();
      _expiryTimer = Timer(_ttl, stop);
    } catch (error) {
      _error = 'app_share_unavailable';
      _errorCode = AppShareErrorCode.unavailable;
      debugPrint('[AppShare] start failed: $error');
      _status = AppShareStatus.failed;
      await stop();
    } finally {
      _isPreparing = false;
      notifyListeners();
    }
  }

  Future<void> _connectHostTunnel() async {
    final worker = Uri.parse(ApiKeys.workerUrl);
    final scheme = worker.scheme == 'https' ? 'wss' : 'ws';
    final uri = worker.replace(scheme: scheme, path: '/app-share', queryParameters: {'token': _token!, 'role': 'host'});
    final tunnel = IOWebSocketChannel.connect(uri);
    _tunnel = tunnel;
    await tunnel.ready;
    _tunnelSubscription = tunnel.stream.listen(_onTunnelMessage, onError: (Object error) {
      _error = 'app_share_tunnel'; _errorCode = AppShareErrorCode.tunnel;
      debugPrint('[AppShare] tunnel failed: $error');
      _status = AppShareStatus.disconnected; notifyListeners();
    }, onDone: () {
      if (_status != AppShareStatus.finished) { _status = AppShareStatus.disconnected; notifyListeners(); }
    });
  }

  void _onTunnelMessage(dynamic raw) {
    if (raw is! String) return;
    try {
      final message = jsonDecode(raw) as Map<String, dynamic>;
      switch (message['type']) {
        case 'guest_connected':
          _status = AppShareStatus.guestConnected;
          break;
        case 'guest_ready':
          if (!_isTransferring) unawaited(_sendApk());
          break;
        case 'progress':
          _transferredBytes = (message['transferred'] as num?)?.toInt() ?? _transferredBytes;
          break;
        case 'transfer_complete':
          _status = AppShareStatus.finished;
          _isTransferring = false;
          break;
        case 'guest_disconnected':
          if (_isTransferring) _status = AppShareStatus.disconnected;
          break;
      }
      notifyListeners();
    } catch (e) {
      debugPrint('[AppShare] tunnel message decode error: $e');
    }
  }

  Future<void> _sendApk() async {
    final apk = _apk;
    final tunnel = _tunnel;
    if (apk == null || tunnel == null) return;
    _isTransferring = true;
    _transferredBytes = 0;
    _transferStartedAt = DateTime.now();
    _status = AppShareStatus.transferring;
    tunnel.sink.add(jsonEncode({'type': 'transfer_start'}));
    notifyListeners();
    try {
      // StreamSink.addStream applies the sink's flow-control contract. A
      // manual `await for` plus `sink.add` can read a full APK into the
      // WebSocket buffer before the network has accepted it.
      await tunnel.sink.addStream(apk.openRead());
      if (_tunnel != tunnel) return;
      tunnel.sink.add(jsonEncode({'type': 'transfer_complete'}));
      _status = AppShareStatus.finished;
      _isTransferring = false;
      _downloads++;
    } catch (error) {
      _error = 'app_share_transfer';
      _errorCode = AppShareErrorCode.transfer;
      debugPrint('[AppShare] transfer failed: $error');
      _status = AppShareStatus.failed;
      tunnel.sink.add(jsonEncode({'type': 'transfer_error'}));
      _isTransferring = false;
    }
    notifyListeners();
  }

  Future<void> share({required String title, required String text}) async {
    final currentUrl = _url; if (currentUrl == null) return;
    await _channel.invokeMethod<void>('shareText', {
      'title': title,
      'text': '$text $currentUrl',
    });
  }

  String _newToken() => List<String>.generate(24, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join();

  Future<void> stop() async {
    _expiryTimer?.cancel(); _expiryTimer = null;
    await _tunnelSubscription?.cancel(); _tunnelSubscription = null;
    await _tunnel?.sink.close(); _tunnel = null;
    _apk = null; _token = null; _url = null; _expiresAt = null;
    _transferredBytes = 0; _isTransferring = false; _isPreparing = false; _transferStartedAt = null;
    if (_error == null) _status = AppShareStatus.ready;
    notifyListeners();
  }

  @override void dispose() { unawaited(stop()); super.dispose(); }
}
