import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/xboard/model/xboard_models.dart';

void main() {
  test('remaining is clamped and null expiry means long-term', () {
    final subscription = XboardSubscription.fromJson(const {
      'u': 900,
      'd': 300,
      'transfer_enable': 1000,
      'expired_at': null,
      'next_reset_at': 0,
      'plan_id': 3,
      'plan': {'name': 'Annual'},
    });

    expect(subscription.upload, 900);
    expect(subscription.download, 300);
    expect(subscription.total, 1000);
    expect(subscription.remaining, 0);
    expect(subscription.used, 1200);
    expect(subscription.expiresAt, isNull);
    expect(subscription.nextResetAt, isNull);
    expect(subscription.isExpired, isFalse);
    expect(subscription.hasPlan, isTrue);
    expect(subscription.hasTraffic, isFalse);
    expect(subscription.canConnect, isFalse);
  });

  test('expired_at zero is expired and future timestamps are not', () {
    final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final expired = XboardSubscription.fromJson({
      'u': 10,
      'd': 10,
      'transfer_enable': 1000,
      'expired_at': nowSeconds - 60,
      'plan_id': 1,
    });
    final active = XboardSubscription.fromJson({
      'u': 10,
      'd': 10,
      'transfer_enable': 1000,
      'expired_at': nowSeconds + 3600,
      'plan_id': 1,
    });
    final zero = XboardSubscription.fromJson(const {
      'u': 0,
      'd': 0,
      'transfer_enable': 1000,
      'expired_at': 0,
      'plan_id': 1,
    });

    expect(expired.isExpired, isTrue);
    expect(expired.expiresAt, isNotNull);
    expect(expired.hasTraffic, isTrue);
    expect(expired.canConnect, isFalse);
    expect(active.isExpired, isFalse);
    expect(active.canConnect, isTrue);
    expect(zero.isExpired, isTrue);
    expect(zero.expiresAt, isNotNull);
    expect(zero.canConnect, isFalse);
  });

  test('public config accepts integer and boolean switches', () {
    final config = XboardPublicConfig.fromJson(const {
      'is_email_verify': 1,
      'is_invite_force': true,
      'is_captcha': '1',
      'tos_url': ' https://panel.example.com/tos ',
    });

    expect(config.emailVerify, isTrue);
    expect(config.inviteForce, isTrue);
    expect(config.captchaEnabled, isTrue);
    expect(config.tosUrl, 'https://panel.example.com/tos');
  });
}
