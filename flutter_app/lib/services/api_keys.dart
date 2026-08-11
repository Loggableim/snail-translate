class ApiKeys {
  // Provider credentials are configured by the user at runtime.
  // Development-only Worker credentials must be injected at build time and
  // never committed into the APK source or repository.
  static const devApiKey = String.fromEnvironment('SNAIL_DEV_API_KEY');
  static const workerUrl = String.fromEnvironment(
    'SNAIL_WORKER_URL',
    defaultValue: 'https://snail-worker.pixstash.workers.dev',
  );
  static const appShareUrl = String.fromEnvironment(
    'SNAIL_APP_SHARE_URL',
    defaultValue: 'https://snail-worker.pixstash.workers.dev/download',
  );
}
