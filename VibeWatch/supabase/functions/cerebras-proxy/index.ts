import { serve } from 'https://deno.land/std@0.131.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import {
  dailyLimitForTier,
  hasReachedDailyLimit,
  requestBodyForCerebras,
  usageCountForToday,
  usageDayKey,
} from './quota.ts'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? ''
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
const CEREBRAS_API_KEY = Deno.env.get('CEREBRAS_API_KEY') ?? ''
const CEREBRAS_ENDPOINT = 'https://api.cerebras.ai/v1/chat/completions'

type SupabaseAdminClient = any

function jsonResponse(body: Record<string, unknown>, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

async function isProUser(adminSupabase: SupabaseAdminClient, userId: string): Promise<boolean> {
  try {
    const { data, error } = await adminSupabase
      .from('user_daily_quota')
      .select('is_pro, updated_at')
      .eq('user_id', userId)
      .order('updated_at', { ascending: false })
      .limit(1)

    if (error) {
      console.warn('Failed to read Pro status:', error.message)
      return false
    }

    return data?.[0]?.is_pro === true
  } catch (error) {
    console.warn('Failed to read Pro status:', error)
    return false
  }
}

async function requestsUsedToday(
  adminSupabase: SupabaseAdminClient,
  userId: string,
  todayKey: string,
): Promise<number> {
  try {
    const { data, error } = await adminSupabase
      .from('user_ai_token_usage')
      .select('total_tokens_used, usage_date, last_updated')
      .eq('user_id', userId)
      .limit(1)

    if (error) {
      console.warn('Failed to read AI request usage:', error.message)
      return 0
    }

    return usageCountForToday(data?.[0] ?? null, todayKey)
  } catch (error) {
    console.warn('Failed to read AI request usage:', error)
  }

  try {
    const { data, error } = await adminSupabase.rpc('get_ai_token_usage', {
      p_user_id: userId,
    })
    if (!error && typeof data === 'number') {
      return data
    }
  } catch (_) {
    // Ignore: quota should fail open if both tracking paths are unavailable.
  }

  return 0
}

async function recordSuccessfulRequest(
  adminSupabase: SupabaseAdminClient,
  userId: string,
  previousUsage: number,
  todayKey: string,
) {
  const now = new Date().toISOString()
  const { error } = await adminSupabase
    .from('user_ai_token_usage')
    .upsert({
      user_id: userId,
      total_tokens_used: previousUsage + 1,
      usage_date: todayKey,
      last_updated: now,
    }, { onConflict: 'user_id' })

  if (!error) return
  console.warn('Direct AI request usage upsert failed:', error.message)

  try {
    const { error: rpcError } = await adminSupabase.rpc('log_ai_token_usage', {
      p_user_id: userId,
      p_tokens_consumed: 1,
    })
    if (rpcError) {
      console.warn('RPC AI request usage logging failed:', rpcError.message)
    }
  } catch (rpcError) {
    console.warn('RPC AI request usage logging failed:', rpcError)
  }
}

serve(async (req) => {
  try {
    // 1. Require Authorization header
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) {
      return jsonResponse({ error: 'Missing Authorization header' }, 401)
    }

    // 2. Verify JWT — creates per-request client carrying the caller's token
    const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: authHeader } }
    })
    const token = authHeader.replace('Bearer ', '')
    const { data: { user }, error: authError } = await supabase.auth.getUser(token)
    if (authError || !user) {
      return jsonResponse({ error: 'Invalid or expired session' }, 401)
    }

    if (!CEREBRAS_API_KEY) {
      return jsonResponse({ error: 'Cerebras API key is not configured' }, 500)
    }

    if (!SUPABASE_SERVICE_ROLE_KEY) {
      return jsonResponse({ error: 'Supabase service role key is not configured' }, 500)
    }

    const adminSupabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)
    const todayKey = usageDayKey()
    const isPro = await isProUser(adminSupabase, user.id)
    const usedToday = await requestsUsedToday(adminSupabase, user.id, todayKey)
    const dailyLimit = dailyLimitForTier(isPro)

    if (hasReachedDailyLimit(usedToday, isPro)) {
      return jsonResponse({
        error: 'Daily AI request limit reached',
        requestsUsedToday: usedToday,
        dailyLimit,
        isPro,
      }, 429)
    }

    // 3. Forward request to Cerebras with gateway-owned model selection.
    const body = await req.text()
    let cerebrasBody: string
    try {
      cerebrasBody = JSON.stringify(requestBodyForCerebras(body))
    } catch (_) {
      return jsonResponse({ error: 'Invalid JSON request body' }, 400)
    }

    const cerebrasResp = await fetch(CEREBRAS_ENDPOINT, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${CEREBRAS_API_KEY}`,
        'Content-Type': 'application/json'
      },
      body: cerebrasBody
    })

    const respBody = await cerebrasResp.text()

    if (!cerebrasResp.ok) {
      return jsonResponse({
        error: 'Cerebras request failed',
        status: cerebrasResp.status,
        details: respBody,
      }, cerebrasResp.status)
    }

    // 4. Count one successful chatbot request.
    await recordSuccessfulRequest(adminSupabase, user.id, usedToday, todayKey)

    // 5. Return raw Cerebras response.
    return new Response(respBody, {
      status: cerebrasResp.status,
      headers: { 'Content-Type': 'application/json' }
    })
  } catch (error) {
    console.error('cerebras-proxy error:', error)
    return jsonResponse({ error: 'Internal server error' }, 500)
  }
})
