import { serve } from 'https://deno.land/std@0.177.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.8'
import { storageRemovalBatches, type UserStorageObject } from './storage.ts'
import { withCors } from '../_shared/cors.ts'

serve(withCors(async (req) => {
  if (req.method !== 'POST' && req.method !== 'DELETE') {
    return new Response('Method not allowed', { status: 405 })
  }

  const authHeader = req.headers.get('authorization') ?? req.headers.get('Authorization')
  if (!authHeader?.startsWith('Bearer ')) {
    return new Response('Missing auth', { status: 401 })
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  // Prefer the new secret key (sb_secret_..., auto-injected as SUPABASE_SECRET_KEYS json),
  // falling back to the legacy service_role. Removes the need for the custom SERVICE_ROLE_KEY secret.
  const serviceRoleKey = (() => {
    const s = Deno.env.get('SUPABASE_SECRET_KEYS')
    if (s) { try { const k = JSON.parse(s)?.default; if (k) return k as string } catch { /* fall back */ } }
    return Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? Deno.env.get('SERVICE_ROLE_KEY') ?? ''
  })()
  if (!supabaseUrl || !serviceRoleKey) {
    console.log('Missing env', { supabaseUrl: !!supabaseUrl, serviceRoleKey: !!serviceRoleKey })
    return new Response('Server misconfigured: missing env', { status: 500 })
  }

  // Use service-role client; pass the user token directly into getUser to validate.
  const adminClient = createClient(supabaseUrl, serviceRoleKey)
  const userToken = authHeader.replace(/Bearer\s+/i, '')

  const { data: userResult, error: userError } = await adminClient.auth.getUser(userToken)
  if (userError || !userResult?.user) {
    console.log('getUser error', userError)
    return new Response('Invalid user', { status: 401 })
  }

  const userId = userResult.user.id

  // Most user-owned tables carry an ON DELETE CASCADE foreign key to auth.users, so
  // auth.admin.deleteUser below clears them — inventario riverificato su pg_constraint il
  // 2026-08-02: OGNI tabella pubblica con una colonna utente cascata da auth.users o da
  // profiles, tranne quelle qui sotto. These do not: user_daily_quota has no foreign key at
  // all, and profiles references auth.users with NO ACTION — which also means it has to go
  // before the auth user, or that delete is rejected.
  // (user_ai_token_usage and user_clip_signals cascade from profiles.)
  //
  // `user_clip_history` e `user_preferences` erano in questo elenco. In F0.d sono diventate
  // viste sempre vuote (le tabelle erano a 0 righe, tenute in vita solo perché il pull iOS
  // <= v2.8 le richiede). Una DELETE su una vista senza trigger INSTEAD OF è un errore, non
  // un no-op: lasciarle qui avrebbe fatto riportare due failures a ogni cancellazione account.
  const failures: string[] = []

  const tables = ['user_daily_quota', 'user_ai_token_usage', 'profiles']
  for (const table of tables) {
    const { error } = await adminClient.from(table).delete().eq(table === 'profiles' ? 'id' : 'user_id', userId)
    if (error) {
      console.log(`Cleanup error for ${table}:`, error.message)
      failures.push(`${table}: ${error.message}`)
    }
  }

  // `api_proxy_budget` non ha una colonna utente: l'id sta DENTRO lo scope testuale
  // (`user:{id}`, `import:{id}`). Sono contatori, ma portano un identificatore: via anche loro.
  {
    const { error } = await adminClient
      .from('api_proxy_budget')
      .delete()
      .in('scope', [`user:${userId}`, `import:${userId}`])
    if (error) {
      console.log('Cleanup error for api_proxy_budget:', error.message)
      failures.push(`api_proxy_budget: ${error.message}`)
    }
  }

  // Storage (GDPR, audit §3b): gli ZIP dell'import in `imports/{userId}/…` — export GDPR che
  // contengono dati personali — e gli avatar, riconoscibili solo dall'`owner` (il nome del
  // file usa uuid di device). L'inventario lo fa `user_storage_objects` (service-only); la
  // cancellazione passa dalla Storage API — mai DELETE su storage.objects: lascerebbe i byte
  // orfani nel bucket sottostante (lezione di imports-cleanup).
  {
    const { data: objects, error } = await adminClient.rpc('user_storage_objects', {
      p_user: userId,
    })
    if (error) {
      console.log('user_storage_objects error:', error.message)
      failures.push(`storage inventory: ${error.message}`)
    } else {
      const failedBuckets = new Set<string>()
      for (const batch of storageRemovalBatches((objects ?? []) as UserStorageObject[])) {
        if (failedBuckets.has(batch.bucket)) continue
        const { error: removeError } = await adminClient.storage
          .from(batch.bucket)
          .remove(batch.names)
        if (removeError) {
          console.log(`Storage cleanup error for ${batch.bucket}:`, removeError.message)
          failures.push(`storage ${batch.bucket}: ${removeError.message}`)
          failedBuckets.add(batch.bucket)
        }
      }
    }
  }

  // revenuecat_webhook_logs has no foreign key either, but it holds billing records that are
  // retained for accounting purposes, so it is pseudonymized rather than deleted. The pseudonym
  // is a SHA-256 digest of the user id: deterministic, so rows still group per (former) user,
  // but not reversible back to the id.
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(userId))
  const pseudonym = 'anon_' + Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('')

  const { error: pseudonymError } = await adminClient.rpc('pseudonymize_revenuecat_logs', {
    p_user_id: userId,
    p_pseudonym: pseudonym,
  })
  if (pseudonymError) {
    console.log('pseudonymize_revenuecat_logs error:', pseudonymError.message)
    failures.push(`revenuecat_webhook_logs: ${pseudonymError.message}`)
  }

  // Stop before removing the auth user. Deleting it now would report success while leaving
  // identifiable rows behind, and without the auth record the caller could not retry knowingly.
  // Leaving the account intact keeps the request safely repeatable.
  if (failures.length > 0) {
    return new Response(
      JSON.stringify({ error: 'Account not deleted: cleanup failed', details: failures }),
      { headers: { 'Content-Type': 'application/json' }, status: 500 },
    )
  }

  const { error: deleteError } = await adminClient.auth.admin.deleteUser(userId)
  if (deleteError) {
    console.log('deleteUser error', deleteError)
    return new Response(deleteError.message ?? 'deleteUser failed', { status: 500 })
  }

  return new Response(JSON.stringify({ status: 'deleted' }), {
    headers: { 'Content-Type': 'application/json' },
    status: 200,
  })
}))
