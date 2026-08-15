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

  // 2. Stato autorevole: rileggi il subscriber da RevenueCat (non fidarsi del payload).
  const isPro = await fetchIsProFromRevenueCat(appUserId)

  // 3. Scrivi is_pro (service_role -> il trigger lascia passare).
  await upsertIsPro(appUserId, isPro)

  // 4. La data di cancellazione sta accanto allo stato dell'abbonamento, non sul profilo.
  //    `profiles.subscription_canceled_at` era `timestamp` senza fuso — l'unica colonna così
  //    dello schema — e RevenueCat manda ISO 8601 con offset: Postgres lo troncava in silenzio.
  //    `user_entitlements.canceled_at` è timestamptz. La riga esiste già: la crea `upsertIsPro`.
  //
  //    Non è un upsert di proposito: `is_pro` è NOT NULL DEFAULT false, quindi inserire una riga
  //    qui scriverebbe "non Pro" mentre una cancellazione lascia l'accesso attivo fino a fine
  //    periodo. Se la riga manca è perché `fetchIsProFromRevenueCat` ha fallito, e allora non
  //    c'è uno stato da annotare — ma lo si dice, invece di non fare nulla in silenzio.
  if (event.type === 'CANCELLATION' && event.cancellation_date) {
    const { error, count } = await supabase
      .from('user_entitlements')
      .update({ canceled_at: event.cancellation_date }, { count: 'exact' })
      .eq('user_id', appUserId)
    if (error) console.error('Errore update canceled_at:', error.message)
    else if (!count) console.warn(`canceled_at non scritto: nessun entitlement per ${appUserId.slice(0, 8)}…`)
  }

  return new Response('OK', { status: 200 })
})

interface RCEvent {
  app_user_id?: string
  type?: string
  product_id?: string
  purchased_at?: string
  cancellation_date?: string
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
