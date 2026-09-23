"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { sendAshaChat, type AshaCitation } from "../lib/api";
import { offlineCompanionReply } from "../lib/asha-companion";
import type { SomaticEvent } from "../lib/maira-api";
import { AshaAvatar } from "./AshaAvatar";

type CompanionMessage = {
  id: string;
  role: "asha" | "patient";
  text: string;
  mode?: string;
  citations?: AshaCitation[];
};

type SpeechRecognitionResultEvent = Event & {
  results: { 0?: { 0?: { transcript?: string } } };
};

type SpeechRecognitionLike = {
  lang: string;
  continuous: boolean;
  interimResults: boolean;
  start(): void;
  stop(): void;
  abort(): void;
  onresult: ((event: SpeechRecognitionResultEvent) => void) | null;
  onerror: (() => void) | null;
  onend: (() => void) | null;
};

type SpeechRecognitionConstructor = new () => SpeechRecognitionLike;

type VoiceWindow = Window & typeof globalThis & {
  SpeechRecognition?: SpeechRecognitionConstructor;
  webkitSpeechRecognition?: SpeechRecognitionConstructor;
};

type Props = {
  aiAvailable: boolean;
  patientContext: Record<string, unknown>;
  somaticEvents?: SomaticEvent[];
  caregiverConfigured: boolean;
  onSpeak(text: string): boolean | Promise<boolean>;
  onClose?(): void;
  onWriteDisplay(text: string): Promise<boolean>;
  onCallCaregiver(): string;
  onConfirmEmergency(): Promise<string>;
};

const QUICK_PROMPTS = [
  "💧 Safe hydration posture",
  "🍽️ Nutrition advice",
  "🌿 Muscle spasm relief",
  "🧘 Breathing exercise",
  "📋 My communication summary",
];

function messageId(): string {
  return typeof crypto.randomUUID === "function" ? crypto.randomUUID() : `message-${Date.now()}-${Math.random()}`;
}

function safeCitationUrl(value: string | undefined): string | null {
  if (!value) return null;
  try {
    const url = new URL(value);
    return url.protocol === "http:" || url.protocol === "https:" ? url.toString() : null;
  } catch {
    return null;
  }
}

export function AshaCompanion({
  patientContext,
  somaticEvents = [],
  caregiverConfigured,
  onSpeak,
  onClose,
  onWriteDisplay,
  onCallCaregiver,
  onConfirmEmergency,
}: Props) {
  const [messages, setMessages] = useState<CompanionMessage[]>([{
    id: "asha-welcome",
    role: "asha",
    text: "Hello! I am Asha, powered by Gigalogy Maira Specialist AI. I am actively monitoring your FingerSpeak hand signals. How can I support your care and communication right now?",
    mode: "maira-specialist",
  }]);
  const [draft, setDraft] = useState("");
  const [busy, setBusy] = useState(false);
  const [displayBusy, setDisplayBusy] = useState(false);
  const [emergencyBusy, setEmergencyBusy] = useState(false);
  const [actionMessage, setActionMessage] = useState("✨ Grounded in Maira AI Specialist knowledge.");
  const [confirmingHelp, setConfirmingHelp] = useState(false);
  const [voiceInputAvailable, setVoiceInputAvailable] = useState(false);
  const [listening, setListening] = useState(false);
  const recognitionRef = useRef<SpeechRecognitionLike | null>(null);
  const requestRef = useRef<AbortController | null>(null);
  const playbackReportRef = useRef(0);

  const latestAshaMessage = useMemo(
    () => [...messages].reverse().find((message) => message.role === "asha")?.text ?? "Asha is ready.",
    [messages],
  );

  useEffect(() => {
    const voiceWindow = window as VoiceWindow;
    const detectionTimer = window.setTimeout(() => {
      setVoiceInputAvailable(Boolean(voiceWindow.SpeechRecognition ?? voiceWindow.webkitSpeechRecognition));
    }, 0);
    return () => {
      window.clearTimeout(detectionTimer);
      recognitionRef.current?.abort();
      requestRef.current?.abort();
      playbackReportRef.current += 1;
    };
  }, []);

  function speakAndReport(text: string, successMessage: string, unavailableMessage: string): void {
    const reportId = ++playbackReportRef.current;
    void Promise.resolve().then(() => onSpeak(text)).then((spoken) => {
      if (playbackReportRef.current === reportId) setActionMessage(spoken ? successMessage : unavailableMessage);
    }).catch(() => {
      if (playbackReportRef.current === reportId) setActionMessage("Voice playback could not start; the message remains visible.");
    });
  }

  async function submitMessage(event?: React.SyntheticEvent, overrideText?: string): Promise<void> {
    event?.preventDefault();
    const message = (overrideText ?? draft).trim();
    if (!message || busy) return;
    setMessages((current) => [...current, { id: messageId(), role: "patient", text: message }]);
    setDraft("");
    setBusy(true);
    playbackReportRef.current += 1;
    setActionMessage("Asha & Maira AI are reasoning…");
    const controller = new AbortController();
    requestRef.current?.abort();
    requestRef.current = controller;
    try {
      const recentSummary = messages
        .slice(-4)
        .map((item) => `${item.role === "asha" ? "Asha" : "Patient"}: ${item.text}`)
        .join(" | ")
        .slice(0, 500);
      const response = await sendAshaChat({
        message,
        locale: navigator.language || "en-US",
        patient_context: { ...patientContext, ...(recentSummary ? { recent_summary: recentSummary } : {}) },
        somatic_events: somaticEvents,
      }, controller.signal);
      setMessages((current) => [...current, {
        id: messageId(),
        role: "asha",
        text: response.reply,
        mode: response.mode,
        citations: response.citations,
      }]);
      if (response.urgent) {
        setActionMessage("Asha noticed that this may be urgent. Please confirm before an alert is sent.");
      } else {
        setActionMessage("Asha replied via Maira AI. Playing the response aloud…");
        speakAndReport(response.reply, "Asha replied aloud. You can also write it on the Pi display.", "Asha replied on screen, but voice playback is unavailable on this device.");
      }
      if (response.urgent) {
        playbackReportRef.current += 1;
        void Promise.resolve().then(() => onSpeak(response.reply)).catch(() => undefined);
      }
      if (response.urgent) setConfirmingHelp(true);
    } catch {
      if (controller.signal.aborted) return;
      const fallback = offlineCompanionReply(message);
      setMessages((current) => [...current, {
        id: messageId(),
        role: "asha",
        text: fallback.reply,
        mode: "offline companion",
      }]);
      if (fallback.urgent) {
        setActionMessage("Online Asha is unavailable and this may be urgent. Please confirm before an alert is sent.");
        playbackReportRef.current += 1;
        void Promise.resolve().then(() => onSpeak(fallback.reply)).catch(() => undefined);
        setConfirmingHelp(true);
      } else {
        setActionMessage("Playing local companion response…");
        speakAndReport(fallback.reply, "The local companion replied aloud while communication controls remain ready.", "The local reply remains on screen while communication controls stay ready.");
      }
    } finally {
      if (requestRef.current === controller) requestRef.current = null;
      setBusy(false);
    }
  }

  function toggleVoiceInput(): void {
    if (listening) {
      recognitionRef.current?.stop();
      return;
    }
    const voiceWindow = window as VoiceWindow;
    const Recognition = voiceWindow.SpeechRecognition ?? voiceWindow.webkitSpeechRecognition;
    if (!Recognition) {
      setActionMessage("Voice input is unavailable in this browser. Type your message instead.");
      return;
    }
    const recognition = new Recognition();
    recognition.lang = navigator.language || "en-US";
    recognition.continuous = false;
    recognition.interimResults = false;
    recognition.onresult = (event) => {
      const transcript = event.results[0]?.[0]?.transcript?.trim();
      if (transcript) setDraft((current) => current ? `${current} ${transcript}` : transcript);
    };
    recognition.onerror = () => setActionMessage("Voice input could not be captured. You can keep typing your message.");
    recognition.onend = () => {
      setListening(false);
      recognitionRef.current = null;
    };
    recognitionRef.current = recognition;
    setListening(true);
    setActionMessage("Listening… your browser may use its own speech service to create text.");
    try {
      recognition.start();
    } catch {
      setListening(false);
      recognitionRef.current = null;
      setActionMessage("Voice input could not start. You can keep typing your message.");
    }
  }

  async function writeDisplay(): Promise<void> {
    const caption = draft.trim() || latestAshaMessage;
    setDisplayBusy(true);
    setActionMessage("Waiting for the Pi display to confirm the caption…");
    try {
      const delivered = await onWriteDisplay(caption);
      setActionMessage(delivered
        ? "The connected Pi confirmed the caption."
        : "Caption is visible in the local preview, but the Pi did not confirm delivery.");
    } finally {
      setDisplayBusy(false);
    }
  }

  function callCaregiver(): void {
    setActionMessage(onCallCaregiver());
  }

  async function confirmEmergency(): Promise<void> {
    setEmergencyBusy(true);
    try {
      const result = await onConfirmEmergency();
      setConfirmingHelp(false);
      setActionMessage(result);
    } finally {
      setEmergencyBusy(false);
    }
  }

  return (
    <section className="asha-companion" aria-labelledby="asha-companion-title">
      <div className="asha-companion-head">
        <AshaAvatar decorative eager />
        <div>
          <span className="eyebrow">ASHA AGENTIC AI</span>
          <h2 id="asha-companion-title">I’m here with you.</h2>
        </div>
        <span className="asha-presence live">
          <i />✨ Maira AI Active
        </span>
        {onClose && <button className="asha-close" type="button" onClick={onClose} aria-label="Close Asha companion">×</button>}
      </div>

      <ol className="conversation" aria-live="polite" aria-busy={busy} aria-label="Conversation with Asha">
        {messages.map((message) => (
          <li key={message.id} className={`conversation-message ${message.role}`}>
            <div>
              <small>
                {message.role === "asha"
                  ? message.mode?.includes("maira")
                    ? "Asha · ✨ Maira Specialist"
                    : `Asha · ${message.mode ?? "companion"}`
                  : "You"}
              </small>
              <p>{message.text}</p>
            </div>
            {message.role === "asha" && (
              <button
                type="button"
                onClick={() => {
                  setActionMessage("Playing Asha’s message…");
                  speakAndReport(message.text, "Asha’s message played aloud.", "Voice playback is unavailable; the message remains visible.");
                }}
                aria-label={`Play Asha message aloud: ${message.text}`}
              >
                ▶ Play
              </button>
            )}
            {message.citations?.length ? (
              <ul className="citation-list" aria-label="Sources">
                {message.citations.map((citation, index) => {
                  const url = safeCitationUrl(citation.url);
                  return (
                    <li key={`${message.id}-source-${index}`}>
                      {url ? <a href={url} target="_blank" rel="noreferrer">{citation.title}</a> : <strong>{citation.title}</strong>}
                      {citation.snippet && <span>{citation.snippet}</span>}
                    </li>
                  );
                })}
              </ul>
            ) : null}
          </li>
        ))}
        {busy && (
          <li className="conversation-message asha pending">
            <div>
              <small>Asha · ✨ Maira Specialist</small>
              <p>Consulting clinical neuro-care knowledge…</p>
            </div>
          </li>
        )}
      </ol>

      {/* Somatic Context Pill Bar (FingerSpeak Hand Gestures) */}
      {somaticEvents && somaticEvents.length > 0 && (
        <div style={{ padding: "8px 20px 0", display: "flex", alignItems: "center", gap: "8px", flexWrap: "wrap" }}>
          <span style={{ fontSize: "10px", fontWeight: 800, color: "var(--ink-soft)", textTransform: "uppercase", letterSpacing: "0.05em" }}>
            Recent Hand Gesture:
          </span>
          {somaticEvents.slice(-2).map((ev) => (
            <button
              key={ev.id}
              type="button"
              style={{
                display: "inline-flex",
                alignItems: "center",
                gap: "5px",
                border: "1px solid rgba(7,91,85,0.2)",
                borderRadius: "999px",
                padding: "4px 10px",
                background: "rgba(169,221,210,0.2)",
                color: "var(--teal-dark)",
                fontSize: "11px",
                fontWeight: 700,
                cursor: "pointer",
              }}
              onClick={(e) => {
                const q = `I recently triggered FingerSpeak hand gesture "${ev.phrase || ev.gestureId}". What clinical or safe posture guidance should I follow?`;
                void submitMessage(e, q);
              }}
              title="Click to ask Maira AI about this hand gesture"
            >
              <span>✋</span>
              <span>{ev.phrase || ev.gestureId}</span>
            </button>
          ))}
        </div>
      )}

      {/* Clinical Quick Prompt Chips */}
      <div style={{ padding: "8px 20px 0", display: "flex", gap: "6px", overflowX: "auto", scrollbarWidth: "none" }}>
        {QUICK_PROMPTS.map((prompt) => (
          <button
            key={prompt}
            type="button"
            style={{
              whiteSpace: "nowrap",
              border: "1px solid var(--line)",
              borderRadius: "999px",
              padding: "4px 10px",
              background: "#fff",
              color: "var(--ink)",
              fontSize: "11px",
              fontWeight: 600,
              cursor: "pointer",
            }}
            onClick={(e) => {
              const cleanPrompt = prompt.replace(/^[^\w\s]+\s*/, "");
              void submitMessage(e, cleanPrompt);
            }}
          >
            {prompt}
          </button>
        ))}
      </div>

      <form className="asha-composer" onSubmit={(event) => void submitMessage(event)}>
        <label htmlFor="asha-message">Message Asha (Maira AI)</label>
        <textarea
          id="asha-message"
          value={draft}
          onChange={(event) => setDraft(event.target.value)}
          rows={2}
          maxLength={1_000}
          placeholder="Ask Asha about safe swallowing, spasms, exercise, or communication…"
        />
        <div className="composer-actions">
          <button
            className={listening ? "voice-input listening" : "voice-input"}
            type="button"
            onClick={toggleVoiceInput}
            disabled={!voiceInputAvailable}
            aria-pressed={listening}
          >
            {listening ? "■ Stop listening" : voiceInputAvailable ? "● Press to talk" : "Voice input unavailable"}
          </button>
          <button className="send-message" type="submit" disabled={!draft.trim() || busy}>
            {busy ? "Thinking…" : "Ask Asha"}
          </button>
        </div>
        <small>
          {voiceInputAvailable
            ? "Voice input starts only when you press the button; typing always works."
            : "This browser does not offer speech recognition. Type your message instead."}
        </small>
      </form>

      <div className="patient-primary-actions" aria-label="Patient quick actions">
        <button type="button" onClick={() => void writeDisplay()} disabled={displayBusy}>
          <span aria-hidden="true">▣</span>
          <strong>{displayBusy ? "Sending…" : "Write on Pi display"}</strong>
          <small>Send this draft, or Asha’s latest reply</small>
        </button>
        <button type="button" onClick={callCaregiver}>
          <span aria-hidden="true">☎</span>
          <strong>Call caregiver</strong>
          <small>{caregiverConfigured ? "Open your phone dialer" : "Add a local contact first"}</small>
        </button>
        <button className="need-help" type="button" onClick={() => setConfirmingHelp(true)}>
          <span aria-hidden="true">!</span>
          <strong>Need help</strong>
          <small>Requires confirmation</small>
        </button>
      </div>

      {confirmingHelp && (
        <div className="emergency-confirmation" role="alertdialog" aria-modal="true" aria-labelledby="confirm-help-title" aria-describedby="confirm-help-copy">
          <div>
            <strong id="confirm-help-title">Send a confirmed help request?</strong>
            <p id="confirm-help-copy">
              This will speak “I need help now” locally and notify approved caregivers when alert sharing is enabled. FingerSpeak is not an emergency service.
            </p>
          </div>
          <div>
            <button type="button" className="confirm-help" onClick={() => void confirmEmergency()} disabled={emergencyBusy}>
              {emergencyBusy ? "Confirming…" : "Confirm I need help"}
            </button>
            <button type="button" onClick={() => setConfirmingHelp(false)} disabled={emergencyBusy}>
              Cancel
            </button>
          </div>
        </div>
      )}
      <p className="asha-action-status" role="status">{actionMessage}</p>
    </section>
  );
}
