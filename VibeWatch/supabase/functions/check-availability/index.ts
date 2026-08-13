// One title, one country: "has it landed on a platform since we last looked?"
//
// The check itself lives in _shared/availability.ts, shared with the daily sweep. What is left
// here is the endpoint: parse the request, run the check, report. `countryCode` used to be
// hardcoded to 'IT' inside the logic — it is now part of the request, defaulted to IT so a caller
// that predates the parameter behaves exactly as before.

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { rejectIfNotServiceCaller } from '../_shared/cronAuth.ts'
import { checkTitleAvailability } from '../_shared/availability.ts'

const TMDB_API_KEY = Deno.env.get('TMDB_API_KEY')!

serve(async (req) => {
  // Cron/service callers only: this used to run for anyone holding the app's publishable
  // key. See _shared/cronAuth.ts.
  const unauthorized = rejectIfNotServiceCaller(req)
  if (unauthorized) return unauthorized

  try {
    const { mediaId, mediaType, countryCode } = await req.json()

    if (!mediaId || !mediaType) {
      return new Response(JSON.stringify({ error: 'mediaId and mediaType are required' }), {
        headers: { 'Content-Type': 'application/json' },
        status: 400,
      })
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      // Prefer the new secret key, fall back to the legacy service_role during migration.
      (() => {
        const s = Deno.env.get('SUPABASE_SECRET_KEYS')
        if (s) { try { const k = JSON.parse(s)?.default; if (k) return k as string } catch { /* fall back */ } }
        return Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
      })()
    )

    const outcome = await checkTitleAvailability(supabase, {
      mediaId: Number(mediaId),
      mediaType: String(mediaType),
      countryCode: String(countryCode ?? 'IT').toUpperCase(),
      tmdbApiKey: TMDB_API_KEY,
    })

    return new Response(JSON.stringify(outcome), {
      headers: { 'Content-Type': 'application/json' },
    })
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    return new Response(JSON.stringify({ error: message }), {
      headers: { 'Content-Type': 'application/json' },
      status: 500,
    })
  }
})
