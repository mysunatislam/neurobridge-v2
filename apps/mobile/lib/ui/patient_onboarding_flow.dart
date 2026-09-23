import 'dart:async';
import 'package:fingerspeak_mobile/core/mobile_services.dart';
import 'package:fingerspeak_mobile/models/patient_access_method.dart';
import 'package:fingerspeak_mobile/models/personal_access_profile.dart';
import 'package:fingerspeak_mobile/services/voice_service.dart';
import 'package:fingerspeak_mobile/ui/effects/liquid_glass.dart';
import 'package:fingerspeak_mobile/ui/hand_calibration_page.dart';
import 'package:flutter/material.dart';

/// 5-Step Liquid Glass Patient Onboarding Flow matching the visual specification.
class PatientOnboardingFlow extends StatefulWidget {
  const PatientOnboardingFlow({
    required this.services,
    required this.onComplete,
    super.key,
  });

  final MobileServices services;
  final VoidCallback onComplete;

  @override
  State<PatientOnboardingFlow> createState() => _PatientOnboardingFlowState();
}

class _PatientOnboardingFlowState extends State<PatientOnboardingFlow>
    with SingleTickerProviderStateMixin {
  int _currentStep = 0; // 0 to 4
  final int _totalSteps = 5;

  // Step 2 State: Access Mode ('hand', 'face', 'adaptive')
  String _selectedAccessMethodMode = 'hand';

  // Step 3 State: Purpose Categories
  final Set<String> _selectedPurposes = {
    'Emergency & Pain',
    'Daily Needs & Food',
    'Family & Emotions',
  };

  // Step 4 State: Voice
  String _selectedVoice = 'female'; // 'female', 'male', 'caregiver'
  bool _isPlayingVoicePreview = false;

  // Animation controller for glowing aura in splash / complete
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);

    // Initialize access method from repository if available
    final saved = widget.services.patientAccessMethodRepository.load();
    if (saved == PatientAccessMethod.faceEyesAndHead) {
      _selectedAccessMethodMode = 'face';
    } else {
      _selectedAccessMethodMode = 'hand';
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _handleNext() async {
    if (_currentStep == 1) {
      // Save chosen access method
      if (_selectedAccessMethodMode == 'adaptive') {
        final profile = widget.services.accessProfileRepository.load() ??
            PersonalAccessProfile.defaultProfile();
        await widget.services.accessProfileRepository.save(
          profile.copyWith(primaryModality: AccessModality.singleSwitchScanning),
        );
        await widget.services.patientAccessMethodRepository
            .save(PatientAccessMethod.faceEyesAndHead);
      } else {
        await widget.services.patientAccessMethodRepository.save(
          _selectedAccessMethodMode == 'face'
              ? PatientAccessMethod.faceEyesAndHead
              : PatientAccessMethod.handGestures,
        );
      }
    } else if (_currentStep == 3) {
      // Configure chosen voice
      final prefs = widget.services.voice.preferences;
      if (_selectedVoice == 'caregiver') {
        await widget.services.voice.setPreferences(
          prefs.copyWith(
            phraseMode: PhraseVoiceMode.caregiverRecording,
            playbackPreference: PlaybackPreference.caregiverRecordingFirst,
          ),
        );
      } else if (_selectedVoice == 'male') {
        await widget.services.voice.setPreferences(
          prefs.copyWith(
            phraseMode: PhraseVoiceMode.asha,
            playbackPreference: PlaybackPreference.systemVoiceOnly,
            pitch: 0.82,
          ),
        );
      } else {
        // female
        await widget.services.voice.setPreferences(
          prefs.copyWith(
            phraseMode: PhraseVoiceMode.asha,
            playbackPreference: PlaybackPreference.systemVoiceOnly,
            pitch: 1.15,
          ),
        );
      }
    }

    if (_currentStep < _totalSteps - 1) {
      setState(() => _currentStep++);
    } else {
      widget.onComplete();
    }
  }

  void _handleBack() {
    if (_currentStep > 0) {
      setState(() => _currentStep--);
    }
  }

  Future<void> _toggleVoicePreview() async {
    if (_isPlayingVoicePreview) {
      setState(() => _isPlayingVoicePreview = false);
      return;
    }

    setState(() => _isPlayingVoicePreview = true);

    final previewText = switch (_selectedVoice) {
      'male' => 'Hello. I am Asha, your clear and dependable voice.',
      'caregiver' => 'Hello my dear, I am right here with you. Take your time.',
      _ => 'Hello! I am Asha, your warm companion and voice whenever you need me.',
    };

    unawaited(
      widget.services.voice.speakAsha(previewText, force: true).then((_) {
        if (mounted) {
          setState(() => _isPlayingVoicePreview = false);
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: LiquidGlassThemeController.isDarkNotifier,
      builder: (context, isDark, _) {
        final theme = LiquidGlassThemeData.current(context);

        return Scaffold(
          body: Container(
            decoration: BoxDecoration(gradient: theme.bgGradient),
            child: SafeArea(
              child: Column(
                children: [
                  _buildTopBar(theme),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 320),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      child: _buildCurrentStep(theme),
                    ),
                  ),
                  _buildBottomControls(theme),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTopBar(LiquidGlassThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          if (_currentStep > 0 && _currentStep < _totalSteps - 1)
            IconButton(
              icon: Icon(Icons.arrow_back_ios_rounded, color: theme.textPrimary, size: 20),
              onPressed: _handleBack,
            )
          else
            const SizedBox(width: 44),
          // Progress Dots
          Row(
            children: List.generate(_totalSteps, (index) {
              final isCurrent = index == _currentStep;
              final isDone = index < _currentStep;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                margin: const EdgeInsets.symmetric(horizontal: 4),
                width: isCurrent ? 24 : 8,
                height: 8,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  color: isCurrent
                      ? theme.speakColor
                      : isDone
                          ? theme.speakColor.withValues(alpha: 0.5)
                          : theme.textSecondary.withValues(alpha: 0.3),
                  boxShadow: isCurrent
                      ? [
                          BoxShadow(
                            color: theme.speakColor.withValues(alpha: 0.5),
                            blurRadius: 8,
                          ),
                        ]
                      : null,
                ),
              );
            }),
          ),
          // Theme Toggle Pill
          const ThemeToggleSwitch(),
        ],
      ),
    );
  }

  Widget _buildBottomControls(LiquidGlassThemeData theme) {
    if (_currentStep == 0) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
        child: SizedBox(
          width: double.infinity,
          height: 60,
          child: LiquidGlassHeroButton(
            icon: Icons.rocket_launch_rounded,
            title: 'Get Started',
            subtitle: 'Configure your personalized interface',
            accentColor: theme.speakColor,
            onTap: _handleNext,
          ),
        ),
      );
    }

    if (_currentStep == _totalSteps - 1) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
        child: SizedBox(
          width: double.infinity,
          height: 60,
          child: LiquidGlassHeroButton(
            icon: Icons.check_circle_rounded,
            title: 'Enter Patient Dashboard',
            subtitle: 'Start communicating with Asha now',
            accentColor: theme.restColor,
            onTap: widget.onComplete,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      child: Row(
        children: [
          TextButton(
            onPressed: widget.onComplete,
            child: Text(
              'Skip',
              style: TextStyle(
                color: theme.textSecondary,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const Spacer(),
          ElevatedButton(
            onPressed: _handleNext,
            style: ElevatedButton.styleFrom(
              backgroundColor: theme.speakColor,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              elevation: 4,
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Continue', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                SizedBox(width: 8),
                Icon(Icons.arrow_forward_rounded, size: 18),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCurrentStep(LiquidGlassThemeData theme) {
    switch (_currentStep) {
      case 0:
        return _buildStep1Splash(theme);
      case 1:
        return _buildStep2AccessMode(theme);
      case 2:
        return _buildStep3Purpose(theme);
      case 3:
        return _buildStep4Voice(theme);
      case 4:
        return _buildStep5Complete(theme);
      default:
        return const SizedBox.shrink();
    }
  }

  // --- Step 1: Splash / Welcome ---
  Widget _buildStep1Splash(LiquidGlassThemeData theme) {
    return SingleChildScrollView(
      key: const ValueKey('step_1_splash'),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Column(
        children: [
          const SizedBox(height: 20),
          // Animated Glowing Halo Aura with Avatar
          AnimatedBuilder(
            animation: _pulseController,
            builder: (context, child) {
              final scale = 1.0 + (_pulseController.value * 0.08);
              return Stack(
                alignment: Alignment.center,
                children: [
                  Transform.scale(
                    scale: scale,
                    child: Container(
                      width: 170,
                      height: 170,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: theme.speakColor.withValues(alpha: 0.35 * _pulseController.value),
                            blurRadius: 40,
                            spreadRadius: 8,
                          ),
                          BoxShadow(
                            color: theme.waterColor.withValues(alpha: 0.25 * _pulseController.value),
                            blurRadius: 60,
                            spreadRadius: 15,
                          ),
                        ],
                      ),
                    ),
                  ),
                  Container(
                    width: 130,
                    height: 130,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: theme.speakColor.withValues(alpha: 0.8),
                        width: 3.5,
                      ),
                      image: const DecorationImage(
                        image: AssetImage('assets/images/asha_waving.png'),
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 32),
          Text(
            'NeuroBridge Asha',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w900,
              color: theme.textPrimary,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Empathetic, Liquid Glass Communication\nTailored To How You Move.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15.5,
              height: 1.4,
              color: theme.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 28),
          LiquidGlassCard(
            padding: const EdgeInsets.all(18),
            customBorderColor: theme.speakColor.withValues(alpha: 0.4),
            child: Column(
              children: [
                _buildFeatureBullet(
                  theme,
                  Icons.blur_on_rounded,
                  'Liquid Glass Interface',
                  'Translucent depth, large high-contrast targets, and smooth haptic feedback.',
                ),
                const SizedBox(height: 14),
                _buildFeatureBullet(
                  theme,
                  Icons.offline_bolt_rounded,
                  'Zero-Latency On-Device CV',
                  'Instant gesture and facial tracking processed locally with total privacy.',
                ),
                const SizedBox(height: 14),
                _buildFeatureBullet(
                  theme,
                  Icons.record_voice_over_rounded,
                  'Empathetic Voice & SOS',
                  'Speaks with warm synthetic cadence or authentic caregiver recorded audio.',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFeatureBullet(
    LiquidGlassThemeData theme,
    IconData icon,
    String title,
    String desc,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: theme.speakColor.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: theme.speakColor, size: 20),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                  color: theme.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                desc,
                style: TextStyle(
                  fontSize: 12.5,
                  color: theme.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // --- Step 2: Access Mode Selection ---
  Widget _buildStep2AccessMode(LiquidGlassThemeData theme) {
    return ListView(
      key: const ValueKey('step_2_access'),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      children: [
        Text(
          'How do you want to interact?',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w800,
            color: theme.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Choose the interaction mode best suited to your comfort. You can switch anytime.',
          style: TextStyle(fontSize: 14, color: theme.textSecondary),
        ),
        const SizedBox(height: 20),
        _buildModeOption(
          theme: theme,
          mode: 'hand',
          title: 'Hand & Finger Gestures',
          subtitle: 'MediaPipe 21-keypoint DTW gesture classifier. Fast, high-accuracy sign communication.',
          icon: Icons.pan_tool_alt_rounded,
          color: theme.speakColor,
        ),
        const SizedBox(height: 16),
        _buildModeOption(
          theme: theme,
          mode: 'face',
          title: 'Face, Eye & Head Tracking',
          subtitle: 'Dwell-based eye gaze, intentional blinks, smile triggers, and head pose scanning.',
          icon: Icons.remove_red_eye_rounded,
          color: theme.waterColor,
        ),
        const SizedBox(height: 16),
        _buildModeOption(
          theme: theme,
          mode: 'adaptive',
          title: 'Adaptive / Single-Switch',
          subtitle: 'Automated linear scanning interface for patients with severe mobility constraints.',
          icon: Icons.accessibility_new_rounded,
          color: theme.toiletColor,
        ),
        if (_selectedAccessMethodMode == 'hand') ...[
          const SizedBox(height: 18),
          LiquidGlassCard(
            padding: const EdgeInsets.all(16),
            customBorderColor: theme.speakColor.withValues(alpha: 0.5),
            customGlowColor: theme.speakColor.withValues(alpha: 0.25),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.tune_rounded, color: theme.speakColor, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      'Learn Your Gestures (Calibration)',
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w800,
                        color: theme.textPrimary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Record custom hand gesture samples with the 21-landmark DTW engine for high-accuracy signing.',
                  style: TextStyle(fontSize: 12, color: theme.textSecondary),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => HandCalibrationPage(services: widget.services),
                        ),
                      );
                    },
                    icon: const Icon(Icons.play_circle_outline_rounded),
                    label: const Text('Launch Hand Calibration Studio'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: theme.speakColor,
                      side: BorderSide(color: theme.speakColor),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildModeOption({
    required LiquidGlassThemeData theme,
    required String mode,
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
  }) {
    final isSelected = _selectedAccessMethodMode == mode;

    return LiquidGlassCard(
      onTap: () => setState(() => _selectedAccessMethodMode = mode),
      borderRadius: 22,
      borderWidth: isSelected ? 2.0 : 1.0,
      customBorderColor: isSelected ? color : theme.cardBorder,
      customGlowColor: isSelected ? color.withValues(alpha: 0.35) : theme.glowShadow,
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: color.withValues(alpha: 0.4)),
            ),
            child: Icon(icon, color: color, size: 28),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 16.5,
                    fontWeight: FontWeight.w800,
                    color: theme.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: theme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(
            isSelected ? Icons.check_circle_rounded : Icons.radio_button_off_rounded,
            color: isSelected ? color : theme.textSecondary.withValues(alpha: 0.5),
            size: 24,
          ),
        ],
      ),
    );
  }

  // --- Step 3: Purpose Selection (6 categories) ---
  Widget _buildStep3Purpose(LiquidGlassThemeData theme) {
    final categories = [
      {'name': 'Emergency & Pain', 'desc': 'SOS alert, nurse call, acute pain', 'icon': Icons.emergency_rounded, 'color': theme.sosColor},
      {'name': 'Daily Needs & Food', 'desc': 'Water, meals, feeding assistance', 'icon': Icons.restaurant_rounded, 'color': theme.foodColor},
      {'name': 'Family & Emotions', 'desc': 'Call family, greetings, affection', 'icon': Icons.favorite_rounded, 'color': theme.familyColor},
      {'name': 'Medical & Vitals', 'desc': 'Medication time, breathing check', 'icon': Icons.medical_services_rounded, 'color': theme.waterColor},
      {'name': 'Comfort & Position', 'desc': 'Bed tilt, blanket, light adjust', 'icon': Icons.bed_rounded, 'color': theme.restColor},
      {'name': 'Media & Entertainment', 'desc': 'Music, TV, audiobook, chat', 'icon': Icons.sports_esports_rounded, 'color': theme.entertainmentColor},
    ];

    return ListView(
      key: const ValueKey('step_3_purpose'),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      children: [
        Text(
          'What do you communicate most?',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w800,
            color: theme.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Select your primary priorities to personalize your daily dashboard.',
          style: TextStyle(fontSize: 14, color: theme.textSecondary),
        ),
        const SizedBox(height: 18),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 14,
            crossAxisSpacing: 14,
            childAspectRatio: 0.95,
          ),
          itemCount: categories.length,
          itemBuilder: (context, index) {
            final cat = categories[index];
            final name = cat['name'] as String;
            final desc = cat['desc'] as String;
            final icon = cat['icon'] as IconData;
            final color = cat['color'] as Color;
            final isSelected = _selectedPurposes.contains(name);

            return LiquidGlassCard(
              onTap: () {
                setState(() {
                  if (isSelected) {
                    _selectedPurposes.remove(name);
                  } else {
                    _selectedPurposes.add(name);
                  }
                });
              },
              borderRadius: 20,
              padding: const EdgeInsets.all(14),
              borderWidth: isSelected ? 2.0 : 1.0,
              customBorderColor: isSelected ? color : theme.cardBorder,
              customGlowColor: isSelected ? color.withValues(alpha: 0.3) : theme.glowShadow,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(icon, color: color, size: 22),
                      ),
                      Icon(
                        isSelected ? Icons.check_circle_rounded : Icons.circle_outlined,
                        color: isSelected ? color : theme.textSecondary.withValues(alpha: 0.4),
                        size: 20,
                      ),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    name,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w800,
                      color: theme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    desc,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: theme.textSecondary,
                    ),
                    maxLines: 2,
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

  // --- Step 4: Choose Voice ---
  Widget _buildStep4Voice(LiquidGlassThemeData theme) {
    return ListView(
      key: const ValueKey('step_4_voice'),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      children: [
        Text(
          'Choose Asha’s Spoken Voice',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w800,
            color: theme.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Select the vocal persona that feels most natural when your gestures speak.',
          style: TextStyle(fontSize: 14, color: theme.textSecondary),
        ),
        const SizedBox(height: 20),
        _buildVoiceCard(
          theme: theme,
          id: 'female',
          title: 'Female Voice (Asha Warm)',
          subtitle: 'Soothing, gentle female voice with empathetic cadence.',
          icon: Icons.record_voice_over_rounded,
          color: theme.familyColor,
        ),
        const SizedBox(height: 14),
        _buildVoiceCard(
          theme: theme,
          id: 'male',
          title: 'Male Voice (Asha Deep)',
          subtitle: 'Clear, steady male voice with resonant tone.',
          icon: Icons.spatial_audio_rounded,
          color: theme.speakColor,
        ),
        const SizedBox(height: 14),
        _buildVoiceCard(
          theme: theme,
          id: 'caregiver',
          title: 'Caregiver Recorded Voice',
          subtitle: 'Plays authentic audio recorded by your personal caregiver.',
          icon: Icons.mic_external_on_rounded,
          color: theme.foodColor,
          badge: 'Personalized',
        ),
        const SizedBox(height: 22),
        // Soundwave preview section
        LiquidGlassCard(
          padding: const EdgeInsets.all(18),
          customBorderColor: theme.speakColor.withValues(alpha: 0.4),
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: theme.speakColor.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      _isPlayingVoicePreview ? Icons.volume_up_rounded : Icons.volume_mute_rounded,
                      color: theme.speakColor,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Voice Audio Preview',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: theme.textPrimary,
                          ),
                        ),
                        Text(
                          _isPlayingVoicePreview ? 'Speaking sample phrase…' : 'Tap play to listen',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: theme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton.filled(
                    onPressed: _toggleVoicePreview,
                    icon: Icon(
                      _isPlayingVoicePreview ? Icons.stop_rounded : Icons.play_arrow_rounded,
                    ),
                    style: IconButton.styleFrom(
                      backgroundColor: theme.speakColor,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              AudioWaveformVisualizer(
                isActive: _isPlayingVoicePreview,
                color: theme.speakColor,
                barCount: 22,
                height: 42,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildVoiceCard({
    required LiquidGlassThemeData theme,
    required String id,
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    String? badge,
  }) {
    final isSelected = _selectedVoice == id;

    return LiquidGlassCard(
      onTap: () => setState(() => _selectedVoice = id),
      borderRadius: 20,
      borderWidth: isSelected ? 2.0 : 1.0,
      customBorderColor: isSelected ? color : theme.cardBorder,
      customGlowColor: isSelected ? color.withValues(alpha: 0.3) : theme.glowShadow,
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: color, size: 26),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style: TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w800,
                          color: theme.textPrimary,
                        ),
                      ),
                    ),
                    if (badge != null) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          badge,
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                            color: color,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          Icon(
            isSelected ? Icons.check_circle_rounded : Icons.radio_button_off_rounded,
            color: isSelected ? color : theme.textSecondary.withValues(alpha: 0.5),
            size: 22,
          ),
        ],
      ),
    );
  }

  // --- Step 5: Onboarding Complete ---
  Widget _buildStep5Complete(LiquidGlassThemeData theme) {
    return SingleChildScrollView(
      key: const ValueKey('step_5_complete'),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Column(
        children: [
          const SizedBox(height: 24),
          AnimatedBuilder(
            animation: _pulseController,
            builder: (context, _) {
              return Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: 160,
                    height: 160,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: theme.restColor.withValues(alpha: 0.4),
                          blurRadius: 50,
                          spreadRadius: 10,
                        ),
                      ],
                    ),
                  ),
                  Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: theme.restColor, width: 3.5),
                      image: const DecorationImage(
                        image: AssetImage('assets/images/asha_heart.png'),
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 0,
                    right: 6,
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: const BoxDecoration(
                        color: Color(0xFF10B981),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.favorite, color: Colors.white, size: 20),
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 28),
          Text(
            'You’re All Set!',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w900,
              color: theme.textPrimary,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Asha is fully configured to your preferred access mode and voice persona. Your bedside wheelchair display and caregiver sync are ready.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              height: 1.4,
              color: theme.textSecondary,
            ),
          ),
          const SizedBox(height: 24),
          LiquidGlassCard(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                _buildSummaryRow(
                  theme,
                  Icons.accessibility_new_rounded,
                  'Interaction Mode',
                  _selectedAccessMethodMode == 'hand'
                      ? 'Hand & Finger Gestures'
                      : _selectedAccessMethodMode == 'face'
                          ? 'Face, Eye & Head'
                          : 'Adaptive Single-Switch',
                ),
                const Divider(height: 20),
                _buildSummaryRow(
                  theme,
                  Icons.record_voice_over_rounded,
                  'Voice Persona',
                  _selectedVoice == 'male'
                      ? 'Male (Asha Deep)'
                      : _selectedVoice == 'caregiver'
                          ? 'Caregiver Voice'
                          : 'Female (Asha Warm)',
                ),
                const Divider(height: 20),
                _buildSummaryRow(
                  theme,
                  Icons.category_rounded,
                  'Priority Topics',
                  '${_selectedPurposes.length} Categories Activated',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryRow(LiquidGlassThemeData theme, IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, color: theme.speakColor, size: 20),
        const SizedBox(width: 12),
        Text(
          label,
          style: TextStyle(
            fontSize: 13.5,
            color: theme.textSecondary,
            fontWeight: FontWeight.w500,
          ),
        ),
        const Spacer(),
        Text(
          value,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
            color: theme.textPrimary,
          ),
        ),
      ],
    );
  }
}
