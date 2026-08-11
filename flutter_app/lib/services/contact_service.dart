import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/snail_contact.dart';

class ContactService extends ChangeNotifier {
  static const _storageKey = 'snail_contacts';
  final List<SnailContact> _contacts = [];

  List<SnailContact> get contacts => List.unmodifiable(_contacts);

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_storageKey) ?? const [];
    _contacts
      ..clear()
      ..addAll(raw.map((value) =>
          SnailContact.fromJson(jsonDecode(value) as Map<String, dynamic>)));
    notifyListeners();
  }

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
        username: username?.isNotEmpty == true ? username! : 'Snail User'));
    await _persist();
    notifyListeners();
    return true;
  }

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
