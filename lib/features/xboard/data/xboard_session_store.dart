import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Everything needed to resume a panel session. Passwords are never stored.
@immutable
class XboardStoredSession {
  const XboardStoredSession({
    required this.origin,
    required this.authData,
    required this.email,
    this.profileId,
    this.revoked = false,
  });

  /// A tombstone used when deleting the secure entry fails. It is never a
  /// usable session and takes priority over any older auth token.
  const XboardStoredSession.revoked({required this.origin})
    : authData = '',
      email = '',
      profileId = null,
      revoked = true;

  final String origin;
  final String authData;
  final String email;
  final String? profileId;
  final bool revoked;

  XboardStoredSession copyWith({String? profileId, bool clearProfileId = false}) {
    return XboardStoredSession(
      origin: origin,
      authData: authData,
      email: email,
      profileId: clearProfileId ? null : (profileId ?? this.profileId),
      revoked: revoked,
    );
  }

  Map<String, dynamic> toJson() => {
    'origin': origin,
    'auth_data': authData,
    'email': email,
    if (profileId != null) 'profile_id': profileId,
    if (revoked) 'revoked': true,
  };

  static XboardStoredSession? fromJson(Map<String, dynamic> json) {
    final origin = json['origin'];
    final revoked = json['revoked'] == true;
    if (revoked) {
      return XboardStoredSession.revoked(origin: origin is String ? origin : '');
    }
    final authData = json['auth_data'];
    final email = json['email'];
    final profileId = json['profile_id'];
    if (origin is! String ||
        origin.isEmpty ||
        authData is! String ||
        authData.isEmpty ||
        email is! String ||
        email.isEmpty) {
      return null;
    }
    return XboardStoredSession(
      origin: origin,
      authData: authData,
      email: email,
      profileId: profileId is String && profileId.isNotEmpty ? profileId : null,
    );
  }
}

abstract interface class XboardSessionStore {
  Future<XboardStoredSession?> read();

  Future<void> write(XboardStoredSession session);

  Future<void> clear();
}

/// Platform-backed secure storage.
///
/// Android uses encrypted shared preferences, Apple platforms the keychain,
/// Windows Credential Manager and Linux libsecret. The token is the only
/// credential persisted; the password exists only in the request body.
class SecureXboardSessionStore implements XboardSessionStore {
  SecureXboardSessionStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));

  static const _sessionKey = 'xboard.session.v1';

  final FlutterSecureStorage _storage;

  @override
  Future<XboardStoredSession?> read() async {
    final raw = await _storage.read(key: _sessionKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        await clear();
        return null;
      }
      final session = XboardStoredSession.fromJson(decoded.cast<String, dynamic>());
      if (session == null) {
        await clear();
        return null;
      }
      if (session.revoked) {
        await clear();
        return null;
      }
      return session;
    } on FormatException {
      await clear();
      return null;
    }
  }

  @override
  Future<void> write(XboardStoredSession session) {
    return _storage.write(key: _sessionKey, value: jsonEncode(session.toJson()));
  }

  @override
  Future<void> clear() => _storage.delete(key: _sessionKey);
}
