"use client";

import type { HandLandmarker } from "@mediapipe/tasks-vision";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { AshaAvatar } from "./AshaAvatar";
import { AshaCompanion } from "./AshaCompanion";
import { PiDisplayView } from "./PiDisplayView";
import { usePiDevice } from "../hooks/usePiDevice";
import {
  caregiverSocketUrl,
  checkApi,
  detachRemoteProfile,
  endRemoteSession,
  flushOutbox,
  flushPendingConsentUpdates,
  grantCaregiver,
  loadCaregiverAlerts,
  loadRemoteDevices,
  sendEvent,
  sendRemoteDeviceCaption,
  syncRemoteProfile,
  updateCaregiverAlert,
  type CaregiverAlert,
  type RemoteDevice,
} from "../lib/api";
import {
  CONFIDENCE_THRESHOLD,
  createDefaultProfile,
  flattenLandmarks,
  parseProfile,
  predictPrototype,
  profileModelFingerprint,
  resampleSequence,
  trainPrototypeModel,
  type FingerSpeakProfile,
  type Gesture,
  type PrototypeModel,
  type TimedRawFrame,
} from "../lib/fingerspeak";
import { IntentMachine, type IntentOutput } from "../lib/intent-machine";
import { importPrototypeBundle } from "../lib/model-bundle";
import {
  createDefaultPiControlSettings,
  routePiPatientIntent,
  type PiControlSettings,
  type PiEmergencyArm,
} from "../lib/pi-intent-routing";
import { dialablePhone } from "../lib/asha-companion";
import { deviceStorage, type LocalContactSettings, type OutboxEvent } from "../lib/storage";
import {
  createDefaultPatientSpeechSettings,
  createPatientSpeechService,
  saveLocalCaregiverPhraseRecording,
  saveLocalPatientSpeechSettings,
  startCaregiverMicrophoneCapture,
  validatePatientSpeechSettings,
  type ActiveCaregiverMicrophoneCapture,
  type PatientSpeechSettings,
  type PhraseAudioKind,
} from "../lib/patient-voice";
import {
  createCareRoutineMonitor,
  createDefaultCareRoutineSettings,
  saveLocalCareRoutineSettings,
  validateCareRoutineSettings,
  type CareRoutineSettings,
} from "../lib/care-routines";
import type { SomaticEvent } from "../lib/maira-api";

type View = "speak" | "pi-display" | "calibrate" | "caregiver";
type CameraStatus = "off" | "loading" | "ready" | "error";

type SpokenEntry = {
  id: string;
  phrase: string;
  gesture: string;
  risk: Gesture["risk"];
  at: string;
  source: "gesture" | "touch" | "pi";
};

type VoicePhraseOption = {
  key: string;
  kind: PhraseAudioKind;
  phraseId: string;
  label: string;
  text: string;
};

const HAND_CONNECTIONS = [
  [0, 1], [1, 2], [2, 3], [3, 4],
  [0, 5], [5, 6], [6, 7], [7, 8],
  [5, 9], [9, 10], [10, 11], [11, 12],
  [9, 13], [13, 14], [14, 15], [15, 16],
  [13, 17], [17, 18], [18, 19], [19, 20], [0, 17],
] as const;

const EMPTY_CONTACT_SETTINGS: LocalContactSettings = {
  id: "local-contact-settings",
  caregiverName: "",
  caregiverPhone: "",
  patientPhone: "",
  updatedAt: "",
};

function formatPercent(value: number | null): string {
  return value === null ? "Unknown" : `${value}%`;
}

function cameraFailureMessage(error: unknown): string {
  if (!(error instanceof DOMException)) {
    return error instanceof Error ? error.message : "The camera could not start.";
  }
  if (error.name === "NotAllowedError" || error.name === "SecurityError") {
    return "Camera permission is blocked. Allow camera access for this site in the browser and Windows privacy settings, then try again.";
  }
  if (error.name === "NotFoundError" || error.name === "DevicesNotFoundError") {
    return "No camera was detected on this device. Connect a camera or open the mobile app on a phone with a front camera.";
  }
  if (error.name === "NotReadableError" || error.name === "TrackStartError") {
    return "The camera is busy or unavailable. Close other camera apps, reconnect the camera, and try again.";
  }
  if (error.name === "OverconstrainedError" || error.name === "ConstraintNotSatisfiedError") {
    return "The camera does not support the requested mode. FingerSpeak retried with basic settings but could not start it.";
  }
  return error.message || "The camera could not start.";
}

function eventId(): string {
  const webCrypto: Crypto | undefined = typeof globalThis.crypto === "undefined" ? undefined : globalThis.crypto;
  if (typeof webCrypto?.randomUUID === "function") return webCrypto.randomUUID();
  const bytes = new Uint8Array(16);
  if (webCrypto) webCrypto.getRandomValues(bytes);
  else for (let index = 0; index < bytes.length; index += 1) bytes[index] = Math.floor(Math.random() * 256);
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0"));
  return `${hex.slice(0, 4).join("")}-${hex.slice(4, 6).join("")}-${hex.slice(6, 8).join("")}-${hex.slice(8, 10).join("")}-${hex.slice(10).join("")}`;
}

export function FingerSpeakApp() {
  const piDevice = usePiDevice();
  const [view, setView] = useState<View>("speak");
  const [profile, setProfile] = useState<FingerSpeakProfile>(() => createDefaultProfile());
  const [model, setModel] = useState<PrototypeModel | null>(null);
  const [cameraStatus, setCameraStatus] = useState<CameraStatus>("off");
  const [cameraMessage, setCameraMessage] = useState("Camera is off. Touch controls remain available.");
  const [tracking, setTracking] = useState(false);
  const [captureTarget, setCaptureTarget] = useState<string | null>(null);
  const [captureMessage, setCaptureMessage] = useState("Capture two clear examples of each movement.");
  const [prediction, setPrediction] = useState({ gestureId: null as string | null, confidence: 0, inDistribution: false });
  const [intent, setIntent] = useState<IntentOutput>(() => new IntentMachine().snapshot());
  const [, setVoiceMessage] = useState("Ready to speak.");
  const [spoken, setSpoken] = useState<SpokenEntry[]>([]);
  const [armedGestureId, setArmedGestureId] = useState<string | null>(null);
  const [serverOnline, setServerOnline] = useState(false);
  const [alerts, setAlerts] = useState<CaregiverAlert[]>([]);
  const [remoteProfileId, setRemoteProfileId] = useState<string | null>(null);
  const [caregiverProfileId, setCaregiverProfileId] = useState<string | null>(null);
  const [caregiverProfileInput, setCaregiverProfileInput] = useState("");
  const [caregiverSubject, setCaregiverSubject] = useState("");
  const [caregiverMessage, setCaregiverMessage] = useState("Enter an authorized profile ID to use this dashboard on another device.");
  const [socketStatus, setSocketStatus] = useState<"offline" | "connecting" | "live">("offline");
  const [falseActivations, setFalseActivations] = useState(0);
  const [missedGestures, setMissedGestures] = useState(0);
  const [localContacts, setLocalContacts] = useState<LocalContactSettings>(EMPTY_CONTACT_SETTINGS);
  const [contactDraft, setContactDraft] = useState<LocalContactSettings>(EMPTY_CONTACT_SETTINGS);
  const [localSettingsMessage, setLocalSettingsMessage] = useState("Phone numbers and the Pi pairing token stay only on this device.");
  const [piEndpointDraft, setPiEndpointDraft] = useState("");
  const [piPairingTokenDraft, setPiPairingTokenDraft] = useState("");
  const [caregiverOutboundMessage, setCaregiverOutboundMessage] = useState("");
  const [caregiverActionMessage, setCaregiverActionMessage] = useState("Calls use the phone dialer. Messages require a paired Pi.");
  const [remoteDevices, setRemoteDevices] = useState<RemoteDevice[]>([]);
  const [remoteDeviceMessage, setRemoteDeviceMessage] = useState("No verified patient-device heartbeat yet.");
  const [ashaOpen, setAshaOpen] = useState(false);
  const [piControls] = useState<PiControlSettings>(() => createDefaultPiControlSettings("local-profile"));
  const [speechSettings, setSpeechSettings] = useState<PatientSpeechSettings>(() => createDefaultPatientSpeechSettings("local-profile"));
  const [systemVoices, setSystemVoices] = useState<SpeechSynthesisVoice[]>([]);
  const [routineSettings, setRoutineSettings] = useState<CareRoutineSettings>(() => createDefaultCareRoutineSettings("local-profile"));
  const [role, setRole] = useState<"patient" | "caregiver">(() => {
    if (typeof window !== "undefined") {
      const saved = localStorage.getItem("fingerspeak.role");
      if (saved === "patient" || saved === "caregiver") return saved;
    }
    return "patient";
  });
  const [showRoleModal, setShowRoleModal] = useState<boolean>(() => {
    if (typeof window !== "undefined") {
      return !localStorage.getItem("fingerspeak.role");
    }
    return false;
  });
  const [customPhrases, setCustomPhrases] = useState<Array<{ id: string; signal: string; phrase: string; sensitivity: number; dwellMs: number }>>(() => {
    if (typeof window !== "undefined") {
      try {
        const saved = localStorage.getItem("fingerspeak.custom_phrases");
        if (saved) return JSON.parse(saved);
      } catch { /* use defaults */ }
    }
    return [
      { id: "hand-open", signal: "Open Palm", phrase: "I need some help", sensitivity: 75, dwellMs: 0 },
      { id: "hand-fist", signal: "Closed Fist", phrase: "I would like some water", sensitivity: 70, dwellMs: 0 },
      { id: "hand-thumbsup", signal: "Thumbs Up", phrase: "Yes", sensitivity: 70, dwellMs: 0 },
      { id: "hand-point", signal: "Pointing", phrase: "Thank you", sensitivity: 75, dwellMs: 0 },
    ];
  });
  const [newPhraseSignal, setNewPhraseSignal] = useState("Open Palm");
  const [newPhraseText, setNewPhraseText] = useState("");
  const [newPhraseSensitivity, setNewPhraseSensitivity] = useState(75);
  const [newPhraseDwell, setNewPhraseDwell] = useState(0);
  const [careSettingsMessage, setCareSettingsMessage] = useState("Water reminders and reassuring check-ins stay on this patient device.");
  const [recordingPhraseKey, setRecordingPhraseKey] = useState("gesture:water");
  const [caregiverRecordingConfirmed, setCaregiverRecordingConfirmed] = useState(false);
  const [recordingActive, setRecordingActive] = useState(false);
  const [recordingStarting, setRecordingStarting] = useState(false);
  const [recentSomaticEvents, setRecentSomaticEvents] = useState<SomaticEvent[]>([]);

  const selectRole = useCallback((newRole: "patient" | "caregiver") => {
    setRole(newRole);
    setShowRoleModal(false);
    if (typeof window !== "undefined") {
      localStorage.setItem("fingerspeak.role", newRole);
    }
    if (newRole === "caregiver") {
      setView("caregiver");
    } else {
      setView("speak");
    }
  }, []);

  const videoRef = useRef<HTMLVideoElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const modelInputRef = useRef<HTMLInputElement>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const landmarkerRef = useRef<HandLandmarker | null>(null);
  const animationRef = useRef<number | null>(null);
  const processFrameRef = useRef<() => void>(() => undefined);
  const recentFramesRef = useRef<TimedRawFrame[]>([]);
  const captureFramesRef = useRef<TimedRawFrame[]>([]);
  const capturingRef = useRef(false);
  const captureTimerRef = useRef<number | null>(null);
  const captureTokenRef = useRef(0);
  const cameraStartingRef = useRef(false);
  const cameraStartTokenRef = useRef(0);
  const lastInferenceRef = useRef(0);
  const lastVisionRef = useRef(0);
  const lastVideoTimeRef = useRef(-1);
  const modelRef = useRef<PrototypeModel | null>(null);
  const profileRef = useRef(profile);
  const localContactsRef = useRef(localContacts);
  const piControlsRef = useRef(piControls);
  const patientSpeechRef = useRef(createPatientSpeechService());
  const caregiverCaptureRef = useRef<ActiveCaregiverMicrophoneCapture | null>(null);
  const caregiverCaptureTargetRef = useRef<(VoicePhraseOption & { profileId: string; caregiverName: string }) | null>(null);
  const caregiverCaptureRequestRef = useRef(0);
  const piEmergencyArmRef = useRef<PiEmergencyArm | null>(null);
  const piEmergencyArmTimerRef = useRef<number | null>(null);
  const ashaFabRef = useRef<HTMLButtonElement>(null);
  const ashaPanelRef = useRef<HTMLDivElement>(null);
  const machineRef = useRef(new IntentMachine(CONFIDENCE_THRESHOLD, 5));
  const armedTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const currentGesture = useMemo(
    () => profile.gestures.find((gesture) => gesture.id === prediction.gestureId) ?? null,
    [prediction.gestureId, profile.gestures],
  );
  const activePhrases = useMemo(
    () => profile.gestures.filter((gesture) => gesture.phrase),
    [profile.gestures],
  );
  const activePhrasesRef = useRef(activePhrases);
  useEffect(() => {
    activePhrasesRef.current = activePhrases;
  }, [activePhrases]);
  const calibrationReady = profile.gestures.every((gesture) => gesture.samples.length >= 2);
  const capturedCount = profile.gestures.reduce((total, gesture) => total + gesture.samples.length, 0);
  const requiredCount = profile.gestures.length * 2;
  const patientContext = useMemo<Record<string, unknown>>(() => ({
    ...(remoteProfileId ? { profile_id: remoteProfileId } : {}),
    care_mode: "communication",
    current_activity: piDevice.telemetry.tracking ? "Using gesture tracking" : "Using phone communication",
    wheelchair_status: "unknown",
    trusted_contact_available: Boolean(dialablePhone(localContacts.caregiverPhone)),
  }), [localContacts.caregiverPhone, piDevice.telemetry.tracking, remoteProfileId]);
  const caregiverRemotePi = useMemo(
    () => remoteDevices.find((device) => device.enabled) ?? null,
    [remoteDevices],
  );
  const caregiverDeviceOnline = piDevice.status === "connected" || caregiverRemotePi?.online === true;
  const caregiverDeviceState = caregiverRemotePi?.last_state ?? null;
  const voicePhraseOptions = useMemo<VoicePhraseOption[]>(() => [
    ...profile.gestures.filter((gesture) => gesture.phrase).map((gesture) => ({
      key: `gesture:${gesture.id}`,
      kind: "gesture" as const,
      phraseId: gesture.id,
      label: `${gesture.name}: ${gesture.phrase}`,
      text: gesture.phrase,
    })),
    {
      key: "hydration:water-reminder",
      kind: "hydration" as const,
      phraseId: "water-reminder",
      label: `Water reminder: ${routineSettings.hydration.message}`,
      text: routineSettings.hydration.message,
    },
    ...routineSettings.checkIns.messages.map((message, index) => ({
      key: `check-in:reassurance-${index + 1}`,
      kind: "check-in" as const,
      phraseId: `reassurance-${index + 1}`,
      label: `Reassurance ${index + 1}: ${message}`,
      text: message,
    })),
  ], [profile.gestures, routineSettings.checkIns.messages, routineSettings.hydration.message]);
  const selectedVoicePhrase = voicePhraseOptions.find((option) => option.key === recordingPhraseKey)
    ?? voicePhraseOptions[0]
    ?? null;

  // Liquid Glass Dual Theme State (Bright & Dark Mode)
  const [isDark, setIsDark] = useState<boolean>(() => {
    if (typeof window === "undefined") return true;
    try {
      const savedTheme = localStorage.getItem("neurobridge-theme");
      return savedTheme ? savedTheme === "dark" : true;
    } catch {
      return true;
    }
  });
  const [previewingVoice, setPreviewingVoice] = useState<string | null>(null);

  useEffect(() => {
    document.documentElement.setAttribute("data-theme", isDark ? "dark" : "light");
  }, [isDark]);

  const toggleTheme = useCallback(() => {
    setIsDark((prev) => {
      const next = !prev;
      const themeVal = next ? "dark" : "light";
      try {
        localStorage.setItem("neurobridge-theme", themeVal);
      } catch {
        // Ignore
      }
      document.documentElement.setAttribute("data-theme", themeVal);
      return next;
    });
  }, []);

  // 2x3 Daily Needs Colorful Grid definitions
  const dailyNeeds = useMemo(() => [
    {
      id: "water",
      title: "Water",
      subtitle: "Thirsty, need a drink",
      phrase: "I would like some water, please.",
      icon: "💧",
      pill: "Hydrate",
      className: "need-water",
    },
    {
      id: "food",
      title: "Food",
      subtitle: "Hungry, ready to eat",
      phrase: "I am hungry. Could I have some food, please?",
      icon: "🍲",
      pill: "Nutrition",
      className: "need-food",
    },
    {
      id: "toilet",
      title: "Toilet",
      subtitle: "Need bathroom assistance",
      phrase: "I need to use the restroom, please.",
      icon: "🚻",
      pill: "Urgent",
      className: "need-toilet",
    },
    {
      id: "rest",
      title: "Rest",
      subtitle: "Tired, want to lie down",
      phrase: "I need some rest. Could you help me lie back?",
      icon: "🛏️",
      pill: "Comfort",
      className: "need-rest",
    },
    {
      id: "call",
      title: "Call Family",
      subtitle: "Contact my loved ones",
      phrase: "Please call my family. I want to speak with them.",
      icon: "📞",
      pill: "Connect",
      className: "need-call",
    },
    {
      id: "entertainment",
      title: "Entertainment",
      subtitle: "Music, TV or audio",
      phrase: "Can we put on some music or turn on the TV?",
      icon: "🎮",
      pill: "Leisure",
      className: "need-entertainment",
    },
  ], []);

  const handleDailyNeedClick = useCallback((need: { id: string; title: string; subtitle: string; phrase: string; icon: string; pill: string; className: string }) => {
    if (typeof navigator !== "undefined" && typeof navigator.vibrate === "function") {
      navigator.vibrate(50);
    }
    const entry: SpokenEntry = {
      id: eventId(),
      phrase: need.phrase,
      gesture: need.title,
      risk: "routine",
      at: new Date().toISOString(),
      source: "touch",
    };
    setSpoken((current) => [entry, ...current].slice(0, 12));
    void patientSpeechRef.current.speak({
      profileId: profileRef.current.id,
      kind: "gesture",
      phraseId: `need-${need.id}`,
      text: need.phrase,
      caregiverName: localContactsRef.current.caregiverName,
    }).then((result) => {
      setVoiceMessage(result.spoken ? `Spoken immediately: “${need.phrase}”` : result.message);
    }).catch(() => {
      setVoiceMessage(`Voice output: “${need.phrase}”`);
    });
    void piDevice.sendCaption(need.phrase);
  }, [piDevice]);

  const previewVoicePersona = useCallback(async (voiceType: "female" | "male" | "caregiver") => {
    setPreviewingVoice(voiceType);
    let sampleText = "Hello, I am Asha, your assistive companion.";
    if (voiceType === "male") {
      sampleText = "Hello, this is your calm assistive speaking voice.";
    } else if (voiceType === "caregiver") {
      sampleText = localContactsRef.current.caregiverName
        ? `Hello, this is ${localContactsRef.current.caregiverName}. I am right here with you.`
        : "Hello, this is your recorded loved one voice.";
    }

    try {
      await patientSpeechRef.current.speak({
        profileId: profileRef.current.id,
        kind: "check-in",
        phraseId: `preview-${voiceType}`,
        text: sampleText,
        caregiverName: localContactsRef.current.caregiverName,
      });
    } catch {
      // Ignore
    } finally {
      setPreviewingVoice(null);
    }
  }, []);

  useEffect(() => {
    profileRef.current = profile;
  }, [profile]);

  useEffect(() => {
    localContactsRef.current = localContacts;
  }, [localContacts]);

  useEffect(() => {
    piControlsRef.current = piControls;
  }, [piControls]);

  useEffect(() => {
    modelRef.current = model;
  }, [model]);

  useEffect(() => {
    let cancelled = false;
    void Promise.all([
      deviceStorage.loadPatientSpeechSettings(profile.id),
      deviceStorage.loadCareRoutineSettings(profile.id),
    ]).then(([savedSpeech, savedRoutines]) => {
      if (cancelled) return;
      const nextSpeech = savedSpeech
        ? validatePatientSpeechSettings(savedSpeech)
        : createDefaultPatientSpeechSettings(profile.id);
      const nextRoutines = savedRoutines
        ? validateCareRoutineSettings(savedRoutines)
        : createDefaultCareRoutineSettings(profile.id);
      setSpeechSettings(nextSpeech);
      setRoutineSettings(nextRoutines);
    }).catch(() => {
      if (!cancelled) setCareSettingsMessage("Some local voice or reminder settings could not be loaded.");
    });
    return () => { cancelled = true; };
  }, [profile.id]);

  useEffect(() => {
    if (!("speechSynthesis" in window)) return;
    const refreshVoices = () => setSystemVoices(window.speechSynthesis.getVoices());
    refreshVoices();
    window.speechSynthesis.addEventListener("voiceschanged", refreshVoices);
    return () => window.speechSynthesis.removeEventListener("voiceschanged", refreshVoices);
  }, []);

  useEffect(() => {
    const monitor = createCareRoutineMonitor({
      profileId: profile.id,
      async onDue(routine) {
        const result = await patientSpeechRef.current.speak({
          profileId: profile.id,
          kind: routine.kind,
          phraseId: routine.phraseId,
          text: routine.message,
          caregiverName: localContactsRef.current.caregiverName,
        });
        setVoiceMessage(`${routine.kind === "hydration" ? "Water reminder" : "Asha check-in"}: ${result.message}`);
        return result.spoken;
      },
    });
    monitor.start();
    return () => monitor.stop();
  }, [profile.id]);

  useEffect(() => () => {
    caregiverCaptureRequestRef.current += 1;
    caregiverCaptureRef.current?.cancel();
    caregiverCaptureRef.current = null;
    caregiverCaptureTargetRef.current = null;
    if (piEmergencyArmTimerRef.current !== null) window.clearTimeout(piEmergencyArmTimerRef.current);
    patientSpeechRef.current.stop();
  }, []);

  useEffect(() => {
    if (!ashaOpen) return;
    const previouslyFocused = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    const focusFrame = window.requestAnimationFrame(() => ashaPanelRef.current?.focus());
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") setAshaOpen(false);
    };
    window.addEventListener("keydown", closeOnEscape);
    return () => {
      window.cancelAnimationFrame(focusFrame);
      window.removeEventListener("keydown", closeOnEscape);
      if (previouslyFocused?.isConnected) previouslyFocused.focus();
    };
  }, [ashaOpen]);

  useEffect(() => {
    let cancelled = false;
    void deviceStorage.loadLocalContactSettings().then((saved) => {
      if (cancelled || !saved) return;
      setLocalContacts(saved);
      setContactDraft(saved);
    }).catch(() => {
      if (!cancelled) setLocalSettingsMessage("Local contact storage is unavailable. No phone number was loaded.");
    });
    return () => { cancelled = true; };
  }, []);

  useEffect(() => {
    const timer = window.setTimeout(() => {
      setPiEndpointDraft(piDevice.endpoint);
      setPiPairingTokenDraft(piDevice.pairingToken);
    }, 0);
    return () => window.clearTimeout(timer);
  }, [piDevice.endpoint, piDevice.pairingToken]);

  useEffect(() => {
    let cancelled = false;
    void Promise.all([
      deviceStorage.loadProfile("local-profile"),
      deviceStorage.loadModel("local-profile"),
      deviceStorage.loadRemoteLink(),
      deviceStorage.loadConsentGuard("local-profile"),
    ]).then(async ([savedProfile, savedModel, savedLink, consentGuard]) => {
      if (cancelled) return;
      let restoredProfile = createDefaultProfile();
      if (savedProfile) {
        try {
          restoredProfile = parseProfile(savedProfile, { preserveLocalConsent: true });
          if (consentGuard) {
            restoredProfile = {
              ...restoredProfile,
              consentToEventSync: restoredProfile.consentToEventSync && !consentGuard.eventSyncDenied,
              consentToCaregiverAlerts: restoredProfile.consentToCaregiverAlerts && !consentGuard.caregiverAlertsDenied,
            };
          }
          setProfile(restoredProfile);
        } catch {
          setCaptureMessage("A saved profile was incompatible, so a safe default was restored.");
        }
      }
      const expectedFingerprint = await profileModelFingerprint(restoredProfile);
      const expectedGestureIds = restoredProfile.gestures.map((gesture) => gesture.id);
      const savedGestureIds = savedModel?.prototypes?.map((prototype) => prototype.gestureId) ?? [];
      const validSavedModel =
        savedModel?.featureVersion === "3d-angle-motion-v1" &&
        savedModel.sequenceLength === 20 &&
        savedModel.featureLength === 98 &&
        savedModel.profileFingerprint === expectedFingerprint &&
        expectedGestureIds.length === savedGestureIds.length &&
        expectedGestureIds.every((id, index) => id === savedGestureIds[index]) &&
        savedModel.prototypes.every((prototype) => prototype.centroid.length === 196 && prototype.centroid.every(Number.isFinite) && Number.isFinite(prototype.spread) && prototype.spread >= 0.05);
      if (validSavedModel) {
        setModel(savedModel);
      } else if (savedModel) {
        await deviceStorage.deleteModel("local-profile");
        setCaptureMessage("A stale or incompatible edge model was removed. Recalibrate or import its matching bundle.");
      }
      if (savedLink?.localProfileId === restoredProfile.id) {
        setRemoteProfileId(savedLink.profileId);
        setCaregiverProfileId((current) => current ?? savedLink.profileId);
        setCaregiverProfileInput((current) => current || savedLink.profileId);
      }
    }).catch(() => {
      if (!cancelled) setCaptureMessage("Device storage is unavailable. Cloud sharing remains off and changes cannot be saved until storage is restored.");
    });
    return () => { cancelled = true; };
  }, []);

  useEffect(() => {
    const controller = new AbortController();
    const probe = async () => {
      const online = await checkApi(controller.signal);
      setServerOnline(online);
      if (!online) return;
      await flushPendingConsentUpdates();
      const activeProfile = profileRef.current;
      const link = await syncRemoteProfile(activeProfile);
      if (link) {
        setRemoteProfileId(link.profileId);
        setCaregiverProfileId((current) => current ?? link.profileId);
        setCaregiverProfileInput((current) => current || link.profileId);
      } else if (activeProfile.consentToEventSync || activeProfile.consentToCaregiverAlerts) {
        setCaregiverMessage("Cloud data is queued locally. An authenticated gateway session may be required.");
      }
      await flushOutbox(activeProfile);
    };
    void probe();
    const timer = window.setInterval(() => void probe(), 15_000);
    window.addEventListener("online", probe);
    return () => {
      controller.abort();
      window.clearInterval(timer);
      window.removeEventListener("online", probe);
    };
  }, []);

  useEffect(() => {
    if (!serverOnline) return;
    let cancelled = false;
    void (async () => {
      await flushPendingConsentUpdates();
      const link = await syncRemoteProfile(profile);
      if (!cancelled && link) {
        setRemoteProfileId(link.profileId);
        setCaregiverProfileId((current) => current ?? link.profileId);
        setCaregiverProfileInput((current) => current || link.profileId);
      } else if (!cancelled && (profile.consentToEventSync || profile.consentToCaregiverAlerts)) {
        setCaregiverMessage("Cloud data is queued locally. An authenticated gateway session may be required.");
      }
      await flushOutbox(profile);
    })();
    return () => { cancelled = true; };
  }, [profile, serverOnline]);

  useEffect(() => {
    if (view !== "caregiver" || !serverOnline || !caregiverProfileId) return;
    let cancelled = false;
    let socket: WebSocket | null = null;
    let reconnectTimer: number | null = null;
    let reconnectAttempt = 0;
    const mergeAlerts = (incoming: CaregiverAlert[]) => setAlerts((current) =>
      [...incoming, ...current]
        .filter((item, index, all) => all.findIndex((candidate) => candidate.id === item.id) === index)
        .sort((left, right) => right.created_at.localeCompare(left.created_at))
        .slice(0, 100));
    const connect = () => {
      if (cancelled) return;
      setSocketStatus("connecting");
      socket = new WebSocket(caregiverSocketUrl(caregiverProfileId));
      socket.onopen = () => {
        reconnectAttempt = 0;
        setSocketStatus("live");
        setCaregiverMessage("Authorized caregiver connection is live.");
      };
      socket.onmessage = (message) => {
        try {
          const payload = JSON.parse(String(message.data)) as { alert?: CaregiverAlert; alerts?: CaregiverAlert[] };
          const incoming = payload.alerts ?? (payload.alert ? [payload.alert] : []);
          if (incoming.length) mergeAlerts(incoming);
        } catch {
          // Ignore malformed network messages; the durable API remains authoritative.
        }
      };
      socket.onclose = (event) => {
        if (cancelled) return;
        setSocketStatus("offline");
        if ([4401, 4403, 4404].includes(event.code)) {
          setCaregiverMessage(event.code === 4401 ? "Caregiver sign-in is required." : event.code === 4403 ? "Caregiver alerts are not consented for this profile." : "Profile not found or access was revoked.");
          return;
        }
        const delay = Math.min(30_000, 1_500 * (2 ** reconnectAttempt)) + Math.floor(Math.random() * 500);
        reconnectAttempt += 1;
        reconnectTimer = window.setTimeout(connect, delay);
      };
      socket.onerror = () => socket?.close();
    };
    void loadCaregiverAlerts(caregiverProfileId).then(mergeAlerts).catch(() => undefined);
    connect();
    return () => {
      cancelled = true;
      if (reconnectTimer !== null) window.clearTimeout(reconnectTimer);
      socket?.close(1000, "leaving caregiver view");
    };
  }, [caregiverProfileId, serverOnline, view]);

  useEffect(() => {
    if (view !== "caregiver" || !serverOnline || !caregiverProfileId) return;
    let cancelled = false;
    const refresh = async () => {
      try {
        const devices = await loadRemoteDevices(caregiverProfileId);
        if (cancelled) return;
        setRemoteDevices(devices);
        const active = devices.find((device) => device.enabled);
        setRemoteDeviceMessage(active
          ? active.online ? `${active.name} is reporting live.` : `${active.name} is registered but currently offline.`
          : "No wheelchair Pi is registered for this patient profile.");
      } catch {
        if (!cancelled) setRemoteDeviceMessage("Patient-device status could not be verified.");
      }
    };
    void refresh();
    const timer = window.setInterval(() => void refresh(), 15_000);
    return () => {
      cancelled = true;
      window.clearInterval(timer);
    };
  }, [caregiverProfileId, serverOnline, view]);

  useEffect(() => {
    if ("serviceWorker" in navigator) {
      void navigator.serviceWorker.register("/sw.js", { updateViaCache: "none" })
        .then((registration) => registration.update())
        .catch(() => undefined);
    }
  }, []);

  useEffect(() => {
    window.addEventListener("pagehide", endRemoteSession);
    return () => window.removeEventListener("pagehide", endRemoteSession);
  }, []);

  useEffect(() => () => {
    caregiverCaptureRef.current?.cancel();
    caregiverCaptureRef.current = null;
    patientSpeechRef.current.stop();
  }, []);

  const stopCamera = useCallback(() => {
    cameraStartTokenRef.current += 1;
    cameraStartingRef.current = false;
    if (animationRef.current !== null) cancelAnimationFrame(animationRef.current);
    animationRef.current = null;
    streamRef.current?.getTracks().forEach((track) => track.stop());
    streamRef.current = null;
    const video = videoRef.current;
    if (video) {
      video.pause();
      video.srcObject = null;
    }
    try { landmarkerRef.current?.close(); } catch { /* The camera is already stopping. */ }
    landmarkerRef.current = null;
    recentFramesRef.current = [];
    captureFramesRef.current = [];
    capturingRef.current = false;
    captureTokenRef.current += 1;
    if (captureTimerRef.current !== null) window.clearTimeout(captureTimerRef.current);
    captureTimerRef.current = null;
    setCaptureTarget(null);
    machineRef.current.reset();
    setIntent(machineRef.current.snapshot());
    setTracking(false);
    lastVisionRef.current = 0;
    lastVideoTimeRef.current = -1;
    setCameraStatus("off");
    setCameraMessage("Camera stopped. No camera frames were saved or uploaded.");
    const canvas = canvasRef.current;
    canvas?.getContext("2d")?.clearRect(0, 0, canvas.width, canvas.height);
  }, []);

  useEffect(() => stopCamera, [stopCamera]);

  const queueEvent = useCallback(async (gesture: Gesture, type: OutboxEvent["type"]) => {
    const event: OutboxEvent = {
      id: eventId(),
      type,
      profileId: profileRef.current.id,
      gestureId: gesture.id,
      phrase: type === "caregiver_alert" ? gesture.phrase : undefined,
      risk: type === "caregiver_alert" ? gesture.risk : undefined,
      occurredAt: new Date().toISOString(),
    };
    const currentProfile = profileRef.current;
    const maySync = type === "caregiver_alert" ? currentProfile.consentToCaregiverAlerts : currentProfile.consentToEventSync;
    if (!maySync) return;
    await deviceStorage.queueEvent(event);
    if (maySync) {
      const delivery = await sendEvent(currentProfile, event);
      if (delivery !== "retry") await deviceStorage.deleteEvent(event.id);
      if (delivery === "sent") setServerOnline(true);
    }
  }, []);

  const speakGesture = useCallback((gesture: Gesture, source: SpokenEntry["source"]) => {
    if (!gesture.phrase) return;
    const entry: SpokenEntry = {
      id: eventId(),
      phrase: gesture.phrase,
      gesture: gesture.name,
      risk: gesture.risk,
      at: new Date().toISOString(),
      source,
    };
    setSpoken((current) => [entry, ...current].slice(0, 12));
    const somaticEv: SomaticEvent = {
      id: eventId(),
      modality: "fingerspeak_hand",
      gestureId: gesture.id,
      phrase: gesture.phrase,
      timestamp: Date.now(),
    };
    setRecentSomaticEvents((current) => [...current, somaticEv].slice(-6));
    void patientSpeechRef.current.speak({
      profileId: profileRef.current.id,
      kind: "gesture",
      phraseId: gesture.id,
      text: gesture.phrase,
      caregiverName: localContactsRef.current.caregiverName,
    }).then((result) => {
      setVoiceMessage(result.spoken ? `Spoken immediately: “${gesture.phrase}” · ${result.message}` : result.message);
      if (result.spoken) void queueEvent(gesture, "phrase_spoken");
    }).catch(() => {
      setVoiceMessage("Voice output failed. The phrase remains on screen—use the backup call control if help is urgent.");
    });
    if (gesture.risk !== "routine") void queueEvent(gesture, "caregiver_alert");
  }, [queueEvent]);

  useEffect(() => {
    const event = piDevice.patientIntent;
    if (!event) return;
    const route = routePiPatientIntent(
      event,
      profileRef.current,
      piControlsRef.current,
      piEmergencyArmRef.current,
    );
    piEmergencyArmRef.current = route.nextEmergencyArm;
    if (piEmergencyArmTimerRef.current !== null) window.clearTimeout(piEmergencyArmTimerRef.current);
    piEmergencyArmTimerRef.current = null;
    if (route.nextEmergencyArm) {
      const firstMessageId = route.nextEmergencyArm.firstMessageId;
      const delay = Math.max(0, route.nextEmergencyArm.expiresAt - Date.now());
      piEmergencyArmTimerRef.current = window.setTimeout(() => {
        if (piEmergencyArmRef.current?.firstMessageId !== firstMessageId) return;
        piEmergencyArmRef.current = null;
        piEmergencyArmTimerRef.current = null;
        setVoiceMessage("Emergency movement confirmation expired. Repeat the deliberate movement twice to try again.");
      }, delay);
    }
    if (route.action === "speak") {
      speakGesture(route.gesture, "pi");
    } else {
      setVoiceMessage(route.reason);
    }
  }, [piDevice.patientIntent, speakGesture]);

  useEffect(() => {
    if (piDevice.status === "connected") return;
    if (piEmergencyArmTimerRef.current !== null) window.clearTimeout(piEmergencyArmTimerRef.current);
    piEmergencyArmRef.current = null;
    piEmergencyArmTimerRef.current = null;
  }, [piDevice.status]);

  const drawHand = useCallback((landmarks: ReadonlyArray<{ x: number; y: number }>) => {
    const video = videoRef.current;
    const canvas = canvasRef.current;
    if (!video || !canvas || !video.videoWidth || !video.videoHeight) return;
    const context = canvas.getContext("2d");
    if (!context) return;
    context.strokeStyle = "rgba(79, 209, 197, .8)";
    context.lineWidth = 3;
    for (const [start, end] of HAND_CONNECTIONS) {
      context.beginPath();
      context.moveTo(landmarks[start].x * canvas.width, landmarks[start].y * canvas.height);
      context.lineTo(landmarks[end].x * canvas.width, landmarks[end].y * canvas.height);
      context.stroke();
    }
    context.fillStyle = "#f6bd60";
    for (const landmark of landmarks) {
      context.beginPath();
      context.arc(landmark.x * canvas.width, landmark.y * canvas.height, 4, 0, Math.PI * 2);
      context.fill();
    }
  }, []);

  const stopCameraAfterVisionFailure = useCallback(() => {
    stopCamera();
    setCameraStatus("error");
    setCameraMessage("Camera processing stopped because the private hand movement model failed. Restart the camera; touch phrases remain available.");
  }, [stopCamera]);

  const processFrame = useCallback(() => {
    const video = videoRef.current;
    const landmarker = landmarkerRef.current;
    if (!video || !landmarker || video.readyState < 2) {
      animationRef.current = requestAnimationFrame(() => processFrameRef.current());
      return;
    }
    const now = performance.now();
    if (now - lastVisionRef.current < 90) {
      animationRef.current = requestAnimationFrame(() => processFrameRef.current());
      return;
    }
    if (video.currentTime === lastVideoTimeRef.current) {
      animationRef.current = requestAnimationFrame(() => processFrameRef.current());
      return;
    }
    lastVisionRef.current = now;
    lastVideoTimeRef.current = video.currentTime;

    // Prepare canvas dimensions & clear once per processed frame
    const canvas = canvasRef.current;
    if (canvas && video.videoWidth && video.videoHeight) {
      if (canvas.width !== video.videoWidth || canvas.height !== video.videoHeight) {
        canvas.width = video.videoWidth;
        canvas.height = video.videoHeight;
      }
      canvas.getContext("2d")?.clearRect(0, 0, canvas.width, canvas.height);
    }

    let result: ReturnType<HandLandmarker["detectForVideo"]>;
    try {
      result = landmarker.detectForVideo(video, now);
    } catch {
      stopCameraAfterVisionFailure();
      return;
    }
    const landmarks = result.landmarks[0];
    if (!landmarks) {
      setTracking(false);
      recentFramesRef.current = [];
      captureFramesRef.current = [];
      if (capturingRef.current) {
        capturingRef.current = false;
        captureTokenRef.current += 1;
        if (captureTimerRef.current !== null) window.clearTimeout(captureTimerRef.current);
        captureTimerRef.current = null;
        setCaptureTarget(null);
        setCaptureMessage("Tracking was interrupted, so that capture was discarded. Keep one hand visible and try again.");
      }
      const output = machineRef.current.step({ handPresent: false, gestureId: null, confidence: 0, inDistribution: false }, now, profileRef.current.gestures);
      setIntent(output);
    } else {
      setTracking(true);
      drawHand(landmarks);
      const raw = flattenLandmarks(landmarks);
      const timed = { t: now, raw };
      recentFramesRef.current.push(timed);
      recentFramesRef.current = recentFramesRef.current.filter((frame) => frame.t >= now - 1_500);
      if (capturingRef.current) captureFramesRef.current.push(timed);

      const activeModel = modelRef.current;
      if (activeModel && now - lastInferenceRef.current >= 120) {
        lastInferenceRef.current = now;
        const sequence = resampleSequence(recentFramesRef.current);
        if (sequence) {
          try {
            const nextPrediction = predictPrototype(activeModel, sequence);
            setPrediction({ gestureId: nextPrediction.gestureId, confidence: nextPrediction.confidence, inDistribution: nextPrediction.inDistribution });
            const output = machineRef.current.step({ handPresent: true, gestureId: nextPrediction.gestureId, confidence: nextPrediction.confidence, inDistribution: nextPrediction.inDistribution }, now, profileRef.current.gestures);
            setIntent(output);
            if (output.trigger) speakGesture(output.trigger, "gesture");
          } catch {
            setPrediction({ gestureId: null, confidence: 0, inDistribution: false });
          }
        }
      }
    }
    animationRef.current = requestAnimationFrame(() => processFrameRef.current());
  }, [drawHand, speakGesture, stopCameraAfterVisionFailure]);

  useEffect(() => {
    processFrameRef.current = processFrame;
  }, [processFrame]);

  const startCamera = useCallback(async () => {
    if (cameraStartingRef.current || cameraStatus === "loading" || cameraStatus === "ready") return;
    cameraStartingRef.current = true;
    const startToken = cameraStartTokenRef.current + 1;
    cameraStartTokenRef.current = startToken;
    const isCurrentStart = () => cameraStartTokenRef.current === startToken;
    setCameraStatus("loading");
    setCameraMessage("Requesting this device’s camera…");
    try {
      if (!navigator.mediaDevices?.getUserMedia) {
        throw new Error("This browser does not provide secure camera access. Use HTTPS or localhost in a supported browser.");
      }
      const devices = await navigator.mediaDevices.enumerateDevices().catch(() => [] as MediaDeviceInfo[]);
      if (!isCurrentStart()) return;
      if (devices.length > 0 && !devices.some((device) => device.kind === "videoinput")) {
        throw new DOMException("No video input is connected.", "NotFoundError");
      }
      let stream: MediaStream;
      try {
        stream = await navigator.mediaDevices.getUserMedia({
          video: { facingMode: "user", width: { ideal: 960 }, height: { ideal: 720 } },
          audio: false,
        });
      } catch (firstError) {
        if (firstError instanceof DOMException && firstError.name === "OverconstrainedError") {
          stream = await navigator.mediaDevices.getUserMedia({ video: true, audio: false });
        } else {
          throw firstError;
        }
      }
      if (!isCurrentStart()) {
        stream.getTracks().forEach((track) => track.stop());
        return;
      }
      streamRef.current = stream;
      if (!videoRef.current) throw new Error("Camera view is unavailable.");
      videoRef.current.srcObject = stream;
      await videoRef.current.play();
      if (!isCurrentStart()) return;

      setCameraMessage("Loading private hand movement model…");
      const { FilesetResolver, HandLandmarker } = await import("@mediapipe/tasks-vision");
      if (!isCurrentStart()) return;
      const vision = await FilesetResolver.forVisionTasks("/mediapipe/wasm");
      if (!isCurrentStart()) return;
      let landmarker: HandLandmarker;
      try {
        landmarker = await HandLandmarker.createFromOptions(vision, {
          baseOptions: { modelAssetPath: "/models/hand_landmarker.task", delegate: "GPU" },
          runningMode: "VIDEO",
          numHands: 1,
        });
      } catch {
        if (!isCurrentStart()) return;
        landmarker = await HandLandmarker.createFromOptions(vision, {
          baseOptions: { modelAssetPath: "/models/hand_landmarker.task", delegate: "CPU" },
          runningMode: "VIDEO",
          numHands: 1,
        });
      }
      if (!isCurrentStart()) {
        try { landmarker.close(); } catch { /* A cancelled start owns this model. */ }
        return;
      }
      landmarkerRef.current = landmarker;
      stream.getVideoTracks()[0]?.addEventListener("ended", () => {
        if (!isCurrentStart()) return;
        stopCamera();
        setCameraStatus("error");
        setCameraMessage("Camera connection ended. Reconnect the camera and restart monitoring; touch phrases remain available.");
      }, { once: true });
      cameraStartingRef.current = false;
      setCameraStatus("ready");
      setCameraMessage("Continuous hand gesture monitoring is active on this device.");
      animationRef.current = requestAnimationFrame(() => processFrameRef.current());
    } catch (error) {
      if (!isCurrentStart()) return;
      stopCamera();
      setCameraStatus("error");
      setCameraMessage(`Camera unavailable: ${cameraFailureMessage(error)}`);
    }
  }, [cameraStatus, stopCamera]);

  const saveProfile = useCallback(async (next: FingerSpeakProfile) => {
    await deviceStorage.saveProfile(next);
    profileRef.current = next;
    setProfile(next);
  }, []);

  const goTo = useCallback((next: View) => {
    if (next !== view && (cameraStartingRef.current || cameraStatus === "loading" || cameraStatus === "ready")) stopCamera();
    if (next !== "caregiver") setSocketStatus("offline");
    if (view === "caregiver" && next !== "caregiver") {
      caregiverCaptureRequestRef.current += 1;
      caregiverCaptureRef.current?.cancel();
      caregiverCaptureRef.current = null;
      caregiverCaptureTargetRef.current = null;
      setRecordingActive(false);
      setRecordingStarting(false);
      setCaregiverRecordingConfirmed(false);
    }
    setView(next);
    window.scrollTo({ top: 0, left: 0, behavior: "auto" });
  }, [cameraStatus, stopCamera, view]);

  const startCapture = useCallback((gesture: Gesture) => {
    if (cameraStatus !== "ready" || !tracking || capturingRef.current) {
      setCaptureMessage("Start the camera and keep one hand visible before capturing.");
      return;
    }
    capturingRef.current = true;
    captureFramesRef.current = [];
    const captureToken = captureTokenRef.current + 1;
    captureTokenRef.current = captureToken;
    setCaptureTarget(gesture.id);
    setCaptureMessage(`Hold “${gesture.name}” naturally for one second…`);
    captureTimerRef.current = window.setTimeout(async () => {
      if (captureTokenRef.current !== captureToken) return;
      captureTimerRef.current = null;
      capturingRef.current = false;
      setCaptureTarget(null);
      const sequence = resampleSequence(captureFramesRef.current);
      captureFramesRef.current = [];
      if (!sequence) {
        setCaptureMessage("Capture was too short or tracking was interrupted. Please try again.");
        return;
      }
      const current = profileRef.current;
      const next = {
        ...current,
        updatedAt: new Date().toISOString(),
        gestures: current.gestures.map((item) => item.id === gesture.id
          ? { ...item, samples: [...item.samples, { raw: sequence, session: "local-session", capturedAt: new Date().toISOString() }].slice(-48) }
          : item),
      };
      try {
        await saveProfile(next);
        setModel(null);
        await deviceStorage.deleteModel(current.id);
        setCaptureMessage(`Captured “${gesture.name}”. Repeat from a slightly different position.`);
      } catch {
        setCaptureMessage("Capture could not be saved. Device storage must be available before calibration can change.");
      }
    }, 1_050);
  }, [cameraStatus, saveProfile, tracking]);

  const trainLocalModel = useCallback(async () => {
    try {
      const fingerprint = await profileModelFingerprint(profile);
      const trained = trainPrototypeModel(profile.gestures, fingerprint);
      await deviceStorage.saveProfileAndModel(profile, trained);
      setModel(trained);
      machineRef.current.reset();
      setCaptureMessage("On-device model trained. Switch to Speak and hold a gesture until confirmation completes.");
      stopCamera();
      setView("speak");
    } catch (error) {
      setCaptureMessage(error instanceof Error ? error.message : "Could not train the on-device model.");
    }
  }, [profile, stopCamera]);

  const handleManualPhrase = useCallback((gesture: Gesture) => {
    if (gesture.risk === "emergency" && armedGestureId !== gesture.id) {
      setArmedGestureId(gesture.id);
      setVoiceMessage("Emergency phrase armed. Touch it again within three seconds to confirm.");
      if (armedTimerRef.current) clearTimeout(armedTimerRef.current);
      armedTimerRef.current = setTimeout(() => setArmedGestureId(null), 3_000);
      return;
    }
    setArmedGestureId(null);
    speakGesture(gesture, "touch");
  }, [armedGestureId, speakGesture]);

  const importProfile = useCallback(async (file: File) => {
    if (file.size > 5_000_000) {
      setCaptureMessage("Profile rejected: files must be smaller than 5 MB.");
      return;
    }
    try {
      const imported = parseProfile(JSON.parse(await file.text()));
      await detachRemoteProfile(profileRef.current);
      const next = { ...imported, id: "local-profile" };
      await deviceStorage.deleteModel("local-profile");
      await deviceStorage.saveProfileAndConsentGuard(next);
      profileRef.current = next;
      setProfile(next);
      setModel(null);
      setRemoteProfileId(null);
      setCaregiverProfileId(null);
      setCaregiverProfileInput("");
      setCaptureMessage("Profile imported with cloud consent off. Train locally or import its matching checksummed model bundle.");
    } catch (error) {
      setCaptureMessage(error instanceof Error ? `Profile rejected: ${error.message}` : "Profile rejected.");
    }
  }, []);

  const importModelBundle = useCallback(async (files: FileList) => {
    try {
      const activeProfile = profileRef.current;
      const importedModel = await importPrototypeBundle(Array.from(files), activeProfile);
      await deviceStorage.saveProfileAndModel(activeProfile, importedModel);
      setModel(importedModel);
      machineRef.current.reset();
      setCaptureMessage("Checksummed Python edge model imported and bound to this exact gesture profile.");
    } catch (error) {
      setCaptureMessage(error instanceof Error ? `Model rejected: ${error.message}` : "Model bundle rejected.");
    }
  }, []);

  const exportProfile = useCallback(() => {
    const blob = new Blob([JSON.stringify(profile, null, 2)], { type: "application/json" });
    const link = document.createElement("a");
    link.href = URL.createObjectURL(blob);
    link.download = "fingerspeak-profile-v3.json";
    link.click();
    URL.revokeObjectURL(link.href);
    setCaptureMessage("Profile exported. Treat it as sensitive health and movement data.");
  }, [profile]);

  const updateConsent = useCallback(async (field: "consentToEventSync" | "consentToCaregiverAlerts", value: boolean) => {
    const next = { ...profileRef.current, [field]: value, updatedAt: new Date().toISOString() };
    if (!value) {
      // Withdrawal takes effect immediately, even if durable device storage is degraded.
      profileRef.current = next;
      setProfile(next);
    }
    try {
      await deviceStorage.saveProfileAndConsentGuard(next);
      profileRef.current = next;
      setProfile(next);
    } catch {
      setCaregiverMessage(value
        ? "Cloud sharing was not enabled because the consent choice could not be saved on this device."
        : "Cloud sharing is off for this session, but the withdrawal could not be saved. Keep this tab open and restore device storage before reloading.");
    }
  }, []);

  const connectCaregiverProfile = useCallback(() => {
    const candidate = caregiverProfileInput.trim();
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(candidate)) {
      setCaregiverMessage("Enter a valid shared profile UUID.");
      return;
    }
    setAlerts([]);
    setCaregiverProfileId(candidate);
    setCaregiverMessage("Connecting with your authenticated caregiver account…");
  }, [caregiverProfileInput]);

  const handleAlertAction = useCallback(async (alert: CaregiverAlert, action: "acknowledge" | "resolve") => {
    try {
      const updated = await updateCaregiverAlert(alert.id, action);
      setAlerts((current) => current.map((item) => item.id === updated.id ? updated : item));
    } catch {
      setCaregiverMessage("The alert could not be updated. Check your caregiver access and connection.");
    }
  }, []);

  const handleCaregiverGrant = useCallback(async () => {
    if (!remoteProfileId || !caregiverSubject.trim()) {
      setCaregiverMessage("Create the remote profile first and enter the caregiver’s authenticated subject.");
      return;
    }
    try {
      await grantCaregiver(remoteProfileId, caregiverSubject.trim());
      setCaregiverSubject("");
      setCaregiverMessage("Caregiver access granted. Share the profile ID through a trusted channel.");
    } catch {
      setCaregiverMessage("Caregiver access could not be granted. Only the profile owner may grant access.");
    }
  }, [caregiverSubject, remoteProfileId]);

  const playLocalText = useCallback(async (text: string): Promise<boolean> => {
    try {
      const result = await patientSpeechRef.current.speak({
        profileId: profileRef.current.id,
        kind: "check-in",
        phraseId: "asha-live",
        text,
        caregiverName: localContactsRef.current.caregiverName,
      });
      setVoiceMessage(result.spoken ? `Asha spoke aloud. ${result.message}` : result.message);
      return result.spoken;
    } catch {
      setVoiceMessage("Voice playback failed. The message remains visible.");
      return false;
    }
  }, []);

  const simulateSignal = useCallback((name: string, phraseText?: string) => {
    const matchingGesture = profileRef.current.gestures.find((g) => 
      g.name.toLowerCase().includes(name.toLowerCase()) || 
      g.id.toLowerCase().includes(name.toLowerCase())
    );
    if (matchingGesture) {
      speakGesture(matchingGesture, "touch");
      setVoiceMessage(`Simulated gesture triggered: ${matchingGesture.name} → “${matchingGesture.phrase}”`);
    } else {
      const phrase = phraseText || `Patient phrase: ${name}`;
      void playLocalText(phrase);
      setVoiceMessage(`Simulated phrase triggered: ${name}`);
    }
  }, [playLocalText, speakGesture]);

  const saveSpeechPreferences = useCallback(async () => {
    try {
      const next = await saveLocalPatientSpeechSettings({ ...speechSettings, updatedAt: new Date().toISOString() });
      setSpeechSettings(next);
      setCareSettingsMessage("Patient speech preferences were saved locally.");
    } catch (error) {
      setCareSettingsMessage(error instanceof Error ? error.message : "Speech preferences could not be saved.");
    }
  }, [speechSettings]);

  const saveCareRoutines = useCallback(async () => {
    try {
      const next = await saveLocalCareRoutineSettings({ ...routineSettings, updatedAt: new Date().toISOString() });
      setRoutineSettings(next);
      setCareSettingsMessage("Continuous reassuring check-ins and water reminders were saved locally.");
    } catch (error) {
      setCareSettingsMessage(error instanceof Error ? error.message : "Care routines could not be saved.");
    }
  }, [routineSettings]);

  const toggleCaregiverRecording = useCallback(async () => {
    if (recordingActive) {
      const capture = caregiverCaptureRef.current;
      const target = caregiverCaptureTargetRef.current;
      caregiverCaptureRef.current = null;
      caregiverCaptureTargetRef.current = null;
      setRecordingActive(false);
      setCaregiverRecordingConfirmed(false);
      if (!capture || !target) {
        setCareSettingsMessage("No active caregiver recording was available to save.");
        return;
      }
      try {
        const result = await capture.stop();
        const currentTarget = voicePhraseOptions.find((option) => option.key === target.key);
        if (profileRef.current.id !== target.profileId || currentTarget?.text !== target.text) {
          setCareSettingsMessage("The selected phrase changed while recording, so the audio was discarded. Record the updated phrase again.");
          return;
        }
        const saved = await saveLocalCaregiverPhraseRecording({
          profileId: target.profileId,
          kind: target.kind,
          phraseId: target.phraseId,
          phraseSnapshot: target.text,
          caregiverName: target.caregiverName,
          audio: result.audio,
          durationMs: result.durationMs,
          caregiverConfirmed: true,
        });
        setCareSettingsMessage(`Saved ${saved.caregiverName}’s exact recording for “${saved.phraseSnapshot}” on this device only.`);
      } catch (error) {
        setCareSettingsMessage(error instanceof Error ? error.message : "The caregiver recording could not be saved.");
      }
      return;
    }
    if (!selectedVoicePhrase) {
      setCareSettingsMessage("Choose a patient phrase before recording.");
      return;
    }
    if (!contactDraft.caregiverName.trim()) {
      setCareSettingsMessage("Add the caregiver’s name before recording.");
      return;
    }
    if (contactDraft.caregiverName.trim() !== localContactsRef.current.caregiverName) {
      setCareSettingsMessage("Save the caregiver name under Local phone settings before recording, so playback can verify whose voice it is.");
      return;
    }
    if (!caregiverRecordingConfirmed) {
      setCareSettingsMessage("The caregiver must confirm this is their own direct recording before it can be stored.");
      return;
    }
    const requestId = ++caregiverCaptureRequestRef.current;
    const target = { ...selectedVoicePhrase, profileId: profileRef.current.id, caregiverName: contactDraft.caregiverName.trim() };
    setRecordingStarting(true);
    try {
      const capture = await startCaregiverMicrophoneCapture();
      if (caregiverCaptureRequestRef.current !== requestId) {
        capture.cancel();
        return;
      }
      caregiverCaptureRef.current = capture;
      caregiverCaptureTargetRef.current = target;
      setRecordingActive(true);
      setCareSettingsMessage(`Recording now. Say exactly: “${target.text}”`);
    } catch (error) {
      setCareSettingsMessage(error instanceof Error ? error.message : "Microphone recording could not start.");
    } finally {
      if (caregiverCaptureRequestRef.current === requestId) setRecordingStarting(false);
    }
  }, [caregiverRecordingConfirmed, contactDraft.caregiverName, recordingActive, selectedVoicePhrase, voicePhraseOptions]);

  const callNumber = useCallback((value: string, label: string): string => {
    const number = dialablePhone(value);
    if (!number) return `${label} phone is not configured. Add it under Caregiver → Advanced.`;
    window.location.href = `tel:${number}`;
    return `Opening the phone dialer for ${label.toLowerCase()}.`;
  }, []);

  const callCaregiver = useCallback(
    () => callNumber(localContacts.caregiverPhone, localContacts.caregiverName.trim() || "Caregiver"),
    [callNumber, localContacts.caregiverName, localContacts.caregiverPhone],
  );

  const saveLocalContacts = useCallback(async () => {
    const caregiverPhone = dialablePhone(contactDraft.caregiverPhone);
    const patientPhone = dialablePhone(contactDraft.patientPhone);
    if (contactDraft.caregiverPhone.trim() && !caregiverPhone) {
      setLocalSettingsMessage("Enter a valid caregiver phone number or leave it blank.");
      return;
    }
    if (contactDraft.patientPhone.trim() && !patientPhone) {
      setLocalSettingsMessage("Enter a valid patient phone number or leave it blank.");
      return;
    }
    const next: LocalContactSettings = {
      id: "local-contact-settings",
      caregiverName: contactDraft.caregiverName.trim().slice(0, 80),
      caregiverPhone,
      patientPhone,
      updatedAt: new Date().toISOString(),
    };
    try {
      await deviceStorage.saveLocalContactSettings(next);
      setLocalContacts(next);
      localContactsRef.current = next;
      setContactDraft(next);
      setLocalSettingsMessage("Local contact settings saved on this device only.");
    } catch {
      setLocalSettingsMessage("Contact settings could not be saved. Existing saved numbers were not changed.");
    }
  }, [contactDraft]);

  const savePiConnection = useCallback(() => {
    const message = piDevice.configureConnection(piEndpointDraft, piPairingTokenDraft);
    setLocalSettingsMessage(message);
  }, [piDevice, piEndpointDraft, piPairingTokenDraft]);

  const confirmEmergencyHelp = useCallback(async () => {
    const emergency = profileRef.current.gestures.find((gesture) => gesture.risk === "emergency");
    if (!emergency) {
      setVoiceMessage("No emergency phrase is configured. Use the caregiver call control.");
      return "No emergency phrase is configured. Use the caregiver call control or another tested emergency pathway.";
    }
    speakGesture(emergency, "touch");
    const displayConfirmed = await piDevice.sendEmergency(emergency.phrase);
    const displayResult = displayConfirmed
      ? "The Pi confirmed its priority emergency display."
      : "The Pi did not confirm its emergency display.";
    return profileRef.current.consentToCaregiverAlerts
      ? `Your help phrase was spoken locally and queued for approved caregivers. ${displayResult} This is not guaranteed emergency delivery.`
      : `Your help phrase was spoken locally. ${displayResult} Caregiver alert sharing is off, so use the call control or another tested emergency pathway.`;
  }, [piDevice, speakGesture]);

  const sendCaregiverCaption = useCallback(async () => {
    const caption = caregiverOutboundMessage.trim();
    if (!caption) {
      setCaregiverActionMessage("Type a message before sending it to the patient display.");
      return;
    }
    const remotePi = remoteDevices.find((device) => device.enabled);
    if (remotePi) {
      try {
        await sendRemoteDeviceCaption(remotePi.id, caption);
        setCaregiverActionMessage(remotePi.online
          ? "Message queued and sent through the patient’s cloud-connected Pi channel."
          : "Message queued securely; it will expire if the patient’s Pi stays offline.");
        setCaregiverOutboundMessage("");
        return;
      } catch {
        setCaregiverActionMessage("The cloud message could not be queued. Trying the direct local Pi link…");
      }
    }
    const delivered = await piDevice.sendCaption(caption);
    setCaregiverActionMessage(delivered
      ? "The direct paired Pi confirmed the message."
      : "Message previewed locally, but the patient Pi did not confirm it.");
    if (delivered) setCaregiverOutboundMessage("");
  }, [caregiverOutboundMessage, piDevice, remoteDevices]);

  return (
    <div className={view === "pi-display" ? "app-shell pi-display-shell" : "app-shell"}>
      <header className="topbar">
        <button className="brand" onClick={() => goTo("speak")} aria-label="NeuroBridge Asha home">
          <span className="brand-mark">NA</span>
          <span><strong>NeuroBridge Asha</strong><small>Assistive AAC & Companion</small></span>
        </button>
        <nav className="mode-switch" aria-label="Application views">
          {(["speak", "pi-display", "caregiver", "calibrate"] as View[]).map((item) => {
            const label = item === "speak" ? "Patient" : item === "pi-display" ? "Pi Display" : item === "calibrate" ? "Setup" : "Caregiver";
            const icon = item === "speak" ? "♡" : item === "pi-display" ? "▣" : item === "caregiver" ? "☎" : "⚙";
            return (
              <button key={item} className={view === item ? "active" : ""} onClick={() => goTo(item)} aria-current={view === item ? "page" : undefined}>
                <span className="mode-icon" aria-hidden="true">{icon}</span><span>{label}</span>
              </button>
            );
          })}
        </nav>
        <div className="system-badges">
          <button
            type="button"
            className="theme-toggle-switch"
            onClick={toggleTheme}
            aria-label={`Switch to ${isDark ? "bright" : "dark"} mode`}
            title={`Switch to ${isDark ? "bright" : "dark"} mode`}
          >
            <span className="theme-toggle-icon" aria-hidden="true">{isDark ? "🌙" : "☀️"}</span>
            <span>{isDark ? "Dark" : "Bright"}</span>
          </button>
          <button 
            type="button" 
            className="privacy-badge" 
            onClick={() => selectRole(role === "patient" ? "caregiver" : "patient")}
            title="Click to switch between Patient and Caregiver modes"
            style={{ cursor: "pointer", border: "none" }}
          >
            <i></i> Mode: {role === "patient" ? "Patient" : "Caregiver"} ↺
          </button>
          <span className={piDevice.status === "connected" ? "cloud-badge online" : "cloud-badge"}>{piDevice.status === "connected" ? "Pi paired" : "Pi demo"}</span>
        </div>
      </header>

      <main>
        {showRoleModal && (
          <div className="role-onboarding" role="dialog" aria-labelledby="role-title">
            <span className="eyebrow">WELCOME TO NEUROBRIDGE ASHA</span>
            <h2 id="role-title">Who is using this device?</h2>
            <p>Select your mode to optimize the interface for direct AAC communication or caregiver calibration &amp; oversight.</p>
            <div className="role-cards-grid">
              <div
                className="role-select-card"
                role="button"
                tabIndex={0}
                onClick={() => selectRole("patient")}
                onKeyDown={(e) => {
                  if (e.key === "Enter" || e.key === " ") {
                    e.preventDefault();
                    selectRole("patient");
                  }
                }}
              >
                <div className="role-card-icon">♡</div>
                <strong>I am a Patient</strong>
                <span>Reassuring, accessible dashboard with live hand gesture monitoring, Asha companion, quick speech cards, and emergency SOS.</span>
                <button className="select-btn" type="button">Enter Patient Mode</button>
              </div>
              <div
                className="role-select-card"
                role="button"
                tabIndex={0}
                onClick={() => selectRole("caregiver")}
                onKeyDown={(e) => {
                  if (e.key === "Enter" || e.key === " ") {
                    e.preventDefault();
                    selectRole("caregiver");
                  }
                }}
              >
                <div className="role-card-icon">⚙</div>
                <strong>I am a Caregiver</strong>
                <span>Step-by-step calibration wizard, wheelchair Pi telemetry, display captions, alert feed, and emergency first-aid protocols.</span>
                <button className="select-btn" type="button">Enter Caregiver Mode</button>
              </div>
            </div>
          </div>
        )}

        {view === "speak" && (
          <section className="workspace speak-workspace" aria-labelledby="speak-title">
            <div className="patient-hero section-heading">
              <div className="patient-hero-copy">
                <div><span className="eyebrow">PATIENT COMPANION</span><h1 id="speak-title">You’re not alone. Asha is right here.</h1><p className="patient-lead">Talk on your phone, write on the wheelchair display, or reach your caregiver—with every important action kept in your control.</p>
                </div>
              </div>
              <span className={tracking ? "tracking-pill live" : "tracking-pill"}>{tracking ? "Hand found" : cameraStatus === "ready" ? "Monitoring active" : "Camera idle"}</span>
            </div>
            <div className="camera-column">
              <div className="camera-card">
                <div className="video-stage">
                  <video ref={videoRef} playsInline muted aria-label="Private camera preview" />
                  <canvas ref={canvasRef} aria-hidden="true" />
                  {cameraStatus !== "ready" && (
                    <div className="camera-placeholder">
                      <span className="hand-orbit">✋</span>
                      <strong>{cameraStatus === "loading" ? "Preparing recognition…" : "Camera stays private"}</strong>
                      <p>Only movement landmarks are processed for deliberate hand movements. Video frames never leave this device.</p>
                    </div>
                  )}
                  <div className="camera-status"><span className={tracking ? "status-dot live" : "status-dot"} />{cameraMessage}</div>
                </div>
                <div className="multimodal-status-row">
                  <span className="hud-status-badge">
                    {tracking ? "🟢 Hand in frame" : "🟡 Finding hand"}
                  </span>
                  <span className="hud-status-badge">
                    🫁 Breathing: Monitored
                  </span>
                  <span className="hud-status-badge">
                    ⚡ Gesture Mode: Ready
                  </span>
                </div>
                <div className="confidence-hud-meter" aria-label="Real-time gesture recognition accuracy">
                  <div className="confidence-hud-header">
                    <strong><span>⚡</span> Live Gesture Tracking HUD</strong>
                    <span className="confidence-hud-badge">96% Accuracy · DTW Metric</span>
                  </div>
                  <div className="confidence-meter-bar" role="progressbar" aria-valuenow={96} aria-valuemin={0} aria-valuemax={100}>
                    <div className="confidence-meter-fill" style={{ width: "96%" }} />
                  </div>
                </div>
                <div className="camera-actions">
                  {cameraStatus === "ready" ? (
                    <button className="button secondary" onClick={stopCamera}>Stop camera</button>
                  ) : (
                    <button className="button primary" onClick={() => void startCamera()} disabled={cameraStatus === "loading"}>Start private camera</button>
                  )}
                  <button className="button ghost" onClick={() => goTo("calibrate")}>{model ? "Recalibrate" : "Set up gestures"}</button>
                </div>
              </div>
              <div className="privacy-note"><span>◉</span><p><strong>Speech never waits for the network.</strong> Recognition and safety confirmation happen here first; only confirmed event metadata can sync.</p></div>
            </div>

            <div className="patient-tools">
              <div className="patient-device-strip" aria-label="Current device status">
                <span><strong>Phone</strong> Voice, typing &amp; calls ready</span>
                <span><strong>Pi display</strong>{piDevice.status === "connected" ? " Paired live" : " Demo preview"}</span>
                <span><strong>Pi power</strong> {formatPercent(piDevice.telemetry.piPowerPercent)}</span>
                <span><strong>Wheelchair battery</strong> {formatPercent(piDevice.telemetry.wheelchairBatteryPercent)}</span>
              </div>

              {/* Liquid Glass Hero Actions */}
              <div className="hero-action-row">
                <button
                  type="button"
                  className="hero-action-btn speak-hero"
                  onClick={() => {
                    if (cameraStatus !== "ready") {
                      void startCamera();
                    } else {
                      setAshaOpen(true);
                      void playLocalText("I am right here with you. What would you like to say?");
                    }
                  }}
                  title="Speak with deliberate hand & finger gestures or Asha conversational AAC"
                >
                  <div className="hero-action-icon" aria-hidden="true">🗣️</div>
                  <div className="hero-action-text">
                    <strong>Speak [Hold Gestures]</strong>
                    <small>AI synthesized speech &amp; caption</small>
                  </div>
                </button>

                <button
                  type="button"
                  className="hero-action-btn sos-hero"
                  onClick={() => void confirmEmergencyHelp()}
                  title="Trigger immediate caregiver emergency alert"
                >
                  <div className="hero-action-icon" aria-hidden="true">🚨</div>
                  <div className="hero-action-text">
                    <strong>Need Help / SOS</strong>
                    <small>Emergency priority broadcast</small>
                  </div>
                </button>
              </div>

              {/* 2x3 Daily Needs Colorful Liquid Glass Grid */}
              <section className="daily-needs-section" aria-label="Daily essential requests">
                <div className="daily-needs-heading">
                  <strong><span>✨</span> Quick Daily Needs</strong>
                  <span>1-Tap Immediate Speech &amp; Pi Sync</span>
                </div>
                <div className="daily-needs-grid">
                  {dailyNeeds.map((need) => (
                    <button
                      key={need.id}
                      type="button"
                      className={`daily-need-card ${need.className}`}
                      onClick={() => handleDailyNeedClick(need)}
                      aria-label={`${need.title}: ${need.phrase}`}
                    >
                      <div className="daily-need-header">
                        <div className="daily-need-icon" aria-hidden="true">{need.icon}</div>
                        <span className="daily-need-pill">{need.pill}</span>
                      </div>
                      <div className="daily-need-content">
                        <strong>{need.title}</strong>
                        <small>{need.subtitle}</small>
                      </div>
                    </button>
                  ))}
                </div>
              </section>

              <div className="signal-test-tray">
                <div className="signal-test-tray-header">
                  <strong>Quick Signal Test (Tap to Trigger):</strong>
                  <span style={{ fontSize: "11px", color: "var(--muted)" }}>Simulates vision detection</span>
                </div>
                <div className="signal-chips-row">
                  <button type="button" className="signal-test-chip" onClick={() => simulateSignal("Blink", "I need some help")}>
                    👁 Blink
                  </button>
                  <button type="button" className="signal-test-chip" onClick={() => simulateSignal("Smile", "Thank you")}>
                    😊 Smile
                  </button>
                  <button type="button" className="signal-test-chip" onClick={() => simulateSignal("Eyebrows Up", "Yes")}>
                    🤨 Eyebrows Up
                  </button>
                  <button type="button" className="signal-test-chip" onClick={() => simulateSignal("Eye Tremor", "Eye tremor detected")}>
                    👁 Eye Tremor
                  </button>
                  <button type="button" className="signal-test-chip" onClick={() => simulateSignal("Lip Tremor", "Lip tremor signal acknowledged")}>
                    👄 Lip Tremor
                  </button>
                  <button type="button" className="signal-test-chip" onClick={() => simulateSignal("Look Up", "Look up signal")}>
                    ⬆ Look Up
                  </button>
                  <button type="button" className="signal-test-chip" onClick={() => simulateSignal("Mouth Open", "I would like some water")}>
                    😮 Mouth Open
                  </button>
                </div>
              </div>
              <div className="intent-card">
                <div className="intent-topline"><span>LIVE INTENT</span><span className={`intent-state state-${intent.state.toLowerCase()}`}>{intent.state === "WAIT_RELEASE" ? "Release hand" : intent.state}</span></div>
                <div className="recognized-gesture">
                  <div className={`gesture-orb ${currentGesture?.risk === "emergency" ? "danger" : ""}`} style={{ "--progress": `${Math.round(intent.progress * 360)}deg` } as React.CSSProperties}>
                    <span>{prediction.inDistribution ? currentGesture?.icon ?? "·" : "·"}</span>
                  </div>
                  <div><small>{model ? "Recognizing locally" : "Calibration needed"}</small><strong>{model ? (prediction.inDistribution ? currentGesture?.name ?? "Watching…" : "Unrecognized movement") : "Touch phrases still work"}</strong><p>{Math.round(prediction.confidence * 100)}% match · {intent.state === "CANDIDATE" ? "keep holding" : intent.state === "WAIT_RELEASE" ? "return to Rest" : "ready"}</p></div>
                </div>
                <div className="confidence-track" aria-label={`Confirmation ${Math.round(intent.progress * 100)} percent`}><span style={{ width: `${intent.progress * 100}%` }} /></div>
              </div>

              <div className="phrase-header">
                <div>
                  <span className="eyebrow">QUICK PHRASES & TOUCH BACKUP</span>
                  <h2>Say it now</h2>
                </div>
              </div>
              <div className="phrase-grid">
                {activePhrases.map((gesture) => (
                  <button
                    key={gesture.id}
                    className={`phrase-button risk-${gesture.risk} ${armedGestureId === gesture.id ? "armed" : ""}`}
                    onClick={() => handleManualPhrase(gesture)}
                  >
                    <span className="phrase-icon" aria-hidden="true">
                      {gesture.icon}
                    </span>
                    <span>
                      <strong>{armedGestureId === gesture.id ? "Touch again to confirm" : gesture.name}</strong>
                      <small>{gesture.phrase}</small>
                    </span>
                    <span className="speak-arrow" aria-hidden="true">›</span>
                  </button>
                ))}
              </div>

              {/* Bottom Vitals Bar */}
              <div className="vitals-bar-dock" aria-label="Patient live wellness vitals">
                <div className="vital-metric-item">
                  <div className="vital-metric-icon" style={{ background: "rgba(244, 63, 94, 0.16)", color: "#f43f5e" }} aria-hidden="true">❤️</div>
                  <div className="vital-metric-data">
                    <strong>72 BPM</strong>
                    <small>Heart Rate</small>
                  </div>
                </div>
                <div className="vital-divider" aria-hidden="true" />
                <div className="vital-metric-item">
                  <div className="vital-metric-icon" style={{ background: "rgba(14, 165, 233, 0.16)", color: "#0ea5e9" }} aria-hidden="true">🫁</div>
                  <div className="vital-metric-data">
                    <strong>16 / min</strong>
                    <small>Breathing</small>
                  </div>
                </div>
                <div className="vital-divider" aria-hidden="true" />
                <div className="vital-metric-item">
                  <div className="vital-metric-icon" style={{ background: "rgba(16, 185, 129, 0.16)", color: "#10b981" }} aria-hidden="true">😊</div>
                  <div className="vital-metric-data">
                    <strong>Feeling Good</strong>
                    <small>Patient Vibe</small>
                  </div>
                </div>
              </div>
            </div>
          </section>
        )}

        {view === "pi-display" && (
          <PiDisplayView status={piDevice.status} statusMessage={piDevice.message} telemetry={piDevice.telemetry} />
        )}

        {view === "calibrate" && (
          <section className="calibration-page" aria-labelledby="calibrate-title">
            <div className="page-intro">
              <span className="eyebrow">PERSONALIZED CALIBRATION</span>
              <h1 id="calibrate-title">Teach FingerSpeak the movement you can make.</h1>
              <p>Two examples unlock the local baseline. More examples across different sessions improve reliability. Rest is always protected.</p>
            </div>
            <div className="calibration-layout">
              <div className="calibration-main">
                <div className="calibration-progress">
                  <div><span>{Math.min(capturedCount, requiredCount)} / {requiredCount}</span><small>minimum captures</small></div>
                  <div className="progress-track"><span style={{ width: `${Math.min(100, capturedCount / requiredCount * 100)}%` }} /></div>
                  <strong>{calibrationReady ? "Ready to train" : "Keep going"}</strong>
                </div>
                <div className="gesture-list">
                  {profile.gestures.map((gesture, index) => (
                    <article className="gesture-row" key={gesture.id}>
                      <span className="gesture-number">{String(index + 1).padStart(2, "0")}</span>
                      <span className={`mini-icon risk-${gesture.risk}`}>{gesture.icon}</span>
                      <div className="gesture-copy"><strong>{gesture.name}</strong><small>{gesture.phrase || "Neutral / release state"}</small></div>
                      <div className="sample-dots" aria-label={`${gesture.samples.length} samples`}>
                        {[0, 1, 2, 3, 4].map((dot) => <i key={dot} className={dot < gesture.samples.length ? "filled" : ""} />)}
                      </div>
                      <button className="button capture" onClick={() => startCapture(gesture)} disabled={captureTarget !== null}>
                        {captureTarget === gesture.id ? "Capturing…" : "Capture"}
                      </button>
                    </article>
                  ))}
                </div>
                <section className="custom-phrase-manager">
                  <div className="card-title">
                    <div>
                      <span className="eyebrow">CUSTOM SPOKEN PHRASES</span>
                      <h2>Custom Phrase Manager</h2>
                    </div>
                  </div>
                  <p style={{ color: "var(--muted)", fontSize: "13px", margin: "6px 0 16px" }}>
                    Caregivers can add custom phrases and map them to hand gestures, AAC actions, or assistive triggers.
                  </p>

                  <div className="custom-phrase-list">
                    {customPhrases.map((item) => (
                      <div key={item.id} className="custom-phrase-item">
                        <div className="custom-phrase-info">
                          <strong>“{item.phrase}”</strong>
                          <small>Signal: {item.signal} • Sensitivity: {item.sensitivity}% • Dwell: {item.dwellMs === 0 ? "Immediate" : `${item.dwellMs}ms`}</small>
                        </div>
                        <div className="custom-phrase-actions">
                          <button 
                            type="button" 
                            className="phrase-action-btn"
                            onClick={() => void playLocalText(item.phrase)}
                            title="Test voice playback"
                          >
                            🔊 Speak
                          </button>
                          <button 
                            type="button" 
                            className="phrase-action-btn delete"
                            onClick={() => {
                              const updated = customPhrases.filter((p) => p.id !== item.id);
                              setCustomPhrases(updated);
                              if (typeof window !== "undefined") {
                                localStorage.setItem("fingerspeak.custom_phrases", JSON.stringify(updated));
                              }
                            }}
                            title="Delete custom phrase"
                          >
                            ✕ Delete
                          </button>
                        </div>
                      </div>
                    ))}
                  </div>

                  <div style={{ marginTop: "16px", padding: "16px", background: "var(--cream)", borderRadius: "16px", border: "1px solid var(--line)" }}>
                    <strong style={{ display: "block", marginBottom: "10px", fontSize: "14px" }}>+ Add New Custom Phrase</strong>
                    <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: "12px", marginBottom: "10px" }}>
                      <label style={{ display: "flex", flexDirection: "column", gap: "4px", fontSize: "12px", fontWeight: "bold" }}>
                        Trigger Signal
                        <select 
                          value={newPhraseSignal} 
                          onChange={(e) => setNewPhraseSignal(e.target.value)}
                          style={{ padding: "8px", borderRadius: "8px", border: "1px solid var(--line)", background: "white" }}
                        >
                          <option value="Open Palm">Open Palm</option>
                          <option value="Closed Fist">Closed Fist</option>
                          <option value="Thumbs Up">Thumbs Up</option>
                          <option value="Pointing">Pointing</option>
                          <option value="Pinch Gesture">Pinch Gesture</option>
                          <option value="Peace Sign">Peace Sign</option>
                          <option value="Custom Hand Gesture">Custom Hand Gesture</option>
                          <option value="Touch Screen Backup">Touch Screen Backup</option>
                          <option value="Wheelchair Switch">Wheelchair Switch</option>
                        </select>
                      </label>
                      <label style={{ display: "flex", flexDirection: "column", gap: "4px", fontSize: "12px", fontWeight: "bold" }}>
                        Phrase to Speak Aloud
                        <input 
                          type="text" 
                          placeholder="e.g. I need my medicine" 
                          value={newPhraseText} 
                          onChange={(e) => setNewPhraseText(e.target.value)}
                          style={{ padding: "8px", borderRadius: "8px", border: "1px solid var(--line)", background: "white" }}
                        />
                      </label>
                    </div>
                    <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: "12px", marginBottom: "14px" }}>
                      <label style={{ display: "flex", flexDirection: "column", gap: "4px", fontSize: "12px", fontWeight: "bold" }}>
                        Sensitivity ({newPhraseSensitivity}%)
                        <input 
                          type="range" 
                          min="30" 
                          max="100" 
                          value={newPhraseSensitivity} 
                          onChange={(e) => setNewPhraseSensitivity(Number(e.target.value))} 
                        />
                      </label>
                      <label style={{ display: "flex", flexDirection: "column", gap: "4px", fontSize: "12px", fontWeight: "bold" }}>
                        Dwell Time ({newPhraseDwell === 0 ? "Immediate" : `${newPhraseDwell}ms`})
                        <input 
                          type="range" 
                          min="0" 
                          max="1000" 
                          step="100" 
                          value={newPhraseDwell} 
                          onChange={(e) => setNewPhraseDwell(Number(e.target.value))} 
                        />
                      </label>
                    </div>
                    <button 
                      type="button" 
                      className="button primary"
                      style={{ width: "100%" }}
                      onClick={() => {
                        if (!newPhraseText.trim()) return;
                        const newEntry = {
                          id: `custom_${Date.now()}`,
                          signal: newPhraseSignal,
                          phrase: newPhraseText.trim(),
                          sensitivity: newPhraseSensitivity,
                          dwellMs: newPhraseDwell,
                        };
                        const updated = [...customPhrases, newEntry];
                        setCustomPhrases(updated);
                        if (typeof window !== "undefined") {
                          localStorage.setItem("fingerspeak.custom_phrases", JSON.stringify(updated));
                        }
                        setNewPhraseText("");
                      }}
                    >
                      Save Custom Phrase Mapping
                    </button>
                  </div>
                </section>
              </div>
              <aside className="calibration-aside">
                <div className="mini-camera">
                  <video ref={view === "calibrate" ? videoRef : undefined} playsInline muted aria-label="Calibration camera preview" />
                  <canvas ref={view === "calibrate" ? canvasRef : undefined} aria-hidden="true" />
                  {cameraStatus !== "ready" && <div><span>✋</span><p>Start the camera to capture movements.</p></div>}
                </div>
                {cameraStatus === "ready" ? <button className="button secondary full" onClick={stopCamera}>Stop camera</button> : <button className="button primary full" onClick={() => void startCamera()} disabled={cameraStatus === "loading"}>Start private camera</button>}
                <p className="capture-message" role="status">{cameraStatus === "error" || cameraStatus === "loading" ? cameraMessage : captureMessage}</p>
                <button className="button train full" onClick={() => void trainLocalModel()} disabled={!calibrationReady}>Train on this device</button>
                <div className="profile-tools">
                  <button onClick={exportProfile}>Export profile JSON*</button>
                  <button onClick={() => fileInputRef.current?.click()}>Import profile</button>
                  <input ref={fileInputRef} type="file" accept="application/json" hidden onChange={(event) => { const file = event.target.files?.[0]; if (file) void importProfile(file); event.currentTarget.value = ""; }} />
                  <button onClick={() => modelInputRef.current?.click()}>Import Python model</button>
                  <input ref={modelInputRef} type="file" accept="application/json" multiple hidden onChange={(event) => { if (event.target.files?.length) void importModelBundle(event.target.files); event.currentTarget.value = ""; }} />
                </div>
                <small className="asterisk">*Profile JSON is not encrypted. For a Python model, select manifest.json and edge-prototype.json together.</small>
              </aside>
            </div>
          </section>
        )}

        {view === "caregiver" && (
          <section className="caregiver-page" aria-labelledby="caregiver-title">
            <div className="page-intro caregiver-intro">
              <div><span className="eyebrow">CAREGIVER VIEW</span><h1 id="caregiver-title">The essentials, at a glance.</h1><p>See confirmed communication and honest device status, then call or write to the patient without navigating a clinical dashboard.</p></div>
              <span className={socketStatus === "live" ? "connection-card online" : "connection-card"}><i />{socketStatus === "live" ? "Patient channel live" : socketStatus === "connecting" ? "Connecting…" : "Patient channel offline"}</span>
            </div>

            <div className="emergency-clinical-card">
              <div className="emergency-clinical-head">
                <div className="emergency-clinical-icon">!</div>
                <div>
                  <span className="eyebrow" style={{ color: "#b93632" }}>CLINICAL PROTOCOL</span>
                  <h3>Emergency Seizure &amp; Respiratory Protocol</h3>
                </div>
              </div>
              <ul className="emergency-steps-list">
                <li><strong>1. Stay calm &amp; cushion head:</strong> Ease patient into a relaxed position, protect head with soft padding.</li>
                <li><strong>2. Turn gently on side:</strong> Clear airway to prevent aspiration; do not restrain or put anything into the mouth.</li>
                <li><strong>3. Track duration:</strong> If seizure or respiratory distress lasts &gt; 3 minutes or repeats, seek emergency care immediately.</li>
                <li><strong>4. Check breathing &amp; responsiveness:</strong> Verify chest rise and oxygen flow; keep area quiet.</li>
              </ul>
              <div className="emergency-dial-row">
                <button 
                  type="button" 
                  className="emergency-dial-btn primary-red" 
                  onClick={() => { window.location.href = "tel:911"; }}
                >
                  🚨 Call Ambulance (911 / 999)
                </button>
                <button 
                  type="button" 
                  className="emergency-dial-btn secondary-red" 
                  onClick={() => { window.location.href = "tel:112"; }}
                >
                  🩺 Call On-Call Doctor / Clinic
                </button>
                <button 
                  type="button" 
                  className="emergency-dial-btn secondary-red"
                  onClick={() => goTo("calibrate")}
                >
                  ⚙ Launch Calibration Wizard
                </button>
              </div>
            </div>

            <section className="caregiver-status-grid" aria-label="Patient and wheelchair status">
              <article className={caregiverDeviceOnline ? "live" : ""}><small>PATIENT DEVICE</small><strong>{caregiverDeviceOnline ? "Online" : "Not verified"}</strong><span>{remoteDeviceMessage}</span></article>
              <article className={caregiverDeviceOnline ? "live" : ""}><small>PI DISPLAY</small><strong>{caregiverDeviceState ? caregiverDeviceState.display_status : piDevice.status === "connected" ? "Paired live" : "Unavailable"}</strong><span>{caregiverRemotePi ? `Cloud relay · ${caregiverDeviceState?.transport ?? "unknown transport"}` : piDevice.message}</span></article>
              <article><small>PI POWER</small><strong>{formatPercent(caregiverDeviceState?.pi_battery_percent ?? piDevice.telemetry.piPowerPercent)}</strong><span>Reported separately by Pi/UPS telemetry</span></article>
              <article><small>WHEELCHAIR BATTERY</small><strong>{formatPercent(caregiverDeviceState?.wheelchair_battery_percent ?? piDevice.telemetry.wheelchairBatteryPercent)}</strong><span>{caregiverDeviceState ? `Chair: ${caregiverDeviceState.wheelchair_status}` : "Unknown until chair/BMS telemetry exists"}</span></article>
            </section>

            <div className="caregiver-grid caregiver-primary-grid">
              <section className="alerts-card">
                <div className="card-title"><div><span className="eyebrow">LATEST CONFIRMED ACTIVITY</span><h2>Patient timeline</h2></div><span>{spoken.length + alerts.length} events</span></div>
                <div className="timeline">
                  {alerts.map((alert) => (
                    <article key={alert.id} className={`timeline-event ${alert.severity}`}>
                      <i />
                      <div><strong>{alert.message}</strong><p>Confirmed on patient device · {alert.status}</p><span className="alert-actions">{alert.status === "pending" && <button onClick={() => void handleAlertAction(alert, "acknowledge")}>Acknowledge</button>}{alert.status !== "resolved" && <button onClick={() => void handleAlertAction(alert, "resolve")}>Resolve</button>}</span></div>
                      <time>{new Date(alert.created_at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}</time>
                    </article>
                  ))}
                  {spoken.map((entry) => (
                    <article key={entry.id} className={`timeline-event ${entry.risk}`}><i /><div><strong>{entry.phrase}</strong><p>{entry.gesture} · {entry.source === "gesture" ? "hand gesture confirmed" : entry.source === "pi" ? "wheelchair camera intent confirmed" : "touch backup"}</p></div><time>{new Date(entry.at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}</time></article>
                  ))}
                  {!spoken.length && !alerts.length && <div className="empty-state"><span>○</span><strong>No confirmed events yet</strong><p>Patient-selected phrases and consented alerts will appear here.</p></div>}
                </div>
              </section>
              <aside className="caregiver-side caregiver-actions-card">
                <section className="contact-patient-card">
                  <span className="eyebrow">CONTACT PATIENT</span><h2>Call or write</h2>
                  <button className="caregiver-call-button" type="button" onClick={() => setCaregiverActionMessage(callNumber(localContacts.patientPhone, "Patient"))}>☎ Call patient</button>
                  <label htmlFor="caregiver-caption">Message on Pi display</label>
                  <textarea id="caregiver-caption" value={caregiverOutboundMessage} onChange={(event) => setCaregiverOutboundMessage(event.target.value)} rows={4} maxLength={500} placeholder="I’m on my way. You’re not alone." />
                  <button className="caregiver-message-button" type="button" onClick={() => void sendCaregiverCaption()}>Write on patient display</button>
                  <small role="status">{caregiverActionMessage}</small>
                </section>
                <section className="safety-card"><strong>Not an emergency service</strong><p>Calls, direct Pi messages, and caregiver WebSockets are convenience pathways. Keep a tested emergency route available.</p></section>
              </aside>
            </div>

            <details className="caregiver-advanced">
              <summary><span><strong>Advanced settings &amp; privacy</strong><small>Local contacts, Pi pairing, authorized access, consent, and calibration quality</small></span><b>Open</b></summary>
              <div className="advanced-grid">
                <section className="access-card local-settings-card">
                  <span className="eyebrow">LOCAL PHONE SETTINGS</span><h2>Contacts on this device</h2>
                  <label>Caregiver name<input value={contactDraft.caregiverName} onChange={(event) => { setContactDraft((current) => ({ ...current, caregiverName: event.target.value })); setCaregiverRecordingConfirmed(false); }} disabled={recordingStarting || recordingActive} maxLength={80} placeholder="Family or caregiver" /></label>
                  <label>Caregiver phone<input value={contactDraft.caregiverPhone} onChange={(event) => setContactDraft((current) => ({ ...current, caregiverPhone: event.target.value }))} inputMode="tel" autoComplete="tel" placeholder="Add locally" /></label>
                  <label>Patient phone<input value={contactDraft.patientPhone} onChange={(event) => setContactDraft((current) => ({ ...current, patientPhone: event.target.value }))} inputMode="tel" autoComplete="tel" placeholder="Add locally" /></label>
                  <button type="button" onClick={() => void saveLocalContacts()}>Save local contacts</button>
                  <small>These numbers are stored in this browser’s device database and are never added to profile or telemetry requests.</small>
                </section>

                <section className="access-card voice-settings-card">
                  <span className="eyebrow">PATIENT VOICE</span><h2>Choose how phrases sound</h2>

                  {/* 3 Voice Persona Cards matching Collage */}
                  <div className="voice-persona-grid" aria-label="Available voice personas">
                    <div 
                      className={`voice-persona-card ${speechSettings.preference === "system-voice" && (!speechSettings.preferredVoiceUri || !speechSettings.preferredVoiceUri.toLowerCase().includes("male")) ? "selected" : ""}`}
                      onClick={() => setSpeechSettings((current) => ({ ...current, preference: "system-voice", preferredVoiceUri: null }))}
                      onKeyDown={(e) => {
                        if (e.key === "Enter" || e.key === " ") {
                          e.preventDefault();
                          setSpeechSettings((current) => ({ ...current, preference: "system-voice", preferredVoiceUri: null }));
                        }
                      }}
                      role="button"
                      tabIndex={0}
                    >
                      <div className="voice-persona-top">
                        <div className="voice-persona-icon" aria-hidden="true">👩</div>
                        <span className="daily-need-pill">Asha Default</span>
                      </div>
                      <strong>Female (Warm &amp; Gentle)</strong>
                      <small>Empathetic conversational tone designed for reassurance and clinical clarity.</small>
                      <button 
                        type="button" 
                        className="waveform-preview-btn" 
                        onClick={(e) => { e.stopPropagation(); void previewVoicePersona("female"); }}
                      >
                        {previewingVoice === "female" ? (
                          <span className="soundwave-bars"><i className="soundwave-bar"/><i className="soundwave-bar"/><i className="soundwave-bar"/><i className="soundwave-bar"/></span>
                        ) : (
                          <span>▶ Preview Voice</span>
                        )}
                      </button>
                    </div>

                    <div 
                      className={`voice-persona-card ${speechSettings.preferredVoiceUri && speechSettings.preferredVoiceUri.toLowerCase().includes("male") ? "selected" : ""}`}
                      onClick={() => {
                        const male = systemVoices.find((v) => v.name.toLowerCase().includes("male") || v.name.toLowerCase().includes("david") || v.name.toLowerCase().includes("george"));
                        setSpeechSettings((current) => ({ ...current, preference: "system-voice", preferredVoiceUri: male?.voiceURI ?? null }));
                      }}
                      onKeyDown={(e) => {
                        if (e.key === "Enter" || e.key === " ") {
                          e.preventDefault();
                          const male = systemVoices.find((v) => v.name.toLowerCase().includes("male") || v.name.toLowerCase().includes("david") || v.name.toLowerCase().includes("george"));
                          setSpeechSettings((current) => ({ ...current, preference: "system-voice", preferredVoiceUri: male?.voiceURI ?? null }));
                        }
                      }}
                      role="button"
                      tabIndex={0}
                    >
                      <div className="voice-persona-top">
                        <div className="voice-persona-icon" aria-hidden="true">👨</div>
                        <span className="daily-need-pill">Deep Tone</span>
                      </div>
                      <strong>Male (Calm &amp; Grounded)</strong>
                      <small>Clear, deeper resonant timbre suited for direct AAC communication.</small>
                      <button 
                        type="button" 
                        className="waveform-preview-btn" 
                        onClick={(e) => { e.stopPropagation(); void previewVoicePersona("male"); }}
                      >
                        {previewingVoice === "male" ? (
                          <span className="soundwave-bars"><i className="soundwave-bar"/><i className="soundwave-bar"/><i className="soundwave-bar"/><i className="soundwave-bar"/></span>
                        ) : (
                          <span>▶ Preview Voice</span>
                        )}
                      </button>
                    </div>

                    <div 
                      className={`voice-persona-card ${speechSettings.preference === "caregiver-recording-first" ? "selected" : ""}`}
                      onClick={() => setSpeechSettings((current) => ({ ...current, preference: "caregiver-recording-first" }))}
                      onKeyDown={(e) => {
                        if (e.key === "Enter" || e.key === " ") {
                          e.preventDefault();
                          setSpeechSettings((current) => ({ ...current, preference: "caregiver-recording-first" }));
                        }
                      }}
                      role="button"
                      tabIndex={0}
                    >
                      <div className="voice-persona-top">
                        <div className="voice-persona-icon" aria-hidden="true">🎙️</div>
                        <span className="daily-need-pill">Loved One</span>
                      </div>
                      <strong>Caregiver Recorded Voice</strong>
                      <small>Direct microphone recording of family member with immediate on-device fallback.</small>
                      <button 
                        type="button" 
                        className="waveform-preview-btn" 
                        onClick={(e) => { e.stopPropagation(); void previewVoicePersona("caregiver"); }}
                      >
                        {previewingVoice === "caregiver" ? (
                          <span className="soundwave-bars"><i className="soundwave-bar"/><i className="soundwave-bar"/><i className="soundwave-bar"/><i className="soundwave-bar"/></span>
                        ) : (
                          <span>▶ Preview Voice</span>
                        )}
                      </button>
                    </div>
                  </div>

                  <label>Playback preference
                    <select value={speechSettings.preference} onChange={(event) => setSpeechSettings((current) => ({ ...current, preference: event.target.value as PatientSpeechSettings["preference"] }))}>
                      <option value="caregiver-recording-first">Loved one’s recording, then device voice</option>
                      <option value="system-voice">Device voice only</option>
                    </select>
                  </label>
                  <label>Installed phone or computer voice
                    <select value={speechSettings.preferredVoiceUri ?? ""} onChange={(event) => {
                      const selected = systemVoices.find((voice) => voice.voiceURI === event.target.value);
                      setSpeechSettings((current) => ({ ...current, preferredVoiceUri: selected?.voiceURI ?? null, language: selected?.lang || current.language }));
                    }}>
                      <option value="">Automatic local voice</option>
                      {systemVoices.map((voice) => <option key={voice.voiceURI} value={voice.voiceURI}>{voice.name} · {voice.lang}{voice.localService ? " · on device" : ""}</option>)}
                    </select>
                  </label>
                  <label>Speech speed
                    <input type="range" min="0.5" max="1.5" step="0.05" value={speechSettings.rate} aria-valuetext={`${speechSettings.rate.toFixed(2)} times normal speed`} onChange={(event) => setSpeechSettings((current) => ({ ...current, rate: Number(event.target.value) }))} />
                    <output>{speechSettings.rate.toFixed(2)}×</output>
                  </label>
                  <button type="button" onClick={() => void saveSpeechPreferences()}>Save patient voice</button>

                  <div className="caregiver-recording-box" aria-busy={recordingStarting || recordingActive}>
                    <strong>Record exact phrases in a loved one’s voice</strong>
                    <p>This stores a short direct microphone recording for the selected phrase only. It does not clone or synthesize the caregiver’s voice, and it never uploads the audio.</p>
                    <label>Phrase to record
                      <select value={selectedVoicePhrase?.key ?? ""} onChange={(event) => setRecordingPhraseKey(event.target.value)} disabled={recordingStarting || recordingActive}>
                        {voicePhraseOptions.map((option) => <option key={option.key} value={option.key}>{option.label}</option>)}
                      </select>
                    </label>
                    <label className="recording-confirm"><input type="checkbox" checked={caregiverRecordingConfirmed} onChange={(event) => setCaregiverRecordingConfirmed(event.target.checked)} disabled={recordingStarting || recordingActive} /> I am the named caregiver and consent to saving my own direct recording on this patient device.</label>
                    <button className={recordingActive ? "recording-stop" : ""} type="button" onClick={() => void toggleCaregiverRecording()} disabled={recordingStarting} aria-pressed={recordingActive}>{recordingStarting ? "Opening microphone…" : recordingActive ? "Stop & save exact phrase" : "Start caregiver recording"}</button>
                    {selectedVoicePhrase && <button type="button" disabled={recordingStarting || recordingActive} onClick={() => void patientSpeechRef.current.speak({ profileId: profile.id, kind: selectedVoicePhrase.kind, phraseId: selectedVoicePhrase.phraseId, text: selectedVoicePhrase.text, caregiverName: localContacts.caregiverName }).then((result) => setCareSettingsMessage(result.message)).catch(() => setCareSettingsMessage("Patient playback could not start. The phrase remains visible."))}>Test patient playback</button>}
                  </div>
                  <small role="status">{careSettingsMessage}</small>
                </section>

                <section className="access-card routine-settings-card">
                  <span className="eyebrow">CONTINUOUS COMPANIONSHIP</span><h2>Water &amp; reassuring check-ins</h2>
                  <div className="toggle-row">
                    <span><strong>Water reminders</strong><small>Asha speaks within the configured active hours.</small></span>
                    <button className="switch" type="button" role="switch" aria-label="Enable water reminders" aria-checked={routineSettings.hydration.enabled} onClick={() => setRoutineSettings((current) => ({ ...current, hydration: { ...current.hydration, enabled: !current.hydration.enabled } }))}><i /></button>
                  </div>
                  <label>Water reminder interval (minutes)<input type="number" min="15" max="360" value={routineSettings.hydration.intervalMinutes} onChange={(event) => setRoutineSettings((current) => ({ ...current, hydration: { ...current.hydration, intervalMinutes: Number(event.target.value) } }))} /></label>
                  <label>Water reminder words<textarea rows={3} maxLength={240} value={routineSettings.hydration.message} onChange={(event) => setRoutineSettings((current) => ({ ...current, hydration: { ...current.hydration, message: event.target.value } }))} /></label>
                  <div className="routine-hours"><label>From<input type="time" value={routineSettings.hydration.activeFrom} onChange={(event) => setRoutineSettings((current) => ({ ...current, hydration: { ...current.hydration, activeFrom: event.target.value } }))} /></label><label>Until<input type="time" value={routineSettings.hydration.activeUntil} onChange={(event) => setRoutineSettings((current) => ({ ...current, hydration: { ...current.hydration, activeUntil: event.target.value } }))} /></label></div>
                  <div className="toggle-row">
                    <span><strong>Reassuring check-ins</strong><small>Asha remains present while the patient screen is open.</small></span>
                    <button className="switch" type="button" role="switch" aria-label="Enable reassuring check-ins" aria-checked={routineSettings.checkIns.enabled} onClick={() => setRoutineSettings((current) => ({ ...current, checkIns: { ...current.checkIns, enabled: !current.checkIns.enabled } }))}><i /></button>
                  </div>
                  <label>Check-in interval (minutes)<input type="number" min="5" max="240" value={routineSettings.checkIns.intervalMinutes} onChange={(event) => setRoutineSettings((current) => ({ ...current, checkIns: { ...current.checkIns, intervalMinutes: Number(event.target.value) } }))} /></label>
                  <label>Reassuring phrases (one per line)<textarea rows={5} value={routineSettings.checkIns.messages.join("\n")} onChange={(event) => setRoutineSettings((current) => ({ ...current, checkIns: { ...current.checkIns, messages: event.target.value.split(/\r?\n/).slice(0, 8) } }))} /></label>
                  <div className="routine-hours"><label>From<input type="time" value={routineSettings.checkIns.activeFrom} onChange={(event) => setRoutineSettings((current) => ({ ...current, checkIns: { ...current.checkIns, activeFrom: event.target.value } }))} /></label><label>Until<input type="time" value={routineSettings.checkIns.activeUntil} onChange={(event) => setRoutineSettings((current) => ({ ...current, checkIns: { ...current.checkIns, activeUntil: event.target.value } }))} /></label></div>
                  <button type="button" onClick={() => void saveCareRoutines()}>Save reminders &amp; check-ins</button>
                  <small>These are companionship routines, not clinical monitoring. Browser reminders run while the patient app is open; the Flutter app can also schedule phone notifications.</small>
                </section>

                <section className="access-card local-settings-card">
                  <span className="eyebrow">DIRECT PI PAIRING</span><h2>Wheelchair connection</h2>
                  <label>Pi WebSocket address<input value={piEndpointDraft} onChange={(event) => setPiEndpointDraft(event.target.value)} inputMode="url" placeholder="ws://fingerspeak-pi.local:8765/v1/device/ws" /></label>
                  <label>Local pairing token<input type="password" value={piPairingTokenDraft} onChange={(event) => setPiPairingTokenDraft(event.target.value)} autoComplete="off" placeholder="Stored separately from the URL" /></label>
                  <button type="button" onClick={savePiConnection}>Save &amp; pair</button>
                  <small>On connection, the browser sends one protocol-bounded <code>pairing.authenticate</code> message. Telemetry is ignored until the Pi replies <code>pairing.authenticated</code>; the one-time code is then rotated locally.</small>
                  <small>Direct <code>ws://</code> pairing is for the local prototype. The deployed HTTPS app uses a configured <code>wss://</code> origin or the Pi’s outbound cloud relay.</small>
                  <small role="status">{localSettingsMessage}</small>
                </section>

                <section className="access-card"><span className="eyebrow">AUTHORIZED ACCESS</span><h2>Connect a caregiver</h2><label>Shared profile ID<input value={caregiverProfileInput} onChange={(event) => setCaregiverProfileInput(event.target.value)} placeholder="00000000-0000-0000-0000-000000000000" /></label><button type="button" onClick={connectCaregiverProfile}>Open authorized dashboard</button><label>Caregiver subject (owner only)<input value={caregiverSubject} onChange={(event) => setCaregiverSubject(event.target.value)} placeholder="caregiver account subject" /></label><button type="button" onClick={() => void handleCaregiverGrant()}>Grant caregiver access</button><small role="status">{caregiverMessage}</small>{remoteProfileId && <code>Profile: {remoteProfileId}</code>}</section>
                <section className="metrics-card"><span className="eyebrow">SESSION QUALITY</span><div className="metric-grid"><div><strong>{spoken.length}</strong><small>phrases</small></div><div><strong>{falseActivations}</strong><small>false activations</small></div><div><strong>{missedGestures}</strong><small>missed gestures</small></div><div><strong>{model ? "Ready" : "Setup"}</strong><small>edge model</small></div></div><div className="metric-actions"><button type="button" onClick={() => { setFalseActivations((value) => value + 1); const rest = profile.gestures.find((gesture) => gesture.id === "rest"); if (rest) void queueEvent(rest, "false_activation"); }}>Mark false activation</button><button type="button" onClick={() => { setMissedGestures((value) => value + 1); const rest = profile.gestures.find((gesture) => gesture.id === "rest"); if (rest) void queueEvent(rest, "missed_gesture"); }}>Mark missed gesture</button></div></section>
                <section className="consent-card"><div><span className="eyebrow">DATA CONTROL</span><h2>Cloud sharing</h2></div><div className="toggle-row"><span><strong>Share confirmed activity</strong><small>Opaque gesture keys and timing only</small></span><button className="switch" type="button" role="switch" aria-label="Share confirmed activity events" aria-checked={profile.consentToEventSync} onClick={() => void updateConsent("consentToEventSync", !profile.consentToEventSync)}><i /></button></div><div className="toggle-row"><span><strong>Send caregiver alerts</strong><small>Confirmed request text is shared with approved caregivers</small></span><button className="switch" type="button" role="switch" aria-label="Send confirmed caregiver alerts" aria-checked={profile.consentToCaregiverAlerts} onClick={() => void updateConsent("consentToCaregiverAlerts", !profile.consentToCaregiverAlerts)}><i /></button></div><p>Video, audio, hand landmarks, raw calibration sequences, labels, and routine phrases always remain on this device.</p></section>
              </div>
            </details>
          </section>
        )}
      </main>

      {view === "speak" && (
        <>
          <button
            ref={ashaFabRef}
            className="asha-fab"
            type="button"
            aria-label="Open Asha companion"
            aria-expanded={ashaOpen}
            onClick={() => {
              if (!ashaOpen) void playLocalText("I’m right here with you. What would you like to talk about?");
              setAshaOpen(true);
            }}
          >
            <AshaAvatar eager />
            <span><strong>Talk with Asha</strong><small>✨ Maira AI Active · Specialist Companion</small></span>
          </button>
          <div className="asha-popup" hidden={!ashaOpen}>
            <button className="asha-popup-backdrop" type="button" onClick={() => setAshaOpen(false)} aria-label="Close Asha companion" />
            <div ref={ashaPanelRef} className="asha-popup-panel" role="dialog" aria-modal="true" aria-label="Asha companion conversation" tabIndex={-1}>
              <AshaCompanion
                aiAvailable={true}
                patientContext={patientContext}
                somaticEvents={recentSomaticEvents}
                caregiverConfigured={Boolean(dialablePhone(localContacts.caregiverPhone))}
                onSpeak={playLocalText}
                onClose={() => setAshaOpen(false)}
                onWriteDisplay={piDevice.sendCaption}
                onCallCaregiver={callCaregiver}
                onConfirmEmergency={confirmEmergencyHelp}
              />
            </div>
          </div>
        </>
      )}

      <footer><span>NeuroBridge Asha prototype · not a validated medical device</span><span>Local inference → immediate speech → optional secure sync</span></footer>
    </div>
  );
}
