/// Session data model.
class Session {
  final String roomId;
  final String sessionToken;
  final String relayUrl;
  final String sourceLang;
  final String targetLang;
  final String tier;
  final String role; // "host" | "guest"
  final String? inviteeId;
  final int quotaRemaining;
  final List<Map<String, dynamic>> iceServers;

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
  });

  factory Session.fromJson(Map<String, dynamic> json, {String role = 'host'}) {
    return Session(
      roomId: json['roomId'] as String,
      sessionToken: json['sessionToken'] as String,
      relayUrl: json['relayUrl'] as String,
      sourceLang: json['sourceLang'] as String? ?? 'de',
      targetLang: json['targetLang'] as String? ?? 'en',
      tier: json['tier'] as String? ?? 'free',
      role: role,
      inviteeId: json['inviteeId'] as String?,
      quotaRemaining: json['quotaRemaining'] as int? ?? 0,
      iceServers: (json['iceServers'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList(growable: false),
    );
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
    if (tier == 'paid') return 'Unbegrenzt';
    final mins = remainingSeconds ~/ 60;
    final secs = remainingSeconds % 60;
    return '${mins}m ${secs}s';
  }
}
