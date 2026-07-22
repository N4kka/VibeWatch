import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''

// Prefer the new secret key (sb_secret_..., auto-injected as SUPABASE_SECRET_KEYS json),
// falling back to the legacy service_role during the migration window. Once the legacy
// JWT-based keys are disabled, only the new secret key remains valid.
function getSupabaseServiceKey(): string {
  const secretKeys = Deno.env.get('SUPABASE_SECRET_KEYS')
  if (secretKeys) {
    try {
      const parsed = JSON.parse(secretKeys)
      if (parsed?.default) return parsed.default as string
    } catch {
      // malformed json → fall back to legacy below
    }
  }
  return Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
}

const SUPABASE_SERVICE_ROLE_KEY = getSupabaseServiceKey()

serve(async () => {
  try {
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)
    const today = new Date().toISOString().slice(0, 10)

    const { data: users, error } = await supabase
      .from('user_gamification')
      .select('user_id, current_streak, last_activity_date')
      .gt('current_streak', 0)
      .or(`last_activity_date.is.null,last_activity_date.neq.${today}`)

    if (error) throw error

    let created = 0
    for (const user of users ?? []) {
      const { error: insertError } = await supabase
        .from('notifications')
        .insert({
          user_id: user.user_id,
          notification_type: 'streak_reminder',
          title: 'Keep your streak',
          body: `Your ${user.current_streak}-day streak is waiting.`,
          is_sent: false,
          category: 'streak_reminder',
          thread_id: 'streak',
        })

      if (!insertError) created += 1
    }

    return new Response(JSON.stringify({ created }), {
      headers: { 'Content-Type': 'application/json' },
      status: 200,
    })
  } catch (error) {
    return new Response(JSON.stringify({ error: error instanceof Error ? error.message : String(error) }), {
      headers: { 'Content-Type': 'application/json' },
      status: 500,
    })
  }
})
