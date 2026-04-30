import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { SignJWT, importPKCS8 } from 'https://esm.sh/jose@v5.2.3'

// Log the function's startup for debugging
console.log('🚀 process-notifications function booting up...')

// --- Firebase Push Notification Logic ---

// Helper function to get a Google API access token using 'jose' library
async function getFirebaseAccessToken(serviceAccount: any) {
  console.log("Requesting Firebase access token using 'jose'...");

  const privateKey = serviceAccount.private_key.replace(/\\n/g, '\n');
  const privateKeyObject = await importPKCS8(privateKey, 'RS256');

  // The main claims for the JWT.
  const claims = {
    iss: serviceAccount.client_email,
    sub: serviceAccount.client_email,
    aud: 'https://oauth2.googleapis.com/token',
    scope: 'https://www.googleapis.com/auth/cloud-platform',
  };

  // Create and sign the JWT.
  const jwt = await new SignJWT(claims)
    .setProtectedHeader({ alg: 'RS256', typ: 'JWT' })
    .setIssuedAt()
    .setExpirationTime('1h')
    .sign(privateKeyObject);

  // Exchange the JWT for a Google OAuth2 access token.
  const response = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: jwt,
    }),
  });

  if (!response.ok) {
    const errorText = await response.text();
    console.error("Raw error response from Google OAuth:", errorText);
    throw new Error(`Failed to get access token: ${response.status} ${response.statusText}`);
  }

  const data = await response.json();
  console.log("✅ Firebase access token obtained.");
  return data.access_token;
}

async function sendPushNotification(
  supabaseClient: SupabaseClient,
  notification: any,
  accessToken: string,
  projectId: string
) {
  console.log(`Preparing to send push for user ${notification.user_id}`);
  // 1. Get user's device tokens
  const { data: devices, error: deviceError } = await supabaseClient
    .from('user_devices')
    .select('fcm_token')
    .eq('user_id', notification.user_id)

  if (deviceError) {
    console.error(`Error fetching devices for user ${notification.user_id}:`, deviceError)
    return
  }

  if (!devices || devices.length === 0) {
    console.log(`No devices found for user ${notification.user_id}. Skipping push.`)
    return
  }

  // 2. Send a notification to each device
  for (const device of devices) {
    const fcmToken = device.fcm_token
    console.log(`Sending push to token: ...${fcmToken.slice(-10)}`);
    const message = {
      message: {
        token: fcmToken,
        notification: {
          title: notification.title,
          body: notification.body,
        },
        data: {
          media_id: String(notification.media_id),
          media_type: notification.media_type,
        },
        apns: {
          payload: {
            aps: {
              'sound': 'default',
              'badge': 1,
            },
          },
        },
      },
    }

    const fcmUrl = `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`

    const response = await fetch(fcmUrl, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${accessToken}`,
      },
      body: JSON.stringify(message),
    })

    if (!response.ok) {
      const errorText = await response.text();
      console.error(`Raw error response from FCM for token ...${fcmToken.slice(-10)}:`, errorText);
    } else {
      console.log(`✅ Push notification sent successfully to token: ...${fcmToken.slice(-10)}`)
    }
  }
}

// --- APNs Direct Push (Phase 8) ---

async function getAPNsJWT(keyBase64: string, keyId: string, teamId: string): Promise<string> {
  const keyPem = atob(keyBase64);
  const privateKey = await importPKCS8(keyPem, 'ES256');

  const jwt = await new SignJWT({})
    .setProtectedHeader({ alg: 'ES256', kid: keyId })
    .setIssuer(teamId)
    .setIssuedAt()
    .sign(privateKey);

  return jwt;
}

async function sendAPNsPush(
  supabaseClient: SupabaseClient,
  notification: any,
  apnsJWT: string,
  bundleId: string
) {
  console.log(`[APNs] Preparing to send APNs push for user ${notification.user_id}`);

  // 1. Get user's APNs device tokens from device_tokens table
  const { data: tokens, error: tokenError } = await supabaseClient
    .from('device_tokens')
    .select('token')
    .eq('user_id', notification.user_id)
    .eq('platform', 'ios');

  if (tokenError) {
    console.error(`[APNs] Error fetching device tokens for user ${notification.user_id}:`, tokenError);
    return;
  }

  if (!tokens || tokens.length === 0) {
    console.log(`[APNs] No APNs device tokens found for user ${notification.user_id}. Skipping.`);
    return;
  }

  const notificationId = crypto.randomUUID();
  const payload = {
    aps: {
      alert: {
        title: notification.title,
        body: notification.body,
      },
      sound: 'default',
      badge: 1,
    },
    // Custom data for deep linking
    media_id: String(notification.media_id ?? ''),
    media_type: notification.media_type ?? '',
    notification_id: notificationId,
  };

  // 2. Send to each device token
  for (const row of tokens) {
    const deviceToken = row.token;
    const apnsUrl = `https://api.push.apple.com/3/device/${deviceToken}`;

    console.log(`[APNs] Sending push to token: ...${deviceToken.slice(-10)}`);

    try {
      const response = await fetch(apnsUrl, {
        method: 'POST',
        headers: {
          'authorization': `bearer ${apnsJWT}`,
          'apns-topic': bundleId,
          'apns-push-type': 'alert',
          'apns-priority': '10',
          'apns-expiration': '0',
          'content-type': 'application/json',
        },
        body: JSON.stringify(payload),
      });

      if (!response.ok) {
        const errorBody = await response.text();
        console.error(`[APNs] Push failed for token ...${deviceToken.slice(-10)}: ${response.status} ${errorBody}`);
      } else {
        console.log(`[APNs] ✅ Push sent successfully to token: ...${deviceToken.slice(-10)}`);
      }
    } catch (err) {
      console.error(`[APNs] Network error sending to token ...${deviceToken.slice(-10)}:`, err);
    }
  }

  // 3. Record remote notification event for dedup
  const { error: insertError } = await supabaseClient
    .from('notification_events_remote')
    .insert({
      notification_id: notificationId,
      user_id: notification.user_id,
      content_type: notification.media_type ?? 'unknown',
      content_id: String(notification.media_id ?? ''),
      channel: 'remote_push',
      title: notification.title,
      body: notification.body,
      payload: {
        media_id: notification.media_id,
        media_type: notification.media_type,
      },
      sent_at: new Date().toISOString(),
    });

  if (insertError) {
    console.error(`[APNs] Failed to record remote notification event:`, insertError);
  }
}

// --- Resend Email Logic ---

async function sendEmail(
  supabaseClient: SupabaseClient,
  notification: any,
  resendApiKey: string,
  fromEmail: string
) {
  console.log(`Preparing to send email for user ${notification.user_id}`);
  // 1. Get user's email address
  const { data: { user }, error: userError } = await supabaseClient.auth.admin.getUserById(notification.user_id)

  if (userError || !user || !user.email) {
    console.error(`Error fetching email for user ${notification.user_id}:`, userError?.message || 'User not found')
    return
  }
  
  const recipientEmail = user.email;
  console.log(`Sending email to ...${recipientEmail.slice(recipientEmail.indexOf('@'))}`);

  // 2. Construct and send the email
  const emailPayload = {
    from: fromEmail,
    to: recipientEmail,
    subject: notification.title,
    html: `
      <!DOCTYPE html>
      <html>
      <head>
        <style>
          body { font-family: sans-serif; color: #333; }
          .container { padding: 20px; border: 1px solid #eee; border-radius: 5px; max-width: 600px; margin: auto; }
          h1 { color: #000; }
        </style>
      </head>
      <body>
        <div class="container">
          <h1>${notification.title}</h1>
          <p>${notification.body}</p>
          <p>Log in to VibeWatch to see more.</p>
        </div>
      </body>
      </html>
    `,
  };

  const response = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${resendApiKey}`,
    },
    body: JSON.stringify(emailPayload),
  })

  if (!response.ok) {
    const errorText = await response.text();
    console.error(`Raw error response from Resend for email ${recipientEmail}:`, errorText);
  } else {
    console.log(`✅ Email sent successfully to ...${recipientEmail.slice(recipientEmail.indexOf('@'))}`)
  }
}


// Main function to handle incoming requests
serve(async (_req) => {
  try {
    // --- 1. SET UP CLIENTS AND GET SECRETS ---
    
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )
    
    const firebaseServiceAccountJson = Deno.env.get('FIREBASE_SERVICE_ACCOUNT')
    const resendApiKey = Deno.env.get('RESEND_API_KEY')
    const fromEmail = Deno.env.get('FROM_EMAIL')

    // Phase 8: APNs secrets (optional — when set, APNs direct push is enabled)
    const apnsKeyBase64 = Deno.env.get('APNS_KEY_BASE64')
    const apnsKeyId = Deno.env.get('APNS_KEY_ID')
    const apnsTeamId = Deno.env.get('APNS_TEAM_ID')
    const apnsBundleId = Deno.env.get('APNS_BUNDLE_ID') ?? 'com.vibewatch.VibeWatchApp'
    const apnsEnabled = !!(apnsKeyBase64 && apnsKeyId && apnsTeamId)

    if (!firebaseServiceAccountJson || !resendApiKey || !fromEmail) {
        throw new Error("Missing required environment variables/secrets.")
    }
    const firebaseServiceAccount = JSON.parse(firebaseServiceAccountJson)
    console.log(`✅ Secrets and clients configured. APNs direct push: ${apnsEnabled ? 'ENABLED' : 'disabled (secrets missing)'}`)

    // --- 2. FETCH PENDING NOTIFICATIONS ---
    const { data: notifications, error: fetchError } = await supabaseClient
      .from('notifications')
      .select('*')
      .eq('is_sent', false)
      .limit(100)

    if (fetchError) {
      throw new Error(`Error fetching notifications: ${fetchError.message}`)
    }

    if (!notifications || notifications.length === 0) {
      const message = "No pending notifications to process."
      console.log(`✅ ${message}`)
      return new Response(JSON.stringify({ message }), {
        headers: { 'Content-Type': 'application/json' },
      })
    }
    
    console.log(`Found ${notifications.length} pending notifications to process.`)

    // --- 3. PROCESS NOTIFICATIONS ---
    const firebaseAccessToken = await getFirebaseAccessToken(firebaseServiceAccount)
    let apnsJWT: string | null = null
    if (apnsEnabled) {
      apnsJWT = await getAPNsJWT(apnsKeyBase64!, apnsKeyId!, apnsTeamId!)
      console.log('✅ APNs JWT generated for direct push.')
    }

    const processedNotificationIds = []

    for (const notification of notifications) {
        console.log(`Processing notification ID: ${notification.id} for user: ${notification.user_id}`)

        // Check dedup: skip if already sent for this content
        if (notification.media_id) {
          const { data: existing } = await supabaseClient
            .from('notification_events_remote')
            .select('notification_id')
            .eq('user_id', notification.user_id)
            .eq('content_type', notification.media_type ?? 'unknown')
            .eq('content_id', String(notification.media_id))
            .limit(1)

          if (existing && existing.length > 0) {
            console.log(`⏭️ Skipping notification ${notification.id} — already sent for ${notification.media_type}:${notification.media_id}`)
            processedNotificationIds.push(notification.id)
            continue
          }
        }

        // Send via FCM (Firebase)
        await sendPushNotification(supabaseClient, notification, firebaseAccessToken, firebaseServiceAccount.project_id)

        // Send via APNs direct push (Phase 8) if configured
        if (apnsJWT) {
          await sendAPNsPush(supabaseClient, notification, apnsJWT, apnsBundleId)
        }
        
        // Send Email
        await sendEmail(supabaseClient, notification, resendApiKey, fromEmail)

        processedNotificationIds.push(notification.id)
    }

    // --- 4. MARK NOTIFICATIONS AS SENT ---
    if (processedNotificationIds.length > 0) {
        console.log(`Marking ${processedNotificationIds.length} notifications as sent.`)
        const { error: updateError } = await supabaseClient
            .from('notifications')
            .update({ is_sent: true, sent_at: new Date().toISOString() })
            .in('id', processedNotificationIds)
        
        if (updateError) {
            console.error('Error marking notifications as sent:', updateError.message)
            // Note: In a real-world scenario, you might want more robust error handling here,
            // as this could lead to re-sending notifications. For now, we just log it.
        }
    }

    const responseMessage = `Function executed. Processed ${notifications.length} notifications.`
    console.log(responseMessage)

    // Return a success response
    return new Response(JSON.stringify({ message: responseMessage }), {
      headers: { 'Content-Type': 'application/json' },
      status: 200,
    })

  } catch (error) {
    // Enhanced error logging
    console.error('❌ An unhandled error occurred. Full error object:', error);

    let errorMessage = 'An unknown error occurred.';
    if (error instanceof Error) {
        errorMessage = error.message;
    } else if (typeof error === 'string') {
        errorMessage = error;
    } else if (typeof error === 'object' && error !== null) {
        errorMessage = JSON.stringify(error);
    }

    console.error('❌ Parsed error message:', errorMessage);
    
    // Return a more informative error response
    return new Response(JSON.stringify({ error: `Caught an exception: ${errorMessage}` }), {
      headers: { 'Content-Type': 'application/json' },
      status: 500,
    })
  }
})
