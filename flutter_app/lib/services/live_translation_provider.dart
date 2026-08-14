import 'package:flutter/foundation.dart';

/// Common observable lifecycle contract for live translation transports.
/// Provider-specific connection parameters remain on each implementation.
abstract interface class LiveTranslationProvider implements Listenable {
  String get state;
  String? get lastError;
  Future<void> disconnect();
}
