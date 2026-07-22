// @ts-nocheck
import { serve } from 'https://deno.land/std@0.177.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.8'

serve(async (req) => {
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
  // auth.admin.deleteUser below clears them. These do not: user_daily_quota, user_clip_history
  // and user_preferences have no foreign key at all, and profiles references auth.users with
  // NO ACTION — which also means it has to go before the auth user, or that delete is rejected.
  // (user_ai_token_usage and user_clip_signals cascade from profiles.)
  const failures: string[] = []

  const tables = ['user_daily_quota', 'user_ai_token_usage', 'user_clip_history', 'user_preferences', 'profiles']
  for (const table of tables) {
    const { error } = await adminClient.from(table).delete().eq(table === 'profiles' ? 'id' : 'user_id', userId)
    if (error) {
      console.log(`Cleanup error for ${table}:`, error.message)
      failures.push(`${table}: ${error.message}`)
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
})
