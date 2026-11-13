import 'package:fl_clash/ui/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_app.dart';

void main() {
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    for (final inert in [false, true]) {
      testWidgets('$platform card body stays regular; inert=$inert', (
        tester,
      ) async {
        await tester.pumpWidget(
          TestApp(
            theme: ThemeData(platform: platform).withAppTypography,
            homeBuilder: (child) => Scaffold(body: child),
            child: CommonCard(
              inert: inert,
              onPressed: () {},
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Builder(
                    builder: (context) =>
                        Text('套餐与流量', style: AppTextStyle.headline.of(context)),
                  ),
                  const Text('剩余流量：9.39 TiB'),
                ],
              ),
            ),
          ),
        );
        final body = DefaultTextStyle.of(
          tester.element(find.text('剩余流量：9.39 TiB')),
        ).style;
        expect(body.fontWeight, FontWeight.w400);
        expect(body.fontSize, AppTextStyle.subheadline.size);
        final heading = tester.widget<Text>(find.text('套餐与流量')).style!;
        expect(heading.fontWeight, FontWeight.w600);
        expect(heading.fontSize, AppTextStyle.headline.size);
      });
    }
    testWidgets('$platform theme and explicit styles agree on text weight', (
      tester,
    ) async {
      final theme = ThemeData(platform: platform).withAppTypography;
      const medium = FontWeight.w600;
      expect(theme.textTheme.labelLarge!.fontWeight, medium);
      expect(theme.primaryTextTheme.labelLarge!.fontWeight, medium);
      expect(theme.textTheme.bodyLarge!.fontWeight, FontWeight.w400);
      expect(theme.textTheme.headlineLarge!.fontWeight, FontWeight.w400);
      await tester.pumpWidget(
        TestApp(
          theme: theme,
          child: Builder(
            builder: (context) {
              expect(
                AppTextStyle.subheadline
                    .of(context, emphasized: true)
                    .fontWeight,
                medium,
              );
              expect(
                AppTextStyle.title1.of(context, emphasized: true).fontWeight,
                FontWeight.w700,
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      );
    });
  }
}
