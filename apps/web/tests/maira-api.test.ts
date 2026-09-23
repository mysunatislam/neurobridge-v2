import assert from "node:assert/strict";
import test from "node:test";

import {
  formatSomaticPrompt,
  getMairaSessionId,
  getMairaUserId,
  askMaira,
  type SomaticEvent,
  DEFAULT_MAIRA_API_KEY,
  DEFAULT_MAIRA_PROJECT_KEY,
} from "../app/lib/maira-api";

test("Maira default API keys are configured and formatted correctly", () => {
  assert.ok(DEFAULT_MAIRA_API_KEY.startsWith("gAAAAAB"));
  assert.ok(DEFAULT_MAIRA_PROJECT_KEY.startsWith("AcH6"));
  assert.equal(DEFAULT_MAIRA_PROJECT_KEY.endsWith("="), true);
});

test("formatSomaticPrompt formats clinical context and FingerSpeak events", () => {
  const events: SomaticEvent[] = [
    {
      id: "ev-1",
      modality: "fingerspeak_hand",
      gestureId: "water",
      phrase: "I need water, please.",
      confidence: 0.92,
      timestamp: Date.now() - 15000,
    },
    {
      id: "ev-2",
      modality: "fingerspeak_hand",
      gestureId: "food",
      phrase: "I need food",
      confidence: 0.95,
      detail: "peace sign hold",
      timestamp: Date.now() - 5000,
    },
  ];

  const patientContext = {
    care_mode: "communication",
    current_activity: "Using gesture tracking",
    trusted_contact_available: true,
  };

  const formatted = formatSomaticPrompt(
    "How can I safely swallow while sitting?",
    events,
    patientContext,
  );

  assert.match(formatted, /Clinical Context: Care Mode: communication/);
  assert.match(formatted, /FingerSpeak Hand: "I need water, please." \(92% conf\)/);
  assert.match(formatted, /FingerSpeak Hand: "I need food" \(95% conf\) \[peace sign hold\]/);
  assert.match(formatted, /How can I safely swallow while sitting\?/);
});

test("getMairaSessionId and getMairaUserId return non-empty strings", () => {
  const sessionId = getMairaSessionId();
  assert.ok(typeof sessionId === "string" && sessionId.length > 0);

  const namedUserId = getMairaUserId("John Doe");
  assert.equal(namedUserId, "john_doe");

  const defaultUserId = getMairaUserId();
  assert.ok(typeof defaultUserId === "string" && defaultUserId.length > 0);
});

test("askMaira falls back to offline companion when network fails", async () => {
  // Pass an invalid URL via custom keys or simulate network error
  const response = await askMaira({
    message: "I need water",
    customApiKey: "invalid-key",
    customProjectKey: "invalid-project",
  });

  assert.ok(response.reply.length > 0);
  assert.match(response.mode, /offline companion/);
  assert.equal(response.urgent, false);
});

test("askMaira detects emergency language and marks urgent even in fallback", async () => {
  const response = await askMaira({
    message: "This is an emergency, I cannot breathe!",
    customApiKey: "invalid-key",
    customProjectKey: "invalid-project",
  });

  assert.equal(response.urgent, true);
  assert.match(response.reply, /Need help button|alert/i);
});

test("askMaira parses live/mocked Maira response structure with clinical citations", async () => {
  const originalFetch = globalThis.fetch;
  try {
    globalThis.fetch = (async () => {
      return {
        ok: true,
        json: async () => ({
          detail: {
            response: "For safe swallowing, keep your chin tucked slightly downward.",
            references: [
              {
                section_id: "swallowing_protocol_v2",
                similarity_score: "88.5",
                content: "Chin-tuck posture reduces aspiration risk during liquid ingestion.",
                reference_url: "https://neurobridge.care/protocol/swallowing",
              },
            ],
          },
          conversation_id: "conv-12345",
        }),
      } as unknown as Response;
    }) as unknown as typeof fetch;

    const res = await askMaira({
      message: "How should I position my neck?",
      recentSomaticEvents: [
        {
          id: "ev-1",
          modality: "fingerspeak_hand",
          gestureId: "water",
          phrase: "I need water",
          timestamp: Date.now(),
        },
      ],
    });

    assert.equal(res.mode, "maira-specialist");
    assert.equal(res.previous_response_id, "conv-12345");
    assert.match(res.reply, /chin tucked/);
    assert.equal(res.citations.length, 1);
    assert.match(res.citations[0].title, /swallowing_protocol_v2/);
    assert.match(res.citations[0].title, /88\.5%/);
    assert.equal(res.citations[0].url, "https://neurobridge.care/protocol/swallowing");
  } finally {
    globalThis.fetch = originalFetch;
  }
});
