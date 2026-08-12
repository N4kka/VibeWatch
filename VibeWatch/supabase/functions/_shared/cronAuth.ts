// Inbound authorisation for the functions that are only ever meant to be triggered by pg_cron
// (or by another Edge Function acting server-to-server).
//
// Why this exists. None of these functions checked who was calling. They were reachable with the
// app's **publishable key**, which ships inside the IPA and is therefore public. Verified against
// production before the fix: a POST to `episode-radar` carrying nothing but that key returned
// `200 {"seriesChecked":49,...}` — the function ran, with the service role key, on real data.
//
// That put the whole notification pipeline in anyone's hands: `release-radar`, `episode-radar`,
// `continue-watching-reminder` and `streak-reminder` queue notifications, `process-notifications`
// delivers them. It is the same push storm that was fixed on 2026-07-23, except reproducible on
// demand by a third party. The per-user delivery cap added then limits how much noise reaches any
// one user, but it does not stop the functions from running, burning TMDB/Cerebras quota, or
// writing to `notifications`.
//
// The crons already send the service key: `net.http_post(..., headers := jsonb_build_object(
// 'apikey', (select decrypted_secret from vault.decrypted_secrets where name='edge_service_key')))`.
// So requiring it costs nothing operationally and locks out the publishable key, which is the
// entire point. Modelled on `revenuecat-webhook`, which already did this correctly.

/// Every credential that legitimately identifies "the project itself".
///
/// Deliberately a set, not the single resolved key that the rest of the codebase uses. The Vault
/// entry the crons send (`edge_service_key`) is the **new** `sb_secret_` key, while
/// `SUPABASE_SERVICE_ROLE_KEY` in the function env can still be the **legacy** JWT during the key
/// migration — comparing against only the first non-empty one rejected the crons themselves.
/// Learned the hard way: the first version of this guard 401'd the real scheduler.
const SERVICE_KEYS: string[] = (() => {
  const candidates: string[] = []

  const secretKeys = Deno.env.get('SUPABASE_SECRET_KEYS')
  if (secretKeys) {
    try {
      const parsed = JSON.parse(secretKeys)
      for (const value of Object.values(parsed ?? {})) {
        if (typeof value === 'string' && value.length > 0) candidates.push(value)
      }
    } catch {
      // Not JSON: treat the raw value as a key.
      candidates.push(secretKeys)
    }
  }

  const serviceRole = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  if (serviceRole) candidates.push(serviceRole)

  // An explicit override, for when neither of the above is what the scheduler sends.
  const explicit = Deno.env.get('CRON_SHARED_SECRET')
  if (explicit) candidates.push(explicit)

  return [...new Set(candidates)]
})()

/// Constant-time comparison: a length-independent early return would leak the key a byte at a time.
function timingSafeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder()
  const ab = enc.encode(a)
  const bb = enc.encode(b)
  if (ab.length !== bb.length) return false
  let diff = 0
  for (let i = 0; i < ab.length; i++) diff |= ab[i] ^ bb[i]
  return diff === 0
}

/// True when the caller presented the project's service key, on either header.
///
/// Both are accepted because the new `sb_secret_` keys are not JWTs and travel on `apikey`, while
/// the legacy transition still puts them on `Authorization`.
export function isServiceCaller(req: Request): boolean {
  if (SERVICE_KEYS.length === 0) {
    // No key configured means we cannot authenticate anyone. Fail closed: an open cron endpoint is
    // worse than a broken one, and a broken one shows up in the cron logs immediately.
    console.error('[cronAuth] no service key configured; refusing all callers')
    return false
  }

  const apikey = req.headers.get('apikey') ?? ''
  const auth = req.headers.get('Authorization') ?? ''
  const bearer = auth.startsWith('Bearer ') ? auth.slice(7) : auth

  for (const key of SERVICE_KEYS) {
    if (apikey.length > 0 && timingSafeEqual(apikey, key)) return true
    if (bearer.length > 0 && timingSafeEqual(bearer, key)) return true
  }

  // Prefixes only — enough to tell "wrong key" from "no key at all" when a scheduler stops working,
  // without putting credentials in the logs.
  console.warn(
    `[cronAuth] rejected caller. presented apikey=${prefix(apikey)} bearer=${prefix(bearer)}; `
    + `known=[${SERVICE_KEYS.map(prefix).join(', ')}]`,
  )
  return false
}

/// First few characters only: enough to identify which credential was used, useless to an attacker.
function prefix(value: string): string {
  if (value.length === 0) return '<empty>'
  return `${value.slice(0, 9)}…(${value.length})`
}

/// Returns a 401 Response when the caller is not the cron/service caller, or null to proceed.
export function rejectIfNotServiceCaller(req: Request): Response | null {
  if (isServiceCaller(req)) return null
  return new Response(
    JSON.stringify({ error: 'Forbidden: this function is invoked by the scheduler only' }),
    { status: 401, headers: { 'Content-Type': 'application/json' } },
  )
}
