// NB: Cerebras ha dismesso "llama3.1-8b" (404 model_not_found). Modelli disponibili
// sulla key attuale: "gpt-oss-120b" e "zai-glm-4.7". Il proxy sovrascrive il model
// inviato dall'app, quindi questo e l'unico punto da aggiornare.
export const CHATBOT_MODEL = "gpt-oss-120b"

// Due bucket di quota: "chat" (la pagina Vibe AI) e "aux" (why-for-me, loglines, embeddings,
// session vibe, nudges, search expansion). I client nuovi taggano la richiesta con il campo
// "feature"; le richieste non taggate (client vecchi) finiscono nel bucket chat, che ha il
// limite piu stretto — il default sicuro.
export type QuotaBucket = "chat" | "aux"

export const CHAT_FREE_DAILY_REQUEST_LIMIT = 8
export const CHAT_PRO_DAILY_REQUEST_LIMIT = 20
export const AUX_FREE_DAILY_REQUEST_LIMIT = 40
export const AUX_PRO_DAILY_REQUEST_LIMIT = 80

// Circuit breaker: budget Cerebras 1M token/giorno sulla key. Oltre questa soglia il proxy
// smette di inoltrare (429 global_capacity) per non esaurire la key a meta giornata.
export const GLOBAL_DAILY_TOKEN_BUDGET = 850_000

export function dailyLimitForTier(isPro: boolean, bucket: QuotaBucket = "chat"): number {
  if (bucket === "aux") {
    return isPro ? AUX_PRO_DAILY_REQUEST_LIMIT : AUX_FREE_DAILY_REQUEST_LIMIT
  }
  return isPro ? CHAT_PRO_DAILY_REQUEST_LIMIT : CHAT_FREE_DAILY_REQUEST_LIMIT
}

export function hasReachedDailyLimit(
  requestsUsedToday: number,
  isPro: boolean,
  bucket: QuotaBucket = "chat",
): boolean {
  return requestsUsedToday >= dailyLimitForTier(isPro, bucket)
}

export function usageDayKey(date = new Date()): string {
  return date.toISOString().slice(0, 10)
}

// The quota is a count of AI requests made today. The stored columns are request_count (chat) and
// aux_request_count (aux); a row from a previous day (usage_date != today) counts as zero, so the
// daily limit resets at UTC midnight.
export function usageCountForToday(
  row: {
    request_count?: number | null
    aux_request_count?: number | null
    usage_date?: string | null
  } | null,
  todayKey = usageDayKey(),
  bucket: QuotaBucket = "chat",
): number {
  if (!row) return 0

  if (row.usage_date) {
    if (row.usage_date !== todayKey) return 0
    return (bucket === "aux" ? row.aux_request_count : row.request_count) ?? 0
  }

  return 0
}

export function parseRequestBody(rawBody: string): Record<string, unknown> {
  const parsed = JSON.parse(rawBody)
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("Invalid JSON request body")
  }
  return parsed as Record<string, unknown>
}

// Bucket dal tag "feature" del body: solo "aux" esplicito va nel bucket aux; qualsiasi altro
// valore, o l'assenza del campo, cade sul bucket chat (limite piu stretto, default anti-abuso).
export function bucketForRequest(parsed: Record<string, unknown>): QuotaBucket {
  return parsed.feature === "aux" ? "aux" : "chat"
}

export function requestBodyForCerebras(parsed: Record<string, unknown>): Record<string, unknown> {
  // Il campo "feature" e un dettaglio del gateway: non va inoltrato a Cerebras.
  const { feature: _feature, ...rest } = parsed
  return {
    ...rest,
    model: CHATBOT_MODEL,
  }
}
