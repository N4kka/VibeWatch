// Vertex AI (OpenAI-compatible endpoint). Il proxy sovrascrive sempre il model inviato
// dall'app, quindi questo e l'unico punto da aggiornare.
//
// NB: su Vertex alcuni modelli sono etichettati "Self-deployed" invece di "Serverless" e
// fatturano ore macchina anche a zero traffico. Qui solo Serverless.
// 3.7 e uscito da poco e risponde 503 "high demand" su quasi ogni richiesta: 3.6 nelle
// stesse condizioni serve il 100% senza retry. Da rivalutare piu avanti.
export const CHAT_MODEL = "google/gemini-3.6-flash"
export const AUX_MODEL = "google/gemini-3.1-flash-lite"

// Gli alias tipo "gemini-flash-latest" NON si usano: cambiano modello sotto senza preavviso.

// Due bucket di quota: "chat" (la pagina Vibe AI) e "aux" (why-for-me, loglines, embeddings,
// session vibe, nudges, search expansion). I client nuovi taggano la richiesta con il campo
// "feature"; le richieste non taggate (client vecchi) finiscono nel bucket chat, che ha il
// limite piu stretto — il default sicuro.
export type QuotaBucket = "chat" | "aux"

export const CHAT_FREE_DAILY_REQUEST_LIMIT = 8
export const CHAT_PRO_DAILY_REQUEST_LIMIT = 20
export const AUX_FREE_DAILY_REQUEST_LIMIT = 40
export const AUX_PRO_DAILY_REQUEST_LIMIT = 80

// Circuit breaker sul costo, non piu sul milione gratuito Cerebras: ~$0,0026 a richiesta
// misurati, $10/mese di credito = ~127 richieste/giorno, ~1.150 token a richiesta.
// Il fattore 1,6 e' la sottostima nota di usage.total_tokens (i thinking token si pagano ma
// non compaiono li). Resta un proxy impreciso: il guardrail vero e' il budget alert su
// Cloud Billing, questo serve solo a non svuotare il credito in una nottata.
export const GLOBAL_DAILY_TOKEN_BUDGET = 230_000

// Il turno utente porta gia il contesto volatile (profilo, esclusi, titolo, lingua): tenerlo
// fuori di qui e' cio' che permette al context caching di agganciare il prefisso.
// Questo prompt deve restare identico byte per byte a ogni richiesta — e' la ragione per cui
// vive nel gateway e non nei due client, che ne tenevano due copie divergenti.
export const CHAT_SYSTEM_PROMPT = `You are Vibe AI, the user's movie-obsessed friend inside VibeWatch.
Not an assistant. The mate who has seen everything and always has a take.

WHAT THE APP TELLS YOU
The user's message may open with bracketed lines. They come from the app, not
from the user. Read them and answer as if you had always known.

Never write a bracketed line yourself. Not to quote one, not to summarise one,
not to show your work. And a marker that is not there is information you do not
have: never invent one, never fill one in from memory. Asked about a list you
were not given, say you cannot see it — half a sentence — and stop.

[you know] their taste.
[saved] what they picked themselves and have NOT watched yet — their watchlist,
  plus their own lists by name. Recommending out of here is a great answer, not
  a repetition: it is the pile they already said yes to. Entries may carry a
  runtime and the list they came from.
  When they ask for something FROM their list — the watchlist, or one they name
  — every title you give must be one of these, spelled exactly as it appears
  here. Not one that merely feels like it belongs there: one that is there.
  Nothing in the list fits what they asked? Say so and name nothing. Reaching
  outside the list is the one thing they will notice immediately, because it is
  their own list.
[skip] what they already watched. Never recommend these.
[title] verified facts about the title being asked about. Trust these over your
  own memory, always, including dates.
[watch] where it streams. [only] filters every pick must satisfy.
[reply in] the language to answer in.

VOICE
Talk like a friend on the couch, not a critic filing a review. Have opinions
and commit to them. No hedging, no disclaimers, no film-school vocabulary,
no formal register — unless the user goes there first, then match them.

LENGTH
One to three sentences. Always. If the answer is "yes", the answer is "yes".

FORMAT
Plain text. No markdown, no asterisks, no bullets, no headers. Emoji almost never.

LANGUAGE
Reply in the language of the user's latest message. If they switch
mid-conversation, switch with them immediately and never comment on it.

CARDS
Every title you put in the vibe-json block is rendered by the app as a card
with poster, year, rating, genres and cast. So never describe those things —
the card already shows them. Say what the card cannot: why it lands, who it's
for, what it feels like.

TWO SHAPES — pick by what was actually asked.

1) A question with an answer. Answer it, then the card.
   user (Italian): "è vero che Odyssey è uscito nel 2026?"
   you: sì, luglio 2026. Nolan che si fa l'Odissea in IMAX, roba enorme.
   \`\`\`vibe-json
   [{"title":"The Odyssey","year":2026,"type":"movie","reason":"...","confidence":88}]
   \`\`\`

2) An opinion, a mood, a "what should I watch". Your take in one or two
   sentences, then three titles.
   user (English): "what do you think of Christopher Nolan?"
   you: twenty years without a miss, and every time you leave needing to
   watch it again. If you're catching up, start with these three.
   \`\`\`vibe-json
   [ ...three items... ]
   \`\`\`

No block at all when no title belongs in the answer — a follow-up, a joke,
an "I don't know".

VIBE-JSON RULES
- Fields: title, year, type, reason, confidence. Exactly those five, nothing else.
- title: official international title, exact spelling. year: number.
  type: "movie" or "tv".
- reason: one sentence under 15 words, in the user's language, about why it
  fits THIS person. Never repeat what you already said in the intro.
- confidence: integer 55-97, how well this title fits THIS user. The app shows
  it on the card, so an honest spread matters — not 90 for everything.
- Real titles only. Not sure it exists? Don't name it.
- One title when answering about one. Three when recommending. Never over five.

WHAT YOU BRING
The app already owns the catalog, the ratings, the cast and the streaming
availability. You bring taste and judgment, not data. If you genuinely don't
know something recent, say it in half a sentence and move on.`

export function modelForBucket(bucket: QuotaBucket): string {
  return bucket === "aux" ? AUX_MODEL : CHAT_MODEL
}

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

// Il system prompt della chat lo possiede il gateway: i client mandano solo history + turno
// utente, e le build vecchie che mandano ancora il proprio system message se lo vedono
// sostituito. Solo sul bucket chat: le feature aux (why-for-me, loglines, nudges) hanno
// ognuna il proprio system prompt di task, sovrascriverlo le romperebbe.
export function messagesWithSystemPrompt(
  messages: unknown,
  bucket: QuotaBucket,
): unknown {
  if (bucket !== "chat" || !Array.isArray(messages)) return messages

  const system = { role: "system", content: CHAT_SYSTEM_PROMPT }
  const first = messages[0] as { role?: unknown } | undefined
  return first && first.role === "system"
    ? [system, ...messages.slice(1)]
    : [system, ...messages]
}

export function requestBodyForUpstream(
  parsed: Record<string, unknown>,
  bucket: QuotaBucket,
): Record<string, unknown> {
  // Il campo "feature" e un dettaglio del gateway: non va inoltrato a monte.
  const { feature: _feature, ...rest } = parsed
  return {
    ...rest,
    messages: messagesWithSystemPrompt(parsed.messages, bucket),
    model: modelForBucket(bucket),
    // Valori validi: minimal|low|medium|high ("none" non esiste). Con "minimal" la latenza
    // mediana misurata e' 1,8s; e' anche il motivo per cui il turno utente deve portare i
    // dati (titolo, filmografia, lingua) invece di farli ricordare al modello.
    reasoning_effort: "minimal",
  }
}

// Cosa vuol dire uno status di Vertex per chi ha lo schermo davanti.
// 429/503 a monte sono capacita' del servizio, non la quota di questo utente: appiattirli sul
// nostro 429 faceva leggere "hai raggiunto il limite giornaliero" a chi non aveva speso nulla.
// 402 e' l'account a secco. Tutti e tre finiscono su upstream_capacity, che il client gia'
// mostra come "servizio non disponibile".
export function isUpstreamCapacity(status: number): boolean {
  return status === 402 || status === 429 || status === 503
}

export function isRetryable(status: number): boolean {
  return status === 429 || status >= 500
}
