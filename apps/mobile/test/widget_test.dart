import 'package:fingerspeak_mobile/core/mobile_services.dart';
import 'package:fingerspeak_mobile/models/user_role.dart';
import 'package:fingerspeak_mobile/ui/hand_calibration_page.dart';
import 'package:fingerspeak_mobile/ui/role_selection_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
      'RoleSelectionPage renders patient and caregiver choices and triggers selection',
      (WidgetTester tester) async {
    final services = await MobileServices.forTest();
    UserRole? selected;

    await tester.pumpWidget(
      MaterialApp(
        home: RoleSelectionPage(
          services: services,
          onRoleSelected: (role) => selected = role,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Who is using this device?'), findsOneWidget);
    expect(find.text('I am a Patient'), findsOneWidget);
    expect(find.text('I am a Caregiver'), findsOneWidget);

    // Tap "I am a Patient" card
    await tester.tap(find.text('I am a Patient'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Open Patient Dashboard'), findsOneWidget);

    // Scroll to button and tap to proceed
    await tester.scrollUntilVisible(find.text('Open Patient Dashboard'), 150);
    await tester.tap(find.text('Open Patient Dashboard'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(selected, UserRole.patient);
  });

  testWidgets('HandCalibrationPage renders hand studio',
      (WidgetTester tester) async {
    final services = await MobileServices.forTest();

    await tester.pumpWidget(
      MaterialApp(
        home: HandCalibrationPage(services: services),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(HandCalibrationPage), findsOneWidget);
  });
}
