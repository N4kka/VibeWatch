// NB: Cerebras ha dismesso "llama3.1-8b" (404 model_not_found). Modelli disponibili
// sulla key attuale: "gpt-oss-120b" e "zai-glm-4.7". Il proxy sovrascrive il model
// inviato dall'app, quindi questo e l'unico punto da aggiornare.
export const CHATBOT_MODEL = "gpt-oss-120b"
export const FREE_DAILY_REQUEST_LIMIT = 5
export const PRO_DAILY_REQUEST_LIMIT = 10

export function dailyLimitForTier(isPro: boolean): number {
  return isPro ? PRO_DAILY_REQUEST_LIMIT : FREE_DAILY_REQUEST_LIMIT
}

export function hasReachedDailyLimit(requestsUsedToday: number, isPro: boolean): boolean {
  return requestsUsedToday >= dailyLimitForTier(isPro)
}

export function usageDayKey(date = new Date()): string {
  return date.toISOString().slice(0, 10)
}

// The quota is a count of AI requests made today. The stored column is request_count; a row from a
// previous day (usage_date != today) counts as zero, so the daily limit resets at UTC midnight.
export function usageCountForToday(
  row: { request_count?: number | null; usage_date?: string | null } | null,
  todayKey = usageDayKey(),
): number {
  if (!row) return 0

  if (row.usage_date) {
    return row.usage_date === todayKey ? row.request_count ?? 0 : 0
  }

  return 0
}

export function requestBodyForCerebras(rawBody: string): Record<string, unknown> {
  const parsed = JSON.parse(rawBody)
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("Invalid JSON request body")
  }

  return {
    ...(parsed as Record<string, unknown>),
    model: CHATBOT_MODEL,
  }
}
