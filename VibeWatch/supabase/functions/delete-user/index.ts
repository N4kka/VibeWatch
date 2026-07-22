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

  // Clean up dependent rows first to avoid FK constraints
  const tables = ['user_daily_quota', 'user_ai_token_usage', 'user_clip_history', 'user_preferences', 'profiles']
  for (const table of tables) {
    const { error } = await adminClient.from(table).delete().eq(table === 'profiles' ? 'id' : 'user_id', userId)
    if (error) console.log(`Cleanup error for ${table}:`, error.message)
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
