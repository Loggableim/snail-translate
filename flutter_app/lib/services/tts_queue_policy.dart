/// Decides what the listener's local text-to-speech is allowed to speak.
///
/// Extracted from the listener screen so the discipline can be tested without
/// a platform channel: only complete sentences are spoken, and a queue that
/// falls behind is dropped instead of reading a transcript that is already
/// seconds old while the speaker has moved on.
class TtsQueuePolicy {
  TtsQueuePolicy({
    required this.speak,
    required this.stop,
    this.maxPending = 2,
  });

  /// Hands one sentence to the engine. Injected so tests can supply a fake.
  final Future<void> Function(String text) speak;

  /// Drops anything the engine still has queued.
  final Future<void> Function() stop;

  /// How many sentences may wait before the queue is considered stale. A
  /// speaker produces roughly one sentence per few seconds, so more than a
  /// couple of pending lines means the voice is already behind.
  final int maxPending;

  int _pending = 0;

  /// Sentences currently waiting to be spoken.
  int get pending => _pending;

  /// True when [text] ends in sentence punctuation.
  ///
  /// Partial turns arrive constantly from a streaming ASR; speaking them
  /// produces stuttering fragments and repeats the same words twice once the
  /// completed sentence arrives.
  static bool isCompleteSentence(String text) {
    final trimmed = text.trim();
    if (trimmed.length < 2) return false;
    return RegExp(r'[.!?。！？…]$').hasMatch(trimmed);
  }

  /// Speaks [text] when it is a complete sentence, dropping the queue first
  /// if it has fallen behind.
  ///
  /// Returns true when the text was handed to the engine.
  Future<bool> offer(String text, {required bool enabled}) async {
    if (!enabled) return false;
    if (!isCompleteSentence(text)) return false;

    if (_pending >= maxPending) {
      // Behind: throw away what is queued rather than reading stale lines.
      await stop();
      _pending = 0;
    }

    _pending++;
    try {
      await speak(text.trim());
    } finally {
      _pending--;
    }
    return true;
  }
}
