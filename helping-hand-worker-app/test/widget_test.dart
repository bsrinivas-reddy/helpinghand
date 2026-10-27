import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:worker_app/services/token_store.dart';
import 'package:worker_app/main.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tokenStore = MemoryTokenStore();
  });

  testWidgets(
    'worker entry explains shifts without synthetic imagery or payout promises',
    (tester) async {
      await tester.pumpWidget(const MyApp());
      await tester.pumpAndSettle();
      expect(find.text('Local work.\nClear terms.'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect(find.textContaining('5 PM'), findsNothing);
      await tester.ensureVisible(find.text('Get started'));
      await tester.tap(find.text('Get started'));
      await tester.pumpAndSettle();
      expect(find.text('Worker sign in'), findsOneWidget);
      final send = find.widgetWithText(
        ElevatedButton,
        'Send verification code',
      );
      expect(tester.widget<ElevatedButton>(send).onPressed, isNull);
      await tester.enterText(find.byType(TextField), '9876543210');
      await tester.pump();
      expect(tester.widget<ElevatedButton>(send).onPressed, isNotNull);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Local work.\nClear terms.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'worker onboarding remains usable on a narrow screen with large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
          child: const MyApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Get started'));
      await tester.tap(find.text('Get started'));
      await tester.pumpAndSettle();
      expect(find.text('Worker sign in'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
