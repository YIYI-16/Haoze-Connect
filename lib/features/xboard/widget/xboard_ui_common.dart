import 'package:flutter/material.dart';

/// The brand the Xboard screens present.
///
/// Override it at build time:
///
/// ```sh
/// flutter build apk --dart-define=XBOARD_APP_NAME="Haoze Connect"
/// ```
const String xboardAppName = String.fromEnvironment('XBOARD_APP_NAME', defaultValue: 'Haoze Connect');

/// The panel this build talks to.
///
/// Override it at build time:
///
/// ```sh
/// flutter build apk --dart-define=XBOARD_BASE_URL="https://panel.example.com"
/// ```
const String xboardPanelUrl = String.fromEnvironment('XBOARD_BASE_URL', defaultValue: 'https://www.haoze.cyou');

/// The brand blue of the identity mark. Everything else follows the app theme,
/// so the screens stay readable in both brightnesses.
const Color xboardBrandBlue = Color(0xFF2F6BFF);

/// The screens of the Xboard flow.
const String xboardLoginRoute = '/login';
const String xboardRegisterRoute = '/register';
const String xboardAccountRoute = '/account';

/// The screens of the app the Xboard flow hands back to.
const String xboardHomeRoute = '/home';
const String xboardProxiesRoute = '/home/proxies';

/// The shortest password the panel accepts.
const int xboardMinPasswordLength = 8;

/// How long the "send code" button waits before it can be used again.
const int xboardEmailCodeCooldown = 60;

/// How long the traffic of the panel stays believable before the card says so.
const Duration xboardUsageStaleAfter = Duration(hours: 1);

/// A mail address, as loosely as a login form needs it.
final RegExp xboardEmailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

/// Whether [value] can be the mail address of an account.
bool isValidXboardEmail(String value) => xboardEmailPattern.hasMatch(value.trim());

/// A byte count the way the traffic card shows it: `1.50 GiB`.
String formatXboardBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  final digits = unit <= 1 ? 0 : 2;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

/// A moment as `2026-10-28 14:05`, or null when there is no moment.
String? formatXboardDateTime(DateTime? value) {
  if (value == null) return null;
  final local = value.toLocal();
  return '${local.year}-${_xboardTwo(local.month)}-${_xboardTwo(local.day)} '
      '${_xboardTwo(local.hour)}:${_xboardTwo(local.minute)}';
}

/// A moment as `2026-10-28`, or null when there is no moment.
String? formatXboardDate(DateTime? value) {
  if (value == null) return null;
  final local = value.toLocal();
  return '${local.year}-${_xboardTwo(local.month)}-${_xboardTwo(local.day)}';
}

/// The days left until [value], negative once it is past.
int xboardDaysLeft(DateTime? value) {
  if (value == null) return 0;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = value.toLocal();
  final target = DateTime(day.year, day.month, day.day);
  return target.difference(today).inDays;
}

String _xboardTwo(int value) => value.toString().padLeft(2, '0');

/// How a [XboardBanner] is colored.
enum XboardBannerTone { info, warning, error, success }

/// A short note under a title, colored by its tone.
class XboardBanner extends StatelessWidget {
  const XboardBanner({
    required this.message,
    super.key,
    this.title,
    this.icon = Icons.info_outline_rounded,
    this.tone = XboardBannerTone.info,
    this.action,
  });

  final String message;
  final String? title;
  final IconData icon;
  final XboardBannerTone tone;

  /// An optional action, shown under the message so it never squeezes it.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (background, foreground) = switch (tone) {
      XboardBannerTone.info => (theme.colorScheme.primaryContainer, theme.colorScheme.onPrimaryContainer),
      XboardBannerTone.warning => (theme.colorScheme.tertiaryContainer, theme.colorScheme.onTertiaryContainer),
      XboardBannerTone.error => (theme.colorScheme.errorContainer, theme.colorScheme.onErrorContainer),
      XboardBannerTone.success => (theme.colorScheme.secondaryContainer, theme.colorScheme.onSecondaryContainer),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 20, color: foreground),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (title != null) ...[
                      Text(
                        title!,
                        style: theme.textTheme.titleSmall?.copyWith(color: foreground, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                    ],
                    Text(message, style: theme.textTheme.bodyMedium?.copyWith(color: foreground)),
                  ],
                ),
              ),
            ],
          ),
          if (action != null) ...[const SizedBox(height: 6), Align(alignment: Alignment.centerLeft, child: action)],
        ],
      ),
    );
  }
}

/// The identity mark of the app: a brand blue tile with a bolt in it.
class XboardBrandMark extends StatelessWidget {
  const XboardBrandMark({super.key, this.size = 60});

  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.3),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [theme.colorScheme.primary, xboardBrandBlue],
        ),
      ),
      child: Icon(Icons.bolt_rounded, size: size * 0.55, color: theme.colorScheme.onPrimary),
    );
  }
}

/// The mark, the name of the app and what the screen is for.
class XboardBrandHeader extends StatelessWidget {
  const XboardBrandHeader({required this.title, required this.subtitle, super.key});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        const XboardBrandMark(),
        const SizedBox(height: 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// The frame of the login and the register screen: one narrow, scrollable
/// column, centered on a wide window and clear of the keyboard on a phone.
class XboardAuthScaffold extends StatelessWidget {
  const XboardAuthScaffold({
    required this.title,
    required this.subtitle,
    required this.children,
    super.key,
    this.footer,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;

  /// What sits under the form, such as the link to the other screen.
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(20, 8, 20, keyboard + 24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  XboardBrandHeader(title: title, subtitle: subtitle),
                  const SizedBox(height: 28),
                  ...children,
                  if (footer != null) ...[const SizedBox(height: 18), footer!],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A field of the login and the register screen.
class XboardTextField extends StatelessWidget {
  const XboardTextField({
    required this.label,
    super.key,
    this.controller,
    this.hint,
    this.obscureText = false,
    this.suffixIcon,
    this.keyboardType,
    this.textInputAction,
    this.validator,
    this.onChanged,
    this.onFieldSubmitted,
    this.enabled = true,
    this.autofillHints,
    this.focusNode,
  });

  final String label;
  final TextEditingController? controller;
  final String? hint;
  final bool obscureText;
  final Widget? suffixIcon;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final String? Function(String?)? validator;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onFieldSubmitted;
  final bool enabled;
  final Iterable<String>? autofillHints;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: theme.colorScheme.outlineVariant),
    );

    return TextFormField(
      controller: controller,
      focusNode: focusNode,
      obscureText: obscureText,
      enabled: enabled,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      autofillHints: autofillHints,
      autocorrect: false,
      enableSuggestions: false,
      validator: validator,
      onChanged: onChanged,
      onFieldSubmitted: onFieldSubmitted,
      style: theme.textTheme.bodyLarge,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        filled: true,
        fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        border: border,
        enabledBorder: border,
        focusedBorder: border.copyWith(borderSide: BorderSide(color: theme.colorScheme.primary, width: 1.6)),
        errorBorder: border.copyWith(borderSide: BorderSide(color: theme.colorScheme.error)),
        focusedErrorBorder: border.copyWith(borderSide: BorderSide(color: theme.colorScheme.error, width: 1.6)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        suffixIcon: suffixIcon,
      ),
    );
  }
}

/// The button that carries the screen: wide, rounded and busy while it works.
class XboardPrimaryButton extends StatelessWidget {
  const XboardPrimaryButton({required this.label, required this.onPressed, super.key, this.loading = false, this.icon});

  final String label;
  final VoidCallback? onPressed;
  final bool loading;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 52,
      child: FilledButton(
        onPressed: loading ? null : onPressed,
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        child: loading
            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.2))
            : icon == null
            ? Text(label)
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [Icon(icon, size: 20), const SizedBox(width: 8), Text(label)],
              ),
      ),
    );
  }
}

/// A label and its value, one row of the account screen.
class XboardInfoRow extends StatelessWidget {
  const XboardInfoRow({required this.label, required this.value, super.key, this.valueColor, this.icon});

  final String label;
  final String value;
  final Color? valueColor;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: valueColor ?? theme.colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A small note that says what the state of the data is.
class XboardStatusChip extends StatelessWidget {
  const XboardStatusChip({required this.label, super.key, this.tone = XboardBannerTone.info, this.icon});

  final String label;
  final XboardBannerTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (background, foreground) = switch (tone) {
      XboardBannerTone.info => (theme.colorScheme.primaryContainer, theme.colorScheme.onPrimaryContainer),
      XboardBannerTone.warning => (theme.colorScheme.tertiaryContainer, theme.colorScheme.onTertiaryContainer),
      XboardBannerTone.error => (theme.colorScheme.errorContainer, theme.colorScheme.onErrorContainer),
      XboardBannerTone.success => (theme.colorScheme.secondaryContainer, theme.colorScheme.onSecondaryContainer),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 14, color: foreground), const SizedBox(width: 4)],
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(color: foreground, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
