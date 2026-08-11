class SnailContact {
  final String userId;
  final String username;

  const SnailContact({required this.userId, required this.username});

  Map<String, dynamic> toJson() => {'userId': userId, 'username': username};

  factory SnailContact.fromJson(Map<String, dynamic> json) => SnailContact(
        userId: json['userId'] as String,
        username: json['username'] as String? ?? 'Snail User',
      );
}
