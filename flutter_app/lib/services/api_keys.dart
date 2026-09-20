/// Runtime/build configuration for Snail.
/// Provider secrets must be entered as BYOK and stored in secure storage.
class ApiKeys {
  static const groq = String.fromEnvironment('GROQ_API_KEY');
  static const fishaudio = String.fromEnvironment('FISHAUDIO_API_KEY');
  static const deepgram = String.fromEnvironment('DEEPGRAM_API_KEY');
  static const openai = String.fromEnvironment('OPENAI_API_KEY');

  // Worker credentials
  static const devApiKey = String.fromEnvironment('SNAIL_DEV_API_KEY');

  /// Relay gateway base URL.
  ///
  /// Overridable at build time so a local `wrangler dev` worker can be used
  /// for two-device testing without touching production:
  ///   flutter run --dart-define=SNAIL_WORKER_URL=http://127.0.0.1:8791
  /// The default stays the deployed worker, so a normal build is unchanged.
  static const workerUrl = String.fromEnvironment(
    'SNAIL_WORKER_URL',
    defaultValue: "https://snail-worker.pixstash.workers.dev",
  );
  // Public fallback used only when the worker response omits its download URL.
  static const appShareUrl = workerUrl;
}
