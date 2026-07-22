// One-shot: riconcilia user_daily_quota.is_pro=true contro RevenueCat (autorevole).
// Per ogni riga Pro: rilegge l'entitlement da RevenueCat REST e, SOLO se la risposta è
// definitiva e l'entitlement NON è attivo, mette is_pro=false. Su errore/secret mancante
// NON demota (conservativo: non si toglie il Pro per un glitch transitorio).
//
// Auth: header Authorization == REVENUECAT_WEBHOOK_SECRET (op amministrativa).
// Gira come service_role -> il trigger trg_enforce_is_pro lascia passare la scrittura.
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
const ADMIN_SECRET = Deno.env.get('REVENUECAT_WEBHOOK_SECRET') ?? ''
const REVENUECAT_API_KEY = Deno.env.get('REVENUECAT_API_KEY') ?? ''
const PRO_ENTITLEMENT_ID = Deno.env.get('PRO_ENTITLEMENT_ID') ?? 'StartingVibe Pro'

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)

function authorized(header: string | null): boolean {
  if (!header || !ADMIN_SECRET) return false
  const provided = header.startsWith('Bearer ') ? header.slice(7) : header
  const a = new TextEncoder().encode(provided)
  const b = new TextEncoder().encode(ADMIN_SECRET)
  if (a.length !== b.length) return false
  let d = 0
  for (let i = 0; i < a.length; i++) d |= a[i] ^ b[i]
  return d === 0
}

function isEntitlementActive(e: { expires_date?: string | null } | undefined): boolean {
  if (!e) return false
  if (e.expires_date == null) return true
  return new Date(e.expires_date).getTime() > Date.now()
}

// Ritorna: true=Pro attivo, false=NON Pro (definitivo), null=indeterminato (errore -> non toccare)
async function revenueCatIsPro(userId: string): Promise<boolean | null> {
  if (!REVENUECAT_API_KEY) return null
  try {
    const resp = await fetch(
      `https://api.revenuecat.com/v1/subscribers/${encodeURIComponent(userId)}`,
      { headers: { Authorization: `Bearer ${REVENUECAT_API_KEY}` } },
    )
    if (!resp.ok) return null
    const json = await resp.json()
    return isEntitlementActive(json?.subscriber?.entitlements?.[PRO_ENTITLEMENT_ID])
  } catch {
    return null
  }
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

serve(async (req) => {
  if (!authorized(req.headers.get('Authorization'))) {
    return new Response('Unauthorized', { status: 401 })
  }

  const { data: rows, error } = await supabase
    .from('user_daily_quota')
    .select('user_id')
    .eq('is_pro', true)
    .not('user_id', 'is', null)

  if (error) {
    return new Response(JSON.stringify({ error: error.message }), { status: 500 })
  }

  let checked = 0
  let demoted = 0
  let keptPro = 0
  let skippedIndeterminate = 0
  const demotedIds: string[] = []

  for (const row of rows ?? []) {
    const userId = row.user_id as string
    checked++
    const isPro = await revenueCatIsPro(userId)
    if (isPro === null) {
      skippedIndeterminate++
    } else if (isPro === false) {
      const { error: updErr } = await supabase
        .from('user_daily_quota')
        .update({ is_pro: false, updated_at: new Date().toISOString() })
        .eq('user_id', userId)
      if (updErr) {
        skippedIndeterminate++
      } else {
        demoted++
        demotedIds.push(userId.slice(0, 8))
      }
    } else {
      keptPro++
    }
    await sleep(120) // gentile col rate-limit RevenueCat
  }

  const summary = { checked, demoted, keptPro, skippedIndeterminate, demotedIds }
  console.log('reconcile-pro-status:', JSON.stringify(summary))
  return new Response(JSON.stringify(summary), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  })
})
