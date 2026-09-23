import 'dart:async';

import 'package:fingerspeak_mobile/core/mobile_services.dart';
import 'package:fingerspeak_mobile/data/pi_device_client.dart';
import 'package:fingerspeak_mobile/models/patient_signal.dart';
import 'package:fingerspeak_mobile/models/patient_record.dart';
import 'package:fingerspeak_mobile/services/caregiver_notification_service.dart';
import 'package:fingerspeak_mobile/services/asha_guide_service.dart';
import 'package:fingerspeak_mobile/ui/caregiver_emergency_sheet.dart';
import 'package:fingerspeak_mobile/ui/caregiver_voice_setup_page.dart';
import 'package:fingerspeak_mobile/ui/doctor_report_sheet.dart';
import 'package:fingerspeak_mobile/ui/guide/asha_guide_host.dart';
import 'package:fingerspeak_mobile/ui/hand_calibration_page.dart';
import 'package:fingerspeak_mobile/ui/patient_live_monitor_sheet.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class CaregiverPage extends StatefulWidget {
  const CaregiverPage({
    required this.services,
    this.calibrationBuilder,
    super.key,
  });

  final MobileServices services;
  final WidgetBuilder? calibrationBuilder;

  @override
  State<CaregiverPage> createState() => CaregiverPageState();
}

class CaregiverPageState extends State<CaregiverPage> {
  final _captionController = TextEditingController();
  final _patientProfileIdController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _calibrationGuideKey = GlobalKey();
  final GlobalKey _reportGuideKey = GlobalKey();
  PiConnectionState _piState = PiConnectionState.disconnected;
  PiDeviceStatus? _piStatus;
  StreamSubscription<PiConnectionState>? _piSubscription;
  StreamSubscription<PiDeviceStatus>? _statusSubscription;
  StreamSubscription<CaregiverAlert>? _alertSubscription;

  @override
  void initState() {
    super.initState();
    _piState = widget.services.pi.state;
    _piSubscription = widget.services.pi.states.listen((state) {
      if (mounted) setState(() => _piState = state);
    });
    _statusSubscription = widget.services.pi.statuses.listen((status) {
      if (mounted) setState(() => _piStatus = status);
    });
    _alertSubscription =
        widget.services.caregiverNotifications.alerts.listen((alert) {
      if (mounted) setState(() {});
    });
    widget.services.cloudAlerts.addListener(_onCloudAlertsChanged);
    widget.services.patientRegistry.addListener(_onPatientRegistryChanged);
  }

  @override
  void dispose() {
    widget.services.patientRegistry.removeListener(_onPatientRegistryChanged);
    widget.services.cloudAlerts.removeListener(_onCloudAlertsChanged);
    unawaited(_piSubscription?.cancel());
    unawaited(_statusSubscription?.cancel());
    unawaited(_alertSubscription?.cancel());
    _captionController.dispose();
    _patientProfileIdController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> revealGuideStep(AshaGuideStep step) async {
    if (step != AshaGuideStep.calibration && step != AshaGuideStep.report) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 40));
    if (!mounted || !_scrollController.hasClients) return;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final key = step == AshaGuideStep.calibration
        ? _calibrationGuideKey
        : _reportGuideKey;
    var targetContext = key.currentContext;
    if (targetContext == null) {
      final position = _scrollController.position;
      final fallback = step == AshaGuideStep.report
          ? position.maxScrollExtent
          : (position.maxScrollExtent * 0.38)
              .clamp(position.minScrollExtent, position.maxScrollExtent);
      if (reduceMotion) {
        _scrollController.jumpTo(fallback);
      } else {
        await _scrollController.animateTo(
          fallback,
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
        );
      }
      if (!mounted) return;
      targetContext = key.currentContext;
    }
    if (targetContext != null && targetContext.mounted) {
      await Scrollable.ensureVisible(
        targetContext,
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
        alignment: 0.35,
      );
    }
  }

  void _onCloudAlertsChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _connectCloudDashboard() async {
    final profileId = _patientProfileIdController.text.trim();
    if (profileId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a Patient Profile UUID.')),
      );
      return;
    }
    await widget.services.cloudAlerts.connectProfile(profileId);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Connected to patient live dashboard: $profileId'),
          backgroundColor: const Color(0xFF0B756A),
        ),
      );
    }
  }

  Future<void> _callPatient() async {
    final phone = widget.services.config.patientPhone.trim();
    if (phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('Patient phone number not set. Configure in Setup tab.'),
        ),
      );
      return;
    }
    if (!await launchUrl(Uri(scheme: 'tel', path: phone)) && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open phone dialer.')),
      );
    }
  }

  Future<void> _sendCaption() async {
    final text = _captionController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a message to write on display.')),
      );
      return;
    }

    // Try cloud relay if remote devices are available
    var sentViaCloud = false;
    final devices = widget.services.cloudAlerts.remoteDevices;
    if (devices.isNotEmpty) {
      try {
        await widget.services.cloudAlerts
            .sendCaptionToDevice(devices.first.id, text);
        sentViaCloud = true;
      } catch (_) {}
    }

    // Direct local Pi fallback
    if (!sentViaCloud) {
      if (_piState != PiConnectionState.connected) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Connect to wheelchair Pi in Setup or connect Patient Profile ID for cloud relay.'),
          ),
        );
        return;
      }
      try {
        widget.services.pi.sendCaption(
          text,
          language: widget.services.config.locale,
        );
      } on Object catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not write to display: $error')),
          );
        }
        return;
      }
    }

    _captionController.clear();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(sentViaCloud
              ? 'Message relayed to patient display via cloud.'
              : 'Message sent directly to wheelchair display.'),
          backgroundColor: const Color(0xFF0B756A),
        ),
      );
    }
  }

  Future<void> _openCalibrationWizard() async {
    final completed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: widget.calibrationBuilder ??
            (_) => HandCalibrationPage(services: widget.services),
      ),
    );
    if (!mounted) return;
    final guide = widget.services.ashaGuide;
    if (completed == true &&
        guide.isActive &&
        guide.step == AshaGuideStep.calibration) {
      await guide.next();
    }
  }

  void _openHandCalibration() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => HandCalibrationPage(services: widget.services),
      ),
    );
  }

  void _openCaregiverVoiceSetup() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CaregiverVoiceSetupPage(services: widget.services),
      ),
    );
  }

  void _onPatientRegistryChanged() {
    if (mounted) setState(() {});
  }

  Widget _quickChoiceChip(String label, VoidCallback onTap) {
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 11)),
      backgroundColor: const Color(0xFFE8F6F3),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFA6E3D9)),
      ),
      onPressed: onTap,
    );
  }

  Future<void> _showSendMessageDialog(PatientRecord patient) async {
    final messenger = ScaffoldMessenger.of(context);
    final controller = TextEditingController();
    var speakAloud = true;
    var displayOnScreen = true;

    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (dialogInnerCtx, setDialogState) {
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Row(
              children: [
                const Icon(Icons.mark_chat_unread, color: Color(0xFF0B756A)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Message to ${patient.name}',
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Send an instant message to ${patient.name}\'s display & audio communicator:',
                    style: const TextStyle(fontSize: 13, color: Color(0xFF556E68)),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    maxLines: 3,
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: 'e.g. I am coming in 5 minutes with lunch.',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      contentPadding: const EdgeInsets.all(12),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Quick Presets:',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF3B5E57)),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _quickChoiceChip('I am on my way', () => setDialogState(() => controller.text = 'I am on my way')),
                      _quickChoiceChip('Lunch is ready', () => setDialogState(() => controller.text = 'Lunch is ready for you')),
                      _quickChoiceChip('Take your rest', () => setDialogState(() => controller.text = 'Take your time and rest well')),
                      _quickChoiceChip('Water is here', () => setDialogState(() => controller.text = 'I am bringing some fresh water')),
                      _quickChoiceChip('Doctor visiting', () => setDialogState(() => controller.text = 'Doctor is coming for rounds at 3 PM')),
                    ],
                  ),
                  const SizedBox(height: 12),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('Show on Wheelchair / Tablet Display', style: TextStyle(fontSize: 13)),
                    value: displayOnScreen,
                    onChanged: (val) => setDialogState(() => displayOnScreen = val ?? true),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('Speak aloud via Asha Voice (TTS)', style: TextStyle(fontSize: 13)),
                    value: speakAloud,
                    onChanged: (val) => setDialogState(() => speakAloud = val ?? true),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogCtx).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF0B756A),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                icon: const Icon(Icons.send, size: 18),
                label: const Text('Send Message'),
                onPressed: () async {
                  final text = controller.text.trim();
                  if (text.isEmpty) return;
                  Navigator.of(dialogCtx).pop();

                  // 1. Deliver to display if selected
                  if (displayOnScreen) {
                    try {
                      final devices = widget.services.cloudAlerts.remoteDevices;
                      if (devices.isNotEmpty) {
                        await widget.services.cloudAlerts.sendCaptionToDevice(devices.first.id, text);
                      } else if (_piState == PiConnectionState.connected) {
                        widget.services.pi.sendCaption(text, language: widget.services.config.locale);
                      }
                    } catch (_) {}
                  }

                  // 2. Speak aloud if selected
                  if (speakAloud) {
                    try {
                      await widget.services.voice.speakAsha(text, force: true);
                    } catch (_) {}
                  }

                  // 3. Record in patient's messagesSent history
                  final channel = [
                    if (displayOnScreen) 'Wheelchair Display',
                    if (speakAloud) 'Asha Voice TTS',
                  ].join(' + ');

                  await widget.services.patientRegistry.sendMessageToPatient(
                    patientId: patient.id,
                    content: text,
                    channel: channel.isEmpty ? 'Direct Notification' : channel,
                  );

                  if (mounted) {
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text('Message delivered to ${patient.name}!'),
                        backgroundColor: const Color(0xFF0B756A),
                      ),
                    );
                  }
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showGiveFeedbackDialog(PatientRecord patient) async {
    final messenger = ScaffoldMessenger.of(context);
    final notesController = TextEditingController();
    final authorController = TextEditingController(text: 'Caregiver');
    var selectedCategory = 'Communication';
    final categories = [
      'Communication',
      'Mobility',
      'Pain/Discomfort',
      'Nutrition/Hydration',
      'Mood/Sleep',
      'Medical Note'
    ];

    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (dialogInnerCtx, setDialogState) {
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Row(
              children: [
                const Icon(Icons.rate_review, color: Color(0xFF0B756A)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Feedback: ${patient.name}',
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Log clinical observation and care feedback into this patient\'s record:',
                    style: TextStyle(fontSize: 13, color: Color(0xFF556E68)),
                  ),
                  const SizedBox(height: 12),
                  const Text('Observation Category:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: categories.map((cat) {
                      final isSel = selectedCategory == cat;
                      return ChoiceChip(
                        label: Text(
                          cat,
                          style: TextStyle(fontSize: 11, fontWeight: isSel ? FontWeight.bold : FontWeight.normal),
                        ),
                        selected: isSel,
                        selectedColor: const Color(0xFFD9F1EC),
                        onSelected: (val) {
                          if (val) setDialogState(() => selectedCategory = cat);
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: notesController,
                    maxLines: 4,
                    decoration: InputDecoration(
                      labelText: 'Clinical Notes & Observation',
                      hintText: 'e.g. Patient showed clear intent with 3-finger flexion; slight fatigue observed after 20 mins.',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      contentPadding: const EdgeInsets.all(12),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: authorController,
                    decoration: InputDecoration(
                      labelText: 'Logged By',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogCtx).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF0B756A),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                icon: const Icon(Icons.save, size: 18),
                label: const Text('Save Feedback'),
                onPressed: () async {
                  final notes = notesController.text.trim();
                  if (notes.isEmpty) return;
                  Navigator.of(dialogCtx).pop();

                  await widget.services.patientRegistry.addFeedback(
                    patientId: patient.id,
                    author: authorController.text.trim().isEmpty ? 'Caregiver' : authorController.text.trim(),
                    category: selectedCategory,
                    notes: notes,
                  );

                  if (mounted) {
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text('Clinical feedback logged for ${patient.name}.'),
                        backgroundColor: const Color(0xFF0B756A),
                      ),
                    );
                  }
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showEditPatientDialog(PatientRecord patient) async {
    final nameCtrl = TextEditingController(text: patient.name);
    final ageCtrl = TextEditingController(text: '${patient.age}');
    final conditionCtrl = TextEditingController(text: patient.condition);
    final modalityCtrl = TextEditingController(text: patient.primaryModality);
    final roomCtrl = TextEditingController(text: patient.roomNumber);
    final doctorCtrl = TextEditingController(text: patient.doctorName);
    final doctorPhoneCtrl = TextEditingController(text: patient.doctorPhone);
    final doctorEmailCtrl = TextEditingController(text: patient.doctorEmail);
    final directivesCtrl = TextEditingController(text: patient.doctorDirectives);

    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.edit_note, color: Color(0xFF0B756A)),
            const SizedBox(width: 8),
            Expanded(child: Text('Edit ${patient.name}')),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: 'Patient Full Name'),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    flex: 1,
                    child: TextField(
                      controller: ageCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Age'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: roomCtrl,
                      decoration: const InputDecoration(labelText: 'Room / Bed Location'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: conditionCtrl,
                decoration: const InputDecoration(labelText: 'Clinical Diagnosis / Condition'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: modalityCtrl,
                decoration: const InputDecoration(labelText: 'Primary Input / Modality'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: doctorCtrl,
                decoration: const InputDecoration(labelText: 'Attending Physician Name'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: doctorPhoneCtrl,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Doctor Phone Number'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: doctorEmailCtrl,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Doctor Email'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: directivesCtrl,
                maxLines: 2,
                decoration: const InputDecoration(labelText: 'Physician Directives / Care Plan'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF0B756A),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () async {
              final name = nameCtrl.text.trim();
              if (name.isEmpty) return;
              final age = int.tryParse(ageCtrl.text.trim()) ?? patient.age;

              final updated = patient.copyWith(
                name: name,
                age: age,
                condition: conditionCtrl.text.trim(),
                primaryModality: modalityCtrl.text.trim(),
                roomNumber: roomCtrl.text.trim(),
                doctorName: doctorCtrl.text.trim(),
                doctorPhone: doctorPhoneCtrl.text.trim(),
                doctorEmail: doctorEmailCtrl.text.trim(),
                doctorDirectives: directivesCtrl.text.trim(),
              );

              await widget.services.patientRegistry.updatePatient(updated);
              if (dialogCtx.mounted) Navigator.of(dialogCtx).pop();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Updated ${updated.name}\'s profile.'),
                    backgroundColor: const Color(0xFF0B756A),
                  ),
                );
              }
            },
            child: const Text('Save Changes'),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddPatientDialog() async {
    final nameCtrl = TextEditingController();
    final ageCtrl = TextEditingController(text: '50');
    final conditionCtrl = TextEditingController(text: 'Post-Stroke Recovery');
    final modalityCtrl = TextEditingController(text: 'Hand Gestures & Eye Blink');
    final roomCtrl = TextEditingController(text: 'Room 201');
    final doctorCtrl = TextEditingController(text: 'Dr. Physician');
    final doctorPhoneCtrl = TextEditingController();
    final doctorEmailCtrl = TextEditingController();

    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.person_add, color: Color(0xFF0B756A)),
            SizedBox(width: 8),
            Expanded(child: Text('Register New Patient')),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: 'Patient Full Name *'),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    flex: 1,
                    child: TextField(
                      controller: ageCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Age'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: roomCtrl,
                      decoration: const InputDecoration(labelText: 'Room / Bed'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: conditionCtrl,
                decoration: const InputDecoration(labelText: 'Condition / Diagnosis'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: modalityCtrl,
                decoration: const InputDecoration(labelText: 'Access Modality'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: doctorCtrl,
                decoration: const InputDecoration(labelText: 'Doctor Name'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: doctorPhoneCtrl,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Doctor Phone'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: doctorEmailCtrl,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Doctor Email'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF0B756A),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () async {
              final name = nameCtrl.text.trim();
              if (name.isEmpty) return;
              final newId = 'patient-${DateTime.now().millisecondsSinceEpoch}';
              final age = int.tryParse(ageCtrl.text.trim()) ?? 50;

              final record = PatientRecord(
                id: newId,
                name: name,
                age: age,
                condition: conditionCtrl.text.trim(),
                primaryModality: modalityCtrl.text.trim(),
                roomNumber: roomCtrl.text.trim(),
                doctorName: doctorCtrl.text.trim(),
                doctorPhone: doctorPhoneCtrl.text.trim(),
                doctorEmail: doctorEmailCtrl.text.trim(),
                heartRate: 72,
                respirationRate: 16,
                painScore: 1,
                gestureAccuracy: 92,
                fatigueLevel: 'Low',
                currentActivity: 'Newly registered patient · Ready for calibration',
              );

              await widget.services.patientRegistry.addPatient(record);
              if (dialogCtx.mounted) Navigator.of(dialogCtx).pop();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Registered new patient: $name'),
                    backgroundColor: const Color(0xFF0B756A),
                  ),
                );
              }
            },
            child: const Text('Add Patient'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final alerts = widget.services.caregiverNotifications.recentAlerts;
    final phrases = widget.services.recognition.phrases;
    final patientRegistry = widget.services.patientRegistry;
    final patients = patientRegistry.patients;
    final activePatient = patientRegistry.activePatient;

    return Material(
      color: Colors.transparent,
      child: ListView(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 120),
        children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Caregiver Hub',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        )),
              ],
            ),
            IconButton.filledTonal(
              style: IconButton.styleFrom(
                backgroundColor: const Color(0xFFFECDCA),
                foregroundColor: const Color(0xFFB42318),
              ),
              icon: const Icon(Icons.emergency),
              tooltip: 'Emergency Clinical Guide',
              onPressed: () =>
                  showCaregiverEmergencySheet(context, widget.services),
            ),
          ],
        ),
        const SizedBox(height: 12),
        StreamBuilder<MonitorStatus>(
          stream: widget.services.monitor.statuses,
          initialData: widget.services.monitor.currentStatus,
          builder: (context, snapshot) {
            final status = snapshot.data;
            final isActive =
                status?.lifecycle == MonitorLifecycle.active ||
                status?.lifecycle == MonitorLifecycle.starting;
            return Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 400),
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isActive
                        ? const Color(0xFF22C55E)
                        : const Color(0xFFEF4444),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  isActive
                      ? 'Asha is monitoring patient'
                      : 'Patient monitoring paused',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isActive
                        ? const Color(0xFF15803D)
                        : const Color(0xFF991B1B),
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 16),

        // Patient Selector Row
        Container(
          margin: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'SELECT PATIENT RECORD',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  Text(
                    '${patients.length} Registered Patients',
                    style: const TextStyle(fontSize: 11, color: Color(0xFF556E68)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ...patients.asMap().entries.map((entry) {
                    final idx = entry.key + 1;
                    final p = entry.value;
                    final isSelected = p.id == activePatient.id;
                    return ChoiceChip(
                      avatar: CircleAvatar(
                        backgroundColor: isSelected ? const Color(0xFF0B756A) : Colors.grey.shade400,
                        radius: 12,
                        child: Text(
                          '$idx',
                          style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                      ),
                      label: Text(
                        'Patient $idx: ${p.name.split(' ').first}',
                        style: TextStyle(
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          color: isSelected ? const Color(0xFF0B756A) : Colors.black87,
                        ),
                      ),
                      selected: isSelected,
                      selectedColor: const Color(0xFFD9F1EC),
                      onSelected: (selected) {
                        if (selected) {
                          widget.services.patientRegistry.selectPatient(p.id);
                        }
                      },
                    );
                  }),
                  ActionChip(
                    avatar: const Icon(Icons.add, size: 16, color: Color(0xFF0B756A)),
                    label: const Text('Add Patient', style: TextStyle(color: Color(0xFF0B756A), fontWeight: FontWeight.bold)),
                    backgroundColor: const Color(0xFFE8F6F3),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: const BorderSide(color: Color(0xFFA6E3D9)),
                    ),
                    onPressed: _showAddPatientDialog,
                  ),
                ],
              ),
            ],
          ),
        ),

        // Active Patient Profile Card
        Card(
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFFD0E7E2), width: 1.2),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 22,
                      backgroundColor: const Color(0xFF0B756A),
                      child: Text(
                        activePatient.name.isNotEmpty ? activePatient.name[0] : 'P',
                        style: const TextStyle(fontSize: 20, color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  activePatient.name,
                                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFE8F6F3),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  'Age ${activePatient.age}',
                                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF0B756A)),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${activePatient.roomNumber} • ${activePatient.condition}',
                            style: const TextStyle(fontSize: 12, color: Color(0xFF556E68)),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.edit_outlined, color: Color(0xFF0B756A)),
                      tooltip: 'Edit Patient Data',
                      onPressed: () => _showEditPatientDialog(activePatient),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                const Divider(height: 1),
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Icon(Icons.pan_tool_outlined, size: 14, color: Color(0xFF0B756A)),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        'Modality: ${activePatient.primaryModality}',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF2E4E46)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(Icons.medical_services_outlined, size: 14, color: Color(0xFF0B756A)),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        'Doctor: ${activePatient.doctorName} (${activePatient.doctorPhone})',
                        style: const TextStyle(fontSize: 12, color: Color(0xFF556E68)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),

        // Caregiver 4-Action Hub
        Card(
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFFE2E8F0)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Actions for ${activePatient.name.split(' ').first}',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF0F172A),
                          ),
                    ),
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      icon: const Icon(Icons.tune, size: 16, color: Color(0xFF0B756A)),
                      label: const Text('Edit Patient', style: TextStyle(fontSize: 12, color: Color(0xFF0B756A))),
                      onPressed: () => _showEditPatientDialog(activePatient),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  'One-tap direct communications, clinical feedback, and doctor reporting:',
                  style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _actionButton(
                        icon: Icons.chat_bubble_outline,
                        label: 'Send\nMessage',
                        subtitle: 'To Screen & TTS',
                        color: const Color(0xFF0B756A),
                        onTap: () => _showSendMessageDialog(activePatient),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _actionButton(
                        icon: Icons.rate_review_outlined,
                        label: 'Give\nFeedback',
                        subtitle: 'Log Clinical Note',
                        color: const Color(0xFF0284C7),
                        onTap: () => _showGiveFeedbackDialog(activePatient),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _actionButton(
                        icon: Icons.assignment_outlined,
                        label: 'Report to\nDoctor',
                        subtitle: 'SMS / Email / PDF',
                        color: const Color(0xFFB45309),
                        onTap: () => showDoctorReportSheet(
                          context: context,
                          services: widget.services,
                          patient: activePatient,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _actionButton(
                        icon: Icons.videocam_outlined,
                        label: 'Live\nCamera',
                        subtitle: 'Tele-Vision Feed',
                        color: const Color(0xFF0D9488),
                        onTap: () => showPatientLiveMonitorSheet(
                          context: context,
                          services: widget.services,
                          patient: activePatient,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),

        // Calibration Mode Launch Card
        Card(
          color: const Color(0xFFF3FBF9),
          shape: RoundedRectangleBorder(
            side: const BorderSide(color: Color(0xFF9DE0D5), width: 1.5),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.tune, color: Color(0xFF0B756A), size: 28),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Patient Signal Calibration',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              color: const Color(0xFF0B756A),
                            ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  'Calibrate custom triggers for eyes, facial muscles, lip/eye micro-movements, head motion, and hand gestures.',
                  style: TextStyle(fontSize: 14, color: Color(0xFF3B5E57)),
                ),
                const SizedBox(height: 14),
                AshaGuideTarget(
                  key: _calibrationGuideKey,
                  step: AshaGuideStep.calibration,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF0B756A),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: _openCalibrationWizard,
                    icon: const Icon(Icons.app_registration),
                    label: const Text(
                      'Start Step-by-Step Calibration',
                      style:
                          TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),

        // Live Tele-Monitoring & Activity Dashboard Card
        Card(
          color: const Color(0xFF0D1821),
          shape: RoundedRectangleBorder(
            side: const BorderSide(color: Color(0xFF38B2AC), width: 1.5),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(0xFF22C55E),
                            boxShadow: [
                              BoxShadow(
                                color: Color(0xFF22C55E),
                                blurRadius: 6,
                                spreadRadius: 2,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'LIVE PATIENT ACTIVITY & CAMERA',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.2,
                            color: Color(0xFF38B2AC),
                          ),
                        ),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF38B2AC)),
                      ),
                      child: const Text(
                        'STREAM READY',
                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF38B2AC)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF16222F),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF283848)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'What patient is doing right now:',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF88A0B0)),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        activePatient.currentActivity,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // Live Telemetry Bar
                Row(
                  children: [
                    _telemetryPill(Icons.favorite, '${activePatient.heartRate}', 'BPM', Colors.redAccent),
                    const SizedBox(width: 8),
                    _telemetryPill(Icons.air, '${activePatient.respirationRate}', 'Br/min', Colors.lightBlueAccent),
                    const SizedBox(width: 8),
                    _telemetryPill(Icons.sentiment_satisfied, '${activePatient.painScore}/10', 'Pain', Colors.amberAccent),
                    const SizedBox(width: 8),
                    _telemetryPill(Icons.check_circle, '${activePatient.gestureAccuracy}%', 'Signal', const Color(0xFF38B2AC)),
                  ],
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF38B2AC),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: const Icon(Icons.videocam, size: 20),
                  label: Text(
                    'View Live Camera for ${activePatient.name.split(' ').first}',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
                  ),
                  onPressed: () => showPatientLiveMonitorSheet(
                    context: context,
                    services: widget.services,
                    patient: activePatient,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),

        // Individualized Clinical Feedback & Observations Section
        Card(
          color: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${activePatient.name.split(' ').first}\'s Clinical Timeline',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                        Text(
                          '${activePatient.feedbackNotes.length} observations • ${activePatient.messagesSent.length} messages',
                          style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                        ),
                      ],
                    ),
                    FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6)),
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Add Note', style: TextStyle(fontSize: 12)),
                      onPressed: () => _showGiveFeedbackDialog(activePatient),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (activePatient.feedbackNotes.isEmpty && activePatient.messagesSent.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'No clinical observations or messages logged for this patient yet.',
                      style: TextStyle(color: Color(0xFF64748B), fontSize: 13),
                    ),
                  )
                else ...[
                  ...activePatient.feedbackNotes.take(3).map((f) => Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: const Color(0xFFE0F2FE),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(Icons.notes, size: 16, color: Color(0xFF0369A1)),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        '${f.category} · ${f.author}',
                                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                      ),
                                      Text(
                                        '${f.timestamp.hour.toString().padLeft(2, '0')}:${f.timestamp.minute.toString().padLeft(2, '0')}',
                                        style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(f.notes, style: const TextStyle(fontSize: 12, color: Color(0xFF334155))),
                                ],
                              ),
                            ),
                          ],
                        ),
                      )),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),

        // MediaPipe Hand Gesture Engine Card (from fingerspeak.html)
        Card(
          color: const Color(0xFF0F1720),
          shape: RoundedRectangleBorder(
            side: const BorderSide(color: Color(0xFF4FD1C5), width: 1.5),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                const CircleAvatar(
                  backgroundColor: Color(0xFF2E7D74),
                  child: Icon(Icons.pan_tool_alt,
                      color: Color(0xFF4FD1C5), size: 22),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Hand Gesture Communicator',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                          color: Color(0xFF4FD1C5),
                        ),
                      ),
                      Text(
                        'Teaches Asha to recognise the patient\'s hand signs.',
                        style:
                            TextStyle(fontSize: 13, color: Color(0xFF8CA0A8)),
                      ),
                    ],
                  ),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF4FD1C5),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                  onPressed: _openHandCalibration,
                  child: Builder(builder: (context) {
                    final hasGestures =
                        widget.services.recognition.phrases.isNotEmpty;
                    return Text(hasGestures
                        ? 'Manage Gestures'
                        : 'Train Hand Gestures');
                  }),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),

        // Emergency Guidance Banner
        Card(
          color: const Color(0xFFFFF0F2),
          shape: RoundedRectangleBorder(
            side: const BorderSide(color: Color(0xFFFECDCA), width: 1.5),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                const CircleAvatar(
                  backgroundColor: Color(0xFFB42318),
                  child: Icon(Icons.medical_services,
                      color: Colors.white, size: 22),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Asha Emergency Assistant',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                          color: Color(0xFF7A150E),
                        ),
                      ),
                      Text(
                        'Instant Seizure & Choking First-Aid + 1-Tap Ambulance',
                        style:
                            TextStyle(fontSize: 13, color: Color(0xFF555555)),
                      ),
                    ],
                  ),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFB42318),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                  onPressed: () =>
                      showCaregiverEmergencySheet(context, widget.services),
                  child: const Text('Open'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),

        // Connect Patient Profile ID Card (Cloud Sync)
        Card(
          color: Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.cloud_sync, color: Color(0xFF0B756A)),
                    const SizedBox(width: 8),
                    Text(
                      'Connect Patient Profile ID',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const Spacer(),
                    if (widget.services.cloudAlerts.currentProfileId != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE8F6F3),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFA6E3D9)),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.check_circle,
                                size: 12, color: Color(0xFF0B756A)),
                            SizedBox(width: 4),
                            Text('LIVE CONNECTED',
                                style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF0B756A))),
                          ],
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  'Enter the patient’s profile UUID to receive real-time cloud alerts and relay display captions.',
                  style: TextStyle(fontSize: 13, color: Color(0xFF556E68)),
                ),
                const SizedBox(height: 12),
                        ValueListenableBuilder<TextEditingValue>(
                          valueListenable: _patientProfileIdController,
                          builder: (context, value, _) {
                            final text = value.text.trim();
                            final isValidFormat = RegExp(
                              r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
                            ).hasMatch(text);
                            final showValid = text.isNotEmpty && isValidFormat;
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller:
                                            _patientProfileIdController,
                                        style: const TextStyle(
                                            fontSize: 13,
                                            fontFamily: 'monospace'),
                                        decoration: InputDecoration(
                                          hintText:
                                              'e.g. 8a3f7c2e-… (36 characters)',
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                                  horizontal: 12,
                                                  vertical: 10),
                                          suffixIcon: showValid
                                              ? const Icon(
                                                  Icons.check_circle,
                                                  color: Color(0xFF0B756A),
                                                  size: 20,
                                                )
                                              : null,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    FilledButton(
                                      onPressed: _connectCloudDashboard,
                                      child: const Text('Connect'),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    const Icon(
                                      Icons.info_outline,
                                      size: 13,
                                      color: Color(0xFF556E68),
                                    ),
                                    const SizedBox(width: 4),
                                    const Expanded(
                                      child: Text(
                                        'Ask the patient\'s NeuroBridge clinic for their profile ID.',
                                        style: TextStyle(
                                            fontSize: 12,
                                            color: Color(0xFF556E68)),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            );
                          },
                        ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),

        // Wheelchair Hardware Card
        Card(
          color: Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: _piState == PiConnectionState.connected
                      ? const Color(0xFFD9F1EC)
                      : const Color(0xFFFFE8C7),
                  child: Icon(
                    _piState == PiConnectionState.connected
                        ? Icons.wifi
                        : Icons.wifi_off,
                    color: _piState == PiConnectionState.connected
                        ? const Color(0xFF0B756A)
                        : Colors.orange.shade800,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Wheelchair Unit (Pi & NoIR Cam)',
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                      ),
                      Text(_piStatusLabel()),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),


        // Guided Caregiver Voice Setup Card
        Card(
          color: const Color(0xFFFFF7ED),
          shape: RoundedRectangleBorder(
            side: const BorderSide(color: Color(0xFFF7C98B), width: 1.5),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.family_restroom,
                      color: Color(0xFFB54708),
                      size: 28,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Caregiver Voice Setup',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              color: const Color(0xFF8A3A06),
                            ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  'Record every calibrated and Hand Studio phrase with guided prompts, listen to each result, and choose whether caregiver recordings should be preferred across the app.',
                  style: TextStyle(fontSize: 14, color: Color(0xFF69411F)),
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFB54708),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: _openCaregiverVoiceSetup,
                  icon: const Icon(Icons.multitrack_audio),
                  label: const Text(
                    'Set Up Caregiver Voice',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),

        // Write on Wheelchair Display Card
        Card(
          color: Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Write to Wheelchair Display',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                const Text(
                  'Send dynamic text captions that appear prominently on the wheelchair screen.',
                  style: TextStyle(color: Color(0xFF556E68)),
                ),
                const SizedBox(height: 12),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _captionController,
                  builder: (context, value, _) {
                    final len = value.text.length;
                    final Color counterColor = len > 270
                        ? const Color(0xFFB42318)
                        : len > 250
                            ? const Color(0xFFB45309)
                            : const Color(0xFF556E68);
                    return TextField(
                      controller: _captionController,
                      maxLength: 280,
                      buildCounter: (context,
                              {required currentLength,
                              required isFocused,
                              required maxLength}) =>
                          Text(
                        '$currentLength/$maxLength',
                        style: TextStyle(
                            fontSize: 12,
                            color: counterColor,
                            fontWeight: FontWeight.w600),
                      ),
                      minLines: 2,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Message for patient display (280 chars max)',
                        hintText: 'e.g., I am bringing your lunch now',
                      ),
                    );
                  },
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _PresetCaptionChip(
                      label: '"I\'m on my way"',
                      onTap: () =>
                          _captionController.text = 'I am on my way',
                    ),
                    _PresetCaptionChip(
                      label: '"Lunch is ready"',
                      onTap: () =>
                          _captionController.text = 'Lunch is ready for you',
                    ),
                    _PresetCaptionChip(
                      label: '"Rest well"',
                      onTap: () => _captionController.text =
                          'Take your time and rest well',
                    ),
                    _PresetCaptionChip(
                      label: '"Water is here"',
                      onTap: () => _captionController.text =
                          'I am bringing some fresh water',
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 52,
                  child: FilledButton.icon(
                    onPressed: _sendCaption,
                    icon: const Icon(Icons.tv),
                    label: const Text('Show on Wheelchair Display'),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 52,
                  child: OutlinedButton.icon(
                    onPressed: _callPatient,
                    icon: const Icon(Icons.call),
                    label: const Text('Call Patient Directly'),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),

        // Real-Time Patient Activity & Alert Feed
        Card(
          color: Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Live Patient Alert Feed',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    if (alerts.isNotEmpty ||
                        widget.services.cloudAlerts.alerts.isNotEmpty)
                      TextButton(
                        onPressed: () async {
                          final messenger = ScaffoldMessenger.of(context);
                          final clearedAlerts = List.of(
                              widget.services.caregiverNotifications
                                  .recentAlerts);
                          await widget.services.caregiverNotifications
                              .clearAlerts();
                          if (mounted) setState(() {});
                          messenger.showSnackBar(
                            SnackBar(
                              content: const Text('Alert history cleared.'),
                              duration: const Duration(seconds: 5),
                              action: SnackBarAction(
                                label: 'Undo',
                                onPressed: () async {
                                  await widget.services.caregiverNotifications
                                      .restoreAlerts(clearedAlerts);
                                  if (mounted) setState(() {});
                                },
                              ),
                            ),
                          );
                        },
                        child: const Text('Clear Local'),
                      ),
                  ],
                ),
                const SizedBox(height: 8),

                // Cloud alerts (if any)
                if (widget.services.cloudAlerts.alerts.isNotEmpty) ...[
                  const Text('Cloud Sync Alerts:',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF0B756A))),
                  const SizedBox(height: 6),
                  ...widget.services.cloudAlerts.alerts.take(5).map((ca) {
                    final isEmergency = ca.severity == 'emergency';
                    final isResolved = ca.status == 'resolved';
                    final isAck = ca.status == 'acknowledged';
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isResolved
                            ? const Color(0xFFF3F4F6)
                            : isEmergency
                                ? const Color(0xFFFFF0F2)
                                : const Color(0xFFE8F6F3),
                        border: Border.all(
                          color: isResolved
                              ? const Color(0xFFD1D5DB)
                              : isEmergency
                                  ? const Color(0xFFFECDCA)
                                  : const Color(0xFFA6E3D9),
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            isEmergency ? Icons.warning : Icons.cloud_queue,
                            color: isResolved
                                ? Colors.grey
                                : isEmergency
                                    ? const Color(0xFFB42318)
                                    : const Color(0xFF0B756A),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      isEmergency
                                          ? 'EMERGENCY ALERT'
                                          : 'PATIENT SPEECH',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: isEmergency
                                            ? const Color(0xFFB42318)
                                            : const Color(0xFF0B756A),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 6, vertical: 1),
                                      decoration: BoxDecoration(
                                        color: isResolved
                                            ? Colors.grey.shade300
                                            : isAck
                                                ? Colors.amber.shade200
                                                : Colors.red.shade100,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        ca.status.toUpperCase(),
                                        style: TextStyle(
                                            fontSize: 9,
                                            fontWeight: FontWeight.bold,
                                            color: isResolved
                                                ? Colors.grey.shade700
                                                : isAck
                                                    ? Colors.amber.shade900
                                                    : Colors.red.shade900),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(ca.message,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600)),
                              ],
                            ),
                          ),
                          if (!isResolved) ...[
                            if (!isAck)
                              TextButton(
                                onPressed: () => widget.services.cloudAlerts
                                    .acknowledgeAlert(ca.id),
                                child: const Text('Ack',
                                    style: TextStyle(fontSize: 12)),
                              ),
                            FilledButton.tonal(
                              style: FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                              ),
                              onPressed: () => widget.services.cloudAlerts
                                  .resolveAlert(ca.id),
                              child: const Text('Resolve',
                                  style: TextStyle(fontSize: 12)),
                            ),
                          ],
                        ],
                      ),
                    );
                  }),
                  const SizedBox(height: 8),
                  const Divider(),
                  const SizedBox(height: 4),
                ],

                if (alerts.isEmpty &&
                    widget.services.cloudAlerts.alerts.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                        'No patient alerts yet. New speech and signals will appear here instantly.'),
                  )
                else
                  ...alerts.take(10).map((a) {
                    final isEmergency = a.urgency == AlertUrgency.emergency;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isEmergency
                            ? const Color(0xFFFFF0F2)
                            : const Color(0xFFF6F9F8),
                        border: Border.all(
                          color: isEmergency
                              ? const Color(0xFFFECDCA)
                              : const Color(0xFFDDE7E4),
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            isEmergency
                                ? Icons.warning
                                : Icons.record_voice_over,
                            color: isEmergency
                                ? const Color(0xFFB42318)
                                : const Color(0xFF0B756A),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  a.title,
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: isEmergency
                                        ? const Color(0xFFB42318)
                                        : Colors.black87,
                                  ),
                                ),
                                Text(a.message),
                              ],
                            ),
                          ),
                          Text(
                            '${a.timestamp.hour.toString().padLeft(2, '0')}:${a.timestamp.minute.toString().padLeft(2, '0')}',
                            style: const TextStyle(
                                fontSize: 12, color: Colors.black54),
                          ),
                        ],
                      ),
                    );
                  }),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),

        // Active Calibrated Signals Summary
        Card(
          color: Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Active Calibrated Phrases (${phrases.length})',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                if (phrases.isEmpty)
                  const Text('No phrases calibrated yet.')
                else
                  ...phrases.map((p) => ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.check_circle_outline,
                            color: Color(0xFF0B756A)),
                        title: Text(p.phrase,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(
                            '${p.signal.displayName} • Sensitivity ${(p.sensitivity * 100).round()}%'),
                      )),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // Session Quality Metrics Card
        AshaGuideTarget(
          key: _reportGuideKey,
          step: AshaGuideStep.report,
          child: ListenableBuilder(
            listenable: widget.services.sessionMetrics,
            builder: (context, _) {
              final metrics = widget.services.sessionMetrics;
              return Card(
                color: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(children: [
                        const Icon(Icons.bar_chart, color: Color(0xFF0B756A)),
                        const SizedBox(width: 8),
                        Text('Session Quality',
                            style: Theme.of(context).textTheme.titleLarge),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: () {
                            widget.services.sessionMetrics.reset();
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('Session metrics reset.')),
                            );
                          },
                          icon: const Icon(Icons.refresh, size: 16),
                          label: const Text('Reset'),
                        ),
                      ]),
                      const SizedBox(height: 4),
                      const Text(
                        'Track communication effectiveness this session.',
                        style:
                            TextStyle(fontSize: 13, color: Color(0xFF556E68)),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _MetricTile(
                            icon: Icons.record_voice_over,
                            color: const Color(0xFF0B756A),
                            label: 'Phrases\nSpoken',
                            value: '${metrics.phrasesSpoken}',
                          ),
                          _MetricTile(
                            icon: Icons.error_outline,
                            color: Colors.orange,
                            label: 'False\nActivations',
                            value: '${metrics.falseActivations}',
                            onMark: () => widget.services.sessionMetrics
                                .markFalseActivation(),
                          ),
                          _MetricTile(
                            icon: Icons.visibility_off,
                            color: Colors.redAccent,
                            label: 'Missed\nGestures',
                            value: '${metrics.missedGestures}',
                            onMark: () => widget.services.sessionMetrics
                                .markMissedGesture(),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    ));
  }

  String _piLabel(PiConnectionState state) => switch (state) {
        PiConnectionState.disconnected => 'Offline — check Setup',
        PiConnectionState.connecting => 'Connecting wirelessly…',
        PiConnectionState.authenticating => 'Authenticating pairing…',
        PiConnectionState.connected => 'Online & synced to wheelchair',
        PiConnectionState.error => 'Connection error — check Wi-Fi/USB',
      };

  String _piStatusLabel() {
    final base = _piLabel(_piState);
    final status = _piStatus;
    if (status == null || _piState != PiConnectionState.connected) return base;
    final piBattery = status.piBatteryPercent?.round();
    final chairBattery = status.wheelchairBatteryPercent?.round();
    return '$base • Cam: ${status.camera}'
        '${piBattery == null ? '' : ' • Pi: $piBattery%'}'
        '${chairBattery == null ? '' : ' • Chair: $chairBattery%'}';
  }
}

class _PresetCaptionChip extends StatelessWidget {
  const _PresetCaptionChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      backgroundColor: const Color(0xFFE8F6F3),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFFA6E3D9)),
      ),
      onPressed: onTap,
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    this.onMark,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String value;
  final VoidCallback? onMark;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onMark,
      child: Container(
        width: 96,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 4),
            Text(
              value,
              style: TextStyle(
                  fontSize: 26, fontWeight: FontWeight.w800, color: color),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 11, color: color, fontWeight: FontWeight.w600),
            ),
            if (onMark != null) ...[
              const SizedBox(height: 6),
              Text(
                'Tap to mark',
                style: TextStyle(
                    fontSize: 9, color: color.withValues(alpha: 0.65)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

Widget _telemetryPill(IconData icon, String value, String unit, Color color) {
  return Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
          Text(
            unit,
            style: const TextStyle(fontSize: 9, color: Color(0xFF94A3B8)),
          ),
        ],
      ),
    ),
  );
}

Widget _actionButton({
  required IconData icon,
  required String label,
  required String subtitle,
  required Color color,
  required VoidCallback onTap,
}) {
  return InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(12),
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(height: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: color,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 10,
              color: color.withValues(alpha: 0.8),
            ),
          ),
        ],
      ),
    ),
  );
}
