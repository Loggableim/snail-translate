class UserIdentity {
  final String userId;
  final String username;
  final String? publicKey;

  const UserIdentity({required this.userId, required this.username, this.publicKey});
  Map<String, dynamic> toJson() => {
        'userId': userId,
        'username': username,
        if (publicKey != null && publicKey!.isNotEmpty) 'publicKey': publicKey,
      };
  factory UserIdentity.fromJson(Map<String, dynamic> json) => UserIdentity(
      userId: json['userId'] as String,
      username: json['username'] as String? ?? 'Snail User',
      publicKey: json['publicKey'] as String?);

  String get qrPayload =>
      'snail://user/$userId?name=${Uri.encodeComponent(username)}'
      '${publicKey == null ? '' : '&pub=${Uri.encodeQueryComponent(publicKey!)}'}';
}
