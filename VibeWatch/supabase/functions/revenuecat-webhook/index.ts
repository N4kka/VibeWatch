// RevenueCat webhook — authoritative source of `user_daily_quota.is_pro`.
//
// Security model (chiude il bypass paywall):
//  - Il client NON è più affidabile per `is_pro` (un trigger DB forza is_pro lato server;
//    vedi migration fase6_lock_is_pro_server_side). L'UNICO writer legittimo di is_pro è
//    questo webhook, che gira come service_role.
//  - Ad ogni evento RevenueCat NON ci si fida del payload per lo stato: si RILEGGE lo
//    stato autorevole dal subscriber RevenueCat (REST v1) e si scrive is_pro di conseguenza.
//  - L'autenticazione del webhook usa l'header Authorization configurato nel dashboard
//    RevenueCat, confrontato (constant-time) con REVENUECAT_WEBHOOK_SECRET. Ne e' accettato
//    anche un secondo (REVENUECAT_WEBHOOK_SECRET_WEB), non configurato oggi: un webhook
//    RevenueCat filtra per UNA app, e se un giorno ne servisse un secondo il suo segreto
//    andrebbe aggiunto qui invece di ruotare il primo — che non e' piu' leggibile da
//    nessuna parte, quindi ruotarlo vorrebbe dire spegnere il webhook che gira in
//    produzione. Oggi ne basta uno, con il filtro App su "All apps": copre iOS e web.
//  - La funzione e' deployata con verify_jwt = false, ed e' l'unica configurazione in cui
//    puo' funzionare: RevenueCat manda il segreto condiviso, non un JWT Supabase, quindi
//    col gateway attivo ogni evento veniva respinto con 401 prima di arrivare qui. E' stato
//    cosi' fino al 2026-08-15: in un anno nessun evento ha mai scritto una riga, e lo stato
//    Pro di user_entitlements veniva tutto dal backfill del 23 luglio.
import { serve } from 'https://deno.land/std@0.131.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
// Prefer the new secret key (sb_secret_..., auto-injected as SUPABASE_SECRET_KEYS json),
// falling back to the legacy service_role during the migration window.
const SUPABASE_SERVICE_ROLE_KEY = (() => {
  const s = Deno.env.get('SUPABASE_SECRET_KEYS')
  if (s) { try { const k = JSON.parse(s)?.default; if (k) return k as string } catch { /* fall back */ } }
  return Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
})()
const REVENUECAT_WEBHOOK_SECRETS = [
  Deno.env.get('REVENUECAT_WEBHOOK_SECRET') ?? '',
  Deno.env.get('REVENUECAT_WEBHOOK_SECRET_WEB') ?? '',
].filter((secret) => secret.length > 0)
// Secret API key RevenueCat (sk_...), la stessa usata da cerebras-proxy per /v1/subscribers.
const REVENUECAT_API_KEY = Deno.env.get('REVENUECAT_API_KEY') ?? ''
const PRO_ENTITLEMENT_ID = Deno.env.get('PRO_ENTITLEMENT_ID') ?? 'StartingVibe Pro'

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)

serve(async (req) => {
  // 1. Autenticazione webhook: header Authorization == secret (constant-time).
  if (REVENUECAT_WEBHOOK_SECRETS.length === 0 || !isAuthorized(req.headers.get('Authorization'))) {
    return new Response('Unauthorized', { status: 401 })
  }

  let event: RCEvent
  try {
    const body = await req.text()
    event = JSON.parse(body).event
  } catch {
    return new Response('Bad request', { status: 400 })
  }

  const appUserId = event?.app_user_id
  if (!appUserId) {
    return new Response('Missing app_user_id', { status: 400 })
  }

  console.log(`RevenueCat event: ${event.type} for ${appUserId.slice(0, 8)}…`)

  // 2. L'evento va in archivio prima di essere elaborato (vedi logEvent).
  const logId = await logEvent(event)

  // Il TEST del dashboard RevenueCat non è un fatto di fatturazione: porta un app_user_id
  // inventato (`test_product`, uno store a caso) e non descrive nessun abbonamento reale.
  // Trattarlo come gli altri significa scrivere righe di quota per utenti che non esistono —
  // successo il 2026-08-16 alle 16:20, riga poi rimossa a mano. Si archivia e basta: serve a
  // provare che il webhook arriva, ed è esattamente quello che continua a provare.
  if (event.type === 'TEST') {
    await markProcessed(logId)
    return new Response('OK', { status: 200 })
  }

  // 3. Stato autorevole: rileggi il subscriber da RevenueCat (non fidarsi del payload).
  const isPro = await fetchIsProFromRevenueCat(appUserId)

  // 4. Scrivi is_pro (service_role -> il trigger lascia passare).
  await upsertIsPro(appUserId, isPro)

  // 5. La data di cancellazione sta accanto allo stato dell'abbonamento, non sul profilo.
  //    `profiles.subscription_canceled_at` era `timestamp` senza fuso — l'unica colonna così
  //    dello schema — e RevenueCat manda ISO 8601 con offset: Postgres lo troncava in silenzio.
  //    `user_entitlements.canceled_at` è timestamptz. La riga esiste già: la crea `upsertIsPro`.
  //
  //    Non è un upsert di proposito: `is_pro` è NOT NULL DEFAULT false, quindi inserire una riga
  //    qui scriverebbe "non Pro" mentre una cancellazione lascia l'accesso attivo fino a fine
  //    periodo. Se la riga manca è perché `fetchIsProFromRevenueCat` ha fallito, e allora non
  //    c'è uno stato da annotare — ma lo si dice, invece di non fare nulla in silenzio.
  const canceledAt = cancellationTimestamp(event)
  if (canceledAt !== undefined) {
    const { error, count } = await supabase
      .from('user_entitlements')
      .update({ canceled_at: canceledAt }, { count: 'exact' })
      .eq('user_id', appUserId)
    if (error) console.error('Errore update canceled_at:', error.message)
    else if (!count) console.warn(`canceled_at non scritto: nessun entitlement per ${appUserId.slice(0, 8)}…`)
  }

  await markProcessed(logId)

  return new Response('OK', { status: 200 })
})

interface RCEvent {
  app_user_id?: string
  type?: string
  product_id?: string
  purchased_at?: string
  /** Quando RevenueCat ha registrato l'evento. È l'unica data che i CANCELLATION portano. */
  event_timestamp_ms?: number
  /** Storico: nessun evento osservato lo contiene. Vedi `cancellationTimestamp`. */
  cancellation_date?: string
  // Il resto del payload viaggia con l'evento e finisce in archivio così com'è.
  [key: string]: unknown
}

/**
 * Quando l'abbonamento è stato disdetto — o `null` per dire "non più", o `undefined`
 * quando l'evento non parla di disdette e la colonna non va toccata.
 *
 * **Perché non `cancellation_date`.** È il campo che questa funzione ha cercato per un anno,
 * e nei payload di RevenueCat non esiste: un CANCELLATION porta `event_timestamp_ms` e
 * `cancel_reason`, nient'altro sul tempo. Il ramo non è mai scattato e `canceled_at` è
 * rimasto NULL per ogni disdetta di ogni utente — verificato il 2026-08-16 su un acquisto
 * web di prova, disdetto dal portale: RevenueCat segnava `unsubscribe_detected_at`, la
 * colonna no. Il campo resta letto per primo se un giorno comparisse davvero.
 *
 * UNCANCELLATION è la disdetta ritirata prima della scadenza: la data va tolta, altrimenti
 * un abbonamento di nuovo vivo resta marcato come disdetto per sempre.
 */
function cancellationTimestamp(event: RCEvent): string | null | undefined {
  if (event.type === 'CANCELLATION') {
    if (typeof event.cancellation_date === 'string') return event.cancellation_date
    if (typeof event.event_timestamp_ms === 'number') {
      return new Date(event.event_timestamp_ms).toISOString()
    }
    // Un evento senza data è comunque una disdetta: meglio "adesso" che nessuna traccia.
    return new Date().toISOString()
  }
  if (event.type === 'UNCANCELLATION') return null
  return undefined
}

/**
 * Confronto constant-time dell'header Authorization coi secret configurati (accetta anche
 * "Bearer <secret>"). Si prova ognuno per intero, senza uscire al primo esito: il tempo di
 * risposta non deve dire quale dei due si e' avvicinato.
 */
function isAuthorized(header: string | null): boolean {
  if (!header) return false
  const provided = header.startsWith('Bearer ') ? header.slice(7) : header
  let matched = false
  for (const secret of REVENUECAT_WEBHOOK_SECRETS) {
    if (timingSafeEqual(provided, secret)) matched = true
  }
  return matched
}

function timingSafeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder()
  const ab = enc.encode(a)
  const bb = enc.encode(b)
  if (ab.length !== bb.length) return false
  let diff = 0
  for (let i = 0; i < ab.length; i++) diff |= ab[i] ^ bb[i]
  return diff === 0
}

function isEntitlementActive(entitlement: { expires_date?: string | null } | undefined): boolean {
  if (!entitlement) return false
  // expires_date null => lifetime. Altrimenti deve essere nel futuro.
  if (entitlement.expires_date == null) return true
  return new Date(entitlement.expires_date).getTime() > Date.now()
}

/**
 * Stato Pro autorevole dal subscriber RevenueCat. In caso di errore/secret mancante
 * ritorna `null` => non si scrive (si evita di azzerare un Pro legittimo per un errore transitorio).
 */
async function fetchIsProFromRevenueCat(userId: string): Promise<boolean | null> {
  if (!REVENUECAT_API_KEY) {
    console.warn('REVENUECAT_API_KEY non configurata; nessuna scrittura is_pro')
    return null
  }
  try {
    const resp = await fetch(
      `https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(userId)}`,
      { headers: { Authorization: `Bearer ${REVENUECAT_API_KEY}` } },
    )
    if (!resp.ok) {
      console.warn(`RevenueCat lookup fallita (${resp.status}); nessuna scrittura is_pro`)
      return null
    }
    const json = await resp.json()
    const entitlement = json?.subscriber?.entitlements?.[PRO_ENTITLEMENT_ID]
    return isEntitlementActive(entitlement)
  } catch (error) {
    console.warn('Errore lookup RevenueCat; nessuna scrittura is_pro:', error)
    return null
  }
}

/**
 * L'evento, com'è arrivato, in `revenuecat_webhook_logs`.
 *
 * È l'unica memoria che esiste di cosa RevenueCat ha detto e quando: i log della funzione
 * durano giorni, questa tabella dura fino alla potatura settimanale (`clean_old_webhook_logs`).
 * Serve a rispondere alla domanda che si fa sempre — "questo utente ha pagato o no, e cosa è
 * successo dopo" — senza dover chiedere al dashboard.
 *
 * Ha smesso di essere scritta il 2026-06-02, con l'esito che il 2026-08-16 una tabella vuota
 * si leggeva come "non arriva più nessun evento" mentre gli eventi arrivavano: un archivio
 * che tace è peggio di uno che non c'è.
 *
 * Scritto **prima** dell'elaborazione, con `processed: false`: un evento che fa cadere la
 * funzione a metà è esattamente quello che si vuole poter ritrovare. Nessun errore qui può
 * fermare il webhook — l'archivio è utile, l'entitlement è essenziale.
 */
async function logEvent(event: RCEvent): Promise<string | null> {
  try {
    const { data, error } = await supabase
      .from('revenuecat_webhook_logs')
      .insert({
        event_type: event.type ?? 'UNKNOWN',
        app_user_id: event.app_user_id,
        product_id: event.product_id ?? null,
        payload: event,
        processed: false,
      })
      .select('id')
      .single()
    if (error) {
      console.warn('Evento non archiviato:', error.message)
      return null
    }
    return (data?.id as string) ?? null
  } catch (error) {
    console.warn('Evento non archiviato:', error)
    return null
  }
}

/** Chiude la riga aperta da `logEvent`: si è arrivati in fondo. */
async function markProcessed(logId: string | null): Promise<void> {
  if (!logId) return
  try {
    const { error } = await supabase
      .from('revenuecat_webhook_logs')
      .update({ processed: true })
      .eq('id', logId)
    if (error) console.warn('Evento non marcato come elaborato:', error.message)
  } catch (error) {
    console.warn('Evento non marcato come elaborato:', error)
  }
}

async function upsertIsPro(userId: string, isPro: boolean | null): Promise<void> {
  if (isPro === null) return
  // Fonte autorevole dell'entitlement (SEC-005). user_daily_quota.is_pro resta una cache che il
  // client scrive sulla propria riga, quindi forgiabile: nessuna decisione puo poggiarci sopra.
  // user_entitlements e scrivibile solo da service_role ed e cio che award_xp legge.
  const { error: entErr } = await supabase
    .from('user_entitlements')
    .upsert(
      { user_id: userId, is_pro: isPro, source: 'revenuecat', verified_at: new Date().toISOString() },
      { onConflict: 'user_id' },
    )
  if (entErr) {
    console.error('Errore upsert user_entitlements:', entErr.message)
  }

  const { error } = await supabase
    .from('user_daily_quota')
    .upsert(
      { user_id: userId, is_pro: isPro, updated_at: new Date().toISOString() },
      { onConflict: 'user_id' },
    )
  if (error) {
    console.error('Errore upsert is_pro:', error.message)
  } else {
    console.log(`is_pro=${isPro} scritto per ${userId.slice(0, 8)}…`)
  }
}
