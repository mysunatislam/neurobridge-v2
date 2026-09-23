import 'dart:async';

import 'package:camera/camera.dart';
import 'package:fingerspeak_mobile/core/mobile_services.dart';
import 'package:fingerspeak_mobile/data/pi_device_client.dart';
import 'package:fingerspeak_mobile/models/patient_access_method.dart';
import 'package:fingerspeak_mobile/models/patient_signal.dart';
import 'package:fingerspeak_mobile/models/personal_access_profile.dart';
import 'package:fingerspeak_mobile/models/user_role.dart';
import 'package:fingerspeak_mobile/services/caregiver_notification_service.dart';
import 'package:fingerspeak_mobile/services/local_peer_sync_service.dart';
import 'package:fingerspeak_mobile/services/asha_guide_service.dart';
import 'package:fingerspeak_mobile/ui/ability_assessment_page.dart';
import 'package:fingerspeak_mobile/ui/asha_chat_sheet.dart';
import 'package:fingerspeak_mobile/ui/effects/liquid_glass.dart';
import 'package:fingerspeak_mobile/ui/hand_calibration_page.dart';
import 'package:fingerspeak_mobile/ui/intent_confirmation_banner.dart';
import 'package:fingerspeak_mobile/ui/guide/asha_guide_host.dart';
import 'package:fingerspeak_mobile/ui/patient_onboarding_flow.dart';
import 'package:fingerspeak_mobile/ui/single_switch_scanning_view.dart';
import 'package:fingerspeak_mobile/ui/widgets/draggable_asha_avatar.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class PatientPage extends StatefulWidget {
  const PatientPage({
    required this.services,
    this.isActive = true,
    super.key,
  });

  final MobileServices services;
  final bool isActive;

  @override
  State<PatientPage> createState() => _PatientPageState();
}

class _PatientPageState extends State<PatientPage> {
  MonitorStatus _monitorStatus = const MonitorStatus.stopped();
  PatientSignal? _lastSignal;
  CalibratedPhrase? _lastPhrase;
  bool _waterEnabled = true;
  bool _busy = false;
  Future<void>? _monitorOperation;
  bool _configuringAccessMethod = false;
  bool _handRouteOpen = false;
  bool _showingOnboarding = false;
  PatientAccessMethod? _accessMethod;
  StreamSubscription<MonitorStatus>? _monitorSubscription;
  StreamSubscription<PatientSignal>? _signalSubscription;
  StreamSubscription<CalibratedPhrase>? _phraseSubscription;
  StreamSubscription<RemoteDisplayCommand>? _remoteDisplaySubscription;
  StreamSubscription<void>? _emergencyAckSubscription;
  String? _incomingCaregiverMessage;
  String? _caregiverSender;
  bool _emergencyAcknowledged = false;

  // Face scanning dwell step (0 to 3) and progress (0.0 to 1.0)
  int _faceDwellIndex = 0;
  double _faceDwellProgress = 0.0;
  Timer? _faceDwellTimer;
  DateTime? _lastFaceNavAt;
  DateTime? _lastFaceSelectAt;
  DateTime? _lastBlinkAt;
  int _recentBlinkCount = 0;

  bool get _isBlinkingNow {
    if (_lastBlinkAt != null &&
        DateTime.now().difference(_lastBlinkAt!).inMilliseconds < 1200) {
      return true;
    }
    if (_monitorStatus.leftEyeOpen != null) {
      final avg = ((_monitorStatus.leftEyeOpen! +
              (_monitorStatus.rightEyeOpen ?? _monitorStatus.leftEyeOpen!)) /
          2);
      return avg < 0.38;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    _monitorStatus = widget.services.monitor.currentStatus;
    _waterEnabled = widget.services.reminders.waterRemindersEnabled;
    _accessMethod = widget.services.patientAccessMethodRepository.load();

    widget.services.patientAccessMethodRepository
        .addListener(_onAccessMethodChanged);
    _monitorSubscription = widget.services.monitor.statuses.listen((status) {
      if (mounted) {
        setState(() {
          _monitorStatus = status;
          if (status.leftEyeOpen != null) {
            final avg = ((status.leftEyeOpen! +
                    (status.rightEyeOpen ?? status.leftEyeOpen!)) /
                2);
            if (avg < 0.38) {
              _lastBlinkAt = DateTime.now();
            }
          }
        });
      }
    });
    _signalSubscription = widget.services.monitor.signals.listen((signal) {
      if (!mounted) return;
      setState(() {
        _lastSignal = signal;
        if (signal.kind == PatientSignalKind.blink) {
          _lastBlinkAt = DateTime.now();
          _recentBlinkCount = (_recentBlinkCount % 3) + 1;
        }
        final intent = signal.metadata?['intent'] as String?;
        if (intent == 'water') {
          _speakQuickNeed('I need water', 'Water');
          widget.services.companion.send(
            'Patient signaled: I need water',
            gestureModality: 'neurosense_face',
            gestureConfidence: signal.confidence,
            physicalEffortObserved: true,
          );
          return;
        } else if (intent == 'food') {
          _speakQuickNeed('I need food', 'Food');
          widget.services.companion.send(
            'Patient signaled: I need food',
            gestureModality: 'neurosense_face',
            gestureConfidence: signal.confidence,
            physicalEffortObserved: true,
          );
          return;
        } else if (intent == 'toilet') {
          _speakQuickNeed('I need to go to toilet', 'Toilet');
          widget.services.companion.send(
            'Patient signaled: I need to go to toilet',
            gestureModality: 'neurosense_face',
            gestureConfidence: signal.confidence,
            physicalEffortObserved: true,
          );
          return;
        } else if (intent == 'okay') {
          _speakQuickNeed('I am okay, thank you', 'Okay');
          widget.services.companion.send(
            'Patient signaled: I am okay, thank you',
            gestureModality: 'neurosense_face',
            gestureConfidence: signal.confidence,
            physicalEffortObserved: true,
          );
          return;
        } else if (intent == 'abnormality' ||
            signal.kind == PatientSignalKind.seizureAlert) {
          _requestEmergencyHelp();
          return;
        }

        if (_accessMethod == PatientAccessMethod.faceEyesAndHead) {
          final now = DateTime.now();
          if (signal.kind == PatientSignalKind.eyeLookRight) {
            if (_lastFaceNavAt == null ||
                now.difference(_lastFaceNavAt!).inMilliseconds > 400) {
              _lastFaceNavAt = now;
              _faceDwellIndex = (_faceDwellIndex + 1) % 4;
              _faceDwellProgress = 0.0;
            }
          } else if (signal.kind == PatientSignalKind.eyeLookLeft) {
            if (_lastFaceNavAt == null ||
                now.difference(_lastFaceNavAt!).inMilliseconds > 400) {
              _lastFaceNavAt = now;
              _faceDwellIndex = (_faceDwellIndex - 1 + 4) % 4;
              _faceDwellProgress = 0.0;
            }
          } else if (signal.kind == PatientSignalKind.blink ||
              signal.kind == PatientSignalKind.headNodSmile ||
              signal.kind == PatientSignalKind.smile) {
            if (_lastFaceSelectAt == null ||
                now.difference(_lastFaceSelectAt!).inMilliseconds > 700) {
              _lastFaceSelectAt = now;
              _triggerCurrentFaceOption();
            }
          }
        }
      });
    });
    _phraseSubscription =
        widget.services.recognition.spokenPhrases.listen((phrase) {
      if (mounted) setState(() => _lastPhrase = phrase);
    });
    _remoteDisplaySubscription =
        widget.services.localPeerSync.remoteDisplayCommands.listen((cmd) {
      if (mounted) {
        setState(() {
          _incomingCaregiverMessage = cmd.message;
          _caregiverSender = cmd.sender;
        });
        unawaited(widget.services.voice.speakAsha(cmd.message, force: true));
      }
    });
    _emergencyAckSubscription =
        widget.services.localPeerSync.emergencyAcks.listen((_) {
      if (mounted) {
        setState(() => _emergencyAcknowledged = true);
        unawaited(widget.services.voice.speakAsha(
            'Your caregiver has acknowledged the emergency. Help is on the way.',
            force: true));
      }
    });

    if (widget.isActive && !_configuringAccessMethod) {
      _scheduleAccessMethodConfiguration();
    }
  }

  void _triggerCurrentFaceOption() {
    const titles = ['I need water', 'I need help', 'I feel pain', 'Yes / Confirm'];
    if (_faceDwellIndex >= 0 && _faceDwellIndex < titles.length) {
      final t = titles[_faceDwellIndex];
      _speakQuickNeed(t, t);
    }
  }

  @override
  void didUpdateWidget(PatientPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isActive && widget.isActive) {
      _scheduleAccessMethodConfiguration();
    } else if (oldWidget.isActive && !widget.isActive) {
      _faceDwellTimer?.cancel();
      _faceDwellTimer = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !widget.isActive) {
          unawaited(_toggleMonitoring(false));
        }
      });
    }
  }

  void _scheduleAccessMethodConfiguration() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.isActive) {
        unawaited(_configureAccessMethod());
      }
    });
  }

  Future<void> _configureAccessMethod() async {
    if (_configuringAccessMethod || !widget.isActive) return;
    _configuringAccessMethod = true;
    try {
      var method = widget.services.patientAccessMethodRepository.load();
      if (method == null) {
        method = await _askFingerCapability();
        if (method == null || !mounted || !widget.isActive) return;
        await widget.services.patientAccessMethodRepository.save(method);
      }
      if (!mounted || !widget.isActive) return;
      setState(() => _accessMethod = method);
      await _activateAccessMethod(method);
    } finally {
      _configuringAccessMethod = false;
    }
  }

  Future<void> _activateAccessMethod(PatientAccessMethod method) async {
    if (method == PatientAccessMethod.faceEyesAndHead) {
      await _toggleMonitoring(true);
      return;
    }

    await _toggleMonitoring(false);
    if (mounted && widget.isActive && !_handRouteOpen) {
      await _openHandCommunicator();
    }
  }

  Future<PatientAccessMethod?> _askFingerCapability() {
    return showDialog<PatientAccessMethod>(
      context: context,
      barrierDismissible: true,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(Icons.accessibility_new,
            color: Color(0xFF0B756A), size: 36),
        title: const Text('Can the patient intentionally move their fingers?'),
        content: const Text(
          'Choose the movement the patient can control reliably. You can change this later in Setup.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Decide Later'),
          ),
          OutlinedButton.icon(
            onPressed: () {
              Navigator.pop(context);
              _openAssessmentWizard();
            },
            style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF0B756A)),
            icon: const Icon(Icons.auto_awesome),
            label: const Text('Ability Assessment'),
          ),
          OutlinedButton.icon(
            onPressed: () => Navigator.pop(
              context,
              PatientAccessMethod.faceEyesAndHead,
            ),
            style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF556E68)),
            icon: const Icon(Icons.face_retouching_natural),
            label: const Text('No — use face & eyes'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(
              context,
              PatientAccessMethod.handGestures,
            ),
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF0B756A),
                foregroundColor: Colors.white),
            icon: const Icon(Icons.pan_tool_alt),
            label: const Text('Yes — use fingers'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _faceDwellTimer?.cancel();
    widget.services.patientAccessMethodRepository
        .removeListener(_onAccessMethodChanged);
    unawaited(_monitorSubscription?.cancel());
    unawaited(_signalSubscription?.cancel());
    unawaited(_phraseSubscription?.cancel());
    unawaited(_remoteDisplaySubscription?.cancel());
    unawaited(_emergencyAckSubscription?.cancel());
    super.dispose();
  }

  void _onAccessMethodChanged() {
    if (!mounted) return;
    setState(() {
      _accessMethod = widget.services.patientAccessMethodRepository.load();
    });
  }

  Future<void> _openAssessmentWizard() async {
    final currentProfile = widget.services.accessProfileRepository.load();
    final completedProfile =
        await Navigator.of(context).push<PersonalAccessProfile>(
      MaterialPageRoute<PersonalAccessProfile>(
        builder: (_) => AbilityAssessmentPage(
          services: widget.services,
          initialProfile: currentProfile,
        ),
      ),
    );
    if (!mounted) return;
    setState(() {});
    final guide = widget.services.ashaGuide;
    if (completedProfile != null &&
        guide.isActive &&
        guide.step == AshaGuideStep.profile) {
      await guide.next();
    }
  }

  Future<void> _changeAccessMethod() async {
    setState(() => _showingOnboarding = true);
  }

  Future<void> _openHandCommunicator() async {
    if (_handRouteOpen || !mounted) return;
    _handRouteOpen = true;
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => HandCalibrationPage(
            services: widget.services,
            mode: HandStudioMode.patientExecution,
          ),
        ),
      );
    } finally {
      _handRouteOpen = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _toggleMonitoring(bool enabled) async {
    final previous = _monitorOperation;
    if (previous != null) {
      try {
        await previous;
      } on Object {
        // ignore error from earlier task
      }
    }
    if (mounted) setState(() => _busy = true);
    final operation = enabled
        ? widget.services.monitor.start()
        : widget.services.monitor.stop();
    _monitorOperation = operation;
    try {
      await operation;
    } finally {
      if (identical(_monitorOperation, operation)) _monitorOperation = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleWater(bool enabled) async {
    await widget.services.reminders.setWaterRemindersEnabled(enabled);
    if (mounted) setState(() => _waterEnabled = enabled);
  }

  Future<void> _callCaregiver() async {
    final phone = widget.services.config.caregiverPhone.trim();
    if (phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Caregiver phone number not set. Configure in Setup tab.'),
        ),
      );
      return;
    }
    final uri = Uri(scheme: 'tel', path: phone);
    if (!await launchUrl(uri)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This device could not open the phone dialer.'),
        ),
      );
    }
  }

  Future<void> _requestEmergencyHelp() async {
    unawaited(widget.services.localPeerSync.broadcastEmergency());
    setState(() => _emergencyAcknowledged = false);

    const message = 'Emergency help requested! Please assist immediately.';
    await widget.services.voice.speakAsha(message, force: true);
    if (widget.services.pi.state == PiConnectionState.connected) {
      widget.services.pi.showEmergency(
        message,
        language: widget.services.config.locale,
      );
    }
    await widget.services.caregiverNotifications.notifyEmergency(
      'Emergency SOS Triggered',
      'Patient requested urgent emergency help.',
      urgency: AlertUrgency.emergency,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Emergency alert sent. Tap Undo if accidental.'),
          backgroundColor: const Color(0xFFB42318),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: 'Undo',
            textColor: Colors.white,
            onPressed: () {
              widget.services.caregiverNotifications.notifyEmergency(
                'SOS Cancelled',
                'Patient indicated the emergency SOS was accidental.',
                urgency: AlertUrgency.normal,
              );
            },
          ),
        ),
      );
      await _callCaregiver();
    }
  }

  Future<void> _speakQuickNeed(String phrase, String title) async {
    await widget.services.voice.speakAsha(phrase, force: true);
    if (widget.services.pi.state == PiConnectionState.connected) {
      widget.services.pi.sendCaption(phrase, language: widget.services.config.locale);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.volume_up, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              Expanded(child: Text('Spoken: “$phrase”')),
            ],
          ),
          duration: const Duration(milliseconds: 2000),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
    }
  }

  Widget _buildCapabilityPending(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: LiquidGlassThemeController.isDarkNotifier,
      builder: (context, isDark, _) {
        final theme = LiquidGlassThemeData.current(context);
        return Scaffold(
          body: Container(
            decoration: BoxDecoration(gradient: theme.bgGradient),
            child: SafeArea(
              child: Stack(
                children: [
                  ListView(
                    padding: const EdgeInsets.fromLTRB(18, 18, 18, 120),
                    children: [
                      _buildTopHeader(theme),
                      const SizedBox(height: 12),
                      _buildCaregiverIncomingAlerts(theme),
                      const SizedBox(height: 12),
                      LiquidGlassCard(
                        padding: const EdgeInsets.all(22),
                        child: Column(
                          children: [
                            Icon(
                              Icons.accessibility_new,
                              size: 52,
                              color: theme.speakColor,
                            ),
                            const SizedBox(height: 14),
                            Text(
                              'Choose the patient’s reliable movement',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                color: theme.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'NeuroBridge Asha will open either hand-gesture communication or face, eye, and head monitoring.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: theme.textSecondary, fontSize: 13.5),
                            ),
                            const SizedBox(height: 18),
                            AshaGuideTarget(
                              step: AshaGuideStep.profile,
                              child: SizedBox(
                                width: double.infinity,
                                child: OutlinedButton.icon(
                                  onPressed: _openAssessmentWizard,
                                  icon: const Icon(Icons.accessibility_new),
                                  label: const Text('Open Patient Ability Profile'),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: theme.speakColor,
                                    side: BorderSide(color: theme.speakColor),
                                    padding: const EdgeInsets.symmetric(vertical: 14),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  DraggableAshaAvatar(services: widget.services),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_showingOnboarding) {
      return PatientOnboardingFlow(
        services: widget.services,
        onComplete: () {
          setState(() {
            _showingOnboarding = false;
            _accessMethod = widget.services.patientAccessMethodRepository.load();
          });
        },
      );
    }

    final profile = widget.services.accessProfileRepository.load();
    if (profile?.primaryModality == AccessModality.singleSwitchScanning) {
      return Scaffold(
        backgroundColor: const Color(0xFF0F172A),
        appBar: AppBar(
          backgroundColor: const Color(0xFF1E293B),
          foregroundColor: Colors.white,
          title: const Text(
            'Single-Switch Scanning',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          actions: [
            AshaGuideTarget(
              step: AshaGuideStep.profile,
              child: IconButton(
                icon: const Icon(Icons.accessibility_new, color: Color(0xFF2DD4BF)),
                tooltip: 'Ability Assessment',
                onPressed: _openAssessmentWizard,
              ),
            ),
          ],
        ),
        body: SingleSwitchScanningView(services: widget.services),
      );
    }

    if (_accessMethod == null) return _buildCapabilityPending(context);

    return ValueListenableBuilder<bool>(
      valueListenable: LiquidGlassThemeController.isDarkNotifier,
      builder: (context, isDark, _) {
        final theme = LiquidGlassThemeData.current(context);

        return Scaffold(
          body: Container(
            decoration: BoxDecoration(gradient: theme.bgGradient),
            child: SafeArea(
              bottom: false,
              child: Stack(
                children: [
                  CustomScrollView(
                    slivers: [
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(18, 14, 18, 110),
                        sliver: SliverList(
                          delegate: SliverChildListDelegate([
                            _buildTopHeader(theme),
                            const SizedBox(height: 14),
                            _buildCaregiverIncomingAlerts(theme),
                            IntentConfirmationBanner(services: widget.services),
                            _buildAshaReassuranceCard(theme),
                            const SizedBox(height: 16),
                            _buildHeroActions(theme),
                            const SizedBox(height: 20),
                            AshaGuideTarget(
                              step: AshaGuideStep.profile,
                              child: SizedBox(
                                width: double.infinity,
                                child: OutlinedButton.icon(
                                  onPressed: _openAssessmentWizard,
                                  icon: const Icon(Icons.accessibility_new),
                                  label: const Text('Open Patient Ability Profile'),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: theme.speakColor,
                                    side: BorderSide(color: theme.speakColor),
                                    padding: const EdgeInsets.symmetric(vertical: 14),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            if (_accessMethod == PatientAccessMethod.faceEyesAndHead)
                              _buildFaceScanningSection(theme)
                            else
                              _buildHandModeSection(theme),
                            const SizedBox(height: 20),
                            _buildDailyNeedsGrid(theme),
                            const SizedBox(height: 20),
                            _buildBottomVitalsBar(theme),
                            const SizedBox(height: 18),
                            _PhraseCard(
                              phrases: widget.services.recognition.phrases,
                              lastPhrase: _lastPhrase,
                              onSpeak: widget.services.recognition.speakNow,
                              theme: theme,
                            ),
                            const SizedBox(height: 16),
                            _buildHydrationReminderCard(theme),
                            const SizedBox(height: 14),
                            _buildOnboardingReplayButton(theme),
                            const SizedBox(height: 20),
                          ]),
                        ),
                      ),
                    ],
                  ),
                  DraggableAshaAvatar(services: widget.services),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // --- Header with Greeting, Mode Switch, and Theme Switch ---
  Widget _buildTopHeader(LiquidGlassThemeData theme) {
    final isHandMode = _accessMethod != PatientAccessMethod.faceEyesAndHead;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'NEUROBRIDGE ASHA',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.2,
                          color: theme.speakColor,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFF10B981).withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: const Color(0xFF10B981).withValues(alpha: 0.4),
                          ),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.wifi, size: 10, color: Color(0xFF10B981)),
                            SizedBox(width: 4),
                            Text(
                              'LAN Active',
                              style: TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF10B981),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'You are not alone.',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      color: theme.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
            // Theme Toggle
            const ThemeToggleSwitch(),
          ],
        ),
        const SizedBox(height: 12),
        // Mode switch pills bar
        Row(
          children: [
            LiquidGlassPill(
              icon: Icons.pan_tool_alt_rounded,
              label: 'Hand Mode',
              isActive: isHandMode,
              accentColor: theme.speakColor,
              onTap: () async {
                setState(() => _accessMethod = PatientAccessMethod.handGestures);
                await widget.services.patientAccessMethodRepository
                    .save(PatientAccessMethod.handGestures);
                await _toggleMonitoring(false);
              },
            ),
            const SizedBox(width: 8),
            LiquidGlassPill(
              icon: Icons.remove_red_eye_rounded,
              label: 'Face Mode',
              isActive: !isHandMode,
              accentColor: theme.waterColor,
              onTap: () async {
                setState(() => _accessMethod = PatientAccessMethod.faceEyesAndHead);
                await widget.services.patientAccessMethodRepository
                    .save(PatientAccessMethod.faceEyesAndHead);
                await _toggleMonitoring(true);
              },
            ),
            const Spacer(),
            IconButton(
              icon: Icon(Icons.settings_suggest_rounded, color: theme.textSecondary, size: 20),
              tooltip: 'Configure Input Method',
              onPressed: _changeAccessMethod,
            ),
          ],
        ),
      ],
    );
  }

  // --- Hero Action Buttons (Speak & SOS) ---
  Widget _buildHeroActions(LiquidGlassThemeData theme) {
    return Column(
      children: [
        LiquidGlassHeroButton(
          icon: Icons.pan_tool_rounded,
          title: 'Speak [Hold Gestures]',
          subtitle: 'Hold calibrated gesture to speak immediately',
          accentColor: theme.speakColor,
          onTap: _openHandCommunicator,
        ),
        const SizedBox(height: 12),
        _LiquidGlassSosButton(
          onTriggered: _requestEmergencyHelp,
          theme: theme,
        ),
      ],
    );
  }

  // --- 2x3 Daily Needs Colorful Liquid Glass Grid ---
  Widget _buildDailyNeedsGrid(LiquidGlassThemeData theme) {
    final needs = [
      {
        'title': 'Water',
        'subtitle': 'I need a sip of water',
        'icon': Icons.water_drop_rounded,
        'color': theme.waterColor,
      },
      {
        'title': 'Food',
        'subtitle': 'I am hungry / meal time',
        'icon': Icons.restaurant_rounded,
        'color': theme.foodColor,
      },
      {
        'title': 'Toilet',
        'subtitle': 'I need bathroom assistance',
        'icon': Icons.wc_rounded,
        'color': theme.toiletColor,
      },
      {
        'title': 'Rest',
        'subtitle': 'I want to sleep / rest',
        'icon': Icons.bed_rounded,
        'color': theme.restColor,
      },
      {
        'title': 'Call Family',
        'subtitle': 'Please call my family',
        'icon': Icons.phone_in_talk_rounded,
        'color': theme.familyColor,
      },
      {
        'title': 'Entertainment',
        'subtitle': 'Turn on TV or music',
        'icon': Icons.sports_esports_rounded,
        'color': theme.entertainmentColor,
      },
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.grid_view_rounded, size: 18, color: theme.speakColor),
            const SizedBox(width: 8),
            Text(
              'Daily Needs & Quick Actions',
              style: TextStyle(
                fontSize: 16.5,
                fontWeight: FontWeight.w800,
                color: theme.textPrimary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.15,
          ),
          itemCount: needs.length,
          itemBuilder: (context, index) {
            final item = needs[index];
            final title = item['title'] as String;
            final subtitle = item['subtitle'] as String;
            final icon = item['icon'] as IconData;
            final color = item['color'] as Color;

            return LiquidGlassCard(
              onTap: () => _speakQuickNeed(subtitle, title),
              borderRadius: 20,
              padding: const EdgeInsets.all(14),
              customBorderColor: color.withValues(alpha: 0.45),
              customGlowColor: color.withValues(alpha: 0.25),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: color.withValues(alpha: 0.4)),
                    ),
                    child: Icon(icon, color: color, size: 24),
                  ),
                  const Spacer(),
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: theme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: theme.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  // --- Real-time Hand Gesture HUD Section (Path 1) ---
  Widget _buildHandModeSection(LiquidGlassThemeData theme) {
    return LiquidGlassCard(
      padding: const EdgeInsets.all(16),
      customBorderColor: theme.speakColor.withValues(alpha: 0.4),
      customGlowColor: theme.speakColor.withValues(alpha: 0.2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: theme.speakColor.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.videocam_rounded, color: theme.speakColor, size: 18),
              ),
              const SizedBox(width: 10),
              Text(
                'Real-Time Hand Gesture HUD',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: theme.textPrimary,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFF10B981).withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.4)),
                ),
                child: const Text(
                  'Confidence 96%',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF10B981),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Viewfinder simulation
          Container(
            height: 130,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: theme.speakColor.withValues(alpha: 0.3)),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Center(
                  child: Icon(
                    Icons.front_hand_rounded,
                    size: 54,
                    color: theme.speakColor.withValues(alpha: 0.7),
                  ),
                ),
                Positioned(
                  bottom: 8,
                  left: 12,
                  child: Row(
                    children: [
                      const Icon(Icons.check_circle, size: 14, color: Color(0xFF10B981)),
                      const SizedBox(width: 6),
                      Text(
                        _lastSignal != null
                            ? 'Gesture: ${_lastSignal!.kind.displayName}'
                            : 'Tracking Ready • Show Hand',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  top: 8,
                  right: 12,
                  child: TextButton.icon(
                    onPressed: _openHandCommunicator,
                    icon: const Icon(Icons.fullscreen_rounded, size: 16),
                    label: const Text('Open Studio'),
                    style: TextButton.styleFrom(
                      foregroundColor: theme.speakColor,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- Face, Eye & Head Scanning Section (Path 2) ---
  Widget _buildFaceScanningSection(LiquidGlassThemeData theme) {
    final monitoring = _monitorStatus.lifecycle == MonitorLifecycle.active ||
        _monitorStatus.lifecycle == MonitorLifecycle.starting;
    final hasFace = monitoring && _monitorStatus.faceDetected;
    final controller = widget.services.monitor.cameraController;

    final faceOptions = [
      {'title': 'I need water', 'icon': Icons.water_drop_rounded, 'color': theme.waterColor},
      {'title': 'I need help', 'icon': Icons.emergency_rounded, 'color': theme.sosColor},
      {'title': 'I feel pain', 'icon': Icons.sentiment_dissatisfied_rounded, 'color': theme.foodColor},
      {'title': 'Yes / Confirm', 'icon': Icons.check_circle_rounded, 'color': theme.restColor},
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(Icons.remove_red_eye_rounded, color: theme.waterColor, size: 18),
                const SizedBox(width: 8),
                Text(
                  'Facial Input Monitor HUD',
                  style: TextStyle(
                    fontSize: 16.5,
                    fontWeight: FontWeight.w800,
                    color: theme.textPrimary,
                  ),
                ),
              ],
            ),
            Row(
              children: [
                ListenableBuilder(
                  listenable: widget.services.ashaGuide,
                  builder: (context, _) {
                    final guide = widget.services.ashaGuide;
                    if (guide.isActive &&
                        guide.step == AshaGuideStep.firstSession) {
                      return AshaGuideTarget(
                        step: AshaGuideStep.firstSession,
                        child: FilledButton.icon(
                          key: const ValueKey('asha-guide-start-face-session'),
                          onPressed: _busy
                              ? null
                              : () async {
                                  if (!monitoring) {
                                    await _toggleMonitoring(true);
                                  }
                                  if (!mounted) return;
                                  if (widget.services.monitor.currentStatus.lifecycle ==
                                          MonitorLifecycle.active &&
                                      guide.isActive &&
                                      guide.step == AshaGuideStep.firstSession) {
                                    await guide.next();
                                  }
                                },
                          icon: Icon(monitoring ? Icons.check : Icons.play_arrow),
                          label: Text(monitoring ? 'Continue' : 'Start'),
                          style: FilledButton.styleFrom(
                            backgroundColor: theme.waterColor,
                            foregroundColor: Colors.white,
                          ),
                        ),
                      );
                    }
                    return Switch(
                      value: monitoring,
                      onChanged: _busy ? null : _toggleMonitoring,
                      activeTrackColor: theme.waterColor.withValues(alpha: 0.6),
                      activeThumbColor: theme.waterColor,
                    );
                  },
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 10),
        // Live camera feed or placeholder
        if (monitoring && controller != null && controller.value.isInitialized)
          Container(
            height: 180,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: theme.waterColor.withValues(alpha: 0.5)),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CameraPreview(controller),
                Center(
                  child: Container(
                    width: 120,
                    height: 150,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(60),
                      border: Border.all(color: const Color(0x774ADE80), width: 1.5),
                    ),
                  ),
                ),
              ],
            ),
          )
        else
          LiquidGlassCard(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(Icons.face_retouching_natural_rounded, color: theme.waterColor, size: 36),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        !monitoring
                            ? 'Face Monitor Paused'
                            : (hasFace
                                ? 'Face Detected & Tracking'
                                : 'Searching for face…'),
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: hasFace ? const Color(0xFF10B981) : theme.textPrimary,
                        ),
                      ),
                      Text(
                        hasFace
                            ? 'Patient aligned. Gaze or dwell to select.'
                            : 'Keep camera at eye level (40–60 cm distance).',
                        style: TextStyle(fontSize: 12, color: theme.textSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 14),
        // Telemetry Chips
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _buildTelemetryPill(
              theme,
              Icons.visibility_rounded,
              'Gaze',
              !hasFace
                  ? 'No Face'
                  : (_monitorStatus.headYaw != null
                      ? (_monitorStatus.headYaw! < -10
                          ? 'Left (${_monitorStatus.headYaw!.abs().toStringAsFixed(0)}°)'
                          : _monitorStatus.headYaw! > 10
                              ? 'Right (+${_monitorStatus.headYaw!.toStringAsFixed(0)}°)'
                              : 'Center')
                      : 'Center'),
              active: hasFace,
            ),
            _buildTelemetryPill(
              theme,
              Icons.remove_red_eye_rounded,
              'Blink',
              !hasFace
                  ? '—'
                  : (_isBlinkingNow
                      ? '⚡ BLINK DETECTED!'
                      : (_monitorStatus.leftEyeOpen != null
                          ? 'Open (${(((_monitorStatus.leftEyeOpen! + (_monitorStatus.rightEyeOpen ?? _monitorStatus.leftEyeOpen!)) / 2) * 100).round()}%)'
                          : 'Open')),
              active: hasFace,
            ),
            _buildTelemetryPill(
              theme,
              Icons.sentiment_satisfied_alt_rounded,
              'Mouth',
              !hasFace
                  ? '—'
                  : ((_monitorStatus.smileProbability ?? 0) > 0.35
                      ? 'Smile (${((_monitorStatus.smileProbability!) * 100).round()}%)'
                      : 'Neutral'),
              active: hasFace,
            ),
            _buildTelemetryPill(
              theme,
              Icons.straighten_rounded,
              'Head Pose',
              !hasFace
                  ? '—'
                  : ((_monitorStatus.headPitch != null && _monitorStatus.headPitch! < -8) ||
                          _lastSignal?.kind == PatientSignalKind.headNodSmile
                      ? 'Nodding (${_monitorStatus.headPitch?.toStringAsFixed(0) ?? "0"}°)'
                      : (_monitorStatus.headYaw != null
                          ? (_monitorStatus.headYaw! > 12
                              ? 'Right (+${_monitorStatus.headYaw!.toStringAsFixed(0)}°)'
                              : _monitorStatus.headYaw! < -12
                                  ? 'Left (${_monitorStatus.headYaw!.abs().toStringAsFixed(0)}°)'
                                  : 'Stable')
                          : 'Stable')),
              active: hasFace,
            ),
          ],
        ),
        const SizedBox(height: 14),
        // Auto-Calibrated Clinical Gesture Legend & Quick Actions Card
        LiquidGlassCard(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          borderRadius: 16,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.auto_awesome_rounded, size: 16, color: theme.waterColor),
                  const SizedBox(width: 8),
                  Text(
                    'Auto-Calibrated Gesture Rules',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: theme.textPrimary,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () {
                      widget.services.monitor.resetAutoCalibration();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Personal baseline auto-calibration reset (2s resting face).'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
                    child: Text(
                      'Recalibrate',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: theme.waterColor,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildGestureChip(
                    theme,
                    label: '💧 3 Blinks: Water',
                    onTap: () => widget.services.monitor.triggerWebGesture('water'),
                  ),
                  _buildGestureChip(
                    theme,
                    label: '🍲 3 Head Left: Food',
                    onTap: () => widget.services.monitor.triggerWebGesture('food'),
                  ),
                  _buildGestureChip(
                    theme,
                    label: '🚻 3 Head Right: Toilet',
                    onTap: () => widget.services.monitor.triggerWebGesture('toilet'),
                  ),
                  _buildGestureChip(
                    theme,
                    label: '😊 Nod + Smile: I am okay',
                    onTap: () => widget.services.monitor.triggerWebGesture('okay'),
                  ),
                  _buildGestureChip(
                    theme,
                    label: '🚨 Abnormality: Emergency',
                    isEmergency: true,
                    onTap: () => widget.services.monitor.triggerWebGesture('abnormality'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Dwell Scanning Selection (Eye Gaze / Head)',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: theme.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        // Vertical stacked dwell cards
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: faceOptions.length,
          itemBuilder: (context, index) {
            final opt = faceOptions[index];
            final isDwellTarget = hasFace && index == _faceDwellIndex;
            final color = opt['color'] as Color;

            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: LiquidGlassCard(
                onTap: () => _speakQuickNeed(opt['title'] as String, opt['title'] as String),
                borderRadius: 18,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                borderWidth: isDwellTarget ? 2.5 : 1.0,
                customBorderColor: isDwellTarget ? color : theme.cardBorder,
                customGlowColor: isDwellTarget ? color.withValues(alpha: 0.4) : theme.glowShadow,
                child: Row(
                  children: [
                    Icon(opt['icon'] as IconData, color: color, size: 22),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        opt['title'] as String,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: theme.textPrimary,
                        ),
                      ),
                    ),
                    if (isDwellTarget && _faceDwellProgress > 0) ...[
                      SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          value: _faceDwellProgress,
                          strokeWidth: 2.5,
                          valueColor: AlwaysStoppedAnimation<Color>(color),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Dwell ${(_faceDwellProgress * 100).round()}%',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: color,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildTelemetryPill(
    LiquidGlassThemeData theme,
    IconData icon,
    String label,
    String value, {
    bool active = true,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: active ? theme.pillGlass : theme.cardBorder.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: active ? theme.pillBorder : theme.cardBorder.withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 14,
            color: active ? theme.waterColor : theme.textSecondary.withValues(alpha: 0.5),
          ),
          const SizedBox(width: 6),
          Text(
            '$label: ',
            style: TextStyle(
              fontSize: 11.5,
              color: active ? theme.textSecondary : theme.textSecondary.withValues(alpha: 0.6),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.bold,
              color: active
                  ? (value.contains('Blink') || value.contains('Smile')
                      ? theme.waterColor
                      : theme.textPrimary)
                  : theme.textSecondary.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGestureChip(
    LiquidGlassThemeData theme, {
    required String label,
    required VoidCallback onTap,
    bool isEmergency = false,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: isEmergency
                ? const Color(0x22EF4444)
                : theme.pillGlass,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isEmergency
                  ? const Color(0x66EF4444)
                  : theme.pillBorder,
              width: 1,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: isEmergency ? const Color(0xFFEF4444) : theme.textPrimary,
            ),
          ),
        ),
      ),
    );
  }

  // --- Bottom Vitals Bar (❤️ 72 BPM, 🫁 16 / min, 😊 "Feeling Good") ---
  Widget _buildBottomVitalsBar(LiquidGlassThemeData theme) {
    return LiquidGlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      customBorderColor: theme.restColor.withValues(alpha: 0.35),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildVitalMetric(
            theme,
            icon: Icons.favorite_rounded,
            value: '72 BPM',
            label: 'Heart Rate',
            color: const Color(0xFFF43F5E),
          ),
          Container(width: 1, height: 28, color: theme.cardBorder),
          _buildVitalMetric(
            theme,
            icon: Icons.air_rounded,
            value: '16 / min',
            label: 'Breathing',
            color: const Color(0xFF0EA5E9),
          ),
          Container(width: 1, height: 28, color: theme.cardBorder),
          _buildVitalMetric(
            theme,
            icon: Icons.sentiment_satisfied_alt_rounded,
            value: 'Comfortable',
            label: 'Patient Vibe',
            color: const Color(0xFF10B981),
          ),
        ],
      ),
    );
  }

  Widget _buildVitalMetric(
    LiquidGlassThemeData theme, {
    required IconData icon,
    required String value,
    required String label,
    required Color color,
  }) {
    return Row(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: theme.textPrimary,
              ),
            ),
            Text(
              label,
              style: TextStyle(
                fontSize: 10.5,
                color: theme.textSecondary,
              ),
            ),
          ],
        ),
      ],
    );
  }

  // --- Asha Reassurance Card ---
  Widget _buildAshaReassuranceCard(LiquidGlassThemeData theme) {
    return LiquidGlassCard(
      onTap: () => showAshaChatSheet(
        context,
        widget.services.companion,
        role: UserRole.patient,
        voiceService: widget.services.voice,
        services: widget.services,
      ),
      padding: const EdgeInsets.all(16),
      customBorderColor: theme.speakColor.withValues(alpha: 0.4),
      customGlowColor: theme.speakColor.withValues(alpha: 0.25),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: theme.speakColor.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.favorite_rounded, color: theme.speakColor, size: 26),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Asha is with you',
                      style: TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w800,
                        color: theme.textPrimary,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: theme.speakColor,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.chat_bubble_outline, size: 10, color: Colors.white),
                          SizedBox(width: 4),
                          Text(
                            'Chat',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 10.5,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  'Powered by Eli-Asha brain. Ready for conversational thoughts, questions, or reassurance.',
                  style: TextStyle(fontSize: 12.5, color: theme.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- Caregiver incoming alert banners ---
  Widget _buildCaregiverIncomingAlerts(LiquidGlassThemeData theme) {
    if (_incomingCaregiverMessage == null && !_emergencyAcknowledged) {
      return const SizedBox.shrink();
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_incomingCaregiverMessage != null) ...[
          LiquidGlassCard(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(14),
            customBorderColor: const Color(0xFF22C55E),
            child: Row(
              children: [
                const Icon(Icons.mark_chat_unread_rounded, color: Color(0xFF16A34A), size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Message from ${_caregiverSender ?? "Caregiver"}:',
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF16A34A),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _incomingCaregiverMessage!,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: theme.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.close_rounded, size: 18, color: theme.textSecondary),
                  onPressed: () => setState(() => _incomingCaregiverMessage = null),
                ),
              ],
            ),
          ),
        ],
        if (_emergencyAcknowledged) ...[
          LiquidGlassCard(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(14),
            customBorderColor: const Color(0xFF3B82F6),
            child: Row(
              children: [
                const Icon(Icons.verified_rounded, color: Color(0xFF2563EB), size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Caregiver Acknowledged SOS',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF2563EB),
                        ),
                      ),
                      Text(
                        'Help is on the way to your bedside now.',
                        style: TextStyle(fontSize: 11.5, color: theme.textSecondary),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.close_rounded, size: 18, color: theme.textSecondary),
                  onPressed: () => setState(() => _emergencyAcknowledged = false),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  // --- Hydration reminder switch tile ---
  Widget _buildHydrationReminderCard(LiquidGlassThemeData theme) {
    return LiquidGlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.waterColor.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.water_drop_outlined, color: theme.waterColor, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Gentle hydration reminder',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: theme.textPrimary,
                  ),
                ),
                Text(
                  'Asha gently reminds you hourly to stay comfortable.',
                  style: TextStyle(fontSize: 11.5, color: theme.textSecondary),
                ),
              ],
            ),
          ),
          Switch(
            value: _waterEnabled,
            onChanged: _toggleWater,
            activeTrackColor: theme.waterColor.withValues(alpha: 0.6),
            activeThumbColor: theme.waterColor,
          ),
        ],
      ),
    );
  }

  // --- Replay Onboarding Button ---
  Widget _buildOnboardingReplayButton(LiquidGlassThemeData theme) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: () => setState(() => _showingOnboarding = true),
        icon: Icon(Icons.auto_awesome_rounded, color: theme.speakColor, size: 18),
        label: Text(
          'Replay Patient Setup Wizard',
          style: TextStyle(
            color: theme.textPrimary,
            fontWeight: FontWeight.w700,
            fontSize: 13.5,
          ),
        ),
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: theme.cardBorder),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
    );
  }
}

// --- Liquid Glass SOS Button with Press-and-Hold Animation ---
class _LiquidGlassSosButton extends StatefulWidget {
  const _LiquidGlassSosButton({
    required this.onTriggered,
    required this.theme,
  });

  final VoidCallback onTriggered;
  final LiquidGlassThemeData theme;

  @override
  State<_LiquidGlassSosButton> createState() => _LiquidGlassSosButtonState();
}

class _LiquidGlassSosButtonState extends State<_LiquidGlassSosButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  bool _holding = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed && _holding) {
        widget.onTriggered();
        _controller.reset();
        setState(() => _holding = false);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onLongPressStart(LongPressStartDetails _) {
    setState(() => _holding = true);
    _controller.forward(from: 0);
  }

  void _onLongPressEnd(LongPressEndDetails _) {
    if (_controller.status != AnimationStatus.completed) {
      _controller.reset();
    }
    setState(() => _holding = false);
  }

  @override
  Widget build(BuildContext context) {
    final sosColor = widget.theme.sosColor;

    return Semantics(
      label: 'Emergency SOS. Press and hold to activate.',
      button: true,
      child: GestureDetector(
        onLongPressStart: _onLongPressStart,
        onLongPressEnd: _onLongPressEnd,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            return Container(
              height: 74,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                boxShadow: [
                  BoxShadow(
                    color: sosColor.withValues(alpha: _holding ? 0.6 : 0.35),
                    blurRadius: _holding ? 28 : 16,
                    spreadRadius: _holding ? 2 : 0,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: Stack(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            sosColor.withValues(alpha: 0.9),
                            sosColor.withValues(alpha: 0.7),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: _holding ? Colors.white : Colors.white24,
                          width: _holding ? 2.0 : 1.0,
                        ),
                      ),
                    ),
                    if (_holding)
                      Positioned.fill(
                        child: LinearProgressIndicator(
                          value: _controller.value,
                          backgroundColor: Colors.transparent,
                          valueColor: const AlwaysStoppedAnimation<Color>(Colors.white38),
                        ),
                      ),
                    Center(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.emergency_rounded, color: Colors.white, size: 28),
                          const SizedBox(width: 12),
                          Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _holding ? 'Hold to confirm SOS…' : 'Need Help / Emergency SOS',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16.5,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 0.2,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _holding ? 'Releasing cancels request' : 'Press and hold for 1.5s to alert caregiver',
                                style: const TextStyle(color: Colors.white70, fontSize: 11.5),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

// --- Quick Phrases Card ---
class _PhraseCard extends StatelessWidget {
  const _PhraseCard({
    required this.phrases,
    required this.lastPhrase,
    required this.onSpeak,
    required this.theme,
  });

  final List<CalibratedPhrase> phrases;
  final CalibratedPhrase? lastPhrase;
  final Future<void> Function(CalibratedPhrase) onSpeak;
  final LiquidGlassThemeData theme;

  @override
  Widget build(BuildContext context) {
    return LiquidGlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.record_voice_over_rounded, color: theme.speakColor, size: 20),
              const SizedBox(width: 8),
              Text(
                'My Voice & Quick Phrases',
                style: TextStyle(
                  fontSize: 15.5,
                  fontWeight: FontWeight.w800,
                  color: theme.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            lastPhrase == null
                ? 'Trigger gestures or tap below to speak immediately.'
                : 'Last spoken: “${lastPhrase!.phrase}”',
            style: TextStyle(fontSize: 12.5, color: theme.textSecondary),
          ),
          const SizedBox(height: 12),
          if (phrases.isEmpty)
            Text(
              'A caregiver can calibrate and add phrases in the Caregiver tab.',
              style: TextStyle(fontSize: 12.5, color: theme.textSecondary),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: phrases
                  .map(
                    (phrase) => FilledButton.tonal(
                      onPressed: () => onSpeak(phrase),
                      style: FilledButton.styleFrom(
                        backgroundColor: theme.speakColor.withValues(alpha: 0.15),
                        foregroundColor: theme.textPrimary,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: Text(
                        phrase.phrase,
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                      ),
                    ),
                  )
                  .toList(),
            ),
        ],
      ),
    );
  }
}
