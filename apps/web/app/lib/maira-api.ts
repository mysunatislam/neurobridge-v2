import type { AshaCitation, AshaChatResponse } from "./api";
import { offlineCompanionReply } from "./asha-companion";

export const MAIRA_API_URL = "https://api.recommender.gigalogy.com/v1/maira/ask";
export const DEFAULT_MAIRA_API_KEY =
  "gAAAAABqrl0URSfPjzZPQLPuox266jB3Vx-ab8uOp17om96nBCYld-UCb9-LuiHlP_WZSrq4Yj8GCbvmRC_Ru_TsYitRjY4FMdSNBzoHDur-430sSZVVBa35gP8NAc2vjTWpko5ffmm7";
export const DEFAULT_MAIRA_PROJECT_KEY =
  "AcH6Slq5xvlwwKTUKSNPUrzXxMScYVf5hnuXBU7m2FM=";
export const DEFAULT_MAIRA_PROFILE_ID =
  "7edb5168-fafd-432c-80e9-de59acc9d0a2";

export type SomaticModality = "fingerspeak_hand" | "chat";

export type SomaticEvent = {
  id: string;
  modality: SomaticModality;
  gestureId: string;
  phrase: string;
  confidence?: number;
  detail?: string;
  timestamp: number;
};

export type MairaAskOptions = {
  message: string;
  userId?: string;
  userName?: string;
  sessionId?: string;
  locale?: string;
  patientContext?: Record<string, unknown>;
  recentSomaticEvents?: SomaticEvent[];
  signal?: AbortSignal;
  customApiKey?: string;
  customProjectKey?: string;
};

const URGENT_PATTERN =
  /\b(emergency|help now|urgent|cannot breathe|can't breathe|chest pain|in danger|seizure|fall|choking)\b/i;

function getOrCreateStorageId(key: string, prefix: string): string {
  if (typeof window === "undefined" || !window.localStorage) {
    return `${prefix}-${Date.now()}`;
  }
  try {
    const existing = window.localStorage.getItem(key);
    if (existing && existing.trim()) return existing.trim();
    const created =
      typeof crypto.randomUUID === "function"
        ? crypto.randomUUID()
        : `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2, 9)}`;
    window.localStorage.setItem(key, created);
    return created;
  } catch {
    return `${prefix}-${Date.now()}`;
  }
}

export function getMairaSessionId(): string {
  return getOrCreateStorageId("neurobridge.maira.session_id", "session");
}

export function getMairaUserId(preferredName?: string): string {
  if (preferredName && preferredName.trim()) {
    return preferredName.trim().replace(/\s+/g, "_").toLowerCase();
  }
  return getOrCreateStorageId("neurobridge.maira.user_id", "patient");
}

export function formatSomaticPrompt(
  message: string,
  events?: SomaticEvent[],
  patientContext?: Record<string, unknown>,
): string {
  const lines: string[] = [];

  if (patientContext && Object.keys(patientContext).length > 0) {
    const parts: string[] = [];
    if (patientContext.care_mode) parts.push(`Care Mode: ${patientContext.care_mode}`);
    if (patientContext.current_activity) parts.push(`Activity: ${patientContext.current_activity}`);
    if (patientContext.trusted_contact_available !== undefined) {
      parts.push(`Caregiver Contact: ${patientContext.trusted_contact_available ? "Configured" : "None"}`);
    }
    if (parts.length > 0) {
      lines.push(`[Clinical Context: ${parts.join(" | ")}]`);
    }
  }

  if (events && events.length > 0) {
    const recent = events.slice(-3);
    const eventSummaries = recent.map((event) => {
      const modLabel =
        event.modality === "fingerspeak_hand"
          ? "FingerSpeak Hand"
          : "Somatic Input";
      const confStr = event.confidence !== undefined ? ` (${Math.round(event.confidence * 100)}% conf)` : "";
      const detailStr = event.detail ? ` [${event.detail}]` : "";
      return `• ${modLabel}: "${event.phrase || event.gestureId}"${confStr}${detailStr}`;
    });
    lines.push(`[Recent Somatic Physical Signals Observed:\n${eventSummaries.join("\n")}\n]`);
  }

  lines.push(message.trim());
  return lines.join("\n\n");
}

export async function askMaira(
  options: MairaAskOptions,
): Promise<AshaChatResponse> {
  const {
    message,
    userId,
    userName,
    sessionId = getMairaSessionId(),
    locale = typeof navigator !== "undefined" ? navigator.language : "en-US",
    patientContext,
    recentSomaticEvents,
    signal,
    customApiKey,
    customProjectKey,
  } = options;

  const apiKey = (customApiKey || DEFAULT_MAIRA_API_KEY).trim();
  const projectKey = (customProjectKey || DEFAULT_MAIRA_PROJECT_KEY).trim();
  const effectiveUserId = userId || getMairaUserId();

  const queryPrompt = formatSomaticPrompt(
    message,
    recentSomaticEvents,
    patientContext,
  );

  const payload: Record<string, unknown> = {
    user_id: effectiveUserId,
    query: queryPrompt,
    conversation_type: "chat",
    session_id: sessionId,
    gpt_profile_id: DEFAULT_MAIRA_PROFILE_ID,
    conversation_metadata: {
      source: "neurobridge_web",
      client: "fingerspeak_suite",
      locale: locale || "en-US",
      has_somatic_events: Boolean(recentSomaticEvents && recentSomaticEvents.length > 0),
    },
  };
  if (userName) payload.user_name = userName;

  try {
    const response = await fetch(MAIRA_API_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "api-key": apiKey,
        "project-key": projectKey,
      },
      body: JSON.stringify(payload),
      signal,
    });

    if (!response.ok) {
      throw new Error(`Maira API returned status ${response.status}`);
    }

    const data = await response.json();
    const detail = data?.detail;
    const replyText = typeof detail?.response === "string" ? detail.response.trim() : "";

    if (!replyText) {
      throw new Error("Maira API returned an empty response.");
    }

    const rawRefs = Array.isArray(detail?.references) ? detail.references : [];
    const citations: AshaCitation[] = rawRefs.slice(0, 3).map((refItem: unknown, idx: number) => {
      const ref = typeof refItem === "object" && refItem !== null ? (refItem as Record<string, unknown>) : {};
      const secId = (typeof ref.section_id === "string" && ref.section_id) || `Clinical Ref #${idx + 1}`;
      const sim = ref.similarity_score ? ` (Relevance: ${String(ref.similarity_score)}%)` : "";
      return {
        title: `Maira Clinical Knowledge: ${secId}${sim}`,
        url: typeof ref.reference_url === "string" ? ref.reference_url : undefined,
        snippet: typeof ref.content === "string" ? ref.content.slice(0, 200) : undefined,
      };
    });

    const isUrgent =
      URGENT_PATTERN.test(message) ||
      URGENT_PATTERN.test(replyText);

    return {
      reply: replyText,
      mode: "maira-specialist",
      previous_response_id: typeof data?.conversation_id === "string" ? data.conversation_id : undefined,
      citations,
      urgent: isUrgent,
    };
  } catch (error) {
    if (signal?.aborted) {
      throw error;
    }
    // Graceful offline fallback
    const offline = offlineCompanionReply(message);
    return {
      reply: offline.reply,
      mode: "offline companion (fallback)",
      citations: [],
      urgent: offline.urgent,
    };
  }
}
