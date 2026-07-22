import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

console.log('🚀 check-all-availability function booting up...')

serve(async (_req) => {
  try {
    // Create a Supabase client with the service role key
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      // Prefer the new secret key, fall back to the legacy service_role during migration.
      (() => {
        const s = Deno.env.get('SUPABASE_SECRET_KEYS')
        if (s) { try { const k = JSON.parse(s)?.default; if (k) return k as string } catch { /* fall back */ } }
        return Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
      })()
    )

    console.log('✅ Supabase client initialized.');

    // 1. Fetch all active release alerts
    const { data: alerts, error } = await supabaseClient
      .from('release_alerts')
      .select('media_id, media_type')
      .eq('is_active', true);

    if (error) {
      throw new Error(`Failed to fetch release alerts: ${error.message}`);
    }

    const ninetyDaysAgo = new Date(Date.now() - 90 * 24 * 60 * 60 * 1000).toISOString();
    const { data: listItems, error: listItemsError } = await supabaseClient
      .from('list_items')
      .select('media_id, media_type')
      .is('deleted_at', null)
      .gte('added_at', ninetyDaysAgo);

    if (listItemsError) {
      throw new Error(`Failed to fetch list items: ${listItemsError.message}`);
    }

    // 2. De-duplicate to get a unique list of media items to check
    const uniqueMedia = new Map<string, { mediaId: number; mediaType: string; listCount: number }>();
    alerts?.forEach(alert => {
        const key = `${alert.media_type}:${alert.media_id}`;
        if (!uniqueMedia.has(key)) {
            uniqueMedia.set(key, { mediaId: alert.media_id, mediaType: alert.media_type, listCount: 0 });
        }
    });

    listItems?.forEach(item => {
      const key = `${item.media_type}:${item.media_id}`;
      const existing = uniqueMedia.get(key);
      if (existing) {
        existing.listCount += 1;
      } else {
        uniqueMedia.set(key, { mediaId: item.media_id, mediaType: item.media_type, listCount: 1 });
      }
    });

    const mediaToCheck = Array.from(uniqueMedia.values());
    if (mediaToCheck.length === 0) {
        const message = "No active release alerts or recent list items found. Nothing to check.";
        console.log(message);
        return new Response(JSON.stringify({ message }), {
            headers: { 'Content-Type': 'application/json' },
            status: 200,
        });
    }

    console.log(`Found ${alerts?.length ?? 0} total alerts and ${listItems?.length ?? 0} recent list items, corresponding to ${mediaToCheck.length} unique media items.`);

    // 3. Sequentially invoke the 'check-availability' function for each item
    // We do this sequentially to avoid rate-limiting and overwhelming the system.
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    // Prefer the new secret key, fall back to the legacy service_role during migration.
    const serviceRoleKey = (() => {
      const s = Deno.env.get('SUPABASE_SECRET_KEYS')
      if (s) { try { const k = JSON.parse(s)?.default; if (k) return k as string } catch { /* fall back */ } }
      return Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    })()

    for (const item of mediaToCheck) {
        console.log(`🎬 Invoking check-availability for ${item.mediaType} ID: ${item.mediaId}`);
        
        try {
            const response = await fetch(`${supabaseUrl}/functions/v1/check-availability`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    // New sb_secret keys must travel on the apikey header (they are not JWTs).
                    // Authorization kept for the legacy transition window. NOTE: the target
                    // `check-availability` must have verify_jwt=false once legacy keys are disabled.
                    'apikey': serviceRoleKey,
                    'Authorization': `Bearer ${serviceRoleKey}`,
                },
                body: JSON.stringify({
                    mediaId: item.mediaId,
                    mediaType: item.mediaType,
                    priority: item.listCount >= 5 ? 'high' : 'normal',
                }),
            });

            if (!response.ok) {
                const errorText = await response.text();
                console.error(`   -> Failed to invoke check-availability for ${item.mediaType}:${item.mediaId}. Status: ${response.status}. Error: ${errorText}`);
            } else {
                const result = await response.json();
                console.log(`   -> Successfully invoked: ${result.message}`);
            }
        } catch (e) {
            const message = e instanceof Error ? e.message : String(e);
            console.error(`   -> Network error invoking check-availability for ${item.mediaType}:${item.mediaId}:`, message);
        }
        
        // Add a small delay between invocations to be considerate to external APIs
        await new Promise(resolve => setTimeout(resolve, 500)); // 500ms delay
    }

    const responseMessage = `Function executed. Invoked availability check for ${mediaToCheck.length} unique media items.`
    console.log(responseMessage)

    return new Response(JSON.stringify({ message: responseMessage }), {
      headers: { 'Content-Type': 'application/json' },
      status: 200,
    })

  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    console.error('❌ An error occurred:', message)
    
    return new Response(JSON.stringify({ error: message }), {
      headers: { 'Content-Type': 'application/json' },
      status: 500,
    })
  }
})
