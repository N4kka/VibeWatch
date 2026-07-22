// RevenueCat webhook — authoritative source of `user_daily_quota.is_pro`.
//
// Security model (chiude il bypass paywall):
//  - Il client NON è più affidabile per `is_pro` (un trigger DB forza is_pro lato server;
//    vedi migration fase6_lock_is_pro_server_side). L'UNICO writer legittimo di is_pro è
//    questo webhook, che gira come service_role.
//  - Ad ogni evento RevenueCat NON ci si fida del payload per lo stato: si RILEGGE lo
//    stato autorevole dal subscriber RevenueCat (REST v1) e si scrive is_pro di conseguenza.
//  - L'autenticazione del webhook usa l'header Authorization configurato nel dashboard
//    RevenueCat, confrontato (constant-time) con REVENUECAT_WEBHOOK_SECRET.
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
const REVENUECAT_WEBHOOK_SECRET = Deno.env.get('REVENUECAT_WEBHOOK_SECRET') ?? ''
// Secret API key RevenueCat (sk_...), la stessa usata da cerebras-proxy per /v1/subscribers.
const REVENUECAT_API_KEY = Deno.env.get('REVENUECAT_API_KEY') ?? ''
const PRO_ENTITLEMENT_ID = Deno.env.get('PRO_ENTITLEMENT_ID') ?? 'StartingVibe Pro'

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)

serve(async (req) => {
  // 1. Autenticazione webhook: header Authorization == secret (constant-time).
  if (!REVENUECAT_WEBHOOK_SECRET || !isAuthorized(req.headers.get('Authorization'))) {
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

  // 4. Mantieni la data di cancellazione sul profilo (comportamento preesistente).
  if (event.type === 'CANCELLATION' && event.cancellation_date) {
    const { error } = await supabase
      .from('profiles')
      .update({ subscription_canceled_at: event.cancellation_date })
      .eq('id', appUserId)
    if (error) console.error('Errore update subscription_canceled_at:', error.message)
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

/** Confronto constant-time dell'header Authorization col secret (accetta anche "Bearer <secret>"). */
function isAuthorized(header: string | null): boolean {
  if (!header) return false
  const provided = header.startsWith('Bearer ') ? header.slice(7) : header
  return timingSafeEqual(provided, REVENUECAT_WEBHOOK_SECRET)
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
