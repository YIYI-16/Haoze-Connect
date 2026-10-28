import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/features/xboard/data/xboard_api_client.dart' show XboardException;
import 'package:hiddify/features/xboard/model/xboard_models.dart';
import 'package:hiddify/features/xboard/notifier/xboard_session_controller.dart';
import 'package:hiddify/features/xboard/widget/xboard_ui_common.dart';
import 'package:hiddify/utils/utils.dart' show UriUtils;
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// The register screen of the panel: an email, a password, and whatever the
/// panel asks for on top of it.
class XboardRegisterPage extends HookConsumerWidget {
  const XboardRegisterPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final session = ref.watch(xboardSessionProvider);
    final config = session.publicConfig;
    final captchaEnabled = config?.captchaEnabled == true;
    final tosUrl = config?.tosUrl;

    final formKey = useMemoized(() => GlobalKey<FormState>());
    final emailController = useTextEditingController();
    final passwordController = useTextEditingController();
    final confirmController = useTextEditingController();
    final emailCodeController = useTextEditingController();
    final inviteCodeController = useTextEditingController();

    final passwordVisible = useState(false);
    final submitting = useState(false);
    final sendingCode = useState(false);
    final loadingConfig = useState(false);
    final localError = useState<String?>(null);
    final configError = useState<String?>(null);
    final tosAccepted = useState(false);
    final countdown = useState(0);

    final countingDown = countdown.value > 0;
    useEffect(() {
      if (!countingDown) return null;
      final timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (countdown.value <= 1) {
          countdown.value = 0;
          timer.cancel();
        } else {
          countdown.value = countdown.value - 1;
        }
      });
      return timer.cancel;
    }, [countingDown]);

    Future<void> loadConfig() async {
      if (loadingConfig.value) return;
      loadingConfig.value = true;
      configError.value = null;
      try {
        await ref.read(xboardSessionProvider.notifier).loadPublicConfig();
      } on XboardException catch (error) {
        if (!context.mounted) return;
        configError.value = error.message;
      } catch (_) {
        if (!context.mounted) return;
        configError.value = '无法获取面板配置，请稍后重试';
      }
      if (!context.mounted) return;
      loadingConfig.value = false;
    }

    Future<void> sendEmailCode() async {
      if (sendingCode.value || countdown.value > 0) return;
      final email = emailController.text.trim();
      if (!isValidXboardEmail(email)) {
        localError.value = '请先填写有效的邮箱地址';
        return;
      }

      sendingCode.value = true;
      localError.value = null;
      try {
        await ref.read(xboardSessionProvider.notifier).sendEmailCode(email);
      } on XboardException catch (error) {
        if (!context.mounted) return;
        localError.value = error.message;
        sendingCode.value = false;
        return;
      } catch (_) {
        if (!context.mounted) return;
        localError.value = '验证码发送失败，请稍后重试';
        sendingCode.value = false;
        return;
      }

      if (!context.mounted) return;
      sendingCode.value = false;
      countdown.value = xboardEmailCodeCooldown;
    }

    Future<void> submit() async {
      if (submitting.value || session.busy) return;
      final form = formKey.currentState;
      if (form == null || !form.validate()) return;

      // The panel decides what a registration needs: the verification code,
      // the invite code and the terms of service. Without its rules a
      // registration would go out half filled, so it waits for them.
      if (config == null) {
        localError.value = '面板配置还没加载好，请先重试加载';
        return;
      }
      if (captchaEnabled) {
        localError.value = '该面板需要人机验证，请在网站上注册';
        return;
      }

      if (config.tosUrl != null && !tosAccepted.value) {
        localError.value = '请先阅读并同意服务条款';
        return;
      }

      submitting.value = true;
      localError.value = null;
      final notifier = ref.read(xboardSessionProvider.notifier);

      try {
        await notifier.register(
          email: emailController.text.trim(),
          password: passwordController.text,
          emailCode: config.emailVerify ? emailCodeController.text.trim() : null,
          inviteCode: inviteCodeController.text.trim().isEmpty ? null : inviteCodeController.text.trim(),
        );
      } on XboardException catch (error) {
        if (!context.mounted) return;
        localError.value = error.message;
        submitting.value = false;
        return;
      } catch (_) {
        if (!context.mounted) return;
        localError.value = '注册失败，请稍后重试';
        submitting.value = false;
        return;
      }

      if (!context.mounted) return;
      submitting.value = false;
      context.go(xboardAccountRoute);
    }

    final errorMessage = localError.value ?? session.error;
    final canSubmit = config != null && !captchaEnabled && !session.busy && !submitting.value;

    return XboardAuthScaffold(
      title: '创建账号',
      subtitle: '注册 $xboardAppName，开始使用你的订阅',
      footer: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('已经有账号了？', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          TextButton(onPressed: () => context.go(xboardLoginRoute), child: const Text('去登录')),
        ],
      ),
      children: [
        if (captchaEnabled) ...[
          XboardBanner(
            title: '该面板开启了人机验证',
            message: '人机验证只能在网页上完成，请前往网站注册，注册成功后回到这里登录。',
            tone: XboardBannerTone.warning,
            icon: Icons.gpp_maybe_outlined,
            action: TextButton.icon(
              onPressed: () => openExternal(xboardPanelUrl),
              icon: const Icon(Icons.open_in_new_rounded, size: 18),
              label: const Text('打开网站注册'),
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (errorMessage != null) ...[
          XboardBanner(message: errorMessage, tone: XboardBannerTone.error, icon: Icons.error_outline_rounded),
          const SizedBox(height: 16),
        ],
        AutofillGroup(
          child: Form(
            key: formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                XboardTextField(
                  controller: emailController,
                  label: '邮箱',
                  hint: 'you@example.com',
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.email],
                  validator: (value) {
                    final text = (value ?? '').trim();
                    if (text.isEmpty) return '请输入邮箱';
                    if (!isValidXboardEmail(text)) return '邮箱格式不正确';
                    return null;
                  },
                ),
                const SizedBox(height: 14),
                XboardTextField(
                  controller: passwordController,
                  label: '密码',
                  hint: '至少 $xboardMinPasswordLength 位',
                  obscureText: !passwordVisible.value,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.newPassword],
                  suffixIcon: IconButton(
                    tooltip: passwordVisible.value ? '隐藏密码' : '显示密码',
                    icon: Icon(passwordVisible.value ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                    onPressed: () => passwordVisible.value = !passwordVisible.value,
                  ),
                  validator: (value) {
                    final text = value ?? '';
                    if (text.isEmpty) return '请输入密码';
                    if (text.length < xboardMinPasswordLength) return '密码至少 $xboardMinPasswordLength 位';
                    return null;
                  },
                ),
                const SizedBox(height: 14),
                XboardTextField(
                  controller: confirmController,
                  label: '确认密码',
                  obscureText: !passwordVisible.value,
                  textInputAction: TextInputAction.done,
                  autofillHints: const [AutofillHints.newPassword],
                  validator: (value) {
                    final text = value ?? '';
                    if (text.isEmpty) return '请再次输入密码';
                    if (text != passwordController.text) return '两次输入的密码不一致';
                    return null;
                  },
                  onFieldSubmitted: (_) => submit(),
                ),
                const SizedBox(height: 14),
                _configSection(
                  context: context,
                  config: config,
                  sessionInitialized: session.initialized,
                  loadingConfig: loadingConfig.value,
                  configError: configError.value,
                  emailCodeController: emailCodeController,
                  inviteCodeController: inviteCodeController,
                  sendingCode: sendingCode.value,
                  countdown: countdown.value,
                  tosAccepted: tosAccepted.value,
                  onRetryConfig: loadConfig,
                  onSendCode: sendEmailCode,
                  onTosChanged: (value) => tosAccepted.value = value,
                  onOpenTos: () => openExternal(tosUrl),
                ),
                const SizedBox(height: 22),
                XboardPrimaryButton(
                  label: '注册并登录',
                  icon: Icons.person_add_alt_1_rounded,
                  loading: submitting.value,
                  onPressed: canSubmit ? submit : null,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Everything the panel asks for on top of the email and the password: the
  /// verification code, the invite code and the terms of service.
  Widget _configSection({
    required BuildContext context,
    required XboardPublicConfig? config,
    required bool sessionInitialized,
    required bool loadingConfig,
    required String? configError,
    required TextEditingController emailCodeController,
    required TextEditingController inviteCodeController,
    required bool sendingCode,
    required int countdown,
    required bool tosAccepted,
    required VoidCallback onRetryConfig,
    required VoidCallback onSendCode,
    required ValueChanged<bool> onTosChanged,
    required VoidCallback onOpenTos,
  }) {
    final theme = Theme.of(context);

    if (config == null) {
      if (loadingConfig || !sessionInitialized) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Center(child: CircularProgressIndicator()),
        );
      }
      return XboardBanner(
        message: configError ?? '无法获取面板配置，请稍后重试',
        tone: XboardBannerTone.error,
        icon: Icons.error_outline_rounded,
        action: TextButton(onPressed: loadingConfig ? null : onRetryConfig, child: const Text('重新加载')),
      );
    }

    final emailVerify = config.emailVerify;
    final inviteForce = config.inviteForce;
    final tosUrl = config.tosUrl;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (emailVerify) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: XboardTextField(
                  controller: emailCodeController,
                  label: '邮箱验证码',
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  validator: (value) {
                    if ((value ?? '').trim().isEmpty) return '请输入邮箱验证码';
                    return null;
                  },
                ),
              ),
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: SizedBox(
                  height: 56,
                  child: OutlinedButton(
                    onPressed: countdown > 0 || sendingCode ? null : onSendCode,
                    child: sendingCode
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(countdown > 0 ? '${countdown}s' : '获取验证码'),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
        ],
        XboardTextField(
          controller: inviteCodeController,
          label: inviteForce ? '邀请码' : '邀请码（选填）',
          textInputAction: TextInputAction.done,
          validator: (value) {
            if (inviteForce && (value ?? '').trim().isEmpty) return '该面板需要邀请码';
            return null;
          },
        ),
        if (tosUrl != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: Checkbox(
                  value: tosAccepted,
                  onChanged: (value) => onTosChanged(value ?? false),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '我已阅读并同意',
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
              TextButton(onPressed: onOpenTos, child: const Text('服务条款')),
            ],
          ),
        ],
      ],
    );
  }
}

/// Opens [url] in the browser of the system.
void openExternal(String? url) {
  if (url == null || url.trim().isEmpty) return;
  UriUtils.tryLaunch(Uri.parse(url.trim()));
}
