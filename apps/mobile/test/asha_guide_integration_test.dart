import 'package:fingerspeak_mobile/app.dart';
import 'package:fingerspeak_mobile/core/mobile_services.dart';
import 'package:fingerspeak_mobile/models/patient_access_method.dart';
import 'package:fingerspeak_mobile/models/user_role.dart';
import 'package:fingerspeak_mobile/services/asha_guide_service.dart';
import 'package:fingerspeak_mobile/services/patient_signal_monitor.dart';
import 'package:fingerspeak_mobile/ui/ability_assessment_page.dart';
import 'package:fingerspeak_mobile/ui/caregiver_page.dart';
import 'package:fingerspeak_mobile/ui/guide/asha_guide_host.dart';
import 'package:fingerspeak_mobile/ui/patient_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _CountingMonitor extends NoOpPatientSignalMonitor {
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Future<void> start() async {
    startCalls++;
    await super.start();
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    await super.stop();
  }
}

Future<void> _advanceTo(AshaGuideService guide, AshaGuideStep target) async {
  while (guide.isActive && guide.step != target) {
    await guide.next();
  }
}

Future<void> _disposeServices(
  WidgetTester tester,
  MobileServices services,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  final disposing = services.dispose();
  await tester.pump(const Duration(seconds: 1));
  await disposing;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('first-time caregiver role reveals the patient profile target',
      (tester) async {
    final services = await MobileServices.forTest();
    await services.patientAccessMethodRepository
        .save(PatientAccessMethod.faceEyesAndHead);

    await tester.pumpWidget(FingerSpeakMobileApp(services: services));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 2300));
    await tester.pump();
    await _advanceTo(services.ashaGuide, AshaGuideStep.role);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Choose who is using this device'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('asha-guide-missing-target')), findsNothing);
    await tester.ensureVisible(find.text('I am a Caregiver'));
    await tester.tap(find.text('I am a Caregiver'));
    await tester.pump();
    await tester.ensureVisible(find.text('Open Caregiver Dashboard'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Open Caregiver Dashboard'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    expect(services.roleRepository.load(), UserRole.caregiver);
    expect(services.ashaGuide.step, AshaGuideStep.profile);
    expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        0);
    expect(find.text('Open Patient Ability Profile'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('asha-guide-missing-target')), findsNothing);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Back'));
    await tester.pump();
    expect(services.ashaGuide.step, AshaGuideStep.welcome);
    await tester.tap(find.widgetWithText(FilledButton, 'Next'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(services.ashaGuide.step, AshaGuideStep.profile);
    await _disposeServices(tester, services);
  });

  testWidgets('assessment advances the guide only after a profile is saved',
      (tester) async {
    final services = await MobileServices.forTest();
    await services.patientAccessMethodRepository
        .save(PatientAccessMethod.faceEyesAndHead);
    await _advanceTo(services.ashaGuide, AshaGuideStep.profile);
    await tester.pumpWidget(MaterialApp(
      home: AshaGuideHost(
        service: services.ashaGuide,
        child: PatientPage(services: services, isActive: false),
      ),
    ));
    await tester.pump();

    await tester.ensureVisible(find.text('Open Patient Ability Profile'));
    await tester.tap(find.text('Open Patient Ability Profile'));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(AbilityAssessmentPage))).pop();
    await tester.pumpAndSettle();
    expect(services.ashaGuide.step, AshaGuideStep.profile);

    await tester.tap(find.text('Open Patient Ability Profile'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 5; i++) {
      await tester.tap(find.text('Next Step'));
      await tester.pump();
    }
    await tester.tap(find.text('Apply Profile & Start'));
    await tester.pumpAndSettle();
    expect(services.accessProfileRepository.load(), isNotNull);
    expect(services.ashaGuide.step, AshaGuideStep.calibration);
    await _disposeServices(tester, services);
  });

  testWidgets('calibration caller advances only on a successful route result',
      (tester) async {
    final services = await MobileServices.forTest();
    await _advanceTo(services.ashaGuide, AshaGuideStep.calibration);
    await tester.pumpWidget(MaterialApp(
      home: AshaGuideHost(
        service: services.ashaGuide,
        child: CaregiverPage(
          services: services,
          calibrationBuilder: (_) => const SizedBox(key: ValueKey('test_calib')),
        ),
      ),
    ));
    await tester.pump();
    final caregiverScroll = find
        .descendant(
          of: find.byType(CaregiverPage),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('Start Step-by-Step Calibration'),
      300,
      scrollable: caregiverScroll,
    );
    await tester.ensureVisible(find.text('Start Step-by-Step Calibration'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start Step-by-Step Calibration'));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byKey(const ValueKey('test_calib')))).pop();
    await tester.pumpAndSettle();
    expect(services.ashaGuide.step, AshaGuideStep.calibration);

    await tester.ensureVisible(find.text('Start Step-by-Step Calibration'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start Step-by-Step Calibration'));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byKey(const ValueKey('test_calib')))).pop(true);
    await tester.pumpAndSettle();
    expect(services.ashaGuide.step, AshaGuideStep.firstSession);
    await _disposeServices(tester, services);
  });

  testWidgets('first-session continue never stops an already active monitor',
      (tester) async {
    final monitor = _CountingMonitor();
    final services = await MobileServices.forTest(monitor: monitor);
    await services.patientAccessMethodRepository
        .save(PatientAccessMethod.faceEyesAndHead);
    await _advanceTo(services.ashaGuide, AshaGuideStep.firstSession);
    await tester.pumpWidget(MaterialApp(
      home: AshaGuideHost(
        service: services.ashaGuide,
        child: PatientPage(services: services),
      ),
    ));
    await tester.pump();
    await tester.pump();
    final startControl =
        find.byKey(const ValueKey('asha-guide-start-face-session'));
    await tester.ensureVisible(startControl);
    await tester.pump(const Duration(milliseconds: 500));
    expect(monitor.startCalls, 1);
    await tester.tap(startControl);
    await tester.pump();
    expect(monitor.stopCalls, 0);
    expect(services.ashaGuide.step, AshaGuideStep.report);
    await _disposeServices(tester, services);
  });
}
