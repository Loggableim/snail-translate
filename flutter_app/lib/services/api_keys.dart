/// Runtime/build configuration for Snail.
/// Provider secrets must be entered as BYOK and stored in secure storage.
class ApiKeys {
  static const groq = String.fromEnvironment('GROQ_API_KEY');
  static const fishaudio = String.fromEnvironment('FISHAUDIO_API_KEY');
  static const deepgram = String.fromEnvironment('DEEPGRAM_API_KEY');
  static const openai = String.fromEnvironment('OPENAI_API_KEY');

  // Worker credentials
  static const devApiKey = String.fromEnvironment('SNAIL_DEV_API_KEY');
  static const workerUrl = "https://snail-worker.pixstash.workers.dev";
  // Public fallback used only when the worker response omits its download URL.
  static const appShareUrl = workerUrl;
}
