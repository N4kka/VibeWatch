// Riallinea lo stato Pro del DB a RevenueCat (autorevole), in entrambe le direzioni.
//
// Per ogni utente candidato rilegge l'entitlement da RevenueCat REST e scrive
// `user_entitlements` (+ la cache `user_daily_quota.is_pro`) solo quando la risposta è
// definitiva. Su errore/secret mancante NON tocca nulla: conservativo, non si toglie né si
// regala il Pro per un glitch transitorio.
//
// **Perché ora promuove e non solo demota.** Fino al 2026-08-16 questa funzione interrogava
// RevenueCat con l'uuid minuscolo che legge da Postgres, mentre iOS registra l'utente con lo
// stesso uuid in MAIUSCOLO: per RevenueCat sono due account, e la GET su quello sconosciuto
// risponde 200 con un subscriber vuoto (vedi _shared/revenuecat.ts). Ogni abbonato risultava
// scaduto, e una funzione che sapeva solo demolire ha azzerato la tabella in una notte
// (2026-08-15: 74 righe di entitlement, zero Pro). Con la lookup corretta il senso unico non
// basta più — chi è stato demosso per sbaglio deve poter tornare Pro senza aspettare il
// prossimo evento RevenueCat.
//
// **Chi viene controllato.** Non i profili tutti — sarebbero minuti di chiamate REST dentro
// una singola invocazione. Solo chi ha un motivo per essere Pro: la cache client-side che lo
// afferma, una riga di entitlement già scritta (è lì che stanno le demozioni sbagliate), e
// chiunque RevenueCat abbia mai nominato in un webhook. Gli altri li promuove il webhook al
// primo evento utile, ora che passa il gateway.
//
// Auth: solo il chiamante di servizio (_shared/cronAuth.ts), come ogni altra funzione che
// esiste per il cron. C'era anche un secondo controllo — Authorization == REVENUECAT_WEBHOOK_SECRET
// — nato prima di cronAuth, quando questa funzione si lanciava a mano: quel valore non e' piu'
// leggibile da nessuna parte (i segreti Supabase sono write-only), quindi lo scheduler non
// avrebbe potuto presentarlo e la funzione sarebbe rimasta senza cron, che e' come e' stata per
// mesi. Il servizio che chiama e' gia' autenticato dalla chiave di servizio.
// Gira come service_role -> il trigger trg_enforce_is_pro lascia passare la scrittura.
import { serve } from 'https://deno.land/std@0.131.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { rejectIfNotServiceCaller } from '../_shared/cronAuth.ts'
import { fetchIsProFromRevenueCat } from '../_shared/revenuecat.ts'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
// Prefer the new secret key (sb_secret_..., auto-injected as SUPABASE_SECRET_KEYS json),
// falling back to the legacy service_role during the migration window.
const SUPABASE_SERVICE_ROLE_KEY = (() => {
  const s = Deno.env.get('SUPABASE_SECRET_KEYS')
  if (s) { try { const k = JSON.parse(s)?.default; if (k) return k as string } catch { /* fall back */ } }
  return Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
})()
const REVENUECAT_API_KEY = Deno.env.get('REVENUECAT_API_KEY') ?? ''
const PRO_ENTITLEMENT_ID = Deno.env.get('PRO_ENTITLEMENT_ID') ?? 'StartingVibe Pro'

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

/**
 * Chi vale la pena chiedere a RevenueCat, in forma canonica (minuscola: è quella che Postgres
 * accetta come uuid). Le grafie le riapre la lookup.
 */
async function candidateUserIds(): Promise<string[]> {
  const ids = new Set<string>()

  const add = (value: unknown) => {
    const id = String(value ?? '')
    if (UUID.test(id)) ids.add(id.toLowerCase())
  }

  // 1. La cache client-side che dichiara Pro (forgiabile: è metà del motivo di questa funzione).
  const { data: quota, error: quotaErr } = await supabase
    .from('user_daily_quota')
    .select('user_id')
    .eq('is_pro', true)
    .not('user_id', 'is', null)
  if (quotaErr) throw new Error(`user_daily_quota: ${quotaErr.message}`)
  for (const row of quota ?? []) add(row.user_id)

  // 2. Ogni entitlement già scritto — comprese le demozioni da riparare.
  const { data: ents, error: entErr } = await supabase
    .from('user_entitlements')
    .select('user_id')
  if (entErr) throw new Error(`user_entitlements: ${entErr.message}`)
  for (const row of ents ?? []) add(row.user_id)

  // 3. Chiunque abbia mai generato un evento RevenueCat: è l'elenco di chi ha davvero pagato.
  //    Gli app_user_id anonimi (`$RCAnonymousID:…`, `anon_…`) non sono uuid e cadono qui.
  const { data: logs, error: logErr } = await supabase
    .from('revenuecat_webhook_logs')
    .select('app_user_id')
    .limit(5000)
  if (logErr) console.warn('revenuecat_webhook_logs non leggibile:', logErr.message)
  for (const row of logs ?? []) add(row.app_user_id)

  return [...ids]
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

serve(async (req) => {
  // Cron/service callers only: this used to run for anyone holding the app's publishable
  // key. See _shared/cronAuth.ts.
  const unauthorized = rejectIfNotServiceCaller(req)
  if (unauthorized) return unauthorized

  let userIds: string[]
  try {
    userIds = await candidateUserIds()
  } catch (error) {
    return new Response(JSON.stringify({ error: String(error) }), { status: 500 })
  }

  let checked = 0
  let promoted = 0
  let demoted = 0
  let unchanged = 0
  let skippedIndeterminate = 0
  const promotedIds: string[] = []
  const demotedIds: string[] = []

  for (const userId of userIds) {
    checked++
    const isPro = await fetchIsProFromRevenueCat(userId, REVENUECAT_API_KEY, PRO_ENTITLEMENT_ID)

    if (isPro === null) {
      skippedIndeterminate++
      await sleep(80)
      continue
    }

    const { data: before } = await supabase
      .from('user_entitlements')
      .select('is_pro')
      .eq('user_id', userId)
      .maybeSingle()
    const changed = (before?.is_pro ?? null) !== isPro

    // Fonte autorevole prima (SEC-005), poi la cache client-side.
    const { error: entErr } = await supabase
      .from('user_entitlements')
      .upsert(
        { user_id: userId, is_pro: isPro, source: 'reconcile', verified_at: new Date().toISOString() },
        { onConflict: 'user_id' },
      )
    if (entErr) {
      console.error(`user_entitlements non scritta per ${userId.slice(0, 8)}…:`, entErr.message)
      skippedIndeterminate++
      await sleep(80)
      continue
    }

    // La cache segue l'entitlement. Upsert e non update: un Pro può non avere ancora una riga
    // di quota, e quella riga è ciò che le app leggono senza rete.
    const { error: quotaErr } = await supabase
      .from('user_daily_quota')
      .upsert(
        { user_id: userId, is_pro: isPro, updated_at: new Date().toISOString() },
        { onConflict: 'user_id' },
      )
    if (quotaErr) {
      console.warn(`user_daily_quota non aggiornata per ${userId.slice(0, 8)}…:`, quotaErr.message)
    }

    if (!changed) unchanged++
    else if (isPro) { promoted++; promotedIds.push(userId.slice(0, 8)) }
    else { demoted++; demotedIds.push(userId.slice(0, 8)) }

    await sleep(80) // gentile col rate-limit RevenueCat
  }

  const summary = { checked, promoted, demoted, unchanged, skippedIndeterminate, promotedIds, demotedIds }
  console.log('reconcile-pro-status:', JSON.stringify(summary))
  return new Response(JSON.stringify(summary), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  })
})
