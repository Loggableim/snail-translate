import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/snail_contact.dart';

class ContactService extends ChangeNotifier {
  static const _storageKey = 'snail_contacts';
  final List<SnailContact> _contacts = [];

  List<SnailContact> get contacts => List.unmodifiable(_contacts);

  /// Contacts that have been accepted (not pending or rejected).
  List<SnailContact> get acceptedContacts =>
      _contacts.where((c) => c.isAccepted).toList();

  /// Pending contact requests awaiting user action.
  List<SnailContact> get pendingRequests =>
      _contacts.where((c) => c.isPending).toList();

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_storageKey) ?? const [];
    _contacts
      ..clear()
      ..addAll(raw.map((value) =>
          SnailContact.fromJson(jsonDecode(value) as Map<String, dynamic>)));
    notifyListeners();
  }

  /// Add a contact from QR payload. New contacts start as pending.
  Future<bool> addFromQr(String payload) async {
    final uri = Uri.tryParse(payload.trim());
    if (uri == null || uri.scheme != 'snail' || uri.host != 'user') {
      return false;
    }
    final userId = uri.pathSegments.isEmpty ? '' : uri.pathSegments.first;
    if (userId.isEmpty) return false;
    final username = uri.queryParameters['name']?.trim();
    if (_contacts.any((contact) => contact.userId == userId)) return true;
    _contacts.add(SnailContact(
      userId: userId,
      username: username?.isNotEmpty == true ? username! : 'Snail User',
      status: ContactStatus.pending,
    ));
    await _persist();
    notifyListeners();
    return true;
  }

  /// Accept a pending contact request.
  Future<void> accept(SnailContact contact) async {
    final index = _contacts.indexWhere((c) => c.userId == contact.userId);
    if (index == -1) return;
    _contacts[index] = _contacts[index].copyWith(status: ContactStatus.accepted);
    await _persist();
    notifyListeners();
  }

  /// Reject a pending contact request.
  Future<void> reject(SnailContact contact) async {
    final index = _contacts.indexWhere((c) => c.userId == contact.userId);
    if (index == -1) return;
    _contacts[index] = _contacts[index].copyWith(status: ContactStatus.rejected);
    await _persist();
    notifyListeners();
  }

  /// Block a contact. Blocked contacts cannot send messages or session requests.
  Future<void> block(SnailContact contact) async {
    final index = _contacts.indexWhere((c) => c.userId == contact.userId);
    if (index == -1) return;
    _contacts[index] = _contacts[index].copyWith(status: ContactStatus.blocked);
    await _persist();
    notifyListeners();
  }

  /// Unblock a previously blocked contact.
  Future<void> unblock(SnailContact contact) async {
    final index = _contacts.indexWhere((c) => c.userId == contact.userId);
    if (index == -1) return;
    _contacts[index] = _contacts[index].copyWith(status: ContactStatus.accepted);
    await _persist();
    notifyListeners();
  }

  /// Check if a user ID is blocked.
  bool isBlocked(String userId) =>
      _contacts.any((c) => c.userId == userId && c.isBlocked);

  Future<void> remove(SnailContact contact) async {
    _contacts.removeWhere((value) => value.userId == contact.userId);
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_storageKey,
        _contacts.map((contact) => jsonEncode(contact.toJson())).toList());
  }
}
