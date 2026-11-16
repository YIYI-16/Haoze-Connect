import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:haoze_xboard/haoze_xboard.dart';

enum AccountDohProvider { alibaba, cloudflare, google, tencent }

enum AccountRoute {
  primary('www.haoze.cyou', false),
  secondary('alt.haoze.cyou', true);

  const AccountRoute(this.host, this.defaultEchEnabled);
  final String host;
  final bool defaultEchEnabled;
  Uri get origin => Uri.https(host);
}

enum AccountProxyKind { http, socks5 }

class AccountNetworkSettings {
  const AccountNetworkSettings({
    this.dohProvider = AccountDohProvider.alibaba,
    this.route = AccountRoute.primary,
    this.primaryDohEnabled = true,
    this.primaryEchEnabled = false,
    this.secondaryDohEnabled = true,
    this.secondaryEchEnabled = true,
    this.proxyEnabled = false,
    this.proxyKind = AccountProxyKind.http,
    this.proxyHost = '127.0.0.1',
    this.proxyPort = 7890,
    this.proxyUsername = '',
    this.proxyPassword = '',
  });

  final AccountDohProvider dohProvider;
  final AccountRoute route;
  final bool primaryDohEnabled;
  final bool primaryEchEnabled;
  final bool secondaryDohEnabled;
  final bool secondaryEchEnabled;
  bool get dohEnabled =>
      route == AccountRoute.primary ? primaryDohEnabled : secondaryDohEnabled;
  bool get echEnabled =>
      route == AccountRoute.primary ? primaryEchEnabled : secondaryEchEnabled;
  final bool proxyEnabled;
  final AccountProxyKind proxyKind;
  final String proxyHost;
  final int proxyPort;
  final String proxyUsername;
  final String proxyPassword;

  AccountNetworkSettings copyWith({
    AccountRoute? route,
    AccountDohProvider? dohProvider,
    bool? dohEnabled,
    bool? echEnabled,
    bool? proxyEnabled,
    AccountProxyKind? proxyKind,
    String? proxyHost,
    int? proxyPort,
    String? proxyUsername,
    String? proxyPassword,
  }) {
    final selected = route ?? this.route;
    return AccountNetworkSettings(
      route: selected,
      dohProvider: dohProvider ?? this.dohProvider,
      primaryDohEnabled: selected == AccountRoute.primary
          ? dohEnabled ?? primaryDohEnabled
          : primaryDohEnabled,
      primaryEchEnabled: selected == AccountRoute.primary
          ? echEnabled ?? primaryEchEnabled
          : primaryEchEnabled,
      secondaryDohEnabled: selected == AccountRoute.secondary
          ? dohEnabled ?? secondaryDohEnabled
          : secondaryDohEnabled,
      secondaryEchEnabled: selected == AccountRoute.secondary
          ? echEnabled ?? secondaryEchEnabled
          : secondaryEchEnabled,
      proxyEnabled: proxyEnabled ?? this.proxyEnabled,
      proxyKind: proxyKind ?? this.proxyKind,
      proxyHost: proxyHost ?? this.proxyHost,
      proxyPort: proxyPort ?? this.proxyPort,
      proxyUsername: proxyUsername ?? this.proxyUsername,
      proxyPassword: proxyPassword ?? this.proxyPassword,
    );
  }

  AccountNetworkSettings defaultsFor(AccountRoute route) => copyWith(
    route: route,
    dohProvider: AccountDohProvider.alibaba,
    dohEnabled: true,
    echEnabled: route.defaultEchEnabled,
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
    'version': 2,
    'route': route.name,
    'primary': {
      'dohEnabled': primaryDohEnabled,
      'echEnabled': primaryEchEnabled,
    },
    'secondary': {
      'dohEnabled': secondaryDohEnabled,
      'echEnabled': secondaryEchEnabled,
    },
    'proxyEnabled': proxyEnabled,
    'proxyKind': proxyKind.name,
    'proxyHost': proxyHost,
    'proxyPort': proxyPort,
    'proxyUsername': proxyUsername,
    'proxyPassword': proxyPassword,
  };

  factory AccountNetworkSettings.fromJson(Map<String, dynamic> data) {
    final legacy = !data.containsKey('version');
    if (!legacy && data['version'] != 2) throw const FormatException();
    final primary = legacy ? null : data['primary'] as Map<String, dynamic>;
    final secondary = legacy ? null : data['secondary'] as Map<String, dynamic>;
    final value = AccountNetworkSettings(
      dohProvider: AccountDohProvider.values.byName(
        data['dohProvider'] as String,
      ),
      route: legacy
          ? AccountRoute.primary
          : AccountRoute.values.byName(data['route'] as String),
      primaryDohEnabled: legacy ? true : primary!['dohEnabled'] as bool,
      primaryEchEnabled: legacy
          ? data['echEnabled'] as bool
          : primary!['echEnabled'] as bool,
      secondaryDohEnabled: legacy ? true : secondary!['dohEnabled'] as bool,
      secondaryEchEnabled: legacy ? true : secondary!['echEnabled'] as bool,
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
