import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { rejectIfNotServiceCaller } from '../_shared/cronAuth.ts'

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

serve(async (req) => {
  // Cron/service callers only: this used to run for anyone holding the app's publishable
  // key. See _shared/cronAuth.ts.
  const unauthorized = rejectIfNotServiceCaller(req)
  if (unauthorized) return unauthorized

  try {
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)
    const today = new Date().toISOString().slice(0, 10)

    // Opt-in list first. This used to queue a row for every user with a live streak — 1701 rows
    // in a month, ~92% of everything the system produced — and the dispatcher then dropped most
    // of them against the preference gate. Rows nobody wants are cheaper never enqueued: the
    // queue stays readable, and one loud producer can no longer push real news into a digest.
    const { data: optedIn, error: prefsError } = await supabase
      .from('user_notification_preferences')
      .select('user_id')
      .eq('streak_reminder', true)
      .eq('push_enabled', true)

    if (prefsError) throw prefsError

    const wanted = (optedIn ?? []).map((row: { user_id: string }) => row.user_id)
    if (wanted.length === 0) {
      return new Response(JSON.stringify({ created: 0, optedIn: 0 }), {
        headers: { 'Content-Type': 'application/json' },
        status: 200,
      })
    }

    const { data: users, error } = await supabase
      .from('user_gamification')
      .select('user_id, current_streak, last_activity_date')
      .in('user_id', wanted)
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
          // English fallback; the dispatcher renders template_key in the user's language.
          title: 'Keep your streak',
          body: `Your ${user.current_streak}-day streak is waiting.`,
          is_sent: false,
          category: 'streak_reminder',
          thread_id: 'streak',
          template_key: 'streak_reminder',
          template_params: { days: user.current_streak },
        })

      if (!insertError) created += 1
    }

    return new Response(JSON.stringify({ created, optedIn: wanted.length }), {
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
