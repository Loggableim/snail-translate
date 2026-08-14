import 'dart:async';

import 'package:flutter/foundation.dart';

enum SessionControllerState { idle, connecting, connected, reconnecting, ended }

/// Widget-independent orchestration for the session lifecycle.
///
/// The callbacks keep transport/provider details out of this state machine and
/// make reconnect races deterministic and directly testable.
class SessionController extends ChangeNotifier {
  SessionController({
    required this.connect,
    required this.disconnect,
    required this.setTargetLanguage,
    String initialTargetLanguage = 'en',
  }) : _targetLanguage = initialTargetLanguage;

  final Future<void> Function(int generation) connect;
  final Future<void> Function() disconnect;
  final Future<void> Function(String language) setTargetLanguage;

  SessionControllerState _state = SessionControllerState.idle;
  String _targetLanguage;
  int _generation = 0;
  bool _disposed = false;

  SessionControllerState get state => _state;
  String get targetLanguage => _targetLanguage;
  int get generation => _generation;

  bool isCurrent(int generation) => !_disposed && generation == _generation;

  Future<void> start() async {
    if (_disposed || _state == SessionControllerState.ended) return;
    final generation = ++_generation;
    _setState(SessionControllerState.connecting);
    await connect(generation);
    if (isCurrent(generation)) _setState(SessionControllerState.connected);
  }

  Future<void> changeLanguage(String language) async {
    if (_disposed || language == _targetLanguage) return;
    _targetLanguage = language;
    final generation = ++_generation;
    _setState(SessionControllerState.reconnecting);
    await disconnect();
    if (!isCurrent(generation)) return;
    await setTargetLanguage(language);
    if (!isCurrent(generation)) return;
    _setState(SessionControllerState.connecting);
    await connect(generation);
    if (isCurrent(generation)) _setState(SessionControllerState.connected);
  }

  Future<void> peerLost() async {
    if (_disposed || _state == SessionControllerState.ended) return;
    ++_generation;
    _setState(SessionControllerState.reconnecting);
    await disconnect();
  }

  Future<void> end() async {
    if (_disposed || _state == SessionControllerState.ended) return;
    ++_generation;
    await disconnect();
    if (!_disposed) _setState(SessionControllerState.ended);
  }

  void _setState(SessionControllerState value) {
    if (_state == value || _disposed) return;
    _state = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
