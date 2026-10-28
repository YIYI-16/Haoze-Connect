import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/features/xboard/data/xboard_api_client.dart' show XboardException;
import 'package:hiddify/features/xboard/notifier/xboard_session_controller.dart';
import 'package:hiddify/features/xboard/widget/xboard_ui_common.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// The login screen of the panel: an email, a password, and a way to the
/// register screen.
class XboardLoginPage extends HookConsumerWidget {
  const XboardLoginPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final session = ref.watch(xboardSessionProvider);

    final formKey = useMemoized(() => GlobalKey<FormState>());
    final emailController = useTextEditingController();
    final passwordController = useTextEditingController();
    final passwordVisible = useState(false);
    final submitting = useState(false);
    final localError = useState<String?>(null);

    Future<void> submit() async {
      if (submitting.value || session.busy) return;
      final form = formKey.currentState;
      if (form == null || !form.validate()) return;

      submitting.value = true;
      localError.value = null;
      final notifier = ref.read(xboardSessionProvider.notifier);

      try {
        await notifier.login(emailController.text.trim(), passwordController.text);
      } on XboardException catch (error) {
        if (!context.mounted) return;
        localError.value = error.message;
        submitting.value = false;
        return;
      } catch (_) {
        if (!context.mounted) return;
        localError.value = '登录失败，请稍后重试';
        submitting.value = false;
        return;
      }

      if (!context.mounted) return;
      submitting.value = false;
      context.go(xboardHomeRoute);
    }

    final errorMessage = localError.value ?? session.error;

    return XboardAuthScaffold(
      title: '欢迎回来',
      subtitle: '登录 $xboardAppName，同步你的订阅与流量',
      footer: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('还没有账号？', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          TextButton(onPressed: () => context.go(xboardRegisterRoute), child: const Text('立即注册')),
        ],
      ),
      children: [
        if (session.isAuthenticated) ...[
          XboardBanner(
            title: '已经登录',
            message: '当前账号：${session.email ?? '未知'}',
            tone: XboardBannerTone.success,
            icon: Icons.check_circle_outline_rounded,
            action: TextButton(onPressed: () => context.go(xboardAccountRoute), child: const Text('查看账户')),
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
                  obscureText: !passwordVisible.value,
                  textInputAction: TextInputAction.done,
                  autofillHints: const [AutofillHints.password],
                  suffixIcon: IconButton(
                    tooltip: passwordVisible.value ? '隐藏密码' : '显示密码',
                    icon: Icon(passwordVisible.value ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                    onPressed: () => passwordVisible.value = !passwordVisible.value,
                  ),
                  validator: (value) {
                    if ((value ?? '').isEmpty) return '请输入密码';
                    return null;
                  },
                  onFieldSubmitted: (_) => submit(),
                ),
                const SizedBox(height: 22),
                XboardPrimaryButton(
                  label: '登录',
                  icon: Icons.login_rounded,
                  loading: submitting.value,
                  onPressed: session.busy ? null : submit,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
