import '../l10n/app_localizations.dart';
import '../services/api_keys.dart';

/// Session data model.
class Session {
  final String roomId;
  final String sessionToken;
  final String relayUrl;
  final String sourceLang;
  final String targetLang;
  final String tier;
  final String role; // "host" | "guest" | "listener"
  final String? inviteeId;
  final int quotaRemaining;
  final List<Map<String, dynamic>> iceServers;
  /// "duo" (two translating peers) or "guide" (one speaker, N listeners).
  /// Fixed at room creation; the relay routes the two modes differently.
  final String mode;
  /// Languages offered to listeners in a guide room.
  final List<String> listenerLanguages;

  Session({
    required this.roomId,
    required this.sessionToken,
    required this.relayUrl,
    required this.sourceLang,
    required this.targetLang,
    required this.tier,
    required this.role,
    this.inviteeId,
    required this.quotaRemaining,
    this.iceServers = const <Map<String, dynamic>>[],
    this.mode = 'duo',
    this.listenerLanguages = const <String>[],
  });

  factory Session.fromJson(Map<String, dynamic> json, {String role = 'host'}) {
    return Session(
      roomId: json['roomId'] as String,
      sessionToken: json['sessionToken'] as String,
      relayUrl: _resolveRelayUrl(json['relayUrl'] as String),
      sourceLang: json['sourceLang'] as String? ?? 'de',
      targetLang: json['targetLang'] as String? ?? 'en',
      tier: json['tier'] as String? ?? 'free',
      role: role,
      inviteeId: json['inviteeId'] as String?,
      quotaRemaining: json['quotaRemaining'] as int? ?? 0,
      iceServers: (json['iceServers'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList(growable: false),
      mode: json['mode'] as String? ?? 'duo',
      listenerLanguages: (json['listenerLanguages'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(growable: false),
    );
  }

  Session copyWith({String? sessionToken}) => Session(
        roomId: roomId,
        sessionToken: sessionToken ?? this.sessionToken,
        relayUrl: relayUrl,
        sourceLang: sourceLang,
        targetLang: targetLang,
        tier: tier,
        role: role,
        inviteeId: inviteeId,
        quotaRemaining: quotaRemaining,
        iceServers: iceServers,
        mode: mode,
        listenerLanguages: listenerLanguages,
      );

  /// Points the relay URL at the worker the app is actually configured for.
  ///
  /// The worker derives the URL from its own request host, which under
  /// `wrangler dev` is the configured production route rather than the local
  /// address — a session created locally would then try to reach production
  /// and fail with "connection to the relay failed". When the app targets a
  /// non-default worker (a local dev worker), the relay lives on that same
  /// host, so the host and scheme are taken from there.
  static String _resolveRelayUrl(String reported) {
    final configured = Uri.tryParse(ApiKeys.workerUrl);
    if (configured == null || configured.host.isEmpty) return reported;
    // The deployed worker is the default: trust what it reports.
    if (configured.host == 'snail-worker.pixstash.workers.dev') return reported;
    final relay = Uri.tryParse(reported);
    if (relay == null) return reported;
    final scheme = configured.scheme == 'https' ? 'wss' : 'ws';
    return relay
        .replace(scheme: scheme, host: configured.host, port: configured.port)
        .toString();
  }
}

/// User quota model.
class Quota {
  final String userId;
  final String tier;
  final int usedSeconds;
  final int remainingSeconds;
  final int totalSeconds;

  Quota({
    required this.userId,
    required this.tier,
    required this.usedSeconds,
    required this.remainingSeconds,
    required this.totalSeconds,
  });

  factory Quota.fromJson(Map<String, dynamic> json) {
    return Quota(
      userId: json['userId'] as String,
      tier: json['tier'] as String? ?? 'free',
      usedSeconds: json['usedSeconds'] as int? ?? 0,
      remainingSeconds: json['remainingSeconds'] as int? ?? 0,
      totalSeconds: json['totalSeconds'] as int? ?? 1800,
    );
  }

  String get formattedUsed {
    final mins = usedSeconds ~/ 60;
    final secs = usedSeconds % 60;
    return '${mins}m ${secs}s';
  }

  String get formattedRemaining {
    if (tier == 'paid') return 'unlimited';
    final mins = remainingSeconds ~/ 60;
    final secs = remainingSeconds % 60;
    return '${mins}m ${secs}s';
  }

  String formattedRemainingLocalized(AppLocalizations l10n) {
    if (tier == 'paid') return l10n.paywallUnlimited;
    return formattedRemaining;
  }
}
