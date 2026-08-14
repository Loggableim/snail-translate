class UserIdentity {
  final String userId;
  final String username;
  final String? publicKey;
  final String? agreementPublicKey;

  const UserIdentity({
    required this.userId,
    required this.username,
    this.publicKey,
    this.agreementPublicKey,
  });
  Map<String, dynamic> toJson() => {
        'userId': userId,
        'username': username,
        if (publicKey != null && publicKey!.isNotEmpty) 'publicKey': publicKey,
        if (agreementPublicKey != null && agreementPublicKey!.isNotEmpty)
          'agreementPublicKey': agreementPublicKey,
      };
  factory UserIdentity.fromJson(Map<String, dynamic> json) => UserIdentity(
      userId: json['userId'] as String,
      username: json['username'] as String? ?? 'Snail User',
      publicKey: json['publicKey'] as String?,
      agreementPublicKey: json['agreementPublicKey'] as String?);

  String get qrPayload =>
      'snail://user/$userId?name=${Uri.encodeComponent(username)}'
      '${publicKey == null ? '' : '&pub=${Uri.encodeQueryComponent(publicKey!)}'}'
      '${agreementPublicKey == null ? '' : '&agree=${Uri.encodeQueryComponent(agreementPublicKey!)}'}';
}
