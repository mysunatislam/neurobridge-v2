import type { FingerSpeakProfile, PrototypeModel } from "./fingerspeak";
import type { CareRoutineProgress, CareRoutineSettings } from "./care-routines";
import type { CaregiverPhraseRecording, PatientSpeechSettings, PhraseAudioKind } from "./patient-voice";

const DATABASE = "fingerspeak-device";
const VERSION = 3;
const STORES = ["profiles", "models", "outbox", "sync", "care", "audio"] as const;

export type OutboxEvent = {
  id: string;
  type: "phrase_spoken" | "false_activation" | "missed_gesture" | "caregiver_alert";
  profileId: string;
  gestureId?: string;
  phrase?: string;
  risk?: string;
  occurredAt: string;
};

export type RemoteLink = {
  id: "remote-link";
  profileId: string;
  sessionId: string;
  clientSessionId: string;
  localProfileId: string;
  apiBase: string;
  createdAt: string;
  telemetrySalt: string;
};

export type PendingConsentUpdate = {
  id: string;
  apiBase: string;
  profileId: string;
  analyticsConsent: boolean;
  caregiverAlertsConsent: boolean;
};

export type ConsentGuard = {
  id: string;
  eventSyncDenied: boolean;
  caregiverAlertsDenied: boolean;
  updatedAt: string;
};

export type LocalContactSettings = {
  id: "local-contact-settings";
  caregiverName: string;
  caregiverPhone: string;
  patientPhone: string;
  updatedAt: string;
};

function openDatabase(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DATABASE, VERSION);
    request.onerror = () => reject(request.error ?? new Error("Could not open device storage."));
    request.onupgradeneeded = () => {
      for (const store of STORES) {
        if (!request.result.objectStoreNames.contains(store)) request.result.createObjectStore(store, { keyPath: "id" });
      }
    };
    request.onsuccess = () => resolve(request.result);
  });
}

async function put<T extends { id: string }>(storeName: (typeof STORES)[number], value: T): Promise<void> {
  const database = await openDatabase();
  await new Promise<void>((resolve, reject) => {
    const transaction = database.transaction(storeName, "readwrite");
    transaction.objectStore(storeName).put(structuredClone(value));
    transaction.oncomplete = () => resolve();
    transaction.onerror = () => reject(transaction.error ?? new Error("Could not save device data."));
  });
  database.close();
}

async function get<T>(storeName: (typeof STORES)[number], id: string): Promise<T | null> {
  const database = await openDatabase();
  const result = await new Promise<T | null>((resolve, reject) => {
    const request = database.transaction(storeName, "readonly").objectStore(storeName).get(id);
    request.onsuccess = () => resolve((request.result as T | undefined) ?? null);
    request.onerror = () => reject(request.error ?? new Error("Could not read device data."));
  });
  database.close();
  return result;
}

async function getAll<T>(storeName: (typeof STORES)[number]): Promise<T[]> {
  const database = await openDatabase();
  const result = await new Promise<T[]>((resolve, reject) => {
    const request = database.transaction(storeName, "readonly").objectStore(storeName).getAll();
    request.onsuccess = () => resolve(request.result as T[]);
    request.onerror = () => reject(request.error ?? new Error("Could not read device data."));
  });
  database.close();
  return result;
}

async function remove(storeName: (typeof STORES)[number], id: string): Promise<void> {
  const database = await openDatabase();
  await new Promise<void>((resolve, reject) => {
    const transaction = database.transaction(storeName, "readwrite");
    transaction.objectStore(storeName).delete(id);
    transaction.oncomplete = () => resolve();
    transaction.onerror = () => reject(transaction.error ?? new Error("Could not delete device data."));
  });
  database.close();
}

async function clear(storeName: (typeof STORES)[number]): Promise<void> {
  const database = await openDatabase();
  await new Promise<void>((resolve, reject) => {
    const transaction = database.transaction(storeName, "readwrite");
    transaction.objectStore(storeName).clear();
    transaction.oncomplete = () => resolve();
    transaction.onerror = () => reject(transaction.error ?? new Error("Could not clear device data."));
  });
  database.close();
}

async function saveProfileAndModel(profile: FingerSpeakProfile, model: PrototypeModel): Promise<void> {
  const database = await openDatabase();
  await new Promise<void>((resolve, reject) => {
    const transaction = database.transaction(["profiles", "models"], "readwrite");
    transaction.objectStore("profiles").put(structuredClone(profile));
    transaction.objectStore("models").put({ id: profile.id, ...structuredClone(model) });
    transaction.oncomplete = () => resolve();
    transaction.onerror = () => reject(transaction.error ?? new Error("Could not activate the edge model."));
  });
  database.close();
}

async function saveProfileAndConsentGuard(profile: FingerSpeakProfile): Promise<void> {
  const database = await openDatabase();
  await new Promise<void>((resolve, reject) => {
    const transaction = database.transaction(["profiles", "sync"], "readwrite");
    transaction.objectStore("profiles").put(structuredClone(profile));
    transaction.objectStore("sync").put({
      id: `consent-guard:${profile.id}`,
      eventSyncDenied: !profile.consentToEventSync,
      caregiverAlertsDenied: !profile.consentToCaregiverAlerts,
      updatedAt: new Date().toISOString(),
    } satisfies ConsentGuard);
    transaction.oncomplete = () => resolve();
    transaction.onerror = () => reject(transaction.error ?? new Error("Could not save the local consent decision."));
  });
  database.close();
}

export const deviceStorage = {
  saveProfile: (profile: FingerSpeakProfile) => put("profiles", profile),
  saveProfileAndModel,
  saveProfileAndConsentGuard,
  loadProfile: (id: string) => get<FingerSpeakProfile>("profiles", id),
  saveModel: (profileId: string, model: PrototypeModel) => put("models", { id: profileId, ...model }),
  loadModel: (profileId: string) => get<PrototypeModel & { id: string }>("models", profileId),
  deleteModel: (profileId: string) => remove("models", profileId),
  queueEvent: (event: OutboxEvent) => put("outbox", event),
  listOutbox: () => getAll<OutboxEvent>("outbox"),
  deleteEvent: (id: string) => remove("outbox", id),
  clearOutbox: () => clear("outbox"),
  saveRemoteLink: (link: RemoteLink) => put("sync", link),
  loadRemoteLink: () => get<RemoteLink>("sync", "remote-link"),
  saveLocalContactSettings: (settings: LocalContactSettings) => put("sync", settings),
  loadLocalContactSettings: () => get<LocalContactSettings>("sync", "local-contact-settings"),
  clearRemoteLink: () => remove("sync", "remote-link"),
  queueConsentUpdate: (update: Omit<PendingConsentUpdate, "id">) => put("sync", { id: `pending-consent:${update.apiBase}:${update.profileId}`, ...update }),
  listPendingConsentUpdates: async () => (await getAll<PendingConsentUpdate | RemoteLink>("sync")).filter((item): item is PendingConsentUpdate => item.id.startsWith("pending-consent:")),
  deletePendingConsentUpdate: (id: string) => remove("sync", id),
  saveConsentGuard: (profileId: string, eventSyncDenied: boolean, caregiverAlertsDenied: boolean) => put("sync", {
    id: `consent-guard:${profileId}`,
    eventSyncDenied,
    caregiverAlertsDenied,
    updatedAt: new Date().toISOString(),
  }),
  loadConsentGuard: (profileId: string) => get<ConsentGuard>("sync", `consent-guard:${profileId}`),
  savePatientSpeechSettings: (settings: PatientSpeechSettings) => put("care", settings),
  loadPatientSpeechSettings: (profileId: string) => get<PatientSpeechSettings>("care", `patient-speech:${profileId}`),
  saveCareRoutineSettings: (settings: CareRoutineSettings) => put("care", settings),
  loadCareRoutineSettings: (profileId: string) => get<CareRoutineSettings>("care", `care-routines:${profileId}`),
  saveCareRoutineProgress: (progress: CareRoutineProgress) => put("care", progress),
  loadCareRoutineProgress: (profileId: string) => get<CareRoutineProgress>("care", `care-routine-progress:${profileId}`),
  saveCaregiverPhraseRecording: (recording: CaregiverPhraseRecording) => put("audio", recording),
  loadCaregiverPhraseRecording: (profileId: string, kind: PhraseAudioKind, phraseId: string) =>
    get<CaregiverPhraseRecording>("audio", `caregiver-audio:${profileId}:${kind}:${phraseId}`),
  listCaregiverPhraseRecordings: async (profileId: string) =>
    (await getAll<CaregiverPhraseRecording>("audio")).filter((recording) => recording.profileId === profileId),
  deleteCaregiverPhraseRecording: (profileId: string, kind: PhraseAudioKind, phraseId: string) =>
    remove("audio", `caregiver-audio:${profileId}:${kind}:${phraseId}`),
};
