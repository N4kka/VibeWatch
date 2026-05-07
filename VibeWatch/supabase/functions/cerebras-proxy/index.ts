import { serve } from 'https://deno.land/std@0.131.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? ''
const CEREBRAS_API_KEY = Deno.env.get('CEREBRAS_API_KEY') ?? ''
const CEREBRAS_ENDPOINT = 'https://api.cerebras.ai/v1/chat/completions'

serve(async (req) => {
  try {
    // 1. Require Authorization header
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) {
      return new Response(JSON.stringify({ error: 'Missing Authorization header' }), {
        status: 401,
        headers: { 'Content-Type': 'application/json' }
      })
    }

    // 2. Verify JWT — creates per-request client carrying the caller's token
    const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: authHeader } }
    })
    const token = authHeader.replace('Bearer ', '')
    const { data: { user }, error: authError } = await supabase.auth.getUser(token)
    if (authError || !user) {
      return new Response(JSON.stringify({ error: 'Invalid or expired session' }), {
        status: 401,
        headers: { 'Content-Type': 'application/json' }
      })
    }

    // 3. Forward the raw request body to Cerebras unchanged
    const body = await req.text()
    const cerebrasResp = await fetch(CEREBRAS_ENDPOINT, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${CEREBRAS_API_KEY}`,
        'Content-Type': 'application/json'
      },
      body
    })

    // 4. Log token usage (best-effort — parse usage from Cerebras response clone)
    try {
      const respClone = cerebrasResp.clone()
      const respJson = await respClone.json()
      const tokensConsumed = respJson?.usage?.total_tokens ?? 0
      if (tokensConsumed > 0) {
        // Use service role key for RPC — separate admin client with elevated permissions
        const adminSupabase = createClient(
          SUPABASE_URL,
          Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
        )
        await adminSupabase.rpc('log_ai_token_usage', {
          p_user_id: user.id,
          p_tokens_consumed: tokensConsumed
        })
      }
    } catch (_) {
      // Non-fatal: quota tracking failure must not block AI response
    }

    // 5. Return raw Cerebras response
    const respBody = await cerebrasResp.text()
    return new Response(respBody, {
      status: cerebrasResp.status,
      headers: { 'Content-Type': 'application/json' }
    })
  } catch (_) {
    return new Response(JSON.stringify({ error: 'Internal server error' }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' }
    })
  }
})
