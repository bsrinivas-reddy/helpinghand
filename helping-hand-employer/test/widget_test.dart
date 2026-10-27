import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:employer_app/main.dart';
import 'package:employer_app/screens/create_shift_screen.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'employer entry has a clear role and validates mobile number before sending',
    (tester) async {
      await tester.pumpWidget(const EmployerApp());
      await tester.pumpAndSettle();
      expect(find.text('FOR EMPLOYERS'), findsOneWidget);
      final send = find.widgetWithText(
        ElevatedButton,
        'Send verification code',
      );
      expect(tester.widget<ElevatedButton>(send).onPressed, isNull);
      await tester.enterText(find.byType(TextField), 'abcdefghij');
      await tester.pump();
      expect(tester.widget<ElevatedButton>(send).onPressed, isNull);
      await tester.enterText(find.byType(TextField), '9876543210');
      await tester.pump();
      expect(tester.widget<ElevatedButton>(send).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'shift request cannot submit a missing worker or collect discarded fields',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: CreateShiftScreen()));
      expect(find.text('Select a worker first'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(
        tester
            .widget<ElevatedButton>(
              find.widgetWithText(ElevatedButton, 'Send shift request'),
            )
            .onPressed,
        isNull,
      );
      expect(find.text('Workers Needed'), findsNothing);
      expect(find.text('Worksite Address'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'selected-worker request validates wage without calling services',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: CreateShiftScreen(targetWorkerId: 'selected-worker'),
        ),
      );
      await tester.tap(find.text('Send shift request'));
      await tester.pump();
      expect(find.text('Please enter a valid daily wage rate'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('request screen names the trade and accepts only wage digits', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: CreateShiftScreen(
          targetWorkerId: 'selected-worker',
          workerCategory: 'PAINTER',
        ),
      ),
    );
    expect(find.text('Painter selected'), findsOneWidget);
    for (final typed in [
      '1',
      '12',
      '12a',
      '123',
      '123.',
      '123.4',
      '123.45',
      '123.456',
    ]) {
      await tester.enterText(find.byType(TextField), typed);
      await tester.pump();
    }
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, '123.45');
  });
}
