import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:haoze_xboard/haoze_xboard.dart';

enum AccountDohProvider { alibaba, cloudflare, google, tencent }

enum AccountProxyKind { http, socks5 }

class AccountNetworkSettings {
  const AccountNetworkSettings({
    this.dohProvider = AccountDohProvider.alibaba,
    this.echEnabled = true,
    this.proxyEnabled = false,
    this.proxyKind = AccountProxyKind.http,
    this.proxyHost = '127.0.0.1',
    this.proxyPort = 7890,
    this.proxyUsername = '',
    this.proxyPassword = '',
  });

  final AccountDohProvider dohProvider;
  final bool echEnabled;
  final bool proxyEnabled;
  final AccountProxyKind proxyKind;
  final String proxyHost;
  final int proxyPort;
  final String proxyUsername;
  final String proxyPassword;

  AccountNetworkSettings copyWith({
    AccountDohProvider? dohProvider,
    bool? echEnabled,
    bool? proxyEnabled,
    AccountProxyKind? proxyKind,
    String? proxyHost,
    int? proxyPort,
    String? proxyUsername,
    String? proxyPassword,
  }) => AccountNetworkSettings(
    dohProvider: dohProvider ?? this.dohProvider,
    echEnabled: echEnabled ?? this.echEnabled,
    proxyEnabled: proxyEnabled ?? this.proxyEnabled,
    proxyKind: proxyKind ?? this.proxyKind,
    proxyHost: proxyHost ?? this.proxyHost,
    proxyPort: proxyPort ?? this.proxyPort,
    proxyUsername: proxyUsername ?? this.proxyUsername,
    proxyPassword: proxyPassword ?? this.proxyPassword,
  );

  String? get proxyUrl => proxyEnabled
      ? Uri(
          scheme: proxyKind == AccountProxyKind.http ? 'http' : 'socks5h',
          host: proxyHost,
          port: proxyPort,
        ).toString()
      : null;

  bool get isValid {
    if (!proxyEnabled) return true;
    final ip = InternetAddress.tryParse(proxyHost);
    final hostValid =
        ip != null ||
        (proxyHost.length <= 253 &&
            proxyHost
                .split('.')
                .every(
                  (label) => RegExp(
                    r'^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$',
                  ).hasMatch(label),
                ));
    return hostValid &&
        proxyPort > 0 &&
        proxyPort <= 65535 &&
        utf8.encode(proxyUsername).length <= 255 &&
        utf8.encode(proxyPassword).length <= 255;
  }

  Map<String, Object> toJson() => {
    'dohProvider': dohProvider.name,
    'echEnabled': echEnabled,
    'proxyEnabled': proxyEnabled,
    'proxyKind': proxyKind.name,
    'proxyHost': proxyHost,
    'proxyPort': proxyPort,
    'proxyUsername': proxyUsername,
    'proxyPassword': proxyPassword,
  };

  factory AccountNetworkSettings.fromJson(Map<String, dynamic> data) {
    final value = AccountNetworkSettings(
      dohProvider: AccountDohProvider.values.byName(
        data['dohProvider'] as String,
      ),
      echEnabled: data['echEnabled'] as bool,
      proxyEnabled: data['proxyEnabled'] as bool,
      proxyKind: AccountProxyKind.values.byName(data['proxyKind'] as String),
      proxyHost: data['proxyHost'] as String,
      proxyPort: data['proxyPort'] as int,
      proxyUsername: data['proxyUsername'] as String,
      proxyPassword: data['proxyPassword'] as String,
    );
    if (!value.isValid) throw const FormatException('Invalid network settings');
    return value;
  }
}

class AccountNetworkController {
  AccountNetworkController({
    Future<String?> Function()? read,
    Future<void> Function(String)? write,
  }) : _read = read ?? (() => _storage.read(key: _key)),
       _write = write ?? ((value) => _storage.write(key: _key, value: value));

  static const _key = 'haoze.account.network.v1';
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
  );
  final Future<String?> Function() _read;
  final Future<void> Function(String) _write;
  Future<AccountNetworkSettings>? _loaded;

  Future<AccountNetworkSettings> get current => _loaded ??= _load();

  Future<AccountNetworkSettings> _load() async {
    try {
      final raw = await _read();
      if (raw == null) return const AccountNetworkSettings();
      if (raw.length > 16384) throw const FormatException();
      return AccountNetworkSettings.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      throw const XboardException(XboardFailure.configuration);
    }
  }

  Future<void> save(AccountNetworkSettings settings) async {
    if (!settings.isValid) {
      throw const FormatException('Invalid network settings');
    }
    await _write(jsonEncode(settings.toJson()));
    _loaded = Future.value(settings);
  }
}

final haozeNetworkProvider = Provider<AccountNetworkController>(
  (ref) => AccountNetworkController(),
);
