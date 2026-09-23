import type { FingerSpeakProfile, Gesture } from "./fingerspeak";
import type { PiPatientIntent, PiPatientIntentName } from "./pi-device";

export const PI_INTENT_MIN_CONFIDENCE = 0.72;
export const PI_EMERGENCY_CONFIRMATION_WINDOW_MS = 10_000;

export type PiControlSettings = {
  profileId: string;
  enabled: boolean;
  bindings: Record<PiPatientIntentName, string | null>;
};

export function createDefaultPiControlSettings(profileId: string): PiControlSettings {
  return {
    profileId,
    enabled: true,
    bindings: {
      blink: "water",
      look_left: "nurse",
      look_right: "emergency",
      eyebrows_up: "yes",
      mouth_open: "emergency",
    },
  };
}

export type PiEmergencyArm = {
  profileId: string;
  gestureId: string;
  phrase: string;
  intent: PiPatientIntentName;
  firstMessageId: string;
  expiresAt: number;
};

export type PiIntentRoute =
  | { action: "ignore"; reason: string; nextEmergencyArm: null }
  | { action: "arm-emergency"; reason: string; nextEmergencyArm: PiEmergencyArm }
  | { action: "speak"; gesture: Gesture; nextEmergencyArm: null };

/**
 * Maps a semantic Pi hardware event only through the active profile's current local device bindings.
 * The Pi sends no phrase, audio, landmarks, frame, or profile data.
 */
export function routePiPatientIntent(
  event: PiPatientIntent,
  profile: FingerSpeakProfile,
  piControls: PiControlSettings,
  emergencyArm: PiEmergencyArm | null,
  now = Date.now(),
): PiIntentRoute {
  if (!piControls.enabled || piControls.profileId !== profile.id) {
    return { action: "ignore", reason: "Pi controls are disabled or belong to another profile.", nextEmergencyArm: null };
  }
  if (event.confidence < PI_INTENT_MIN_CONFIDENCE) {
    return { action: "ignore", reason: "Pi movement confidence was below the local safety threshold.", nextEmergencyArm: null };
  }
  const gestureId = piControls.bindings[event.intent];
  if (!gestureId) return { action: "ignore", reason: "This Pi movement has no current patient phrase binding.", nextEmergencyArm: null };
  const gesture = profile.gestures.find((candidate) => candidate.id === gestureId);
  if (!gesture?.phrase) return { action: "ignore", reason: "The current Pi movement binding does not resolve to a spoken phrase.", nextEmergencyArm: null };

  if (gesture.risk !== "emergency") return { action: "speak", gesture, nextEmergencyArm: null };
  const confirmsCurrentArm = emergencyArm
    && emergencyArm.profileId === profile.id
    && emergencyArm.gestureId === gesture.id
    && emergencyArm.phrase === gesture.phrase
    && emergencyArm.intent === event.intent
    && emergencyArm.firstMessageId !== event.messageId
    && emergencyArm.expiresAt >= now;
  if (confirmsCurrentArm) return { action: "speak", gesture, nextEmergencyArm: null };
  return {
    action: "arm-emergency",
    reason: "Emergency phrase armed. Repeat the same deliberate movement once more within ten seconds to speak it.",
    nextEmergencyArm: {
      profileId: profile.id,
      gestureId: gesture.id,
      phrase: gesture.phrase,
      intent: event.intent,
      firstMessageId: event.messageId,
      expiresAt: now + PI_EMERGENCY_CONFIRMATION_WINDOW_MS,
    },
  };
}
