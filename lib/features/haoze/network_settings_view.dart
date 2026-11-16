import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/features/form/form.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'network_settings.dart';
import 'network_transport.dart';

class AccountNetworkSettingsPage extends ConsumerStatefulWidget {
  const AccountNetworkSettingsPage({super.key});

  @override
  ConsumerState<AccountNetworkSettingsPage> createState() =>
      _AccountNetworkSettingsPageState();
}

class _AccountNetworkSettingsPageState
    extends ConsumerState<AccountNetworkSettingsPage> {
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  AccountNetworkSettings? _value;
  bool _saving = false;
  bool _loadFailed = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    AccountNetworkSettings value;
    try {
      value = await ref.read(haozeNetworkProvider).current;
    } catch (_) {
      value = const AccountNetworkSettings();
      _loadFailed = true;
    }
    if (!mounted) return;
    _host.text = value.proxyHost;
    _port.text = '${value.proxyPort}';
    _username.text = value.proxyUsername;
    _password.text = value.proxyPassword;
    setState(() => _value = value);
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  AccountNetworkSettings get _draft => _value!.copyWith(
    proxyHost: _host.text.trim(),
    proxyPort: int.tryParse(_port.text) ?? 0,
    proxyUsername: _username.text,
    proxyPassword: _password.text,
  );

  bool _validate() {
    if (_draft.isValid) return true;
    setState(() => _error = context.appLocalizations.haozeNetworkInvalidProxy);
    return false;
  }

  Future<void> _save() async {
    if (_saving || !_validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(haozeNetworkProvider).save(_draft);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() => _error = context.appLocalizations.haozeStorageError);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _chooseRoute() async {
    if (!_validate()) return;
    final settings = _draft;
    final probe = ref.read(accountRouteProbeProvider);
    final l10n = context.appLocalizations;
    final route = await showFormSheet<AccountRoute>(
      context: context,
      builder: (_) => _NetworkChoicePage<AccountRoute>(
        title: l10n.haozeContentRoute,
        choices: AccountRoute.values,
        selected: settings.route,
        label: (route) => route.label,
        footer: l10n.haozeRouteLatencyDescription,
        probe: (route) => probe(settings: settings.defaultsFor(route)),
        timeout: const Duration(seconds: 22),
      ),
    );
    if (mounted && route != null) {
      setState(() => _value = _value!.copyWith(route: route));
    }
  }

  Future<void> _chooseDoh() async {
    if (!_validate()) return;
    final settings = _draft;
    final probe = ref.read(accountDohProbeProvider);
    final l10n = context.appLocalizations;
    final provider = await showFormSheet<AccountDohProvider>(
      context: context,
      builder: (_) => _NetworkChoicePage<AccountDohProvider>(
        title: l10n.haozeDohProvider,
        choices: AccountDohProvider.values,
        selected: settings.dohProvider,
        label: (provider) => provider.label,
        footer: l10n.haozeDohLatencyDescription,
        probe: (provider) => probe(
          options: nativeNetworkOptions(
            settings.copyWith(dohProvider: provider),
          ),
        ),
        timeout: const Duration(seconds: 6),
      ),
    );
    if (mounted && provider != null) {
      setState(() => _value = _value!.copyWith(dohProvider: provider));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    final value = _value;
    if (value == null) {
      return CommonScaffold(
        title: l10n.haozeNetworkSettings,
        body: const NullStatusSwitcher(
          isLoading: true,
          child: SizedBox.shrink(),
        ),
      );
    }
    return FormPage(
      title: l10n.haozeNetworkSettings,
      saving: _saving,
      error: _error ?? (_loadFailed ? l10n.haozeStorageError : null),
      onSave: _save,
      children: [
        generateSection(
          footer: l10n.haozeNetworkDescription,
          items: [
            FormRow(
              title: l10n.haozeContentRoute,
              onPressed: _saving ? null : _chooseRoute,
              trailing: Text(value.route.label),
            ),
            FormRow(
              title: l10n.haozeDoh,
              trailing: CommonSwitch(
                semanticLabel: l10n.haozeDoh,
                value: value.dohEnabled,
                onChanged: _saving
                    ? null
                    : (enabled) => setState(() {
                        _value = value.copyWith(dohEnabled: enabled);
                      }),
              ),
            ),
            FormRow(
              title: l10n.haozeDohProvider,
              onPressed: _saving ? null : _chooseDoh,
              trailing: Text(value.dohProvider.label),
            ),
            FormRow(
              title: l10n.haozeEch,
              trailing: CommonSwitch(
                semanticLabel: l10n.haozeEch,
                value: value.echEnabled,
                onChanged: _saving
                    ? null
                    : (enabled) => setState(() {
                        _value = value.copyWith(echEnabled: enabled);
                      }),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            '${l10n.haozeDohDescription}\n${l10n.haozeEchDescription}',
            style: AppTextStyle.footnote
                .of(context)
                .copyWith(color: context.colorScheme.onSurfaceVariant),
          ),
        ),
        generateSection(
          title: l10n.haozeNetworkProxy,
          footer: l10n.haozeNetworkProxyDescription,
          items: [
            FormRow(
              title: l10n.haozeNetworkProxy,
              trailing: CommonSwitch(
                semanticLabel: l10n.haozeNetworkProxy,
                value: value.proxyEnabled,
                onChanged: _saving
                    ? null
                    : (enabled) => setState(() {
                        _value = value.copyWith(proxyEnabled: enabled);
                      }),
              ),
            ),
            if (value.proxyEnabled) ...[
              FormRow(
                title: l10n.proxyType,
                trailing: DropdownButton<AccountProxyKind>(
                  value: value.proxyKind,
                  underline: const SizedBox.shrink(),
                  items: [
                    for (final kind in AccountProxyKind.values)
                      DropdownMenuItem(value: kind, child: Text(kind.label)),
                  ],
                  onChanged: _saving
                      ? null
                      : (kind) {
                          if (kind != null) {
                            setState(() {
                              _value = value.copyWith(proxyKind: kind);
                            });
                          }
                        },
                ),
              ),
              FormRow(
                title: l10n.host,
                trailing: FormRowTextField(
                  controller: _host,
                  autocorrect: false,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.next,
                ),
              ),
              FormRow(
                title: l10n.port,
                trailing: FormRowTextField(
                  controller: _port,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.next,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                ),
              ),
              FormRow(
                title: l10n.username,
                trailing: FormRowTextField(
                  controller: _username,
                  hintText: l10n.optional,
                  autocorrect: false,
                  textInputAction: TextInputAction.next,
                ),
              ),
              FormRow(
                title: l10n.password,
                trailing: FormRowSecretTextField(
                  controller: _password,
                  hintText: l10n.optional,
                  textInputAction: TextInputAction.done,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class _NetworkChoicePage<T> extends StatefulWidget {
  const _NetworkChoicePage({
    required this.title,
    required this.choices,
    required this.selected,
    required this.label,
    required this.footer,
    required this.probe,
    required this.timeout,
  });
  final String title;
  final List<T> choices;
  final T selected;
  final String Function(T) label;
  final String footer;
  final Future<int> Function(T) probe;
  final Duration timeout;

  @override
  State<_NetworkChoicePage<T>> createState() => _NetworkChoicePageState<T>();
}

class _NetworkChoicePageState<T> extends State<_NetworkChoicePage<T>> {
  final _latencies = <T, int?>{};
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_probe());
  }

  Future<void> _probe() async {
    final generation = ++_generation;
    setState(_latencies.clear);
    await Future.wait(
      widget.choices.map((choice) async {
        int? latency;
        try {
          latency = await widget.probe(choice).timeout(widget.timeout);
        } catch (_) {
          latency = null;
        }
        if (mounted && generation == _generation) {
          setState(() => _latencies[choice] = latency);
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.appLocalizations;
    return CommonScaffold(
      title: widget.title,
      iconActions: [
        IconButtonData(
          glyph: AppGlyphs.refresh,
          tooltip: l10n.haozeDohRetest,
          onPressed: _latencies.length == widget.choices.length ? _probe : null,
        ),
      ],
      body: ListView(
        shrinkWrap: true,
        padding: EdgeInsets.fromLTRB(
          16,
          context.sectionsTopPadding,
          16,
          20 + context.bottomInset,
        ),
        children: [
          generateSection(
            footer: widget.footer,
            items: [
              for (final choice in widget.choices)
                FormRow(
                  title: widget.label(choice),
                  leading: choice == widget.selected
                      ? const GlyphIcon(AppGlyphs.check)
                      : null,
                  onPressed: () => Navigator.of(context).pop(choice),
                  trailing: !_latencies.containsKey(choice)
                      ? const CommonCircleLoading(size: 16)
                      : Text(switch (_latencies[choice]) {
                          final int latency => l10n.haozeDohLatency(latency),
                          null => l10n.haozeDohUnavailable,
                        }),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
