import assert from "node:assert/strict";
import test from "node:test";

import { createDefaultProfile } from "../app/lib/fingerspeak";
import {
  PI_EMERGENCY_CONFIRMATION_WINDOW_MS,
  createDefaultPiControlSettings,
  routePiPatientIntent,
} from "../app/lib/pi-intent-routing";
import type { PiPatientIntent, PiPatientIntentName } from "../app/lib/pi-device";

test("Pi semantics map only through the current profile bindings", () => {
  const profile = createDefaultProfile();
  const settings = createDefaultPiControlSettings(profile.id);
  settings.bindings["look_right"] = "nurse";

  const route = routePiPatientIntent(intent("look_right"), profile, settings, null, 1_000);
  assert.equal(route.action, "speak");
  if (route.action === "speak") assert.equal(route.gesture.id, "nurse");

  settings.bindings["look_right"] = "missing-phrase";
  assert.equal(routePiPatientIntent(intent("look_right"), profile, settings, null, 1_000).action, "ignore");
  settings.profileId = "another-profile";
  assert.equal(routePiPatientIntent(intent("look_right"), profile, settings, null, 1_000).action, "ignore");
});

test("low-confidence or disabled Pi intents fail closed", () => {
  const profile = createDefaultProfile();
  const settings = createDefaultPiControlSettings(profile.id);
  assert.equal(routePiPatientIntent({ ...intent("blink"), confidence: 0.71 }, profile, settings, null).action, "ignore");
  settings.enabled = false;
  assert.equal(routePiPatientIntent(intent("blink"), profile, settings, null).action, "ignore");
});

test("an emergency mapping requires two distinct deliberate edge events", () => {
  const profile = createDefaultProfile();
  const settings = createDefaultPiControlSettings(profile.id);
  const firstEvent = intent("mouth_open", "11111111-1111-4111-8111-111111111111");
  const first = routePiPatientIntent(firstEvent, profile, settings, null, 1_000);
  assert.equal(first.action, "arm-emergency");
  if (first.action !== "arm-emergency") return;

  assert.equal(routePiPatientIntent(firstEvent, profile, settings, first.nextEmergencyArm, 2_000).action, "arm-emergency");
  const second = routePiPatientIntent(intent("mouth_open", "22222222-2222-4222-8222-222222222222"), profile, settings, first.nextEmergencyArm, 2_000);
  assert.equal(second.action, "speak");
  if (second.action === "speak") assert.equal(second.gesture.risk, "emergency");

  const expired = routePiPatientIntent(
    intent("mouth_open", "33333333-3333-4333-8333-333333333333"),
    profile,
    settings,
    first.nextEmergencyArm,
    1_000 + PI_EMERGENCY_CONFIRMATION_WINDOW_MS + 1,
  );
  assert.equal(expired.action, "arm-emergency");
});

function intent(name: PiPatientIntentName, messageId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"): PiPatientIntent {
  return {
    messageId,
    deviceId: "fingerspeak-pi",
    sequence: 1,
    sentAt: "2026-08-22T06:00:01Z",
    intent: name,
    confidence: 0.91,
    detectedAt: "2026-08-22T06:00:00.900Z",
  };
}
