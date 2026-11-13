import 'package:material_ui/material_ui.dart';
import 'font.dart';
import 'typography.dart';

void main() => runApp(const Probe());

class Probe extends StatelessWidget {
  const Probe({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    locale: const Locale('zh', 'CN'),
    theme: ThemeData(
      platform: TargetPlatform.windows,
      fontFamily: 'Segoe UI',
      fontFamilyFallback: appFontFamilyFallback(
        platform: TargetPlatform.windows,
        locales: const [Locale('zh', 'CN')],
      ),
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
    ).withAppTypography,
    home: Scaffold(
      body: SingleChildScrollView(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final weight in [FontWeight.w400, FontWeight.w500, FontWeight.w600, FontWeight.w700])
              Expanded(child: Sample(weight: weight)),
          ],
        ),
      ),
    ),
  );
}

class Sample extends StatelessWidget {
  const Sample({super.key, required this.weight});
  final FontWeight weight;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Weight ${weight.value}', style: AppTextStyle.footnote.of(context)),
        const SizedBox(height: 20),
        for (final family in [null, 'Microsoft YaHei UI', 'Microsoft YaHei', 'Noto Sans SC']) ...[
          Text(family ?? 'Segoe UI + fallback', style: AppTextStyle.footnote.of(context)),
          const SizedBox(height: 12),
          for (final role in [AppTextStyle.pageTitle, AppTextStyle.headline, AppTextStyle.subheadline, AppTextStyle.footnote])
            Text('账户 套餐与流量 88.50 GiB', style: role.of(context).copyWith(fontFamily: family, fontWeight: weight)),
          const SizedBox(height: 12),
          Text('剩余流量：88.50 GiB\n总流量：100.00 GiB\n到期时间：长期有效\n香港 日本 美国 刷新流量', style: AppTextStyle.subheadline.of(context).copyWith(fontFamily: family, fontWeight: weight)),
          const SizedBox(height: 24),
        ],
      ],
    ),
  );
}
