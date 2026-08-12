/// Status of a contact relationship.
enum ContactStatus {
  /// Contact request is pending — not yet accepted or rejected.
  pending,

  /// Contact has been accepted.
  accepted,

  /// Contact request has been rejected.
  rejected,

  /// Contact has been blocked.
  blocked,
}

class SnailContact {
  final String userId;
  final String username;
  final ContactStatus status;

  const SnailContact({
    required this.userId,
    required this.username,
    this.status = ContactStatus.accepted,
  });

  bool get isPending => status == ContactStatus.pending;
  bool get isAccepted => status == ContactStatus.accepted;
  bool get isRejected => status == ContactStatus.rejected;
  bool get isBlocked => status == ContactStatus.blocked;

  SnailContact copyWith({ContactStatus? status}) => SnailContact(
        userId: userId,
        username: username,
        status: status ?? this.status,
      );

  Map<String, dynamic> toJson() => {
        'userId': userId,
        'username': username,
        'status': status.name,
      };

  factory SnailContact.fromJson(Map<String, dynamic> json) => SnailContact(
        userId: json['userId'] as String,
        username: json['username'] as String? ?? 'Snail User',
        status: _parseStatus(json['status'] as String?),
      );

  static ContactStatus _parseStatus(String? raw) {
    if (raw == null) return ContactStatus.accepted;
    return ContactStatus.values.firstWhere(
      (s) => s.name == raw,
      orElse: () => ContactStatus.accepted,
    );
  }
}
