import 'dart:async';
import '../models/patient_signal.dart';

/// Clean stub bridge for web platform without external face runtime.
class WebFaceBridge {
  Stream<MonitorStatus> get statuses => const Stream.empty();
  Stream<PatientSignal> get signals => const Stream.empty();

  void start() {}
  void stop() {}
  void triggerGesture(String gesture) {}
  void resetCalibration() {}
  void dispose() {}
}
