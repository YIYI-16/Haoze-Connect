import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Public registration/login switches returned by `GET /guest/comm/config`.
@immutable
class XboardPublicConfig {
  const XboardPublicConfig({
    required this.emailVerify,
    required this.inviteForce,
    required this.captchaEnabled,
    this.tosUrl,
  });

  factory XboardPublicConfig.fromJson(Map<String, dynamic> json) {
    return XboardPublicConfig(
      emailVerify: _asBool(json['is_email_verify'] ?? json['email_verify']),
      inviteForce: _asBool(json['is_invite_force'] ?? json['invite_force']),
      captchaEnabled: _asBool(json['is_captcha'] ?? json['captcha_enable']),
      tosUrl: _asNonEmptyString(json['tos_url']),
    );
  }

  final bool emailVerify;
  final bool inviteForce;
  final bool captchaEnabled;
  final String? tosUrl;
}

/// Subscription usage as reported by the panel.
///
/// Deliberately contains no token or subscription URL: widgets receive only
/// what they need to render, while the caller keeps the URL in the data layer.
@immutable
class XboardSubscription {
  const XboardSubscription({
    required this.upload,
    required this.download,
    required this.total,
    required this.remaining,
    required this.isExpired,
    required this.hasPlan,
    required this.hasTraffic,
    this.expiresAt,
    this.nextResetAt,
    this.planName,
  });

  /// Builds the public model from `GET /user/getSubscribe`.
  ///
  /// `u`/`d`/`transfer_enable` are byte counters. A null `expired_at` means a
  /// long-lived account; `0` is the panel's marker for an already expired one.
  factory XboardSubscription.fromJson(Map<String, dynamic> json) {
    final upload = _asInt(json['u'] ?? json['upload']) ?? 0;
    final download = _asInt(json['d'] ?? json['download']) ?? 0;
    final total = _asInt(json['transfer_enable'] ?? json['total']) ?? 0;
    final remaining = math.max(total - upload - download, 0);
    final expiresAt = _asDateTime(json['expired_at'], zeroIsEpoch: true);
    final plan = json['plan'];
    final planName = plan is Map<String, dynamic>
        ? _asNonEmptyString(plan['name'])
        : _asNonEmptyString(json['plan_name']);
    final planId = _asInt(json['plan_id']);
    final hasPlan = (planId != null && planId != 0) || planName != null;
    final isExpired = expiresAt != null && !expiresAt.isAfter(DateTime.now());

    return XboardSubscription(
      upload: upload,
      download: download,
      total: total,
      remaining: remaining,
      expiresAt: expiresAt,
      nextResetAt: _asDateTime(json['next_reset_at']),
      planName: planName,
      isExpired: isExpired,
      hasPlan: hasPlan,
      hasTraffic: total > 0 && remaining > 0,
    );
  }

  final int upload;
  final int download;
  final int total;
  final int remaining;
  final DateTime? expiresAt;
  final DateTime? nextResetAt;
  final String? planName;
  final bool isExpired;
  final bool hasPlan;
  final bool hasTraffic;

  int get used => upload + download;

  bool get canConnect => hasPlan && hasTraffic && !isExpired;

  /// A copy with the given fields replaced.
  XboardSubscription copyWith({
    int? upload,
    int? download,
    int? total,
    int? remaining,
    DateTime? expiresAt,
    DateTime? nextResetAt,
    String? planName,
    bool? isExpired,
    bool? hasPlan,
    bool? hasTraffic,
  }) {
    return XboardSubscription(
      upload: upload ?? this.upload,
      download: download ?? this.download,
      total: total ?? this.total,
      remaining: remaining ?? this.remaining,
      expiresAt: expiresAt ?? this.expiresAt,
      nextResetAt: nextResetAt ?? this.nextResetAt,
      planName: planName ?? this.planName,
      isExpired: isExpired ?? this.isExpired,
      hasPlan: hasPlan ?? this.hasPlan,
      hasTraffic: hasTraffic ?? this.hasTraffic,
    );
  }
}

bool _asBool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final normalized = value.trim().toLowerCase();
    return normalized == '1' || normalized == 'true' || normalized == 'yes';
  }
  return false;
}

int? _asInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

String? _asNonEmptyString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

DateTime? _asDateTime(Object? value, {bool zeroIsEpoch = false}) {
  final raw = _asInt(value);
  if (raw == null) return null;
  if (raw == 0) {
    return zeroIsEpoch ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true).toLocal() : null;
  }
  // Xboard returns seconds. Accept milliseconds too because plugins sometimes
  // pass timestamps through a different serializer.
  final millis = raw > 100000000000 ? raw : raw * 1000;
  return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true).toLocal();
}
