import 'package:flutter/foundation.dart';

/// Common observable lifecycle contract for live translation transports.
/// Provider-specific connection parameters remain on each implementation.
abstract interface class LiveTranslationProvider implements Listenable {
  String get state;
  String? get lastError;

  /// Running transcript of what this endpoint's microphone heard, in the
  /// source language. Empty until the provider reports one.
  String get inputTranscript => '';

  /// Running transcript of the translation the provider produced. Empty
  /// until the provider reports one.
  String get outputTranscript => '';

  Future<void> disconnect();
}
