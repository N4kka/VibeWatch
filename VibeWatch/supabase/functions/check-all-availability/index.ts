import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

console.log('🚀 check-all-availability function booting up...')

serve(async (_req) => {
  try {
    // Create a Supabase client with the service role key
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
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

    if (!alerts || alerts.length === 0) {
        const message = "No active release alerts found. Nothing to check.";
        console.log(message);
        return new Response(JSON.stringify({ message }), {
            headers: { 'Content-Type': 'application/json' },
            status: 200,
        });
    }

    // 2. De-duplicate to get a unique list of media items to check
    const uniqueMedia = new Map<string, { mediaId: number; mediaType: string }>();
    alerts.forEach(alert => {
        const key = `${alert.media_type}:${alert.media_id}`;
        if (!uniqueMedia.has(key)) {
            uniqueMedia.set(key, { mediaId: alert.media_id, mediaType: alert.media_type });
        }
    });

    const mediaToCheck = Array.from(uniqueMedia.values());
    console.log(`Found ${alerts.length} total alerts, corresponding to ${mediaToCheck.length} unique media items.`);

    // 3. Sequentially invoke the 'check-availability' function for each item
    // We do this sequentially to avoid rate-limiting and overwhelming the system.
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');

    for (const item of mediaToCheck) {
        console.log(`🎬 Invoking check-availability for ${item.mediaType} ID: ${item.mediaId}`);
        
        try {
            const response = await fetch(`${supabaseUrl}/functions/v1/check-availability`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': `Bearer ${serviceRoleKey}`,
                },
                body: JSON.stringify({
                    mediaId: item.mediaId,
                    mediaType: item.mediaType,
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
            console.error(`   -> Network error invoking check-availability for ${item.mediaType}:${item.mediaId}:`, e.message);
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
    console.error('❌ An error occurred:', error.message)
    
    return new Response(JSON.stringify({ error: error.message }), {
      headers: { 'Content-Type': 'application/json' },
      status: 500,
    })
  }
})
