// ability_assessment_page.dart
// First-run interactive accessibility assessment wizard for NeuroBridge.

import 'package:flutter/material.dart';
import '../core/mobile_services.dart';
import '../models/patient_access_method.dart';
import '../models/personal_access_profile.dart';
import '../services/access_assessment_service.dart';

class AbilityAssessmentPage extends StatefulWidget {
  const AbilityAssessmentPage({
    super.key,
    required this.services,
    this.initialProfile,
    this.onCompleted,
  });

  final MobileServices services;
  final PersonalAccessProfile? initialProfile;
  final VoidCallback? onCompleted;

  @override
  State<AbilityAssessmentPage> createState() => _AbilityAssessmentPageState();
}

class _AbilityAssessmentPageState extends State<AbilityAssessmentPage> {
  final _service = const AccessAssessmentService();
  int _currentStep = 0;
  bool _caregiverAssisted = false;
  String _patientName = 'Patient';
  int? _patientAge;
  String? _conditionNotes;
  String? _caregiverName;
  String? _caregiverContact;

  final Map<BodyPart, CapabilityGrade> _capabilities = {
    BodyPart.rightHand: CapabilityGrade.good,
    BodyPart.leftHand: CapabilityGrade.limited,
    BodyPart.wrist: CapabilityGrade.moderate,
    BodyPart.head: CapabilityGrade.good,
    BodyPart.facialMuscles: CapabilityGrade.good,
    BodyPart.eyes: CapabilityGrade.good,
    BodyPart.blink: CapabilityGrade.excellent,
    BodyPart.voice: CapabilityGrade.unavailable,
    BodyPart.touchScreen: CapabilityGrade.limited,
    BodyPart.singleSwitch: CapabilityGrade.good,
  };

  AssessmentRecommendation? _recommendation;

  @override
  void initState() {
    super.initState();
    if (widget.initialProfile != null) {
      _patientName = widget.initialProfile!.patientName;
      _patientAge = widget.initialProfile!.patientAge;
      _conditionNotes = widget.initialProfile!.conditionNotes;
      _caregiverName = widget.initialProfile!.caregiverName;
      _caregiverContact = widget.initialProfile!.caregiverContact;
      _caregiverAssisted = widget.initialProfile!.caregiverAssistedSetup;
      _capabilities.addAll(widget.initialProfile!.capabilities);
    }
  }

  void _nextStep() {
    if (_currentStep < 4) {
      setState(() => _currentStep++);
    } else {
      setState(() {
        _recommendation = _service.evaluate(_capabilities);
        _currentStep = 5;
      });
    }
  }

  void _prevStep() {
    if (_currentStep > 0) {
      setState(() => _currentStep--);
    }
  }

  Future<void> _saveAndFinish() async {
    final rec = _recommendation ?? _service.evaluate(_capabilities);
    final profile = PersonalAccessProfile(
      id: widget.initialProfile?.id ?? 'profile_',
      patientName: _patientName,
      patientAge: _patientAge,
      conditionNotes: _conditionNotes,
      caregiverName: _caregiverName,
      caregiverContact: _caregiverContact,
      capabilities: _capabilities,
      primaryModality: rec.primaryModality,
      backupModality: rec.backupModality,
      sensitivity: rec.recommendedSensitivity,
      caregiverAssistedSetup: _caregiverAssisted,
    );

    await widget.services.accessProfileRepository.save(profile);
    
    await widget.services.patientAccessMethodRepository.save(PatientAccessMethod.handGestures);

    if (!mounted) return;

    if (widget.onCompleted != null) {
      widget.onCompleted!();
    } else {
      Navigator.of(context).pop(profile);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        foregroundColor: Colors.white,
        title: const Text('Access Ability Assessment', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
        actions: [
          Row(
            children: [
              const Text('Assisted', style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
              Switch(
                value: _caregiverAssisted,
                activeTrackColor: const Color(0xFF14B8A6),
                onChanged: (v) => setState(() => _caregiverAssisted = v),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            LinearProgressIndicator(
              value: (_currentStep + 1) / 6,
              backgroundColor: const Color(0xFF334155),
              valueColor: const AlwaysStoppedAnimation(Color(0xFF14B8A6)),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: _buildCurrentStep(),
              ),
            ),
            _buildBottomNav(),
          ],
        ),
      ),
    );
  }

  Widget _buildCurrentStep() {
    switch (_currentStep) {
      case 0: return _buildIntroStep();
      case 1: return _buildHandsStep();
      case 2: return _buildHeadStep();
      case 3: return _buildFaceStep();
      case 4: return _buildEyesStep();
      case 5: return _buildSummaryStep();
      default: return const SizedBox.shrink();
    }
  }

  Widget _buildIntroStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF134E4A),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF2DD4BF)),
          ),
          child: const Row(
            children: [
              Icon(Icons.accessibility_new, color: Color(0xFF2DD4BF), size: 36),
              SizedBox(width: 14),
              Expanded(
                child: Text(
                  'NeuroBridge adapts around your voluntary physical abilities.',
                  style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const Text('Patient Name / Identifier', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13)),
        const SizedBox(height: 6),
        TextFormField(
          initialValue: _patientName == 'Patient' ? '' : _patientName,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'e.g. Asha Patient',
            hintStyle: const TextStyle(color: Color(0xFF64748B)),
            filled: true,
            fillColor: const Color(0xFF1E293B),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
          ),
          onChanged: (v) => _patientName = v.trim().isEmpty ? 'Patient' : v.trim(),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              flex: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Age (optional)', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13)),
                  const SizedBox(height: 6),
                  TextFormField(
                    initialValue: _patientAge?.toString() ?? '',
                    keyboardType: TextInputType.number,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'e.g. 58',
                      hintStyle: const TextStyle(color: Color(0xFF64748B)),
                      filled: true,
                      fillColor: const Color(0xFF1E293B),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    ),
                    onChanged: (v) => _patientAge = int.tryParse(v.trim()),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              flex: 5,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Condition / Support Notes', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13)),
                  const SizedBox(height: 6),
                  TextFormField(
                    initialValue: _conditionNotes ?? '',
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'e.g. ALS, Stroke, Parkinson’s',
                      hintStyle: const TextStyle(color: Color(0xFF64748B)),
                      filled: true,
                      fillColor: const Color(0xFF1E293B),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    ),
                    onChanged: (v) => _conditionNotes = v.trim().isEmpty ? null : v.trim(),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Caregiver Name', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13)),
                  const SizedBox(height: 6),
                  TextFormField(
                    initialValue: _caregiverName ?? '',
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'e.g. Sarah',
                      hintStyle: const TextStyle(color: Color(0xFF64748B)),
                      filled: true,
                      fillColor: const Color(0xFF1E293B),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    ),
                    onChanged: (v) => _caregiverName = v.trim().isEmpty ? null : v.trim(),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Caregiver Contact / Phone', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13)),
                  const SizedBox(height: 6),
                  TextFormField(
                    initialValue: _caregiverContact ?? '',
                    keyboardType: TextInputType.phone,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'e.g. +1 555-0199',
                      hintStyle: const TextStyle(color: Color(0xFF64748B)),
                      filled: true,
                      fillColor: const Color(0xFF1E293B),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    ),
                    onChanged: (v) => _caregiverContact = v.trim().isEmpty ? null : v.trim(),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        const Text(
          'We will evaluate your voluntary control across hands, head, face, and eyes to configure your easiest communication mode.',
          style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 14, height: 1.5),
        ),
      ],
    );
  }

  Widget _buildHandsStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepHeader('Step 1 of 4: Hands & Fingers', Icons.pan_tool_alt, 'Can you make voluntary finger, pinch, or wrist movements?'),
        const SizedBox(height: 18),
        _gradeSelector('Right Hand / Fingers', BodyPart.rightHand),
        _gradeSelector('Left Hand / Fingers', BodyPart.leftHand),
        _gradeSelector('Wrist Mobility', BodyPart.wrist),
        _gradeSelector('Direct Touchscreen Tapping', BodyPart.touchScreen),
      ],
    );
  }

  Widget _buildHeadStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepHeader('Step 2 of 4: Head & Neck', Icons.face, 'Can you move or tilt your head voluntarily?'),
        const SizedBox(height: 18),
        _gradeSelector('Head Movement & Nodding', BodyPart.head),
      ],
    );
  }

  Widget _buildFaceStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepHeader('Step 3 of 4: Facial Expressions', Icons.sentiment_very_satisfied, 'Can you produce intentional facial movements (smile, eyebrow raise, mouth open)?'),
        const SizedBox(height: 18),
        _gradeSelector('Facial Muscle Control', BodyPart.facialMuscles),
      ],
    );
  }

  Widget _buildEyesStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _stepHeader('Step 4 of 4: Eyes & Blinking', Icons.remove_red_eye, 'Can you control your eye gaze or blink voluntarily?'),
        const SizedBox(height: 18),
        _gradeSelector('Voluntary Blink Control', BodyPart.blink),
        _gradeSelector('Eye Gaze & Fixation', BodyPart.eyes),
        _gradeSelector('Single-Switch / Any 1 Voluntary Movement', BodyPart.singleSwitch),
      ],
    );
  }

  Widget _buildSummaryStep() {
    final rec = _recommendation ?? _service.evaluate(_capabilities);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF134E4A),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF2DD4BF)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.auto_awesome, color: Color(0xFF2DD4BF)),
                  SizedBox(width: 8),
                  Text('Recommended Access Method', style: TextStyle(color: Color(0xFF2DD4BF), fontWeight: FontWeight.bold, fontSize: 16)),
                ],
              ),
              const SizedBox(height: 10),
              Text(rec.primaryModality.title, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(rec.reasoning, style: const TextStyle(color: Color(0xFFCCFBF1), fontSize: 13, height: 1.4)),
              if (rec.backupModality != null) ...[
                const SizedBox(height: 10),
                Text('Backup Input: ${rec.backupModality!.title}', style: const TextStyle(color: Color(0xFF99F6E4), fontSize: 13, fontWeight: FontWeight.w600)),
              ],
              if (rec.autoFacialCalibrationTriggered) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF59E0B).withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFF59E0B)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.face_retouching_natural_rounded, color: Color(0xFFFBBF24), size: 22),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Hand/Finger score is below 50%. Auto Facial Calibration Mode will turn on next.',
                          style: TextStyle(color: Color(0xFFFEF3C7), fontSize: 12.5, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 24),
        const Text('Interaction Capability Scores', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        ...rec.capabilityScores.entries.map((e) => _scoreRow(e.key, e.value)),
      ],
    );
  }

  Widget _stepHeader(String title, IconData icon, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: const Color(0xFF2DD4BF), size: 24),
            const SizedBox(width: 8),
            Text(title, style: const TextStyle(color: Color(0xFF2DD4BF), fontSize: 14, fontWeight: FontWeight.bold)),
          ],
        ),
        const SizedBox(height: 6),
        Text(subtitle, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600, height: 1.3)),
      ],
    );
  }

  Widget _gradeSelector(String title, BodyPart part) {
    final current = _capabilities[part] ?? CapabilityGrade.unavailable;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: CapabilityGrade.values.map((grade) {
                final isSel = current == grade;
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(grade.label, style: TextStyle(fontSize: 11, color: isSel ? Colors.black : const Color(0xFF94A3B8))),
                    selected: isSel,
                    selectedColor: const Color(0xFF2DD4BF),
                    backgroundColor: const Color(0xFF0F172A),
                    onSelected: (selected) {
                      if (selected) setState(() => _capabilities[part] = grade);
                    },
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _scoreRow(String label, int score) {
    final color = score >= 70 ? const Color(0xFF2DD4BF) : (score >= 40 ? const Color(0xFFFBBF24) : const Color(0xFF94A3B8));
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          SizedBox(width: 140, child: Text(label, style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 13))),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: score / 100,
                minHeight: 8,
                backgroundColor: const Color(0xFF334155),
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text('$score%', style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _buildBottomNav() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        color: Color(0xFF1E293B),
        border: Border(top: BorderSide(color: Color(0xFF334155))),
      ),
      child: Row(
        children: [
          if (_currentStep > 0)
            OutlinedButton(
              onPressed: _prevStep,
              style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF94A3B8)),
              child: const Text('Back'),
            ),
          const Spacer(),
          ElevatedButton(
            onPressed: _currentStep == 5 ? _saveAndFinish : _nextStep,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2DD4BF),
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
            child: Text(_currentStep == 5 ? 'Apply Profile & Start' : 'Next Step', style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}
